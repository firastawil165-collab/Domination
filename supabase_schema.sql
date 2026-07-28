-- Domination — Supabase schema (Phase 1: accounts, + foundation for Phase 2/3)
-- Run this in Supabase Dashboard -> SQL Editor -> New query -> paste -> Run.
-- Safe to re-run: uses IF NOT EXISTS / CREATE OR REPLACE throughout.

-- ============ profiles ============
-- One row per signed-up player, keyed to Supabase's built-in auth.users.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

-- Anyone (including signed-out visitors) can read profiles — needed later so
-- players can see opponents' names in a lobby/match.
drop policy if exists "profiles are publicly readable" on public.profiles;
create policy "profiles are publicly readable"
  on public.profiles for select
  using (true);

-- A user can only edit their own profile row.
drop policy if exists "users can update own profile" on public.profiles;
create policy "users can update own profile"
  on public.profiles for update
  using (auth.uid() = id);

-- Auto-create a profile row whenever someone signs up.
create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id) values (new.id);
  return new;
end;
$$ language plpgsql security definer set search_path = public;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();


-- ============ lobbies ============
-- Phase 2 groundwork: a lobby is a match that hasn't started yet. Not wired
-- into the game UI yet — this just gets the table ready.
create table if not exists public.lobbies (
  id uuid primary key default gen_random_uuid(),
  host_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'waiting' check (status in ('waiting', 'starting', 'in_progress', 'closed')),
  mode text not null default 'ffa' check (mode in ('ffa', '2v2')),
  max_players int not null default 2,
  created_at timestamptz not null default now()
);

alter table public.lobbies enable row level security;

drop policy if exists "lobbies are publicly readable" on public.lobbies;
create policy "lobbies are publicly readable"
  on public.lobbies for select
  using (true);

drop policy if exists "signed-in users can create lobbies" on public.lobbies;
create policy "signed-in users can create lobbies"
  on public.lobbies for insert
  with check (auth.uid() = host_id);

drop policy if exists "host can update own lobby" on public.lobbies;
create policy "host can update own lobby"
  on public.lobbies for update
  using (auth.uid() = host_id);


-- ============ lobby_players ============
-- Who's currently sitting in a given lobby.
create table if not exists public.lobby_players (
  lobby_id uuid not null references public.lobbies(id) on delete cascade,
  player_id uuid not null references auth.users(id) on delete cascade,
  ready boolean not null default false,
  joined_at timestamptz not null default now(),
  primary key (lobby_id, player_id)
);

alter table public.lobby_players enable row level security;

drop policy if exists "lobby_players are publicly readable" on public.lobby_players;
create policy "lobby_players are publicly readable"
  on public.lobby_players for select
  using (true);

drop policy if exists "users can join as themselves" on public.lobby_players;
create policy "users can join as themselves"
  on public.lobby_players for insert
  with check (auth.uid() = player_id);

drop policy if exists "users can update own ready state" on public.lobby_players;
create policy "users can update own ready state"
  on public.lobby_players for update
  using (auth.uid() = player_id);

drop policy if exists "users can leave lobbies" on public.lobby_players;
create policy "users can leave lobbies"
  on public.lobby_players for delete
  using (auth.uid() = player_id);


-- ============ matches ============
-- Phase 3 groundwork: a started game. In the host-authoritative design, this
-- mostly just records who played and the outcome — the live game state itself
-- travels over a Supabase Realtime channel, not this table, to avoid database
-- write latency in the middle of gameplay.
create table if not exists public.matches (
  id uuid primary key default gen_random_uuid(),
  lobby_id uuid references public.lobbies(id) on delete set null,
  host_id uuid not null references auth.users(id) on delete cascade,
  mode text not null,
  winner_id uuid references auth.users(id) on delete set null,
  started_at timestamptz not null default now(),
  ended_at timestamptz
);

alter table public.matches enable row level security;

drop policy if exists "matches are publicly readable" on public.matches;
create policy "matches are publicly readable"
  on public.matches for select
  using (true);

drop policy if exists "host can create matches" on public.matches;
create policy "host can create matches"
  on public.matches for insert
  with check (auth.uid() = host_id);

drop policy if exists "host can update own match" on public.matches;
create policy "host can update own match"
  on public.matches for update
  using (auth.uid() = host_id);


-- ============ server-owned match timeline (v0.261) ============
-- The fix for "a player leaves and the game freezes."
--
-- Online play runs a deterministic simulation on BOTH clients (Supabase has
-- nowhere to run a 60Hz game loop), but the two clients used to be each other's
-- clock: neither could advance a command frame until the other's inputs for it
-- arrived, so one player backgrounding the app froze the match for the player
-- still looking at it. What lives here is the missing third party — a timeline
-- that belongs to the server:
--
--   * `started_at` is a Postgres timestamp, and command frame F is defined to
--     execute at started_at + F * 100ms. That makes "what frame is the match on"
--     a question about real time rather than about who still has the app open,
--     so a match keeps aging while both players are away and whoever comes back
--     finds the troops that regenerated meanwhile.
--   * clients wait on a DEADLINE, not on each other. Past it a frame is sealed
--     with the absent player's input empty and play continues without them.
--   * `match_snapshots` is what a returning player re-anchors to when nobody is
--     live to hand them state — and what lets a match survive both players
--     closing the app entirely.
--
-- Access is deliberately open (see the policies): online play is a private room
-- reached by a 5-character code, with no sign-in, exactly as it works today. The
-- room code is the only secret, and a client that can already run the whole
-- simulation locally gains nothing from writing to these rows that it couldn't
-- do over the Realtime channel anyway. Tighten this if online ever grows a
-- ranked/public mode, where a forged snapshot would actually be worth something.

create table if not exists public.online_matches (
  id uuid primary key default gen_random_uuid(),
  room_code text not null,
  seed bigint not null,
  -- THE anchor. Every frame deadline on every device is measured from this.
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  outcome text check (outcome in ('host', 'guest')), -- who won, in canonical labeling
  -- Full initial state, canonical (host) labeling, including the per-tower
  -- Voronoi `cell` polygons. Those are static after map generation and are the
  -- heaviest thing in the state by far, so they travel exactly once — here — and
  -- every later snapshot omits them. A player rejoining after force-quitting the
  -- app rebuilds the whole board's geometry from this row.
  initial_state jsonb not null,
  created_at timestamptz not null default now()
);

create index if not exists online_matches_room_code_idx
  on public.online_matches (room_code, started_at desc);

alter table public.online_matches enable row level security;

drop policy if exists "online matches are publicly readable" on public.online_matches;
create policy "online matches are publicly readable"
  on public.online_matches for select using (true);

drop policy if exists "anyone can open an online match" on public.online_matches;
create policy "anyone can open an online match"
  on public.online_matches for insert with check (true);

drop policy if exists "anyone can close an online match" on public.online_matches;
create policy "anyone can close an online match"
  on public.online_matches for update using (true);

grant select, insert, update on public.online_matches to anon, authenticated;


-- One row per match: the most recent state either player persisted. Kept as a
-- single upserted row rather than a history — nothing needs the past, only the
-- latest point to resume from.
create table if not exists public.match_snapshots (
  match_id uuid primary key references public.online_matches(id) on delete cascade,
  frame int not null,          -- command frame this state is AT
  state jsonb not null,        -- canonical labeling, no cells (see initial_state)
  updated_at timestamptz not null default now()
);

alter table public.match_snapshots enable row level security;

drop policy if exists "snapshots are publicly readable" on public.match_snapshots;
create policy "snapshots are publicly readable"
  on public.match_snapshots for select using (true);

-- Read-only to clients: writes go exclusively through save_match_snapshot below,
-- which enforces that a newer frame can't be clobbered by an older one.
grant select on public.match_snapshots to anon, authenticated;


-- Snapshot writes must be conditional: both players persist, and a client that
-- is still fast-forwarding through a gap holds an OLD state that must never
-- overwrite a current one. PostgREST's upsert can't put a WHERE on the conflict
-- branch, so the write goes through here instead, and the newer frame always
-- wins. security definer so the open policies above don't need an insert/update
-- policy on the table at all — this function is the only way in.
create or replace function public.save_match_snapshot(p_match uuid, p_frame int, p_state jsonb)
returns void as $$
  insert into public.match_snapshots (match_id, frame, state, updated_at)
  values (p_match, p_frame, p_state, now())
  on conflict (match_id) do update
    set frame = excluded.frame,
        state = excluded.state,
        updated_at = now()
    where public.match_snapshots.frame < excluded.frame;
$$ language sql security definer set search_path = public;

grant execute on function public.save_match_snapshot(uuid, int, jsonb) to anon, authenticated;


-- The reference clock. Clients probe this a few times, keep the sample with the
-- fastest round-trip, and measure every frame deadline against it — so both
-- devices agree what time the match is on regardless of their own clocks.
create or replace function public.server_now()
returns timestamptz as $$
  select now();
$$ language sql stable;

grant execute on function public.server_now() to anon, authenticated;
