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
