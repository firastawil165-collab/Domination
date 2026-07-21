# Domination — Project Handoff

A browser-based real-time territory-conquest strategy game (in the style of State.io / Galcon),
built as a single-file React component rendered on an HTML5 canvas. Player vs. AI, with online
PvP multiplayer now in progress (see the section below).
Originally prototyped as "Towerfront"; renamed to **Domination**. Currently **v0.254**
(see `APP_VERSION` near the top of the file, shown in the bottom-right corner of the menu).

To continue in a new chat: **upload `index.html` and this file**, and say
"continue my Domination game — here's the current build and the project notes." That gives
the new session everything it needs.

**Versioning convention:** bump `APP_VERSION` by `0.001` for every change shipped, however small.

---

## Online multiplayer (in progress — Vercel + Supabase)

Goal: real accounts + matchmaking + live PvP, on top of the existing single-file game.

1. **Phase 1 (done, v0.254): accounts.** Supabase project `domination-game` created. Supabase JS
   client (`@supabase/supabase-js@2`, loaded from **jsdelivr**, not cdnjs — see note below) wired
   into `index.html`; `SUPABASE_URL` / `SUPABASE_ANON_KEY` constants near the top of the script
   block. Sign in / sign up (email+password) UI added to the menu screen — a small account pill
   under the title, opens a modal. Playing vs AI still requires no account; this is purely
   groundwork for matchmaking needing a stable player identity. Schema: `supabase_schema.sql`
   (run once in Supabase's SQL Editor) — `profiles` (auto-created on signup via trigger),
   `lobbies`, `lobby_players`, `matches`, all RLS-enabled. **Note:** the Supabase JS client
   instance is named `sb`, not `supabase` — the UMD bundle's own global is already called
   `supabase`, and `const supabase = ...` collides with it (silent SyntaxError, whole script
   dead, stuck on the boot screen — fixed in v0.255).
2. **Phase 2 (done, v0.255, scoped down): private 1v1 room.** Not the full lobby-browser/
   matchmaking system originally sketched in `supabase_schema.sql` (those tables are still
   unused) — instead, the simplest useful slice: a "Play a Friend" button on the menu opens a
   modal to Host (generates a 5-character room code) or Join (enter a code). No DB writes at
   all — a room is just an ephemeral Supabase Realtime channel named
   `domination-room-<CODE>`, torn down when either side leaves. Presence tracks when both
   players are in the channel; the host's "Start Match" button is disabled until then.
3. **Phase 3 (done, v0.255): live gameplay sync.** Host-authoritative, as planned — the host
   runs the real simulation completely unchanged (`startGame(2, "ffa")`, same as vs-AI) and
   broadcasts a full `gameRef.current` snapshot ~10x/sec over the room channel; the guest never
   simulates locally (the sim has ~30 scattered `Math.random()` calls, so two independently-
   ticking clients would desync in seconds) — its `gameRef.current` is just overwritten by
   whatever snapshot arrived most recently, and it forwards its own input (drag-orders,
   double-tap upgrades, special casts) back over the channel for the host to apply via the
   same `issueOrder`/`startUpgrade`/`CAST_FNS` functions used locally.
   - **The "always player 0" trick**: dozens of call sites across rendering/input/specials
     hardcode `owner === 0` / `g.teams[0]` to mean "the local human." Rather than thread a
     dynamic player id through all of them, the host relabels player 0<->1 in the snapshot
     it sends the guest (`remapSnapshotForGuest`/`remapHudForGuest`) so the guest's client
     always sees itself as player 0 too — camera, "this is you" highlights, the specials
     train, the HUD's own-stats row all just work, unmodified.
   - **AI is disabled for the guest's slot**: online is 1v1-only specifically so the sim
     loop's `for (pid = 1; ...)` AI loop only ever touches the guest's player index; both
     `aiAct` and `aiSpecials` are skipped entirely when `g.net.role === "host"`.
   - **Coordinate rescaling (fixed in v0.256)**: this game has no separate "world size" —
     `startGame` generates the map directly in the local viewport's own pixel dimensions
     (`viewSize()`), and `proj`/`unproj`/`regionAt` all assume every coordinate already
     lives in `[0, g.W] x [0, g.H]`. Broadcasting the host's snapshot unscaled meant a guest
     on a differently-sized screen saw nothing — the whole match was drawn in the host's
     coordinate space, mostly or entirely off their own canvas. `applyGuestSnapshot` now
     rescales every coordinate-bearing field (tower `x`/`y`/`cell` polygon/`defs`, unit
     `x`/`y`, arrows, rings, sparks, slashes) against the guest's own current viewport on
     every incoming snapshot — self-correcting if the guest resizes/rotates mid-match.
   - **Non-serializable state (fixed in v0.257)**: `g.terrainTex` is a live `<canvas>` element
     — the baked terrain texture, built once at map-gen time (`buildTerrainTexture`). It isn't
     JSON-safe, so it arrived on the guest as `{}`; `draw()`'s `ctx.drawImage(g.terrainTex, ...)`
     is the very first thing it does each frame, so this threw immediately and silently
     blanked the guest's entire canvas — the actual cause of "guest sees nothing" (the
     coordinate-rescaling fix above was real and necessary, but not sufficient on its own;
     this was the thing actually blocking every frame). Fixed by stripping `terrainTex`
     (alongside `net`) before broadcast in `remapSnapshotForGuest`, and having the guest
     rebuild its own copy locally in `applyGuestSnapshot` — cached by viewport size
     (`guestTerrainKeyRef`) since it's expensive (per-pixel noise over the whole board) and
     only actually needs redoing when the guest's own size changes.
   - **Guest input wiped mid-gesture (fixed in v0.258)**: with the map finally visible, the
     guest still couldn't *do* anything — "could only watch." Cause: `applyGuestSnapshot`
     replaces `gameRef.current` wholesale ~10x/sec, but `drag`/`hover`/`lastTap` are
     client-only pointer state that live nowhere else. `handleDown` sets `g.drag`; the next
     snapshot (≤100ms later) swaps in a fresh object with no `drag`, so by the time
     `handleUp` fires the drag is gone and the order never sends. Fixed by carrying the
     guest's own `drag`/`hover`/`lastTap` (and the local `terrainTex`) forward onto each new
     gameRef in `applyGuestSnapshot` (guarded on same-session via `prev.net === netRef.current`).
     Also stripped the HOST's `drag`/`hover`/`lastTap` in `remapSnapshotForGuest` so one
     player's pointer state never paints on the other's screen. Verified with a live two-tab
     test (different viewport sizes): a drag set on the guest survives multiple snapshot
     replacements, and an order broadcast from the guest reaches the host and spawns the
     guest's (owner-1) marching troops.
   - **Known gaps**: hold-to-convert (castle<->tower) isn't networked yet — a no-op for the
     guest, host-only for now. No rematch — "Redeploy"/"Menu" both tear the room down after
     an online match; playing again means re-hosting/re-joining. Guest's hero is auto-assigned
     from the AI pool rather than picked. No reconnect-on-drop — a lost connection just ends
     the session for both sides. All reasonable follow-ups, not attempted this session.

**Note on CDN sourcing:** this file's own notes say cdnjs-only because of Claude's artifact
sandbox. That restriction doesn't apply once the file is actually deployed (Vercel = a real
browser), so the Supabase client script is loaded from jsdelivr instead — cdnjs doesn't mirror
`@supabase/supabase-js`.

The Supabase **anon/publishable key** embedded in the file is meant to be public client-side (like
the old anon key) — access control lives in Postgres Row Level Security policies, not in keeping
that key secret. The **secret/service_role key** must never go in this file.

---

## How to run / edit
- Single self-contained file: `index.html`. React (18.3.1), ReactDOM (18.3.1), and Babel
  Standalone (7.24.7) load from **cdnjs.cloudflare.com** (not unpkg — unreliable/blocked in
  Claude's artifact sandbox).
- Rendered on a `<canvas>` via a `requestAnimationFrame` game loop. Almost all game state lives
  in a mutable `gameRef.current` object (not React state) so the loop can mutate it cheaply.
  React state drives the menu, HUD, dropdowns, outcome screen, pause, tutorial overlay, and
  specials loading-progress display.
- Inline styles + canvas drawing only, no CSS framework. Fonts: Oxanium + IBM Plex Mono.
- **Deploy target (as of v0.254): Vercel.** Push `index.html` + `vercel.json` to a repo (or
  `vercel deploy` from the CLI) — no build step, it's still static, `vercel.json` just sets
  `cleanUrls`. GitHub Pages still works too if ever needed (same static file, no server code),
  but Vercel is the live target now because of the Supabase multiplayer work below.
- **Syntax-checking workflow used throughout this session:** extract the `<script type="text/
  babel">` block and run it through `@babel/core`'s `transformSync` with `@babel/preset-react`
  (installed locally via `npm install --no-save @babel/core @babel/preset-react`). Catches JSX/
  syntax errors before shipping without needing a browser. Always do this before presenting a
  new `index.html`.

---

## Controls
- **Send troops:** drag from any region you own to any other region (enemy, neutral, or your
  own to reinforce). Whole Voronoi region is the hit area.
- **Commit %:** 25 / 50 / 75 / 100 buttons, now **overlaid on the bottom of the map itself**
  (translucent, not in the panel below) — moving them here is what let the map grow bigger.
- **Upgrade a building:** double-tap one of your own castles/towers when it's full. 5-second
  build. Same cost/formula for both building types.
- **Convert castle ↔ tower:** press and hold (no drag) on one of your own buildings for
  ~0.55s (`HOLD_MS`), then release — opens a floating confirm bubble at the tap point
  (`convertConfirm` React state) showing the cost and target type; tap **Confirm** to start
  the conversion (costs `CONVERT_COST` (10) troops, paid up front) or **Cancel**/tap
  elsewhere on the map to dismiss. As of this session, converting is a real `CONVERT_DUR`
  (5s) build — same shape as upgrading, sharing its `t.upgrading` state and dust/hammer
  animation — the actual type flip and reset to level 1 only lands when the build finishes.
  A "hold for convert-to-…option" hint appears on hover when it's affordable.
- **Specials:** one merged segmented control in the panel below the map — tap a loaded segment
  to cast **instantly** (no aim/target step anymore — see Specials section).
- **Top-left HUD button:** just ☰ Menu now (this session — the 👥 players button and the
  standalone ⏸/▶ pause button are both gone; see the "Menu doubles as pause" note below).
  Opens a dropdown with 🔊 sound toggle and 🗺️ New map; tap outside to close.
- **Momentum display:** always visible, top-right, no toggle — translucent name+percentage
  chips, one per living player (see the Momentum section for details). This is what replaced
  the 👥 button's player list; it isn't a button, so it wasn't removed with it.

---

## Current features (all implemented)

### Map
- Rotationally symmetric layouts so every player starts equal, mapped onto a screen-filling
  ellipse. Territory is Voronoi cells (half-plane clipping) derived from castle points — castles
  are placed first (symmetric template), regions are whatever's closest.
- **Castle recentering / Lloyd relaxation (this session)**: after the initial symmetric template
  positions are placed and `computeCells` runs once, `recenterCastles` moves every castle to the
  centroid of the Voronoi cell it was just given (`polyCentroid`, single pass — not iterated), then
  calls `computeCells` again so `t.cell` matches the moved positions. A castle whose cell came out
  lopsided — the shape you get when it's sitting close to a neighbor — has its centroid pulled
  toward the open side of its own region, so tightly-clustered starting placements spread apart.
  Requested because castles were ending up visually close together in some layouts. Preserves the
  template's rotational symmetry automatically (relaxation is applied uniformly, so a symmetric
  input point set produces a symmetric relaxed one). Verified via a standalone 2000-trial
  simulation (random + deliberately clustered point sets): average nearest-neighbor distance
  between castles improved ~49% (114px → 170px) with zero degenerate/overlapping results. Defense
  towers are attached last via `computeCells`'s own `placeDefenders` call, so they always end up
  on the *final*, relaxed castle position — not the original template one.
- **Edge-clipping bug fix (this session)**: the relaxation above initially moved castles' points
  straight to their cell centroid with no bounds check. An edge or corner castle's cell gets
  clipped flat against the world rectangle (`computeCells` always clips to the full `[0,W]×[0,H]`,
  since territory needs to fill the screen edge-to-edge with no gaps), which pulls that lopsided
  cell's centroid *outward* toward the flat edge — reported as castle sprites appearing half cut
  off, sitting right at or past the screen boundary. Fixed by promoting the local `margin = 80`
  that `generateMap` already used to inset the original elliptical template (so home-base points
  were never placed too close to the edge to begin with) into a shared top-level
  `MAP_EDGE_MARGIN`, and clamping `recenterCastles`'s output to that same inset
  (`Math.min(W - MAP_EDGE_MARGIN, Math.max(MAP_EDGE_MARGIN, c.x))`, same for `y`). The Voronoi
  *cell* can still legally touch the world edge — only the castle's own point, and therefore its
  rendered sprite, is kept a safe distance in. Re-verified via the same style of standalone
  simulation, including edge-hugging point distributions mimicking the real template's home-base
  placement: zero edge violations across 3000 trials, spacing improvement still intact (~23–49%
  depending on trial mix).
- `MAX_CASTLES = 12` hard cap, verified by 200k-map simulation; trims center neutral → castles-
  per-player → inner/buffer rings, in that priority.
- **Start levels (this session):** player castles start at level 1 or 2 (one random roll per
  template slot, applied identically across every player's wedge — fully symmetric, no one gets
  an edge). Neutral rings each roll one level 1–3 (buffer ring, inner ring), with level 4
  reserved for the single map-center tower only. A fairness guard also ensures **not every**
  neutral ring can out-level the strongest player starting castle — if all rolled higher, the
  weakest neutral roll gets clamped down to match.
- 2v2 uses a 180°-symmetric layout, same rules, same 12-cap.
- **Random mode**: 75% FFA (2–4 players, evenly split) / 25% 2v2, resolved at Deploy time; the
  *resolved* mode is what's stored as `gameRef.current.mode`.

### Buildings: castles vs. towers (this session — major system change)
Previously every region had a built-in defense tower (all castles passively fired arrows).
That's gone. Buildings are now one of two distinct types, tracked via `t.type` (`"castle"` /
`"tower"`, defaults to `"castle"` if unset):
- **Castle**: regenerates troops (`towerRegen` scales with level as before), can be upgraded,
  but has **no passive ranged defense** — it doesn't fire on its own.
- **Tower**: **never regenerates troops** (`towerRegen` returns 0 for `type==="tower"`), but
  passively fires at hostiles in range. Range grows with level: `towerRange(t) = ARROW_RANGE +
  (level-1) * TOWER_RANGE_PER_LEVEL` (92 / 112 / 132 / 152 px at levels 1–4). Shown on-map as a
  dashed range circle (re-added this session; previously removed entirely per earlier feedback
  — now scoped specifically to towers, plus any castle mid-buff, see below).
- **Conversion**: press-and-hold (no drag) on your own building for `HOLD_MS` (550ms), release
  → opens a confirm bubble (`convertConfirm` state + its JSX overlay, positioned at the tap
  point over the canvas) rather than converting instantly. Tapping **Confirm** there calls
  `startConversion()`, which pays `CONVERT_COST` (10) troops up front and starts a
  `CONVERT_DUR` (5s) build — sharing `t.upgrading` with the upgrade mechanic (mutually
  exclusive, same dust/hammer animation) via `kind: "convert"` and a stashed `toType`. The
  actual type flip and reset to level 1 (you trade accumulated levels for the other
  building's abilities) only lands when the build-completion loop's timer fires; it was an
  instant flip before this session. Tapping Cancel, or starting any new press on the map
  (`handleDown` clears the bubble unconditionally), dismisses the bubble with no effect.
  `startConversion()` re-checks `canConvert()` (and the confirm-button handler re-checks
  ownership) at confirm-time, so a stale bubble left open across a capture or a troop change
  can't do anything harmful. A build in progress is cancelled (with no refund, same as an
  upgrade) if the building is captured before it finishes. Upgrade cost formula is identical
  for both types.
- **Castle defense bonus**: castles defend 20% stronger than a flat 1-for-1 fight
  (`CASTLE_DEFENSE_BONUS = 1.2`) — a 10-troop castle needs 12 attacking troops to fall, not 11.
  Implemented in `unitArrives` as a per-arrival damage of `1 / CASTLE_DEFENSE_BONUS` (≈0.833)
  against castles vs. a flat `1` against towers, with the capture check done *after* applying
  that hit (garrison ≤ 0 → that arrival captures) — this lands exactly on the intended troop
  counts (verified by standalone simulation: 10→12, 20→24, 50→60 for castles; N→N for towers).
  Towers get no bonus. This replaces the old implicit "+1" quirk from the pre-existing
  `troops >= 1` chip-check (which needed 11 attackers for a 10-troop building, no type split).
- **Specials still work on castles (for Tower Defense specifically)**: `castTowerDefense`
  sets `rateMult` on every owned building's `t.defs[0]` regardless of type — for a
  tower this just speeds it up, but for a **castle** this is what temporarily "activates" tower
  behavior in it (grants firing capability for `TOWER_DEF_DURATION` seconds). Barrage (the
  renamed, tower-only hero-kit ability — see the Specials section below) deliberately does NOT
  do this — it filters to `t.type === "tower"` before setting `d.boulder`, so it never touches
  castles. The firing loop's eligibility check is `t.type === "tower" || d.rateMult > 1 ||
  d.boulder`. Range circles are drawn for towers always, and for castles while a Tower Defense
  buff is active.
- **Map placement**: players never start with a tower (only neutrals can be pre-placed as
  towers). The single true-center neutral (when present) is **always** a tower — one shared,
  perfectly even chokepoint. In FFA, the inner contested ring is *occasionally* (30% chance)
  made entirely of towers too — always the whole symmetric ring together (never a subset), so
  no wedge gets an edge. Same idea in 2v2 for the mid-axis pair (30% chance, both together).
  Kept intentionally rare so most maps don't start tower-heavy. Neutral towers start at full
  garrison for their level (`(level+1)*BASE_MAX`, i.e. `towerMax`) rather than `START_TROOPS`,
  since they can't regenerate back up to it. Verified via a 2000-trial simulation per mode
  (2/3/4-player FFA + 2v2): zero `MAX_CASTLES` cap violations, zero players starting with a
  tower, average neutral tower count well under 1.5 per map.
- **Rendering**: new `drawWatchtowerSprite` — a tall, narrow, tapered stone shaft with
  crenellations, one window per level, a beacon at the apex (matches `defenderPoint`'s tower
  branch — that's the actual arrow/boulder origin), and one flag per level. Deliberately a
  distinct silhouette from `drawTowerSprite`'s castle (which is otherwise unchanged — still has
  the visually "grows/glows" right turret under a Tower Defense buff, since that's exactly the
  temporary-activation effect described above). Both sprite functions draw a small "hold to
  convert…" hint on hover when `canConvert(t)` is true. `defenderPoint(t)` now branches on
  `t.type` to return the right anchor (castle's right turret vs. tower's apex beacon).

### Core loop
- Gradual troop deployment (`SPAWN_RATE` soldiers/sec), individual soldier units, 1-for-1 mid-
  field collisions between opposing soldiers (spatial-grid broadphase).
- Castles: 3 starting troops, level caps 10/20/30/40, `LEVEL_MULT = [1, 1.6, 2.2, 3]` for regen
  + fire rate. Double-tap-when-full to upgrade (5s build, costs half current cap). Defeated
  castles lose a level (min 1); any in-progress upgrade or active Tower Defense buff is cancelled
  on capture (buffs don't carry over to whoever just took it).
- Every region (including neutrals) is either a castle or a tower — see the Buildings section
  above. Only towers (or a castle mid-Tower-Defense-buff) fire; range/hit-detection is a true
  circle centered on the building's actual defense-origin point (`defenderPoint`).

### Hero system (current as of v0.203 — live, not banked)
The hero picker is real now: a HERO row on the menu screen (`HERO_IDS.map(...)`, next to MODE/
COMBATANTS) lets the human pick one of 4 heroes before deploying; `selectedHero` React state
feeds `startGame`. Each hero carries exactly 3 abilities, one per tier — `HEROES[id].kit[tier]`
— and that kit is what populates the specials train for that match, for that player. Tempo
(Rally/Speed/Tower Defense — Rally and Slow Down were swapped with Warlord in a later session,
see below) is the default, so a player who never opens the picker still gets a sensible kit.

- **`ABILITY_META`** is the single source of truth for every one of the 12 abilities — name,
  icon, tier, and UI colors, keyed by `kind`. **`SPECIAL_STAGE` is now derived from it**
  (`Object.fromEntries(Object.entries(ABILITY_META).map(...))`) instead of being hand-maintained,
  so tier is intrinsic to the ability itself (Barrage is always Tier 2, whoever carries it) and
  can't drift out of sync with the hero table.
- **`CAST_FNS`** is a single `{ kind: castFn }` dispatch map covering all 12 `cast____`
  functions. `castPlayerSpecial(kind)` and `aiSpecials` both call through it — neither has a
  hardcoded if/else chain anymore, which is what lets either one work for any of the 4 heroes'
  kits without a special case per hero.
- **Per-match hero assignment** happens in `startGame`: the human gets `selectedHero`; the up-to-
  3 AI players each draw one of the *other* 3 heroes via a Fisher-Yates shuffle, guaranteed no
  repeats (at most 3 AI opponents ever exist — FFA caps at 4 total, 2v2 is exactly 4 — which is
  exactly enough heroes to go around). **The tutorial forces EVERY player to Tempo**, not just the
  human — `aiSpecials` runs even during the tutorial, and a randomly-assigned AI hero (Frost
  freezing the scripted enemy trickle, Sabotage sniping a building early, etc.) would be running
  against tuned pacing that's only ever been tested against Tempo's behavior.
- **`g.heroes[owner]`** (a `HEROES` key per player, set once at match start) is what
  `syncSpecials`, the specials UI array, and `aiSpecials` all read to know which 3 kinds belong
  to that player. `fireInfo` and the `pulse`/`prevSecsRef` ready-flash tracking are keyed by
  **tier (1/2/3), not by ability name** — this is what lets the same UI/animation code work
  regardless of which specific kind occupies each tier for the current match's hero.
- **AI heuristics** are now a single `aiWantsToCast(g, pid, kind, incoming, marching)` switch
  covering all 12 kinds, grouped by shared reasoning rather than duplicated: the three
  "defensive buff, held for real pressure" kinds (Slow Down/Fortify at ≥3 incoming; Tower
  Defense/Barrage/Frost at ≥5) share the same `incoming` bar Slow Down originated; the two
  "wants a real marching force" kinds (Speed/Rolling Stones) share a ≥5-marching bar; momentum
  boosts (Rage, and Rally — which since v0.246 asks whether *any* teammate is below the
  cap, not just the caster) skip only if already at `MOMENTUM_MAX`; Second Wind/Instant
  Upgrade/Sabotage are unconditional — each is either self-correcting or safely a no-op if
  there's nothing to spend it on.
- **Load order / train mechanics are unchanged** from before heroes existed: `TRAIN_STAGE =
  15`s per stage by default (changed from 20 in v0.247), casting costs the ability's own tier
  threshold (15/30/45s at the default), each ability also
  has its own `specialCooldown()` per-caster cooldown (equal to `TRAIN_STAGE`, so it follows the SKILL TIMER setting) independent of train progress, and a
  4th phantom "Reserve 🔋" stage extends `TRAIN_MAX` to `80`s so maxing out and casting the
  Tier-3 ability still leaves 20s to immediately follow up with the Tier-1 one. Battlefield
  deaths still refill everyone's train (`TRAIN_KILL_GAIN = 0.1`s per death). All of this is
  still driven by `trainThreshold(kind)`/`readyFor`/`cooldownRemaining` exactly as before — only
  `kind` can now be any of 12 values instead of 3.

The 4 heroes:

| Hero | Tier 1 | Tier 2 | Tier 3 |
|---|---|---|---|
| **Tactician** (default) | Rally | Speed | Tower Defense |
| **Disruptor** | Second Wind | Barrage | Sabotage |
| **Warlord** | Slow Down | Fortify | Rage |
| **Juggernaut** | Instant Upgrade | Rolling Stones | Frost |

Every ability appears on exactly one hero — the 4×3 grid is fully and uniquely filled, verified
with a standalone Node script (`/tmp/test_hero_structure.js`, this session) that checked every
`HEROES[id].kit` covers tiers 1/2/3 exactly, every kind referenced exists in `ABILITY_META` at
the matching tier, and the 12 assigned kinds are exactly the 12 keys in `ABILITY_META` — no
orphans, no duplicates. A second script (`/tmp/test_dispatch_draw.js`) ran 1000 trials of the
hero-draw logic (random human pick × random player count) confirming no repeated hero ever
appears in a single match's `heroes` array, and confirmed `CAST_FNS`'s keys match
`ABILITY_META`'s keys exactly (nothing in the metadata table is undispatchable).

### Ability reference (all 12, tier + effect + status)

| Ability | Tier | Effect | Magnitude | Target | Status |
|---|---|---|---|---|---|
| **Slow Down** | 1 | Instantly sets `u.speedMul = SLOW_DEBUFF` (0.75×, -25%) on every currently-marching HOSTILE soldier — global, no radius/targeting, mirror image of Speed. | -25% speed, no duration (lasts the rest of that unit's march) | Every currently-marching hostile unit at cast time | Implemented (`castSlow`) |
| **Second Wind** | 1 | Instant flat troop injection to ONE building on the caster's team — whichever has the worst defense deficit against hostile troops actually incoming right now (units in flight + queued orders); falls back to the team's weakest building if nothing's under attack. | +15 troops (`SECOND_WIND_AMOUNT`) | Caster's team's buildings (own + ally's, in 2v2) — **changed v0.246**, was own-only | Implemented (`castSecondWind`) |
| **Rally** | 1 | Instant momentum boost to every player on the caster's team. No troops, no targeting. | +10% momentum (`RALLY_MOMENTUM_BOOST`) each, clamped to `MOMENTUM_MAX` | Caster's whole team (own + ally, in 2v2) — **changed v0.246**, was caster-only | Implemented (`castRally`) |
| **Instant Upgrade** | 1 | Instantly completes an upgrade on ONE random eligible building on the caster's team (level below `MAX_LEVEL`, not already mid-build/-convert) — no troop cost, no build timer, unlike a normal upgrade. Does nothing if nothing is eligible. Momentum credit goes to the **building's owner**, not the caster. | +1 level on the chosen building | One random eligible building on the caster's team — **changed v0.246**, was own-only | Implemented (`castInstantUpgrade`) |
| **Speed** | 2 | Instantly sets `u.speedMul = SPEED_BOOST` (1.5×, +50%) on every currently-marching soldier on the caster's team — global, no radius/targeting. | +50% speed, no duration | Every currently-marching allied unit at cast time | Implemented (`castSpeed`) |
| **Barrage** | 2 | Renamed + reworked from the former "Tower Defense 2.0". Every **tower** (never a castle) the caster's team owns lobs splash-damage boulders instead of arrows — each impact destroys a small cluster of enemies. Deliberately excludes castles, unlike Tower Defense: it does NOT temporarily grant castles firing capability. | Boulders destroy up to `BOULDER_SPLASH_COUNT = 4` enemies within `BOULDER_SPLASH_RADIUS = 42`px, for `TOWER_DEF_DURATION = 10`s | Caster's (and team's) towers only — castles untouched | Implemented (`castBarrage`) |
| **Rolling Stones** | 2 | Turns every currently-marching allied soldier into a Rolling Stone for the rest of its march — visually replaced by an actual rotating boulder sprite (not a marker under a soldier), with a faction-colored rim for ownership. Four effects: (1) 4x strength at building-arrival damage/reinforcement; (2) immune to tower/castle defensive fire; (3) **+50% movement speed**; (4) can grind **any** enemy building (castle OR tower) down to 1 troop but can never be the arrival that captures it — a non-stone unit is always needed to finish that. | 4x strength (`ROLLING_STONE_STRENGTH_MULT`), +50% speed (`ROLLING_STONE_SPEED_MULT`), radius `ROLLING_STONE_R` | Every currently-marching allied unit at cast time | Implemented (`castRollingStones`) |
| **Fortify** | 2 | Temporarily boosts the caster's (or team's) buildings' effective DEFENSIVE troop strength — attackers need proportionally more troops to capture a Fortified building. Visually recolors the building metallic silver (`METALLIC_COLORS`) so the buff is noticeable, not just reflected in combat math — castle body + left turret, or a tower's full shaft (right turret/tower shaft still shows Tower Defense/Barrage's own color if that's also active on the same building). Lazy expiry check (`fortifyMult(g,t)`), no per-frame cleanup loop needed. | +50% effective defensive troop strength (`FORTIFY_MULT = 1.5`), 10s duration (`FORTIFY_DURATION`) | Caster's own buildings (and team's, in 2v2) | Implemented (`castFortify`) |
| **Tower Defense** | 3 | Every tower/castle the caster's team owns fires **25% faster** (`TOWER_DEF_RATE_MULT = 1.25`) for `TOWER_DEF_DURATION = 10`s. Also temporarily grants castles firing capability (normally passive). Merges into the castle's right turret with recoloring and size growth during the buff. | +25% fire rate, 10s | Caster's (and team's) towers and castles | Implemented (`castTowerDefense`) |
| **Sabotage** | 3 | Two-part: (1) weakens **every** enemy building on the map by a combined troop total, split evenly — each one also gets a visible ninja-sword slash effect plus a literal 🥷 emoji popping up and rising above it (`g.slashes`); (2) a flat threshold check against **every** enemy building left under the threshold after that debuff — each one that qualifies is instantly captured via `captureBuilding()`, not just the single weakest. | 30 total troops split evenly (`SABOTAGE_TOTAL_DAMAGE`); capture threshold 5 troops (`SABOTAGE_SNEAK_TROOPS`), strictly-under | Every enemy building globally (both parts) | Implemented (`castSabotage`) |
| **Frost** | 3 | Global, instant hard stop (not a slow) on every currently-marching HOSTILE soldier: full freeze in place for a fixed window, then automatic thaw. Uses a SEPARATE `u.frozen` boolean flag rather than reusing `u.speedMul = 0` — the movement formula's `u.speedMul \|\| 1` fallback treats `0` as JS falsy/"unset" and would have silently snapped a frozen unit back to full speed. Reuses Slow Down's dashed-ring + sparkle visual (gated on `(u.speedMul < 1) \|\| u.frozen`). | Full freeze (0 speed) for `FROST_DURATION = 10`s, then auto-thaw | Every currently-marching hostile unit at cast time | Implemented (`castFrost`) |
| **Rage** | 3 | Every currently-marching soldier on the caster's team turns red (visual: solid red glow, distinct in color from Speed's teal filled glow, layered independently so it can stack with other unit overlays) and permanently gains bonus strength for the rest of its march — a "whoever's marching right now" transformation, same shape as Speed/Slow Down/Rolling Stones, no duration/timer. Applied at building-arrival damage/reinforcement (`unitArrives`), the same point Rolling Stones' 4x is applied — the two stack multiplicatively if a single unit somehow carries both (possible in 2v2, since both are team-inclusive casts). | 1.5x strength (`RAGE_STRENGTH_MULT`, +50%) | Every currently-marching allied unit at cast time | Implemented (`castRage`) |
| ~~Barricade~~ | ~~2~~ | ~~Briefly raise the troop threshold to capture the caster's buildings~~ | — | — | **Removed** — proposed, then dropped before any code was written |

### AI
- Attacks the cheapest capturable target, factoring in the target's own inbound reinforcements
  (`inc[t.id].enemy`) — previously blind to this, causing wasted attacks on castles about to be
  re-garrisoned.
- **Revenge cooldown:** for 8s after losing a castle, retaking it requires a 2x margin instead of
  the normal 1.3x, so the AI doesn't immediately peck at a castle it just lost.
- **Attack sizing:** never sends more than `ATTACK_CAP = 75%` of a castle's garrison in one order;
  requires the sent force to clear `1.3×` the target's projected defense. If one castle can't
  clear the bar even at 75%, it coordinates a second nearby castle to combine forces rather than
  attacking too thin or overcommitting one castle.
- **Defense-tower attrition now factored into `evalTarget` (this session):** the AI was sizing
  attacks purely off the target's troop count + regen, completely ignoring that the target's own
  defense tower shoots down approaching soldiers one by one during the march — the reported
  symptom was the AI attacking constantly and rarely actually taking a castle. `evalTarget` now
  estimates expected arrow losses as `(travel time + spawn-trickle time) / towerFireCd(t)` (faster
  fire rate at higher tower levels ⇒ more expected losses ⇒ demands a bigger force, or skips the
  attack entirely if it's not winnable) and adds that to the required send before the existing
  1.3×/2× margin is applied. Net effect: fewer doomed attacks against strong towers, and the
  attacks it does launch send enough troops to actually survive the gauntlet and capture.
- Teammate-aware in 2v2: defends a falling ally castle, reinforces a short-handed ally attack,
  before its own expansion.

### Sound (new this session)
- **`SoundEngine`**: fully synthesized via the Web Audio API (oscillators + generated noise
  buffers) — no external audio files, keeps the single-file architecture. Master gain node,
  per-sound-type throttling (`throttled()`) to stop combat spam from creating dozens of
  overlapping nodes.
- Sounds: arrow/boulder impacts (distinct), mid-field clashes, all three specials (AI casts play
  quieter), win/lose fanfare, UI clicks (Deploy/Pause/Menu/New map). **Explicitly NOT present**:
  sending troops, upgrading, conquering a castle — removed per feedback, kept silent.
- **Battle bed**: an ambient layer of quiet, muffled percussive taps (same noise-burst primitive
  as the foreground hit sounds, just duller/quieter) that intensifies with sustained combat near
  the player's **own** castles only (`BATTLE_RADIUS = 140`px proximity check, `nearFriendlyCastle`
  / `addBattleHeat`, decaying `g.battleHeat`). Self-rescheduling via `setTimeout`, not a looped
  track — stops rescheduling itself once intensity decays to ~0. Explicitly **defense-only**
  (proximity-based) — an earlier ownership-based version that also covered the player's own
  *attacks* on enemy castles was tried and reverted per feedback, along with a discrete "swords
  clashing at the gate" sound for the same reason (replaced by the attack-smoke visual instead).
- **Safari fix**: `SoundEngine.resume()` (which calls `ctx.resume()` if suspended) is now called
  from every real user-gesture handler — `handleDown` (board taps) and `castPlayerSpecial`
  (special taps), in addition to Deploy. Safari suspends `AudioContext` aggressively and only
  reliably resumes it from a direct gesture, not from timer-fired sounds (AI casts, battle-bed
  taps) — this was causing the game to go silent mid-match and never recover.
- **iOS PWA backgrounding fix (this session)**: reported as "sound keeps getting silenced" when
  installed as a standalone PWA. Backgrounding (locking the screen, switching apps, a phone call)
  suspends — or on iOS, sometimes fully **closes** — the `AudioContext`, and it wasn't reliably
  coming back once the player returned; they'd have to wait for some in-game tap to happen to
  trigger `ensureCtx()` again, and a *closed* context previously wasn't handled at all (`resume()`
  throws on a closed context). Fixed in `ensureCtx()`:
  - Detects `ctx.state === "closed"` and rebuilds the context + master gain node from scratch
    instead of calling `resume()` on it.
  - Resume check broadened from `=== "suspended"` to `!== "running"`, since iOS Safari also uses
    an `"interrupted"` state (phone call, Control Center audio route change, etc.).
  - New `visibilitychange` / `pageshow` / `focus` listeners at the module level proactively call
    `resume()` the moment the app becomes visible again — covers the PWA-relaunched-from-home-
    screen case (`pageshow`) as well as ordinary tab/app switching — rather than waiting on the
    next gesture-driven sound call to notice the context needs resuming.
- Also worth knowing (told to the user, not fixed in code — not fixable via Web Audio API): the
  iPhone hardware silent switch mutes raw Web Audio API output in Safari regardless of in-app
  sound settings.

### Visual effects (new this session)
- **Attack smoke**: any castle with hostile troops within `ATTACK_SMOKE_R = 60`px (i.e. actually
  at the walls, not just an order in transit from across the map) shows rising smoke from its
  base. Uses the **same churning-cloud algorithm** as the castle-upgrade dust plume (procedural,
  seeded per-puff via `g.pulse`, no particle array), just recolored solid grey instead of warm-
  to-cool. The upgrade dust plume itself was **shrunk** this session (42 puffs → 6, smaller
  radius/rise/alpha) to roughly its original small scale, since the attack-smoke reuse made the
  bigger version redundant-looking in two places.
- **Hammer added to the build animation (this session)**: the dust plume alone read ambiguously
  (could pass for attack smoke at a glance, especially since both now share the same algorithm).
  Added a small hammer silhouette in the same `if (t.upgrading)` block in `drawTowerSprite`,
  tucked beside the gate (`x + keepW/2 + 5`) so it doesn't overlap it: bobs up ~11px and back down
  on a `g.pulse`-driven cycle (`strike = (g.pulse * 2.5) % 1`, `lift = sin(strike * π)`), with a
  slight backward tilt on the way up and forward on the way down so it reads as a swing, not just
  a floating bar. No lifecycle to manage — purely a function of `g.pulse` and `t.upgrading` being
  truthy, same pattern as the dust puffs.
- **Region flash on hostile contact (this session)**: `unitArrives` now stamps
  `t.underAttackFlashAt = g.pulse` the instant a hostile soldier actually reaches a castle and
  fights — both the ordinary "chip off one garrison troop" branch and the capture branch, but
  *not* the friendly-reinforcement branch, since this is specifically about being attacked.
  `draw()`'s territory-fill loop reads it: for `REGION_FLASH_DUR = 0.3`s after the timestamp, the
  region's whole polygon gets a white overlay fading from `rgba(255,255,255,0.6)` to 0, layered
  on the same traced cell path as the existing hover/drag highlight (no extra `beginPath`). A
  single hit reads as a sharp flash; a sustained attack re-triggers it on every arrival (up to
  `SPAWN_RATE = 9`/s from one order) and reads as a flicker for as long as the siege lasts. No
  particle/state array — just one timestamp per tower, same lightweight pattern as `t.lostAt`.
- **"This is you" ring**: for the first `START_HIGHLIGHT_DURATION = 5`s of any match, a pulsing
  gold dashed ring (marching-ants rotation via `lineDashOffset`) circles every castle owned by
  the player, fading out over the last second. Ground-layer, under the building sprites.
- **Castle sprite shrunk 25%, then bumped back up twice**: `CASTLE_SCALE` — originally `0.75`,
  raised to `0.825`, then to **`0.9`** per follow-up feedback — applied in `drawTowerSprite`
  as a `translate → scale → translate` centered on the castle's ground point (`x, groundY`),
  right after the per-level geometry (`cfg` from `CASTLE_LEVEL_CFG`, `baseW`, `totalH`, etc.) is
  computed and before anything is actually drawn. Because it's a canvas transform rather than a
  change to the geometry numbers themselves, every subsequent draw call in the function — shadow,
  team ring, body/turrets/flags, upgrade dust plume, drag/hover rings, upgrade-ready hint —
  shrinks together automatically, and the castle still sits at the same ground point in its
  region (just takes up less room) rather than floating or sinking. Requested because higher-
  level castles (wider silhouettes) were visually crossing into tightly-packed neighbours'
  sprites.
- **Defense tower merged into the castle (this session)**: previously each region's defense
  tower was a fully separate sprite (`drawDefenseTower`) placed off to the side of the castle
  inside the cell (`placeDefenders`, toward the cell centroid), with its own shaft/crenellations/
  shadow, independently depth-sorted — a second freestanding "thing" per castle on the map, and
  requested to be reduced. It's now just the castle's own right flanking turret:
  - `CASTLE_LEVEL_CFG` (the per-level `{w, keepH, turretH, roof, wide, grand}` table) was pulled
    out of `drawTowerSprite` to top-level so it can be shared.
  - New top-level `defenderPoint(t)` computes the world-space top of the right turret for a
    given tower, matching `CASTLE_LEVEL_CFG` and pre-multiplied by `CASTLE_SCALE` so it lands
    exactly on the (shrunk) rendered turret. `placeDefenders` now just calls this once at map
    generation instead of the old cell-centroid offset math (and the now-unused `polyCentroid`
    helper was removed). The level-up block and the capture/knockdown block (which changes
    `t.level`) both call `defenderPoint` again afterward to re-attach `t.defs[0].x/y` to the new
    turret position — the turret moves as the silhouette grows or shrinks a level.
  - `drawTowerSprite`'s "Flanking turrets" section now also reads `t.defs[0]` and, using *local*
    (already-transformed, so no extra `CASTLE_SCALE` math needed) coordinates `rx, defMidY`,
    draws the buff glow halo *before* the turret stone (so stone sits on top) and a small arrow-
    slit accent *after* it — ember glow for the boulder buff, gold for the 2x fire-rate buff,
    faction color otherwise. This is the same visual language `drawDefenseTower` used, just
    layered onto the existing turret instead of a whole separate structure.
  - `drawDefenseTower` was deleted outright, and the sprite depth-sort loop (`draw()`) went from
    two entries per castle (`{def:true}` / `{def:false}`) back down to one — `t.defs[0].x/y` is
    now purely a gameplay value (arrow-origin point for `evalTarget`'s attrition math, arrow
    spawn position) with no corresponding independent render pass.
- **Buffed turret made more noticeable (this session)**: the merge above initially only added a
  small tinted arrow-slit accent, which was too subtle to read at a glance. Reworked so an active
  buff visibly **grows** the right turret, not just recolors a detail: `rTurretW`/`rTurretH` (1.45x
  / 1.25x the base `turretW`/`cfg.turretH`) are computed right after `cfg`, before `totalH`, so the
  castle's overall bounding box (`totalH` → `topY`/`midY` → the drag/hover selection ring's
  `ringR`) grows to match rather than the turret poking out past it. `stone()`/`crenellate()`
  gained optional tint-color params (every other call site keeps the default grey) so the whole
  right turret — not just the window — recolors: dark scorched stone for boulder mode, gold for
  the 2x fire-rate buff. The glow halo behind it and the arrow-slit both scale off the new
  `rTurretW`/`rTurretH` too, so the whole assembly reads as one enlarged, recolored turret rather
  than a normal turret with a bright dot on it. `defenderPoint` (the gameplay arrow-origin point)
  deliberately still uses the base, unbuffed geometry — only the render size changes.

- **Tower range rings removed entirely (this session)**: made dashed/thicker/more visible last
  session, then removed outright the session after per follow-up feedback. `ARROW_RANGE` still
  governs actual defense-tower reach (used by `evalTarget`'s AI attrition math, the nearest-target
  search in the arrow-firing loop, etc.) — only the circle visualizing it in `draw()` is gone.

### Tutorial mode (new this session)
- "🎓 Play Tutorial" button on the menu, below Deploy. Starts a real 2-player FFA match
  (`startGame(2, "ffa", true)`) tagged `g.tutorial = true`.
- **The player literally cannot lose** — the lose-outcome check is skipped entirely when
  `g.tutorial` is true. **As of v0.248 the WIN check is skipped too**: eliminating the rival is
  now a scripted step, so the victory screen would cut the wrap-up step off. The tutorial ends
  only via "Finish Tutorial" / "Skip tutorial".
- **9 scripted steps** (`TUTORIAL_STEPS`, top-level array; was 8 before v0.248 added the
  "Finish Them Off" step): each has a title/body, and optionally
  a `waitFor` flag name + a short `hint`. Steps with no `waitFor` are pure explanation — the
  overlay's button just says "Continue →" and advances immediately (still paused, chains to the
  next step). Steps with `waitFor` say "Try it →" — clicking unpauses the game, a small hint
  banner (🎯) shows what to do, and once the matching flag in `g.tutorialFlags` goes true
  (set at the actual action sites: `handleUp`'s order/upgrade paths, `castPlayerSpecial`), the
  game loop auto-pauses again and advances to the next step. `onEnter` per-step hands the player
  whatever they need to try it immediately (tops off a castle's troops, charges the train to
  exactly that special's threshold) rather than making them wait.
- Steps cover: intro, sending troops, regions/defense towers (info-only), upgrading, all three
  specials in train order, and (v0.248) finishing the rival off. Final step is a wrap-up with a
  "Finish Tutorial" button.
  "Skip tutorial" is always available, and both routes send `screen` back to `"menu"`.
- The tutorial overlay replaces (not layers on top of) the regular "PAUSED / tap to resume"
  screen — gated via `!gameRef.current?.tutorial` on the regular one.
- **No tower-type buildings at all (v0.249)**: right after `generateMap`, `startGame` flips
  every `type: "tower"` building to a castle when `tutorial` is true. `generateMap` normally
  seeds neutral watchtowers (always one in the center, sometimes more on the inner ring /
  mid-pairs), and a board where some buildings shoot back and never regenerate is a lot to
  parse while you're still learning the drag gesture. See the v0.249 section below for the two
  fix-ups the flip requires.
- **All non-player castles start at level 1 (this session)**: right after `generateMap` runs,
  `startGame` loops `map.towers` and clamps every tower with `owner !== 0` to `level = 1` when
  `tutorial` is true. The player's own starting castle(s) keep whatever the normal symmetric
  roll gave them (level 1 or 2); every AI castle and every neutral (buffer/inner/center ring)
  is forced down so nothing the player attacks is beefed up beyond baseline — keeps early
  captures fast and unambiguous while they're still learning the controls.
- **Pacing fix (this session): steps no longer auto-advance before the effect is visible.**
  Previously `waitFor` flags were set the instant the player *acted* (order issued, upgrade
  tapped, special tapped), so the tutorial jumped to the next step before anything actually
  happened on screen — most noticeably, Tower Defense 2.0 was never actually seen because the
  tutorial ended the moment it was pressed. Fixed two ways:
  - `waitFor` flags now fire on the **outcome**, not the button press: the Sending Troops step's
    flag (renamed `ordered` → `captured`) is set in `unitArrives` when the targeted castle
    actually flips to the player's ownership, not when the drag is released; the Upgrading
    step's `upgraded` flag is set when the 5s build actually completes (in the game loop's
    upgrade-finishing block), not when the double-tap starts it.
  - A new `settleFor` (seconds) field per step holds the step open that long *after* the flag
    trips before auto-pausing/advancing, tracked via `g.tutorialWaitStart` (a `g.pulse`
    timestamp set the first frame the flag is seen true, reset to `null` by `applyTutorialStep`
    whenever a new step becomes current). Values: Sending Troops and Upgrading get 1.5s to let
    the visual settle; the two Tower Defense specials get `TOWER_DEF_DURATION` (12s) so the
    player watches the full buff window play out; Speed gets 3s.
- **Enemy trickle during the Tower Defense steps (this session):** holding a special step open
  longer only helps if there's actually something for the buffed tower to shoot at, and the
  tutorial AI's normal `aiAct` decisions weren't reliable enough to guarantee that. Both
  Tower Defense steps now set `tutorialWave: true`; `applyTutorialStep` reads that into
  `g.tutorialAutoWave` (on for those two steps, off for every other step), each step's
  `onEnter` tops off the nearest AI-owned castle to full so it has plenty to send, and a game-
  loop tick (guarded by `g.tutorial && g.tutorialAutoWave`) calls the new `tutorialSendWave(g)`
  every ~2.5–4s. That helper finds the nearest AI-castle/player-castle pair and ships a small
  **fixed** troop count (`min(3, attacker.troops − 1)`, not a percent) at the player — enough for
  the tower to visibly fire on, deliberately too small to ever threaten the castle. Stops the
  instant the step changes (`tutorialAutoWave` resets to `false` in `applyTutorialStep`).

### UI (new/changed this session)
- **How to play** is now a modal dialog (click-outside or ✕ to close), not an inline expansion —
  same content as before.
- **Top-left HUD** (was top-right, was always-visible player chips): 👥 players dropdown (closed
  by default, 2-chips-per-row grid so it doesn't cover the map), ⏸/▶ icon-only pause, ☰ Menu
  dropdown (🔊 sound toggle + 🗺️ New map). All three anchor left, dropdowns open below-left,
  mutually exclusive, tap-outside-to-close.
- **Commit % row moved onto the map** (translucent overlay, bottom-center) instead of living in
  the panel below — this is what made the map bigger, since the panel below shrank by that row's
  height and the map fills whatever's left via `flex: 1`.
- Version number (`v0.146` etc.) shown bottom-right of the menu screen, monospace, subtle.
- **Specials bullet in "How to play" simplified (this session)**: dropped the exact numbers
  (train stage costs, per-special cooldowns, kill-refill amount) from the modal copy — that
  detail still lives in-game via the segmented bar itself. Copy now just names what each special
  does and that they share one bar, fire instantly, and refill from battlefield deaths.

---

### Graphics pass — terrain texture, unified lighting, combat feedback (this session)
Prototyped first as a standalone concept artifact (toggleable before/after, click-to-clash
demo) before touching the real game, per the "concept before committing" workflow. First
concept pass used a low-res (160px-wide) upscaled buffer + raw per-pixel noise — read as
pixelated/grainy — so it was rebuilt at full CSS-pixel resolution with smoothstep-interpolated
noise before porting into `index.html`.

- **Cached terrain texture (`buildTerrainTexture`, `LIGHT_DIR`, `smoothNoise`/`noiseHash`,
  `projPoint`)**: because the camera is fixed per session and cell geometry (`t.cell`) is
  static during a match (only ownership/level change, never the polygon shapes), the terrain
  base — organic noise mottling + a directional-light gradient + a blurred ambient-occlusion
  band along every cell border — is baked **once** into an offscreen canvas at CSS-pixel
  resolution, not recomputed per frame. Built right after `gameRef.current` is assigned in
  `startGame`, and rebuilt in the resize handler (after `computeCells` rescales the towers,
  since cell shapes change with viewport size). `draw()` just does one `ctx.drawImage` of the
  cached texture in place of the old flat `#41547d` fill. The old flat per-cell prefill and the
  1px diagonal hatching were removed — the ownership tint fill (unchanged, still `tracePoly`
  + faction `fill` color) is drawn directly over the textured base and lets it show through,
  same as it showed through the old flat fill.
  - `projPoint(g, wx, wy)` is a necessary top-level duplicate of the component's `proj()` —
    `buildTerrainTexture` runs outside the component closure (needs to run before first
    render / on resize) but still has to project `t.cell` world-space vertices through the
    same tilted-camera math when stroking the AO border, or the border shadow ends up
    misaligned with the actual rendered (projected) cell edges. Must be kept in sync with
    `proj()` if the camera formula ever changes.
  - `LIGHT_DIR = { x: -0.55, y: -0.8 }` (upper-left) is shared between the terrain texture's
    light gradient and each castle's ground-shadow offset (`drawTowerSprite`'s "Ground
    shadow" block now offsets by `-LIGHT_DIR.x`/`-LIGHT_DIR.y` instead of sitting dead-center
    under the castle) — the point of "unified lighting" is that terrain and castles agree on
    where the light is coming from, so bump both together if this ever changes.
  - Perf note: the per-pixel noise loop runs at full CSS-pixel resolution (no supersampling,
    no downsampled buffer — that's specifically what fixed the pixelation) — roughly
    100–300ms one-time cost on a typical viewport, paid at Deploy and on every resize, never
    during steady-state play. Frequent resize events (e.g. mobile browser chrome show/hide)
    will each pay this cost; not yet optimized, flagged as a possible follow-up if it's felt
    on real devices.
- **Combat feedback — impact puffs (`g.puffs`)**: field clashes and boulder impacts now also
  spawn a soft expanding dust-puff (radial gradient + a brief bright flash on the impact
  frame) in addition to the existing colored spark dot. New `g.puffs` array alongside
  `g.sparks` — same lifecycle shape (age up to a `dur`, rescaled on resize, drawn in `draw()`
  just before the sparks loop so sparks pop on top of the puff).
- **Not yet done**: only field-clash and boulder-impact puffs were added; regular arrow hits
  still only spark (kept as-is, deliberately lighter-weight than a boulder crunch). Terrain
  noise/AO tuning (amplitude, blur radius, border wobble) hasn't been revisited since the
  concept-approved values — if it reads too subtle/strong in real matches (vs. the static
  concept demo), those constants (`smoothNoise` amplitude in `buildTerrainTexture`, AO
  `blur(7px)`/`lineWidth 9`) are the ones to tune.

### Light-consistent soldiers + castle gradient (this session, follow-up)
Closed the gap where castles and terrain agreed on `LIGHT_DIR` but the castle stone gradient
was still a hardcoded left-bright/right-dark, and soldiers had no lighting at all.
- **Castle stone gradient (`stone` helper in `drawTowerSprite`) now derives its lit side from
  `LIGHT_DIR.x`** (`litLeft = LIGHT_DIR.x < 0`) instead of always putting the bright color on
  the left. Currently a no-op visually (`LIGHT_DIR.x` is negative, same as before), but the
  two are now actually linked — change `LIGHT_DIR` and the castles follow automatically
  instead of silently going stale. `roofTop` got the same treatment (was a single flat fill,
  now a two-stop gradient using the same `litLeft` flag).
- **Soldier sprites (`soldierSprite`)**: added `litLeft` / `shadowOnLocalRight` / `shadowOffX`
  at the top of the function, reused for two things — the baked-in ground shadow is now
  nudged toward the shadow side instead of sitting dead-center under the feet, and the tunic
  gets a subtle `rgba(0,0,0,0.16)` shade rect over its shadow-side half so it reads as lit
  from one direction instead of flat faction color.
  - **Important subtlety**: soldier sprites are pre-rendered once per `(owner, frame, flip)`
    and cached (`soldierCache`), and `flip` is implemented as a canvas mirror transform
    (`x.translate(SOLDIER_W,0); x.scale(-1,1)`) applied *before* any of the drawing below it —
    so a naive fixed local-space light offset would flip along with the sprite's facing,
    making left-facing and right-facing soldiers look lit from opposite directions.
    `shadowOnLocalRight` compensates for this (`flip ? litLeft : !litLeft`) so the shadow/tunic
    shading stays anchored to the same world-space light direction regardless of which way a
    given soldier is walking. Any future per-sprite lighting effect on soldiers needs the same
    flip compensation or it'll have this bug.
- **Not yet done**: arrow/spear metal, helmet, and head don't pick up any directional shading
  yet (flat colors) — low priority, they're tiny on-screen. `LIGHT_DIR` is now referenced from
  three places (`buildTerrainTexture`'s gradient, the castle ground-shadow offset, `stone`/
  `roofTop`, and `soldierSprite`) — if it's ever tuned, all four follow without further edits.

---

### Castle level rebalance — dropped old L1, added a new top tier (this session)
Requested change: cancel the old level 1 tier (old level 2 becomes the new level 1), and add
a new top tier capped at 50 troops with regen/fire-rate exactly 3x the new level 1's rate,
keeping the same +10-troops-per-level rate throughout.

- **`towerMax(t)`** changed from `t.level * BASE_MAX` to `(t.level + 1) * BASE_MAX` — the `+1`
  is what shifts the whole cap ladder up one `BASE_MAX` (10) step now that the bottom tier is
  gone. New caps: **level 1→20, level 2→30, level 3→40, level 4→50** (old caps were
  10/20/30/40). Still +10 per level, per spec ("the same rate should apply").
- **`LEVEL_MULT`** changed from `[1, 1.6, 2.2, 3]` to `[1.6, 2.2, 3, 4.8]` — old level 1's
  entry (`1`) was dropped, old levels 2/3/4's multipliers (`1.6, 2.2, 3`) shifted down to fill
  new levels 1/2/3, and the new level 4 is exactly `1.6 * 3 = 4.8` (new level 1's rate,
  tripled), per spec.
- **`CASTLE_LEVEL_CFG`** (visual silhouette per level) shifted the same way: new level 1 uses
  the old level 2 geometry (roofed, not wide), new level 2 uses old level 3 (wide roofed
  gatehouse), new level 3 uses old level 4 (grand). New level 4 is a larger "grand" config
  (`w: 66` vs. old grand's `58`, taller keep/turret) — reuses the existing grand rendering
  path in `drawTowerSprite` (single wide body + raised roofed center keep) at a bigger size.
- **Flag-count bug (found and fixed in a follow-up pass)**: the flag rendering ("one flag per
  level") had hardcoded flag-count arrays baked into the `cfg.grand` and `cfg.wide` branches —
  4 flags for any grand castle, 3 for any wide-non-grand castle — which only worked before
  because exactly one level ever used each shape. Once levels 3 *and* 4 both became `grand`,
  level 3 wrongly rendered 4 flags (like level 4) instead of 3, reading as an extra level. Also
  briefly shipped (and then removed) a small pennant flourish on level 4's spire meant to
  distinguish it from level 3 visually — turned out to be visually identical to the flag shape
  (pole + triangle), so it read as an unwanted 5th flag on top of level 4's correct 4. Fixed by
  deriving `flagOffs` directly from `nFlags` (`Math.min(lvl, 4)`) for every shape — no more
  hardcoded per-shape arrays — and removing the pennant entirely; levels 3 and 4 are now told
  apart by size and by their correct 3-vs-4 flag count, nothing else. If a level's shape is
  ever shared by more than one level again in the future, this is the pattern to follow (derive
  from level number, don't hardcode).
- **Nothing else needed to change.** Level numbers throughout the rest of the codebase
  (upgrade progression `t.level < MAX_LEVEL`, capture knock-down `Math.max(1, t.level - 1)`,
  map-gen's `pick([1,2])` / `pick([1,2,3])` / `pick([1,2,3,4])` starting-level rolls,
  `defenderPoint`, `unitArrives`, etc.) all operate on the numeric level 1–4, which didn't
  change shape — only what each number *means* underneath (cap + multiplier + silhouette)
  changed. So map generation, upgrades, and captures all "just work" with the new balance
  without any further edits.
- **Balance implication worth knowing**: since starting levels (player home castles roll
  `pick([1,2])`, neutral rings roll up to `pick([1,2,3])` or `pick([1,2,3,4])` for the map
  center) are unchanged numerically but now map to bigger caps/multipliers across the board,
  every match starts meaningfully stronger than before this session (e.g. a starting level-1
  castle now caps at 20 troops instead of 10). This is the direct, intended consequence of
  dropping the old bottom tier — flagging it here in case matches feel faster-paced or
  neutral rings feel tougher than expected and it's not obvious why at a glance.

### Order overcommitment cutoff (this session)
Reported bug: stacking multiple orders from the same castle while an earlier one is still
trickling out (e.g. 50% of 50 → 25, then 50% of the 40 still showing → 20, then 50% of the 30
still showing → 15 — 60 promised from 50 actual troops) had no ceiling. Worse, once the castle
ran dry mid-drain, any leftover backlog on a pending order just sat there and would silently
resume the instant the garrison ticked back up — via `towerRegen`, or a reinforcement unit
arriving from another castle (`unitArrives`'s `t.troops += 1`) — shipping those newly-arrived
troops right back out to satisfy a stale commitment the player never re-confirmed.

- **Confirmed intentional, unchanged**: `issueOrder`'s percentage math still reads straight off
  the garrison's current `t.troops` at the moment of the click, with no "subtract what's
  already promised to other pending orders" adjustment. The three stacked orders in the
  example above are all *supposed* to compute those exact amounts (25/20/15) — verified by
  simulation before touching anything, since an earlier "reserve troops per pending order"
  design would have silently shrunk order 2 and 3 below what was wanted. Documented directly
  above `issueOrder` so this doesn't get "fixed" into a reservation system later.
- **The actual fix is at drain time**, in the "Orders trickle soldiers out of the gate" loop
  (search `Cutoff` in `index.html`): once a castle's `t.troops` drops below 1 with an order's
  `remaining` still > 0, that leftover is zeroed out (and the order removed) right there,
  instead of being left pending. Runs per-order every tick, so multiple orders sharing one now-
  empty source castle all get cut off together in the same pass — no extra bookkeeping needed.
- **Net effect**: total troops that ever actually leave a castle from any stack of orders is
  hard-capped at whatever the castle had when it ran out (matches the example: 60 promised,
  50 actually spawn). Any troops that arrive afterward — regen topping the garrison back up,
  or a reinforcement order landing — start with a clean slate; no stale order is left around to
  auto-consume them. Verified with a standalone Node simulation (drain-loop logic only, no
  DOM/canvas) reproducing the exact 50→40→30 stacking scenario plus a post-cutoff
  reinforcement arrival, confirming spawned total caps at 50 and the reinforcement's 10 troops
  stay in the castle untouched.

---

### AI attack sizing rewrite (this session — was "AI keeps sending troops pointlessly")
This went through three iterations before landing on something robust — worth recording all of
them since the earlier "fixes" are exactly the kind of clever-but-fragile math this replaced.

1. **First report**: "the AI keeps sending troops pointlessly." The castle defense bonus
   (`CASTLE_DEFENSE_BONUS`, 20%) had been added to `aiAct`'s "defend a teammate" block and to
   fresh-attack target sizing, but not to the "reinforce a teammate's attack that's coming up
   short" block — so the AI judged an assault "topped off" ~20% early, watched it fail, and
   reinforced the same doomed assault forever. Patched by adding the bonus there too.
2. **Second report**: "after the initial attack, which is fine, they fail but keep sending
   troops pointlessly afterwards." Deeper issue: fresh-attack sizing only projected a target
   castle's regen over marching *travel* time, never over the time it takes to actually deploy
   a large force out of the source castle's gate (troops trickle out at `SPAWN_RATE`, not
   instantly). That gap used to be masked because every castle fired arrows pre-tower/castle
   split, and the resulting "arrow shots" bonus over-corrected enough to also cover it by
   accident — once plain castles stopped firing by default, they lost that accidental
   compensation and started undershooting on *every* attack, identically, forever. Patched with
   a two-pass travel+spawn-deploy window estimate.
3. **Third report, with a concrete repro**: converting a tower sitting on 100+ troops
   (reinforcing your own/an ally's building is uncapped — see `unitArrives`, "may exceed 100")
   into a castle, and watching the AI lob 3-4 troops at it repeatedly. **This was the real
   culprit**, and it was present in both patches above: every garrison estimate capped itself at
   `Math.min(towerMax(t), ...)` — including the building's *current* troop count, not just
   projected regen growth. A 105-troop level-1 castle (`towerMax` = 20) was evaluated as if it
   only had 20 troops.

Rather than patch the cap once more, the whole thing was replaced with something deliberately
simple and hard to get subtly wrong: **look at what's actually in the target right now, require
at least 50% more than that.** No regen projection, no travel/spawn-deploy window, no per-type
capping:
```js
const ATTACK_MARGIN = 1.5;
const currentDefense = t.troops + inc[t.id].enemy; // real troops now, no cap, + its own inbound reinforcements
const need = currentDefense * ATTACK_MARGIN - inc[t.id].team; // minus our team's own inbound attackers
```
Used identically in both the section-2 "reinforce an ally's attack" block and section-3
`evalTarget` (fresh-target sizing). The flat 1.5x comfortably clears the real capture math (a
castle only needs 1.2x to fall, see `unitArrives`) plus slack for regen/arrow uncertainty during
the march, in one number that's trivially easy to verify by inspection — a 105-troop castle
now requires ~158 attackers, not ~24. `revengeMargin` (extra caution when retaking a castle just
lost, `REVENGE_COOLDOWN` window) is now a small additional multiplier on top (1.3x) rather than
stacking with an already-inflated need. The now-unused `projectedGarrison` helper and the
travel/spawn-deploy window math were removed entirely.

### Accounting for tower fire along the march route (this session — feature, not a bugfix)
Requested: the AI should factor in how many troops will die to a tower's fire if one sits in
their path — not just when the tower IS the destination. Added `expectedLosses(g, src, dst,
isTeam)`: for every hostile tower (or currently-buffed hostile castle), checks whether the
straight-line route from `src` to `dst` passes within that tower's `towerRange`
(`pointToSegmentDist`, a new small geometry helper next to `dist`), and if so estimates how many
shots it gets off during the exposure — chord length of the route inside its range circle,
converted to time via `UNIT_SPEED`, divided by its fire cooldown. Deliberately approximate (real
units wobble/lane-offset near arrival, and a tower always shoots the single nearest hostile
rather than marching lockstep down the column) — it only needs to be in the right ballpark.
Folded into both attack-sizing paths in `aiAct`: `evalTarget` (fresh-target sizing, added
straight into `need`) and section 2 (reinforcing an ally's attack, added to `need` once a
helper source — and therefore a route — is known). Since a target's own tower fire is just the
`segDist === 0` case of the same calculation, this also naturally subsumes what used to be a
separate "the destination shoots back" special case, and additionally makes the AI's own
target-selection scoring implicitly prefer routes that avoid gauntlets, without any extra code
for that.

### The actual root cause of "keeps sending troops after a failed attack" (this session — the real fix)
All three earlier attempts in this session (see "AI attack sizing rewrite" above) made the
*estimate* more accurate, but missed a much dumber bug sitting right next to it: `evalTarget`
clamps its result with `Math.max(0, need)`, so once a target was already sufficiently covered
by troops the AI had in flight, `need` came back as exactly `0` — never negative. Downstream,
`minSend = need * revengeMargin` was then also `0`, and the bracket-picker
`[25, 50, 75].find(o => Math.floor(src.troops * o / 100) >= minSend)` trivially satisfies
`>= 0` on its very first option no matter what `src.troops` is (short of literally 0 troops).
So `choice` was *always* truthy, and the AI *always* fired off a fixed ~25%-of-current-garrison
order at whatever target currently scored lowest — which, once a target's need reads as 0, tends
to keep scoring lowest (`0 + small distance term`) for many ticks in a row, since sending yet
more troops at it only pushes `inc[t.id].team` up further and keeps `need` pinned at 0. The
result: a small, near-constant-sized order (whatever 25% of that AI's current strongest castle
happens to be — commonly single digits) fired at the same already-covered target on every single
`aiAct` tick, indefinitely. This is what looked like "sending troops pointlessly after a failed
attack" — the target doesn't even need to have failed; the AI would do this to any target it had
already thrown enough force at, win or lose.

Fixed on two levels: (1) target selection now skips any target with `need <= 0` outright — being
already-covered isn't a tiebreaker-losing reason to attack less, it's a reason not to attack at
all; (2) even after that, `minSend < 1` short-circuits before the bracket search runs, so a
near-zero-but-technically-positive need can't sneak through and still trigger a token attack.

### Population cap: MAX_POPULATION, a per-PLAYER budget scaled by building count (this session — took five tries)
1. **First pass**: hard per-building cap, clamping reinforcement growth itself at 50.
2. **Corrected to**: a flat total population budget per PLAYER (sum across everything they own,
   with a single building allowed to exceed 50 via consolidation) — based on a misreading of
   "total population."
3. **Corrected again**: back to a per-BUILDING cap, but flat and level-independent for BOTH
   regen and reinforcement — a level-1 building could regen all the way to 50, not just its old
   `towerMax` of 20.
4. **Corrected again**: regen reverted to level-scaled (`towerMax`, unchanged from the base
   game) since that was never supposed to change; `MAX_POPULATION` (flat 50) became a separate,
   *per-building* reinforcement ceiling instead — a level-1 building could be topped up to 50 by
   reinforcement even though it'd only regen to 20 on its own.
5. **Corrected once more, final**: there's no per-building ceiling at all — a building can hold
   as many troops as reinforcement brings it, full stop. Regeneration still only fills a
   building up to its own level cap (unchanged, step 4 got this part right). What actually
   scales is the player's total budget across ALL their buildings, and it scales *with how much
   they own*: `buildingCount(player) * MAX_POPULATION` — a player with 10 buildings can regen up
   to a 500-troop total, not a flat 50.

Final implementation, in the regen step of the game loop:
- Reinforcement (`unitArrives`) has no cap at all: `t.troops += 1`. Moving troops between a
  player's own buildings only redistributes population they already have — it can't create
  more, so it never needs to respect any budget.
- Regen computes `buildingCount[owner]` and `totalPop[owner]` for every player once per tick,
  then each building's regen room is `Math.min(cap - t.troops, buildingCount[owner] *
  MAX_POPULATION - totalPop[owner])` before applying `towerRegen(t) * dt` — i.e. bounded by
  BOTH the building's own level cap AND the player's building-count-scaled total budget,
  whichever is tighter.

Verified with simulations: (a) reinforcement is genuinely unbounded — 100 arrivals on a
level-1 building take it to 105+; (b) with plenty of budget headroom, regen still stops at each
building's own level cap exactly as before (two level-1 buildings → 20 + 20, not more); (c) the
budget *can* be the actual binding constraint even when a building is below its own level cap —
one building reinforced to 95 plus a second, mostly-empty level-1 building (own cap 20) only
gets to regen 2 more troops before the pair hits their shared 100-troop budget (2 buildings ×
50), stopping at 5 rather than climbing to 20.

### Capacity headroom above the upgrade threshold: towerCapacity (this session)
Added `CAPACITY_BONUS = 5` and `towerCapacity(t) = towerMax(t) + CAPACITY_BONUS`. Upgrade
eligibility and cost are still keyed to `towerMax` alone — a level-1 building is still
upgrade-ready at 20 troops, unchanged. What changed is the regen *ceiling*: a building that
isn't upgraded yet can now keep passively regenerating past its upgrade-ready point, up to
`towerCapacity` (25/35/45/55 for levels 1–4) instead of stopping dead at `towerMax`
(20/30/40/50). This only matters for a player who chooses not to upgrade immediately — leaving
a level-1 castle alone now banks up to 25 troops, not 20.

`MAX_POPULATION` (the per-building unit of a player's total regen budget — see above) is
derived from this rather than hardcoded, so the two stay in sync: `MAX_POPULATION = (MAX_LEVEL +
1) * BASE_MAX + CAPACITY_BONUS = 55`. A player's total budget is now `buildingCount * 55`, not
`* 50`. Neutral towers also start at full `towerCapacity` now (previously just `towerMax`), so
a level-1 neutral tower spawns with 25 troops instead of 20 — consistent with "start full for
that level" now meaning the actual capacity ceiling, not just the upgrade threshold.

Also updated the garrison-plate UI's over-capacity highlight (the colored border around the
troop-count plate) from `troops > towerMax(t)` to `troops > towerCapacity(t)` — otherwise it'd
light up on essentially every building that regens past its upgrade threshold, which is now the
normal case rather than a true "reinforced past what this building can naturally hold" signal.

### Momentum: replaced the flat castle defense bonus (this session)
`CASTLE_DEFENSE_BONUS` (the flat 20% castle-defends-stronger rule from an earlier session) is
gone. In its place: every player has a **momentum** multiplier, baseline `1.0` (100%), that
rises when they win fights and falls when they lose them — a streaky, dynamic combat modifier
instead of a static per-building-type bonus.

**Mechanics** (all in `unitArrives` and the arrow/boulder kill loop, game loop):
- Combat damage per hostile arrival is `momentumMult(attacker) / momentumMult(defender)` — at
  baseline (both 1.0) that's exactly 1, so an N-troop building falls to N attackers with truly
  no bonus either way (this is what "remove the defense advantage" meant — not just deleting the
  number, but replacing the whole mechanism with something dynamic).
- Every attacker killed by a tower or castle defense — whether by arrow/boulder fire in transit,
  or by the defending garrison itself (the "chip" branch of `unitArrives`, one call = one dead
  attacker, regardless of the fractional damage a momentum edge lets it deal) — shifts
  `MOMENTUM_KILL_STEP` (0.5%) both ways: defender up, attacker down.
- Capturing a building (the very last arrival, the one that succeeds) is worth
  `MOMENTUM_CAPTURE_BONUS` (20%) to the capturer alone. The player who loses the building gets
  no corresponding penalty for the loss itself — only whatever momentum they already bled from
  kills earlier in the same siege stands; losing the ground is free.
- Momentum is clamped to `[MOMENTUM_MIN, MOMENTUM_MAX]` (0.4–2.5) so the damage ratio can't go
  degenerate (zero/negative or absurdly lopsided) after a long losing or winning streak.
- NEUTRAL always reads as exactly 1.0 (`momentumMult` falls through for any owner outside
  `0..numPlayers-1`) — it isn't a player, can't build or lose momentum, but attackers still lose
  their 0.5% per casualty fighting a neutral (deaths are deaths regardless of who caused them);
  there's just no one on the other side to gain it.

Verified against both of the worked examples from the request: 10 attackers killed with no
capture → defender +5%, attacker −5% (105%/95%) exactly; 30 sent, 20 killed, then a capture →
attacker down 10% from the kills, up 20% from the capture, net +10% (110%) exactly. Also
verified the damage ratio itself: at baseline a 50-troop building takes 50 attackers (matches
towers' old no-bonus behavior); attacker momentum 1.05 vs. defender 0.95 only takes 46; the
reverse takes 56 — scales proportionally as expected, with only small-troop-count quantization
at very small garrisons (e.g. 10 troops) where the discrete per-arrival hit count doesn't divide
evenly.

**AI**: `aiAct`'s three attack/defense-planning spots that referenced `CASTLE_DEFENSE_BONUS`
now multiply by the relevant player's `momentumMult(g, owner)` instead — the defending player's
momentum in the "defend a teammate" and target-sizing paths, so an AI won't misjudge a
streaking defender as an easy target. `ATTACK_MARGIN` (1.5x, from the earlier attack-sizing
rewrite) still supplies the general safety buffer on top; attacker-side momentum isn't
separately modeled in the sizing math, left as a reasonable simplification.

**Display**: player names + live momentum are now shown automatically, top-right of the play
screen, no toggle required — small translucent pill chips (`rgba(10,14,24,0.32)` background,
`pointerEvents: "none"` so they never intercept a tap), one per living player, colored dot +
name + percentage (green above 100%, red below, gray at exactly 100%). Eliminated players are
filtered out. Also added a compact `· 105%` momentum readout to the existing toggleable 👥
players dropdown, alongside the towers/troops count it already showed.

### Momentum tuning: smaller kill step, build bonus, passive recovery (this session)
Three adjustments on top of the momentum system above:
- **Kill step halved**: `MOMENTUM_KILL_STEP` 0.5% → **0.25%** per attacker killed by a
  tower/castle defense. Combat swings momentum more gradually now.
- **New: build bonus**. Completing an upgrade OR a castle↔tower conversion now grants
  `MOMENTUM_BUILD_BONUS` (**+2%**) via a new `applyMomentumBuild(g, owner)` helper — called from
  the upgrade-completion block in the game loop (level-up moment, not when the build starts) and
  from `convertBuilding` (which is instant, so immediately). Rewards investing in your economy,
  independent of combat outcomes.
- **New: passive recovery below baseline**. Anyone sitting under 100% momentum climbs back
  toward it on their own over time — `MOMENTUM_RECOVERY_STEP` (1%) per
  `MOMENTUM_RECOVERY_INTERVAL` (5s). Implemented as a continuous per-frame rate
  (`MOMENTUM_RECOVERY_STEP / MOMENTUM_RECOVERY_INTERVAL` per second × `dt`) rather than a
  discrete 5-second tick, for smoothness — mathematically equivalent in aggregate, verified with
  a standalone simulation (5×1s steps from 90% → exactly 91%). Explicitly one-directional: only
  applies below 1.0, clamped with `Math.min(1, ...)` so it can never overshoot past baseline or
  pull a winning streak (momentum > 1) back down — it's a floor-recovery mechanic, not
  regression to the mean.

Verified all three with standalone simulations matching the spec exactly: 10 kills now move
momentum by exactly ±2.5% (not ±5%); one upgrade/conversion adds exactly +2%; recovery from 90%
reaches exactly 91% after 5 simulated seconds and correctly caps at 100% rather than overshooting
when starting close to baseline.

### Momentum tuning, round 2: symmetric revert, bigger build bonus (this session)
Two more adjustments on top of the round above:
- **Build bonus raised**: `MOMENTUM_BUILD_BONUS` 2% → **5%** for completing an upgrade or a
  castle↔tower conversion.
- **Decay above baseline**: momentum over 100% now also drifts back down on its own — 1% per
  5s, the same rate and mechanism as the existing below-baseline recovery. Renamed
  `MOMENTUM_RECOVERY_STEP`/`_INTERVAL` → `MOMENTUM_REVERT_STEP`/`_INTERVAL` since the mechanic is
  now symmetric (pulls toward baseline from either side) rather than one-directional recovery.
  Still a continuous per-frame rate, not a discrete tick; still can't overshoot past 1.0 from
  either direction. A kill or capture landing in the same tick isn't fought — this is just
  steady background pressure toward the middle between combat events, not a hard clamp.

Verified with a standalone simulation: from 110%, 5 simulated seconds of decay lands at exactly
109%; from 90%, recovery still lands at exactly 91% (unchanged); from 100.3%, decay settles
exactly at 100% rather than overshooting past baseline.

### Momentum tuning, round 3: capture bonus lowered (this session)
`MOMENTUM_CAPTURE_BONUS` 20% → **15%** for the player who captures a building. Everything else
about the mechanic is unchanged — still capturer-only, still no penalty for the player who lost
the building.

### AI momentum-awareness + defensive posture (this session)
Requested: the AI should be more aware of momentum and play more defensively sometimes. Two
distinct things landed:

**A real correctness bug, fixed**: `evalTarget` (fresh-attack sizing) and section 2's
"reinforce an ally's attack" required-force calc both multiplied by the DEFENDER's momentum
(`momentumMult(g, t.owner)`) but never divided by the ATTACKER's own — even though the real
combat formula in `unitArrives` is symmetric (`attackerMomentum / defenderMomentum` per
arrival). A weakened AI (momentum < 1) was therefore underestimating what its own attacks
needed by exactly the amount its own weakness should have cost it. Fixed by dividing by
`myMomentum` (computed once at the top of `aiAct`) in both places. Verified: evaluating a
20-troop target, a momentum-0.8 attacker now correctly needs ~37.5 troops (not 30), and a
momentum-1.3 attacker correctly needs only ~23.1.

**Defensive posture while cautious** (`myMomentum < MOMENTUM_CAUTIOUS` = 0.9): three behavior
changes, all gated on this one flag —
- **Section 1 (defend)** reacts to smaller threats: the shortfall threshold that triggers
  sending reinforcement drops from 1 to 0.4. Better to overreact defensively while already
  weak than lose more ground and feed the spiral.
- **Section 3 (expand)**: `revengeMargin` — previously only extra-cautious about retaking a
  castle just lost — now also carries a flat 1.25x multiplier whenever cautious, on top of the
  (now-corrected) momentum-adjusted need. A weakened AI won't gamble on expansion unless it has
  a clearly superior force, not just a technically-sufficient one.
- **Fallback consolidation**: previously a flat 25% chance to shuffle troops toward the
  weakest owned castle when nothing else qualified. While cautious this is now unconditional
  (not a coin flip) and sends 50% instead of 25% — actively shoring up the weakest point rather
  than leaving it to chance, which is the actual point of "playing defensively" rather than
  just declining to attack.

Not implemented: AI-triggered castle↔tower conversion for defense (would also net a momentum
build bonus) was considered but left out to keep this change scoped — conversion has been a
player-only action so far, and having the AI use it risks awkward timing (e.g., converting away
regen capability mid-siege) without more tuning than fits here.

### Menu doubles as pause; players button and standalone pause button removed (this session)
Requested: drop the 👥 players button and the ⏸/▶ pause button, and have the ☰ Menu button
itself act as pause. Implementation:
- The Menu button's `onClick` now toggles `menuOpen` AND `paused` together in one state update
  (open → paused, close → resume) instead of two separate buttons/handlers.
- Tapping outside the menu to close it, and the "🗺️ New map" item inside it, both also call
  `setPaused(false)` so they can't leave the game silently stuck paused after closing the menu
  some other way than the Menu button itself.
- The old full-screen "PAUSED" overlay (centered text + its own Resume button) is gone — it was
  purely a byproduct of the standalone pause button and would otherwise show redundantly
  alongside the Menu dropdown every time it's open. The Menu dropdown itself is now the only
  paused-state UI.
- The `showPlayers` state, its toggle button, and its whole dropdown (which showed a 2-per-row
  grid of team/player chips with towers/troops/momentum) are removed entirely — the
  always-visible momentum panel added earlier this session already covers names + momentum
  without a button, and the towers/troops figures that dropdown also showed aren't shown
  anywhere else now (out of scope for this change; can be re-added on request).
- `paused`/`pausedRef` themselves are untouched structurally — they still gate `handleDown`/
  `handleUp` and the main step loop exactly as before. Only how they get set/unset (and whether
  a dedicated overlay reacts to them) changed.

### Rally, Sabotage, and Fortify fully spec'd and implemented (this session)
Continuation of the hero-kit design from last session. All three are now real, tested code
— banked the same way Second Wind and Tower Defense 2.0 are (not wired into the active
specials UI/train/AI, since the hero-picker system still doesn't exist).

- **Rally** (Tier 1): instant +10% momentum (`RALLY_MOMENTUM_BOOST`) to the caster alone,
  never the team. Simplest of the three — no troops, no targeting.
- **Sabotage** (Tier 3, moved up from the Tier 2 slot proposed last session): a two-part
  effect, finalized after clarifying an ambiguous first draft ("give 30 troops to enemy
  buildings" turned out to mean something closer to the opposite — see below). (1) Weakens
  every enemy building on the map (excludes neutral/unclaimed and the caster's own team) by
  a combined 30 troops (`SABOTAGE_TOTAL_DAMAGE`), split evenly across however many enemy
  buildings currently exist. (2) A flat 5-troop threshold check (`SABOTAGE_SNEAK_TROOPS`)
  against whichever ONE enemy building is weakest after that debuff — if its post-debuff
  troops are under 5, it's instantly captured for the caster. No real troops are deducted
  from the caster for the "sneak" part; it's a threshold check, not a marching squad.
- **Fortify** (Tier 3): the "turtle" ability identified as the clear gap last session.
  Temporarily grants the caster's (or team's) buildings +50% effective defensive troop
  strength (`FORTIFY_MULT`) for 10 seconds (`FORTIFY_DURATION`) — attackers need 50% more
  troops to take a Fortified building during that window.

**Also changed this session: `TOWER_DEF_DURATION` 12s → 10s**, specifically requested so
Tower Defense and Fortify — the game's two Tier-3 timed buffs — share one duration. This
affects the banked Tower Defense 2.0 too, since it shares the same constant.

**Implementation notes:**
- Fortify's buff is a lazy timestamp check (`fortifyMult(g, t)`, comparing
  `t.fortifyExpiresAt` against `g.pulse` on demand) rather than an actively-reset flag like
  Tower Defense's `d.rateMult`/`rateExpiresAt` pair — no per-frame cleanup loop needed,
  since every consumer already does the comparison itself each time it asks.
- `fortifyMult` had to be threaded into every place a building's defensive troop strength
  is computed, not just the obvious one — the real combat formula in `unitArrives`, all
  three of the AI's defense-estimate call sites (`aiAct`'s defend/reinforce/expand
  sections), and Second Wind's own "worst deficit" targeting calc from last session. Missing
  any of these would have silently made Fortify inert in the AI's eyes (repeating the exact
  shape of bug fixed earlier this project, where the AI's attack-sizing didn't account for a
  defender's momentum) or made Second Wind misjudge a Fortified building as more threatened
  than it really is.
- Extracted a shared `captureBuilding(g, t, newOwner)` helper out of `unitArrives`' capture
  branch, so Sabotage's instant-capture could reuse the *exact* same logic (momentum bonus,
  level knockdown, defs/Fortify buff reset, order cancellation, tutorial flag) rather than a
  second copy that could quietly drift out of sync over time. `unitArrives` itself is
  otherwise unchanged aside from calling this helper and folding `fortifyMult` into its
  damage formula.
- Sabotage's clarifying exchange is worth recording: the first draft phrasing ("give a
  combined 30 troops split among enemy buildings") read as literally strengthening the
  enemy, which would contradict an ability called Sabotage — asked rather than guessing,
  and the actual answer turned out to be a two-part weaken-then-snipe-capture mechanic quite
  different from the original "debuff regen/fire rate" framing floated last session.

Verified: a standalone simulation of Rally's momentum clamp (including near the ceiling);
Fortify's lazy-expiry multiplier at three points (before cast, mid-buff, after expiry, with
no active reset step involved) and its effect on the real combat formula; two Sabotage
simulations covering the full weaken-then-snipe-capture flow (confirming neutral and the
caster's own buildings are correctly excluded from the debuff, the damage split matches the
enemy building count, and the snipe-capture boundary case — post-debuff troops exactly
equal to 5 — correctly does NOT capture, since the check is strictly "under 5"). Also the
standard Babel transpile check and a full Playwright playthrough (load → Deploy → drag
troops → idle AI turns) with zero page errors — notable this time since, unlike Second
Wind, this session's changes (the capture refactor, the Tower Defense duration change, the
Fortify hooks threaded through the AI's live attack-sizing code) touch code paths every
real match already runs, not just banked/unreachable functions.

### Hero roster design (planning) + Second Wind implemented (this session)
Started as a question about turning the game into an online multiplayer experience.

**Multiplayer architecture plan (discussed, not implemented — no code changed for this
part).** Confirmed via current docs that Vercel's serverless/edge functions can't hold a
persistent connection well (even their new WebSocket beta pins to one instance, no
built-in fan-out) — Vercel is the right choice for hosting the static frontend, but not
for the realtime layer. Landed on: **Vercel** (static hosting) + **Supabase Realtime**
(Presence + Broadcast channels — explicitly built and documented for this exact multiplayer
use case, no custom server needed) + a **host-authoritative** model, since this game's sim
is a continuous `requestAnimationFrame` loop, not turn-based, and true deterministic
lockstep across browsers would be fragile (heavy `Math.random()` use in map gen/AI). Plan:
whichever player creates a room keeps running the existing simulation exactly as-is
(`gameRef`, the RAF loop, `aiAct` for any unfilled seat); other players' inputs
(`issueOrder`/`startUpgrade`/`startConversion`/`castPlayerSpecial` calls) get broadcast
instead of applied locally, the host receives them and calls those same functions, and the
host periodically broadcasts a state snapshot that everyone else just renders — no
lockstep, no rewrite of game logic. Confirmed requirements from the user: matches
support **both** a public lobby (a Presence-tracked room list) **and** direct
invite-by-room-code (same room-channel mechanism either way, just discovered differently),
and **up to 4 humans** (matching the existing FFA/2v2 modes), with any unfilled seat
staying AI-controlled exactly like single-player today.

Attempted to connect the Supabase MCP connector to start building this for real, but hit a
snag: the OAuth flow's "open desktop app" handoff did nothing, and even after the user
confirmed (via screenshot) that Supabase's own page showed "Connected," repeated
`tool_search` calls from this end never surfaced any Supabase tools — only Chrome
browser-automation tools loaded. Landed on: the account-level authorization likely
succeeded, but the connector probably needs to be toggled on for this specific
conversation (a separate state from account-level connection) and/or the tool list needed a
fresh conversation to pick it up. **Unresolved this session** — next session should retry
`tool_search` for Supabase tools before doing anything else if multiplayer work continues;
if still unavailable, check Claude's connector settings directly (outside chat) for
whether Supabase shows connected-but-off-for-this-chat vs. not connected at all.

From there, pivoted into a **hero system** design discussion: each hero would have a
unique 3-ability kit, one ability per tier (T1/T2/T3), reusing the existing specials-train
tier shape (cheap/fast → strong/slow) as the balance framework.

**New ability pool discussed, alongside the 3 existing specials (Slow Down/Speed/Tower
Defense) and the shelved Tower Defense 2.0:**
- **Second Wind** (T1) — now implemented, see below.
- **Rally** (T1, not yet implemented) — instant flat momentum nudge toward the caster.
- **Sabotage** (T2, not yet implemented) — instant debuff on an enemy building's regen or
  fire rate; conceived as Slow Down's mirror image (troops vs. buildings).
- **Barricade** (T2, not yet implemented) — briefly raises the troop threshold to capture
  the caster's buildings.
- **Fortify** (T3, not yet implemented) — strong temporary defense buff, the "turtle"
  answer to Tower Defense's "tempo" framing; identified as the clearest gap in the current
  kit, since Tower Defense is really offense/tempo despite the name.

A sample 3-hero split discussed (not committed to): Hero A = Slow Down/Speed/Tower Defense
(literally today's default kit, useful as a balance baseline), Hero B =
Rally/Sabotage/Fortify, Hero C = Second Wind/Barricade/Tower Defense 2.0 (reusing the
shelved special as a hero-exclusive ultimate rather than a generic rotation slot).

**Second Wind, fully spec'd through iteration and implemented this session:**
Instantly adds a flat 15 troops (`SECOND_WIND_AMOUNT`) to ONE of the caster's own
buildings — never a teammate's, even in 2v2 (deliberately breaks from every other
special's team-inclusive targeting). Targets whichever of the caster's own buildings has
the worst defense deficit against hostile troops actually marching at it right now
(reusing the same incoming-threat tally shape `aiAct` already computes elsewhere — both
`g.units` in flight and still-queued `g.orders` count — just scoped to one player's own
buildings instead of a team). Falls back to the caster's weakest building by current troop
count if nothing is under attack, so the cast is never wasted. Landed on this shape after a
few iterations: started at "10 troops to every building" (rejected — scales with building
count, so it rewards whoever's already ahead instead of helping whoever's behind, and 10
troops instantly is already half of what upgrading a level-1 castle costs), through "15 to
whichever building is under attack, fallback to weakest, own buildings only" as the final
spec.

Implemented as `castSecondWind(g, owner)`, placed alongside the other special-cast
functions and following their shape exactly (visual ring + sparks in a new amber/orange
`#FFA94D`, distinct from every other special's color; a new `SoundEngine.secondWind` rising
double-chime, distinct from the sweep-based speed/slow sounds). **Not wired into the active
specials UI array, `SPECIAL_STAGE`, or `aiSpecials`** — same "banked, not deleted" treatment
Tower Defense 2.0 got, since there's no hero-picker system yet to gate which 3 abilities
are active per player. It's built and verified now so it's a drop-in the moment hero
selection exists.

Verified with a standalone targeting simulation covering both the worst-deficit-among-own-
buildings case (confirming an ally's building in objectively worse shape is correctly
ignored, even though it'd otherwise "win" the deficit comparison) and the no-one's-under-
attack fallback case (confirming an ally's weaker building is still correctly ignored in
favor of the caster's own weakest) — both matched spec exactly. Also ran the standard Babel
transpile check and a full Playwright playthrough with zero page errors.

### Conversion now takes real build time, like upgrading (this session)
Reported as "conversion takes as much time as upgrading" — checked the code and found the
opposite was true: conversion was actually instant (fired the moment Confirm was tapped),
with zero relation to upgrading's 5s build. Clarified with the user: intent was to make
conversion legitimately take 5s of build time too, not to speed anything up.

Replaced the old `convertBuilding(g, t)` — which deducted `CONVERT_COST`, flipped `t.type`,
and reset `t.level` all synchronously in one call — with `startConversion(g, t)`, which now
follows the exact same shape as `startUpgrade`: pay the cost up front, then start a real
build. It reuses `t.upgrading` (the same field that already gates upgrades) with a new
`kind: "convert"` tag and a stashed `toType`, so the two are automatically mutually
exclusive and share the existing dust/hammer "under construction" animation for free — no
new rendering code needed, since that animation was already generic (no level-specific
labels baked in). Added `CONVERT_DUR = 5` (named separately from `UPGRADE_DUR` even though
currently equal, so either can be retuned independently later) and split the old single-shot
build-completion block into two branches on `t.upgrading.kind`: `"upgrade"` increments
`t.level` as before; `"convert"` flips `t.type` to the stashed `toType`, resets to level 1,
resets the defense tower's buffs/position, and fires the same ring/spark burst the old
instant version used — now landing at build completion instead of at confirm-tap. A
building captured mid-conversion has its build cancelled with no refund, for free, since
that cancellation (`t.upgrading = null` on capture) was already generic across both kinds.

Updated every place that described the old instant behavior: the confirm bubble's own label
text (now states the 5s build), the tutorial step that introduces conversion, the in-game
Help panel, and the reference sections of this doc (the mechanics list, the constants table,
and the function-reference list) — deliberately left the *historical* momentum-tuning
changelog entry that mentions "`convertBuilding` (which is instant...)" untouched, since
changelog entries are a record of what was true at the time, not living documentation.

Verified: Babel transpile check; a standalone simulation driving `startConversion` +
the completion loop through a full 5s build confirms the building stays at its old
type/level with the cost already deducted for the entire build (checked at 4.9s, still
mid-build) and only flips to the new type/level exactly at completion (5.1s), plus that a
mid-build castle correctly reports `canConvert() === false` (can't double-start); and a full
Playwright playthrough (load → Deploy → drag troops → idle AI turns) with zero page errors.

### Momentum tuning, round 5: range narrowed to 75%–150% (this session)
`MOMENTUM_MIN` 0.4 → 0.75, `MOMENTUM_MAX` 2.5 → 1.5 — momentum's floor/ceiling narrowed
from a 40%–250% swing to 75%–150%. Pure constant change; `clampMomentum` itself, the
percentage display (`Math.round(momentum * 100)`, no fixed-range scaling to update), and
the AI's `MOMENTUM_CAUTIOUS = 0.9` posture threshold all already worked off the live
min/max rather than hardcoding the old numbers, so nothing else needed touching. Verified
the clamp behaves correctly at the new bounds via a standalone simulation, plus the
standard Babel transpile check and a full Playwright playthrough — zero page errors.

### Momentum tuning, round 4: kill step lowered, capture bonus lowered (this session)
Requested: `MOMENTUM_KILL_STEP` 0.25% → 0.15% per kill (defensive-fire kills only — field
clashes still don't touch momentum, unchanged from earlier sessions), and
`MOMENTUM_CAPTURE_BONUS` 15% → 10%. Both are pure constant changes in the same spot as
prior momentum tuning rounds; no logic changed. Also updated the in-game Help panel text,
which quoted the old 0.25%/15% figures verbatim and would otherwise have gone stale.
Verified with a Babel transpile check and a full Playwright playthrough — zero page errors.

### Fixed castles clipping off the screen edge, especially after upgrading (this session)
Reported: buildings getting cut off at the sides, especially after upgrading. Root cause
traced to `MAP_EDGE_MARGIN` (the inset used both by `generateMap`'s elliptical template
placement and `recenterCastles`' post-relaxation clamp to keep a castle's own point far
enough from the world edge that its sprite doesn't clip) — it was a flat `80`, which turned
out to be wrong on two independent axes at once:

1. **The camera's horizontal perspective zoom.** `proj()`'s screenX = `W/2 + (worldX -
   W/2) * CAM_ZOOM * p`, where `p` (the near-row widening factor) reaches `1 + PERSP/2`
   at the bottom-most row of the board. That means the horizontal zoom at the tightest
   row is `CAM_ZOOM * 1.15 ≈ 1.554`, so the actually-visible horizontal window shrinks to
   roughly 64% of the raw world width there — and a fixed pixel margin can't account for
   that, since the shrinkage is multiplicative (a fraction of W), not additive. Vertical
   turned out not to need any of this correction — `screenY = worldY` exactly, since
   `CAM_ZOOM * TILT` cancels to 1 — so this was purely a horizontal bug.
2. **Per-level sprite growth.** A castle's ground shadow (the widest element of its
   normal, non-buffed silhouette — wider than the keep/turrets themselves) grows from
   ~23 world px radius at level 1 to ~43 at level 4. The old margin was tuned by eye
   against small, fresh, low-level castles, so nothing accounted for how much wider a
   maxed-out one actually gets — hence "especially after upgrading."

Fix: replaced the flat constant with `mapEdgeMarginX(W)`, a proper derivation —
`(W/2) * (1 - 1/(CAM_ZOOM * (1 + PERSP/2))) + CASTLE_MAX_HALF_FOOTPRINT` — that scales
correctly with viewport width and bakes in the level-4 shadow radius as a hard floor.
Vertical keeps a flat `MAP_EDGE_MARGIN_Y = 80`, unchanged, since it never needed the
perspective correction and 80 already comfortably covers a maxed castle's ~60px upward
height. Both `generateMap` and `recenterCastles` now use `mapEdgeMarginX(W)` for the
horizontal clamp/ellipse-radius and `MAP_EDGE_MARGIN_Y` for the vertical one.

Verified: computed `mapEdgeMarginX` at several viewport widths (380/768/1280/1920) and
found the old flat 80 was insufficient at every single one (needed 110–385 depending on
width) — confirming this wasn't a rare edge case but a near-universal shortfall, worse on
wider screens and higher levels. Then directly simulated the actual `proj()` math for a
level-4 castle placed exactly at the new margin boundary, at the worst-case (bottom) row,
at each of those widths: the sprite's rendered edge lands exactly on the canvas boundary
(0px of clipping, 0px wasted) every time — confirming the derivation is both correct and
tight, not just "bigger and probably fine." Also ran the standard Babel transpile check and
a full Playwright playthrough (including a dedicated pass at a 390×844 mobile viewport,
this game's primary target) with zero page errors.

### Decoupled per-level regen and fire-rate curves (this session)
Requested as a follow-up to the fire-rate rebalance above: split the shared `LEVEL_MULT`
table so castle regen speed and tower/castle fire rate can be tuned independently going
forward, instead of one number always moving both.

Replaced the single `LEVEL_MULT` array + `levelMult(t)` accessor with two independent
ones — `REGEN_LEVEL_MULT` / `regenLevelMult(t)` (feeds `towerRegen`) and `FIRE_LEVEL_MULT`
/ `fireLevelMult(t)` (feeds `towerFireCd`). Both start at identical values
(`[1.5, 2.3, 3.1, 4]`, the same numbers the old shared table had), so this is a pure
refactor — it changes nothing about current behavior by itself. Verified with a standalone
simulation confirming both tables produce byte-identical numbers to the old shared one, a
Babel transpile check, and a full Playwright playthrough (load → Deploy → drag troops →
idle AI turns) with zero page errors.

From here, regen and fire rate can each be re-tuned per level without touching the other —
e.g. changing `FIRE_LEVEL_MULT` alone (as requested last session) no longer has any
side effect on castle regen speed.

### Fire rate rebalance: Tower Defense +25% (was +100%), new per-level curve (this session)
Two constant changes, both requested directly:

**`TOWER_DEF_RATE_MULT`**: `2` → `1.25` — the Tower Defense special now boosts fire rate by
25% instead of doubling it. All comparison sites (`d.rateMult === TOWER_DEF_RATE_MULT`) key
off the constant itself, not a hardcoded `2`, so nothing else needed to change structurally
— just the descriptive text that used to say "doubles"/"2x"/"twice as fast" in the help
panel, the Tower Defense tutorial step, and a few code comments, all updated to say "+25%"
for accuracy.

**`LEVEL_MULT`**: `[1.6, 2.2, 3, 4.8]` → `[1.5, 2.3, 3.1, 4]` — per-level fire rate curve.
Worth flagging: this constant is shared between `towerFireCd` (fire rate) AND `towerRegen`
(castle regen speed) — see both functions right below its definition — so this change also
retunes castle regen speed by the same proportions, not just tower fire rate. Called this
out to the user before making the change; no request to split them into independent
constants, so left them shared as before.

Resulting fire cooldowns (`ARROW_FIRE_CD / levelMult`, `ARROW_FIRE_CD = 1.3s`):

| Level | Mult | Cooldown | Shots/sec | w/ Tower Defense (+25%) |
|---|---|---|---|---|
| 1 | 1.5× | 0.867s | 1.15 | 0.693s (1.44/s) |
| 2 | 2.3× | 0.565s | 1.77 | 0.452s (2.21/s) |
| 3 | 3.1× | 0.419s | 2.38 | 0.335s (2.98/s) |
| 4 | 4.0× | 0.325s | 3.08 | 0.260s (3.85/s) |

Verified: Babel transpile clean; full Playwright playthrough (load → Deploy → drag troops →
idle AI turns) came back with zero page errors.

### Slow Down visual effect — so slowed troops are identifiable (this session)
Requested: give the Slow Down special a visible tell on affected troops, like the existing
speed-boost glow. Added to the same soldier-rendering pass in `draw()` (right where the
existing `u.speedMul > 1` teal glow lives), gated on `u.speedMul < 1` instead:
- **A dashed ring beneath the unit**, frost-blue (`rgba(143,163,199,0.85)`) — deliberately a
  *dashed ring*, not a filled glow like the speed boost, so the two effects are visually
  distinct by shape as well as color (matters for colorblind players, and just at a glance
  in a crowded battle).
- **A small rotating 3-line "frost sparkle" above the unit's head**, drawn after the sprite
  so it isn't hidden behind it, gently bobbing (`Math.sin` on `g.pulse`/`u.phase`, same
  desync trick already used for march-frame timing) and slowly rotating. A second,
  unmistakable cue independent of the ring, in case the ring alone is easy to miss in a
  cluttered fight.
Deliberately did NOT tint the sprite itself via per-pixel compositing (`source-atop` over
the drawn sprite) — with many units clustered together that risks bleeding the tint onto
whatever's drawn at the same screen position from a neighboring overlapping sprite. The
ring + sparkle approach is exact per-unit and has no such bleed risk, at the same rendering
cost as the effect it's modeled on.

Verified two ways: a Playwright playthrough (load → Deploy → drag troops → idle AI turns)
came back with zero page errors after the change, same as prior sessions; and — since
driving the real game to a state with an actually-slowed unit on screen requires either a
full tutorial walkthrough or ~20s of real-time train charging plus an active enemy march —
the exact new drawing block was copy-isolated into a minimal standalone canvas harness with
a synthetic `speedMul: 0.75` unit, run in a real browser, and its output pixel-scanned:
confirmed the dashed ring color, the sparkle color, and the sprite itself all render
correctly and don't interfere with each other.

### Specials rework: Tower Defense 2.0 shelved, Slow Down added as new tier 1 (this session)
Requested: pull Tower Defense 2.0 out of active play (but keep its implementation for
possible reuse later), promote Tower Defense to the 3rd/top tier, and add a new 1st-tier
"Slow Down" special that reduces enemy speed by 25%.

**New tier order**: Slow Down (1st stage, 20s) → Speed (2nd stage, 40s, unchanged) →
Tower Defense (3rd stage, 60s, promoted from 1st). The 4-segment train UI structure itself
didn't need to change — it was already 3 active specials + 1 phantom reserve stage; this
just swaps which special sits in which slot.

**Slow Down** (`castSlow`, kind `"slow"`): a mirror image of `castSpeed` — global, instant,
no radius/targeting — but applies `SLOW_DEBUFF` (0.75, i.e. -25%) to every currently-marching
HOSTILE soldier's `speedMul` instead of buffing the caster's own team. Deliberately mild
since it's the cheapest tier. New sound (`SoundEngine.slow`, a falling pitch sweep — the
inverse of Speed's rising one) and a new frost-blue ring color so it reads as its own
effect. AI casts it (`aiSpecials`) against any incoming threat of 3+ (lower bar than
Tower Defense's 5+, since it's cheap and fast to reload).

**Tower Defense 2.0 ("fire") is NOT deleted** — every piece of it (the boulder branch in
`castTowerDefense`, `BOULDER_SPLASH_COUNT`/`RADIUS`, the arrow-flight splash-kill logic,
its sound, its tutorial step) is left fully intact in the code, just disconnected from the
three places that make a special reachable in play:
1. The specials UI array (button list) — its entry is removed, left as a commented-out
   snippet directly below with a note on how to restore it.
2. `aiSpecials` — its cast condition is commented out in place, same restore note.
3. The tutorial step demonstrating it is commented out in `TUTORIAL_STEPS` (its `waitFor:
   "castFire"` would otherwise reference a button that no longer exists — softlock risk if
   left active).
`SPECIAL_STAGE` still maps `fire: 3` (its original top-tier cost) so if it's restored later
nothing about its cost/threshold needs to change. `castPlayerSpecial`'s `fire` branch and
`g.tutorialFlags.castFire` are also left wired up and harmless while unused.

**Verified**: Babel transpile clean; a standalone Node simulation of `castSlow`'s
targeting confirms it slows every unit outside the caster's team (including a third,
unrelated player) while leaving the caster's own units untouched; a full Playwright
playthrough (load → Deploy → drag a troop send → idle AI turns, plus clicking every
special button in the panel) produced zero page errors. The specials panel in that run
rendered exactly `🐢 Slow Down (19s) · 💨 Speed (39s) · 🛡️ Tower Defense (59s)` — no
Tower Defense 2.0 button — confirming both the new order and its removal from the UI.

### Crash on every "Deploy" (this session — the actual reported bug)
Reported as "uncaught error, Script error, when I try to deploy." Root cause: the earlier
"Menu doubles as pause" session removed the `showPlayers` state and its setter entirely, but
missed one call site — `startGame` itself still called `setShowPlayers(false)` on every game
start. Since the setter no longer existed, this threw `ReferenceError: setShowPlayers is not
defined` the instant the Deploy button (or Play Tutorial) ran `startGame`, aborting it every
time. This was already broken in the uploaded build before this session's other two fixes;
confirmed via a headless Playwright run against the original file (routing the three CDN
`<script>` tags — react, react-dom, babel-standalone, pinned to the exact versions the page
requests — to local copies so it can actually execute in a sandboxed, network-restricted
environment) that the crash reproduced identically pre-existing. Fix: deleted the stray line.
Re-ran the same Playwright harness afterward through a full sequence — load, click Deploy,
drag-drop a troop send on the canvas, then several seconds of live AI turns — with zero
`pageerror`s at any step.

### Arrows "missing," and AI still sending hopeless reinforcements (this session)
Two separate reported symptoms, two separate root causes — no relation to each other despite
landing in the same session.

**Arrows visually missing.** Each frame's arrow-flight loop looks its target up fresh out of
`byUid` (rebuilt every frame from live `g.units`) and homes toward wherever that unit currently
is. The bug: if the target died — clash, another arrow, or it simply arrived at its destination
— between the frame the arrow launched and the frame it would've landed, `byUid.get(a.targetUid)`
returns `undefined` from then on. The arrow doesn't re-aim or fizzle on the spot; it freezes
`a.lx/a.ly` at the target's last known position, keeps flying there for however many frames are
left, and then silently `splice`s out with no impact effect once it arrives — no spark, no sound,
nothing. Visually that reads exactly as "the arrow missed," even though there was never really a
miss in the sense of flying past a live target.

Fix: added a one-shot retarget. When an arrow's `tgt` comes back missing (or already claimed by
another arrow this same frame via `arrowKilled`), and it hasn't already tried retargeting once
(`a.retargeted`), it scans live hostile units for the nearest one within `RETARGET_RADIUS` (160px)
of the arrow's *current* position and snaps onto it instead of the stale point. If nothing hostile
is within that radius, it's left alone — coasts to the stale spot and fizzles as before, which at
that point is a genuine miss (nothing was nearby to hit anyway). One retarget attempt per arrow
keeps the extra scan cheap and avoids an arrow endlessly chasing a moving crowd.

**AI reinforcing with hopeless numbers, especially right after losing a building.** Section 2 of
`aiAct` ("reinforce a teammate's attack that's coming up short") gated the send with
`canSend >= Math.min(need, 2)`. For any `need` of 2 or more — i.e. almost always, once there's a
real deficit — `Math.min(need, 2)` just evaluates to `2`, so the entire check collapses to
`canSend >= 2`. A helper castle with only 5 troops to spare would happily commit them to an
assault that actually needed 35+ more, because the guard never looked at `need` past a floor of 2.
Losing a building makes this worse: the castles left over tend to be small, so *most* available
helpers are exactly the "few spare troops, huge real deficit" case this let through. `pct` then
usually resolved to `ATTACK_CAP` (75%) as the fallback since no fixed bracket cleared such a small
clamped `need`, compounding it — the AI would dump most of a nearly-empty castle's garrison into a
fight it had no chance of affecting.

Fix: replaced the guard with `canSend >= need * 0.6`, the same proportional standard already used
by section 1 (defend) just above it — commit only if the helper can cover a real majority of the
shortfall, not just clear an unrelated floor of 2. Verified with a standalone comparison: the
5-troops-vs-~35-deficit case now correctly declines (old guard let it through), while genuine
small top-offs (e.g. 1 spare troop covering a 1.4 deficit) still go through as before.

### Tower Defense 2.0 renamed to Barrage, reworked as a tower-only Tier 2 hero-kit ability (this session)
Requested: bring the banked "Tower Defense 2.0" special back under a new name, restrict it to
towers only, and make it a Tier 2 ability. Decided (per explicit direction) NOT to activate it
in the live 3-slot train — it goes straight into the hero-kit pool alongside Second Wind/Rally/
Sabotage/Fortify, for whenever the hero-picker system gets built.

Changes:
- **Renamed** `castTowerDefense`'s old boulder branch (`kind === "fire"`) into a standalone
  `castBarrage(g, owner)` function, following the exact same shape as the other hero-kit
  abilities (own ring/color `#FF3B30`, own `SoundEngine.barrage` sound — renamed from
  `towerDefense2` — own `setCd(g, "barrage", owner)`).
- **Tower-only**: `castBarrage` filters to `t.type === "tower"` before touching a building's
  `defs`, so — unlike Tower Defense — it never sets `d.boulder` on a castle and therefore never
  temporarily grants a castle firing capability. Verified with a standalone Node simulation
  (4 buildings: own tower, own castle ×2, enemy tower — only the own tower ends up affected).
- **`castTowerDefense` simplified back to storm-only** (dropped the `kind`/`boulder` branch
  entirely — it was only ever used for the old "fire" slot).
- **`SPECIAL_STAGE` now only has 3 entries** (`slow`/`speed`/`storm`) — `fire` is gone. Since
  Barrage isn't part of the train at all, it doesn't need a `trainThreshold` mapping — same as
  every other hero-kit ability.
- **Removed the old "banked, quick-restore" scaffolding** that kept Tower Defense 2.0 wired into
  train-adjacent UI state even while pulled from the active rotation: the `fireSecs`/`fireCd`
  keys on the specials-info state, the `fire` entries in the pulse/`prevSecsRef` ready-flash
  tracking, the `castFire` tutorial flag, the commented-out tutorial step, and the commented-out
  `aiSpecials`/UI-array restore snippets. Barrage gets the same minimal footprint as the other
  hero-kit abilities instead (just the `cast____` function itself, nothing wired into the UI).
- Updated the hero-kit table and sample-roster note in this doc; Hero C ("Siege") is now
  Second Wind / Barrage / (open Tier-3 slot).
- Verified: Babel transpile check on the full script block passed, and the tower-only targeting
  was confirmed with the Node simulation described above.

### Frost, Rage, Rolling Stones, and Instant Upgrade added — hero-kit tier grid now complete for 4 heroes (this session)
Requested: fill out the hero-kit pool to a clean 4-per-tier grid (12 abilities total, counting
the 3 active train specials) so 4 fully-unique hero kits are possible. Four abilities specified
by name/tier/effect; implemented all four following the established "banked hero-kit ability"
shape (own `cast____(g, owner)` function, own ring color, own `SoundEngine` sound, own `setCd`
key) — none wired into the specials UI array, `SPECIAL_STAGE`, or `aiSpecials`.

- **Instant Upgrade** (Tier 1): picks one random eligible building the caster owns (level below
  `MAX_LEVEL`, not already mid-build) and completes an upgrade on it instantly — no troop cost,
  no build timer. No-ops if nothing is eligible.
- **Rage** (Tier 2): team-inclusive momentum boost (`RAGE_MOMENTUM_BOOST = 0.50`) — the Tier-2
  answer to Rally, explicitly boosting every ally's momentum (not just the caster's) at a bigger
  number to justify the higher tier.
- **Rolling Stones** (Tier 2): transforms every currently-marching allied unit for the rest of
  its march (permanent transformation, same "no duration" shape as Speed/Slow Down). Three
  effects threaded into three different systems: (1) `ROLLING_STONE_STRENGTH_MULT = 4` applied
  in `unitArrives` at the same point momentum already scales combat — field-to-field clashes
  deliberately stay ordinary 1-for-1, since momentum doesn't touch those either, keeping this
  consistent with the existing damage model instead of inventing a parallel one; (2) excluded
  from every tower-targeting loop (nearest-target search, arrow retarget, boulder splash) via a
  `u.rollingStone` check, so they can't be shot by towers; (3) `unitArrives` special-cases a
  Rolling Stone hitting an enemy **castle** specifically — full damage still lands but the
  troops are clamped at a floor of 1, so that arrival can never be the one that captures it. A
  non-stone unit (or later wave) is still needed to finish that capture. Towers have no such
  restriction — Rolling Stones can capture a tower outright, confirmed by simulation (a single
  4x-strength stone one-shot a 3-troop tower).
- **Frost** (Tier 3): global instant freeze on every currently-marching hostile unit,
  `FROST_DURATION = 10`s, then auto-thaw (lazy expiry check before the March step, same pattern
  Fortify already uses for buildings). **Caught a real bug during implementation**: the natural
  first pass set `u.speedMul = 0` to represent "frozen," reusing Slow Down's mechanism — but the
  movement formula's `u.speedMul || 1` fallback treats `0` as JS falsy/"unset" and silently snaps
  back to full speed, which would have made Frost a complete no-op. Fixed by using a dedicated
  `u.frozen` boolean instead, checked explicitly in the movement formula (`u.frozen ? 0 : ...`)
  rather than folded into the existing multiplier. The dashed-ring + sparkle "slowed" visual is
  reused (now gated on `(u.speedMul < 1) || u.frozen`) rather than adding a near-identical one.
- Verified all four with a standalone Node simulation (`/tmp/test_specials.js` — freeze/thaw
  correctness including the speedMul-zero footgun, team-scoped Rage momentum with clamping,
  Rolling Stones' 4x tower one-shot + castle-capture block + normal-unit follow-up capture,
  Instant Upgrade's eligibility filtering and empty-target no-op) plus a Babel transpile check
  on the full script block.
- Updated the hero-kit table, constants reference, and code-map bullet in this doc; sample
  roster is now a 4-hero example: Tempo (today's default), Saboteur (Second Wind/Barrage/
  Sabotage), Warlord (Rally/Rage/Fortify), Siege (Instant Upgrade/Rolling Stones/Frost).

### Hero system wired live: 4 heroes, real pre-match picker, all 12 abilities dispatched generically (this session)
Requested: turn the 4-hero, 3-tier grid from a design document into an actual pre-match picker —
"make 4 heroes and split all the abilities among them." This is the single biggest refactor of
the specials system since it was first built, because almost everything downstream used to
assume exactly 3 hardcoded kinds (`slow`/`speed`/`storm`).

- **`ABILITY_META`** replaces the old 3-entry `SPECIAL_STAGE` as the source of truth for all 12
  abilities (name/icon/tier/colors); `SPECIAL_STAGE` is now *derived* from it
  (`Object.fromEntries(...)`) so tier can never drift out of sync between the two.
- **`HEROES`** defines the 4 heroes and **`CAST_FNS`** is a single `{kind: fn}` dispatch map
  covering all 12 `cast____` functions — this is what let `castPlayerSpecial` and `aiSpecials`
  both drop their old hardcoded if/else chains and work generically for any hero's kit.
- **`startGame`** now assigns `g.heroes[owner]` per player: the human gets `selectedHero` (new
  menu-screen state, defaults to Tempo so old behavior is preserved if no one touches the
  picker); AI players draw the 3 *other* heroes via Fisher-Yates shuffle, guaranteed no repeats
  (verified: at most 3 AI opponents exist in any real mode, exactly matching the 3 remaining
  heroes). **The tutorial forces every player to Tempo**, deliberately — `aiSpecials` runs even
  during the tutorial, and letting the AI opponent draw a random hero risked something like
  Frost freezing the scripted enemy trickle mid-demo, which the tuned pacing has never been
  tested against.
- **`fireInfo`/`pulse`/`prevSecsRef`** (the specials-UI train-progress and ready-flash-animation
  state) are now keyed by **tier (1/2/3) instead of ability name** — this is what lets the same
  UI code render correctly regardless of which specific kind occupies each tier for the current
  match's hero, with zero per-hero special-casing.
- **`aiWantsToCast(g, pid, kind, incoming, marching)`** replaced the old 3-branch `aiSpecials`
  body with a single switch covering all 12 kinds, grouped by shared reasoning rather than
  written out per-kind: the defensive-buff group (Slow Down/Fortify at ≥3 incoming; Tower
  Defense/Barrage/Frost at ≥5) and the "wants marching troops" group (Speed/Rolling Stones at
  ≥5 marching) each reuse one threshold; momentum boosts (Rally/Rage) skip only once already at
  `MOMENTUM_MAX`; Second Wind/Instant Upgrade/Sabotage are unconditional since each is either
  self-correcting or a safe no-op.
- **Menu screen** gained a HERO row (4 buttons, icon + name + kit-icon preview) below MODE/
  COMBATANTS, driven by `HERO_IDS.map(...)` and `ABILITY_META` — no hardcoded per-hero JSX.
- **How-to-play copy** rewritten to describe the hero system generically instead of naming
  Tempo's 3 specific abilities (which are no longer guaranteed to be what the player has).
- **Verified with two standalone Node scripts** (kept at `/tmp/test_hero_structure.js` and
  `/tmp/test_dispatch_draw.js` this session): the first confirms every hero's kit covers tiers
  1/2/3 exactly, every referenced kind exists in `ABILITY_META` at the matching tier, and the 12
  assigned kinds are exactly `ABILITY_META`'s 12 keys with no orphans or duplicates; the second
  ran 1000 trials of the hero-draw logic (random human pick × random player count) confirming no
  repeated hero ever appears in one match's `heroes` array, confirmed `CAST_FNS`'s keys match
  `ABILITY_META`'s exactly (nothing undispatchable), and confirmed the tutorial forces
  `["tempo","tempo"]`. All four previously-added abilities' own logic tests (`/tmp/test_specials.js`)
  were re-run and still pass unchanged. A full Babel transpile check on the complete script block
  also passed.
- Also fixed, while in this section: a bug from last session's doc edit had accidentally deleted
  the `## Tuning constants` section header when a new session-log entry was inserted — restored.

### Capture momentum bonus lowered to 5%; hero ability details added to the menu (this session)
Two small requests:
- **`MOMENTUM_CAPTURE_BONUS` 10% → 5%.** Pure constant change (`applyMomentumCapture` reads it
  directly, no other logic touches the number). Updated the stale comment on
  `RALLY_MOMENTUM_BOOST`, which used to note it was "currently equal" to the capture bonus —
  no longer true at 10% vs 5%, so it now just says the two are independently tunable. Also
  updated the How-to-play modal copy, which quoted the old 10% figure by name.
- **Menu hero picker now shows full ability details, not just names.** Added a `desc` field (one
  concise line each) to every entry in `ABILITY_META`. Below the 4 hero buttons, a detail panel
  lists the currently-selected hero's 3 abilities — icon, name, tier, and description — instead
  of the previous single line that just joined the 3 ability names with " · ". Purely a
  `HERO_IDS`/`ABILITY_META`-driven render, no per-hero JSX.
- Verified: Babel transpile check on the full script block passed, all four previously-added
  abilities' logic tests (`/tmp/test_specials.js`) and the hero/ability structural integrity
  check (`/tmp/test_hero_structure.js`) were re-run and still pass unchanged, and a quick script
  confirmed all 12 `ABILITY_META` entries now carry a `desc` field.

### Sabotage can now capture multiple buildings in one cast (this session)
Requested: Sabotage's 30-troop debuff should be able to take over more than one building if
several end up near-empty, not just the single weakest.

- `castSabotage` used to track only the single `weakest` post-debuff building and check that one
  against `SABOTAGE_SNEAK_TROOPS`. Changed to a second full pass over `enemies` (after the debuff
  pass finishes for everyone) that captures **every** building left under the threshold, not just
  the weakest. Kept as two separate passes rather than checking-and-capturing inline during the
  debuff loop, so the damage always lands on every enemy building first regardless of capture
  order.
- Practical effect: a low troop count spread across many enemy buildings (small `perBuilding`
  split, so more of them survive near the threshold) now has real multi-capture upside; a single
  well-defended enemy building still just gets softened or taken alone, same as before — nothing
  changed about the per-building math, only how many captures can result from one cast.
- Updated the menu's Sabotage description (`ABILITY_META.sabotage.desc`) and the ability
  reference table in this doc to say "every" instead of "the weakest."
- Verified with a standalone Node script (`/tmp/test_sabotage.js`, three cases: all-enemies-near-
  empty → all captured; one weak + one strong → only the weak one captured; single enemy →
  unchanged from prior behavior) plus a full Babel transpile check and a re-run of the existing
  hero/ability test suite.

### Rage reworked: momentum boost → per-unit strength buff on marching troops, with a red visual (this session)
Requested: Rage should only affect troops currently on the field (marching), not a lasting
player-wide momentum stat, and those troops should visibly turn red while boosted.

- **`castRage` rewritten** to follow the exact same shape as `castSpeed`/`castSlow`/
  `castRollingStones` instead of `castRally` (which it used to mirror): every currently-marching
  soldier on the caster's team gets `u.rageBoosted = true` — a permanent transformation for that
  unit for the rest of its march, no duration/timer, same "whoever's marching right now" pattern
  every other troop-targeting special uses. The old team-wide momentum loop
  (`g.momentum[pid] += RAGE_MOMENTUM_BOOST`) is gone entirely.
- **New top-level constant `RAGE_STRENGTH_MULT = 1.5`** (+50%), replacing the removed
  `RAGE_MOMENTUM_BOOST`. Applied in `unitArrives` at the exact same point Rolling Stones' 4x
  multiplier already was: `strength = (rollingStone ? 4 : 1) * (rageBoosted ? 1.5 : 1)`. The two
  now stack **multiplicatively** if a single unit somehow carries both flags — possible in 2v2,
  since Rage and Rolling Stones are both team-inclusive casts and a teammate's ability can land
  on another teammate's marching units. No special-casing needed; it's the same multiplier
  architecture Rolling Stones already established, just composed.
- **Red visual**: a solid, saturated red glow drawn beneath the sprite (same "filled glow"
  visual language as Speed's teal one, color-distinct rather than shape-distinct from it) for
  every unit with `u.rageBoosted`. Drawn as its own independent `if` block (not chained into the
  existing speed/slow/frost branch), so it layers correctly even if a unit is also
  slowed/frozen/a Rolling Stone at the same time.
- **`aiWantsToCast`'s "rage" case moved to the marching-force heuristic group** (`marching >= 5`,
  same bar as Speed/Rolling Stones) — the old `momentumMult(g, pid) < MOMENTUM_MAX` check no
  longer made sense once Rage stopped touching momentum at all.
- Updated the menu's Rage description (`ABILITY_META.rage.desc`) and the ability reference table
  in this doc.
- Verified with a standalone Node script (`/tmp/test_rage.js`): Rage only flags the caster's own
  currently-marching units, not enemies'; a Rage-boosted unit deals exactly 1.5x damage on attack
  and reinforces for exactly 1.5 troops; a unit with BOTH Rolling Stones and Rage flags correctly
  stacks to 6x (4 × 1.5); and a plain unaffected unit still deals exactly the original 1x damage
  (baseline unchanged). Also re-ran the full existing test suite (`/tmp/test_specials.js`,
  `/tmp/test_sabotage.js`, `/tmp/test_hero_structure.js`) and a full Babel transpile check — all
  still pass. (Note: `test_specials.js`'s own "Rage" test is a stale standalone reimplementation
  of the *old* momentum-based design from an earlier session — it isn't exercising the real
  `castRage` code and its passing doesn't verify anything about this change; `test_rage.js` is
  the actual verification for this session's rework.)

### Four requests in one pass: opponent hero visibility, map-trap fix, Fortify's metallic look, Sabotage's slash effect (this session)
Delivered without follow-up questions per explicit instruction; a few judgment calls were made
and are called out below for later discussion.

- **See which hero you're versing + total troops**: the top-right momentum pill row (already
  showed faction color + name + momentum %) now also shows that player's hero icon (looked up via
  `gameRef.current.heroes[s.pid]` → `HEROES[...].icon`, falling back to Tempo) and their total
  troop count (`s.troops`, which `hud`'s stats loop was already computing — garrisoned + marching
  + queued — just wasn't displayed). Applies to every row including the human's own, for
  consistency and because it's harmless/useful there too.
- **Map generation no longer traps players behind towers unless the whole map only has one
  tower.** The only two things that can turn a *neutral* building into a tower are: the FFA inner
  ring (`innerRingIsTower`, all-or-nothing across the ring) and the 2v2 mid/flank pair
  (`midIsTower`, same all-or-nothing), plus the single always-a-tower map-center neutral when
  present. Both of the ring/pair rolls are now gated on a same-side non-tower alternative also
  being present: FFA's inner ring can only become towers when the rim `buffered` ring also exists
  (`innerRingIsTower = innerRing && buffered && Math.random() < 0.3`); 2v2's mid pair can only
  become towers when the central `extraMid` pair also exists (`midIsTower = extraMid &&
  Math.random() < 0.3`). Either way, if the gate fails, that ring just stays castles instead of
  being skipped — no map ends up with fewer options than before, only fewer *tower-only* ones.
  When neither gate condition holds, the sole remaining possible tower is the single map-center
  one, which is exactly the stated exception. Verified with a standalone Node script
  (`/tmp/test_map_towers.js`) that reproduced both rolls' boolean logic across 20,000 trials each
  and asserted the invariant directly: zero cases where total map towers exceeded 1 while the
  escape-route ring (`buffered`/`extraMid`) was absent.
- **Fortify now visibly recolors buildings metallic silver** (`METALLIC_COLORS`/`METALLIC_CREN`,
  a bright cool silver-steel gradient, distinct from stone's blue-grey and from Tower
  Defense's gold / Barrage's scorched-brown buff colors) instead of being invisible on the
  building itself. Castles: the main body/keep and the LEFT turret go metallic (the RIGHT turret
  stays reserved for Tower Defense/Barrage's own buff coloring, so a building fortified AND
  buffed by an ally's offensive special in 2v2 still shows both clearly, one per turret). Towers
  (single shaft, no turret split): metallic shaft + crenellations + a soft silver glow, but only
  when no offensive buff is overriding it (`fortified = fortifyMult(g,t) > 1 && !buffed`) — same
  priority the castle sprite's right turret already uses. **Judgment call to revisit**: towers
  fortified AND buffed simultaneously (2v2 edge case) show only the offensive buff's color, with
  no visual trace of Fortify — unlike castles, which always show at least the left turret/body
  metallic regardless. Could give towers a thin metallic outline in that dual-buff case if it
  matters in practice.
- **Sabotage now shows a ninja-sword slash against every enemy building it hits** (not just ones
  it ends up capturing) — a new `g.slashes` effect array (mirroring `g.rings`/`g.sparks`: pushed
  in `castSabotage`'s debuff loop, decayed once per tick, scaled on resize, rendered in `draw()`
  right after the existing cast-ring block). Each slash is a curved two-stroke line (a wider dim
  stroke + a thin bright core, for some "blade thickness") at a random angle per building, with a
  fast ease-out fade (`alpha ~ (1-p)²`) over `0.32`s for a sharp "flash cut" read rather than a
  lingering glow. **Judgment call to revisit**: "ninja sword swing" was interpreted as a stylized
  curved slash streak rather than literal sprite/character art (no ninja figure appears) — flag if
  actual character art was intended instead.
- Verified: full Babel transpile check on the complete script block passed; the existing test
  suite (`/tmp/test_rage.js`, `/tmp/test_sabotage.js`, `/tmp/test_hero_structure.js`) was re-run
  and still passes unchanged; the new `/tmp/test_map_towers.js` script (20,000 trials/mode) is
  described above.

### Fix: Sabotage's slash wasn't visible at all — draw-order bug, plus lengthened it (this session)
Reported: the ninja-sword slash from last session's batch of changes wasn't displaying, and
needed more visible screen time even once fixed.

- **Root cause**: `g.slashes` was rendered *before* the buildings sprite loop in `draw()` (right
  after the special-cast rings block) — so every building sprite drawn afterward painted directly
  on top of the slash at that same location, completely hiding it. This is exactly the kind of
  z-order mistake the other one-shot effects (rings, sparks) don't have, since none of them are
  anchored essentially on top of a building the way this one is. Fixed by moving the slash render
  block to run AFTER the buildings sprite loop, so it now draws on top of the building it's
  hitting, where it's actually visible.
- **Also lengthened it**, since a bug-free version at the original `0.32`s duration with a
  `(1-p)²` fade starting from frame 0 would still have read as barely-there: duration is now
  `0.65`s, and the fade curve holds full brightness for the first 30% of its life before easing
  out, instead of starting to fade immediately.
- Verified: full Babel transpile check and the entire existing test suite (`/tmp/test_rage.js`,
  `/tmp/test_sabotage.js`, `/tmp/test_hero_structure.js`, `/tmp/test_map_towers.js`) re-run and
  still passing — this was a rendering-only fix, no game-logic tests were affected.

### Population budget now counts marching troops too, not just garrison (this session)
Requested: a player's total-population regen budget (`buildingCount(player) * MAX_POPULATION`)
should include troops currently on the field (marching), not just troops sitting in buildings —
with Second Wind explicitly called out as something that should keep working regardless.

- **`totalPop[owner]`** (computed once per tick, right before the regen loop) now sums `g.units`
  too: `totalPop[u.owner] += 1` per marching unit owned by that player, in addition to the
  existing per-building `t.troops` sum. Each marching unit counts as exactly 1 toward population
  — deliberately NOT scaled by any Rolling Stones (4x) or Rage (1.5x) combat-strength multiplier
  a unit might be carrying, since population budget is a headcount concern (how many troops
  exist), not a combat-damage one (how hard they hit) — those are different axes and this keeps
  them from bleeding into each other.
  - Practical effect: a player who sends out a large army no longer gets to keep regenerating
    freely at their buildings while that army is in transit — the army still counts against their
    budget, throttling regen, exactly as if those troops were still sitting at home. Once the army
    arrives (dies or reinforces), it stops counting as "marching" and regen room opens back up.
  - Reinforcement (`unitArrives`) is still completely unbounded, unchanged — a marching unit
    finally arriving doesn't create new population, it just resolves already-counted population
    into a building, so it was never the thing this budget needed to throttle.
- **Second Wind (`castSecondWind`) is untouched and unaffected**, as explicitly required: it's a
  direct `t.troops += SECOND_WIND_AMOUNT` outside the regen loop entirely, so it was never
  throttled by this budget before and still isn't now — confirmed with a simulation (below) that
  casts it against a building whose owner's budget is already completely full from a marching
  army, and it still lands its full +15.
- Verified with a standalone Node script (`/tmp/test_population.js`, five cases): a marching army
  that already fills a player's budget blocks ALL regen even when a building is far below its own
  level cap; a partially-full budget grants exactly the remaining room; a player with zero
  marching units regenerates exactly as before (regression check); an enemy's marching units never
  count against a different player's budget; and Second Wind still adds its full flat amount even
  when regen is fully blocked. Also re-ran the complete existing test suite and a full Babel
  transpile check — all still passing.

### Momentum kill step 0.15% → 0.2% (this session)
Pure constant change: `MOMENTUM_KILL_STEP` 0.0015 → 0.002. Updated the How-to-play modal copy,
which quoted the old 0.15% figure by name, and this doc's constants table. No other logic
touches this constant. Re-ran the full existing test suite and a Babel transpile check — all
still passing (this change doesn't intersect with anything they cover, but re-verified anyway).

### Per-player specials-train mini bars added to the standings row (this session)
Requested: show each player's specials train loading progress, in a way that scales to 4
players without affecting the map.

- **`trainOf(g, pid)`** (already existed, used internally by `readyFor`/`castPlayerSpecial` etc.)
  is now also read into the `hud` stats array every HUD tick (`trainPct: trainOf(g, pid) /
  TRAIN_MAX`, 0..1) alongside the existing troops/momentum stats.
- **Rendered as a compact 4-segment mini bar** inside the existing top-right standings pill for
  each player (the same pill that already got a hero icon and troop count last session) — NOT on
  the map/canvas itself, so it costs zero battlefield space and scales cleanly to 4 players; it's
  purely additional HUD chrome in an area that already existed. Segmented into 3 ticks (matching
  the 3 real train stages, each an equal 25% of the bar) plus a dimmer 4th sliver for the reserve
  stage, so it reads as "how close to their next special" rather than a single vague fullness bar.
- Verified the segment-fill math with a standalone check (`node -e`, this session): at 0%/25%/40%/
  75%/100% train progress, each quarter-segment fills fully before the next one starts (e.g. 40%
  produces `[1, 0.6, 0, 0]`) — confirmed correct rather than guessed. Also ran a full Babel
  transpile check and the complete existing test suite (unaffected by this change, but re-verified
  regardless) — all passing.

### Standings pill redesigned: shows each opponent's actual 3 abilities, bigger bars (this session)
Requested: also show which specific abilities each opponent has (not just their hero icon), and
make the loading bars bigger.

- **Replaced the generic unlabeled 4-segment strip** (26×5px, folded into the single identity
  row) with a proper two-row pill: the existing identity row (dot/hero icon/name/troops/momentum)
  on top, and a new row below with **3 separate bars — one per tier, each labeled with that
  specific ability's own icon and tinted its own color** (via `HEROES[heroId].kit[tier]` →
  `ABILITY_META[kind]`, the same lookup the menu's hero picker already uses). This directly shows
  "which 3 abilities" in addition to "how charged," not just a generic fullness readout.
- **Bars are bigger**: 8px tall (was 5px) and each spans roughly a third of the pill's width
  instead of a fixed 26px total for all 4 segments combined — a real width/height increase, not
  just a repaint.
- **Dropped the 4th "reserve" segment** from this per-player view — it's not itself an ability, so
  showing 3 clearly-labeled bars (the actual abilities) reads better than 3 labeled + 1 unlabeled.
  The reserve concept is still fully intact for the human player's own specials bar at the bottom
  of the screen; this was purely about what's useful to surface for *other* players at a glance.
- **A bar at full charge gets a brighter fill + a colored glow** (`boxShadow` in the ability's own
  color), so a genuinely-ready enemy special stands out rather than just quietly reaching 100%.
- Still pure HUD chrome in the existing standings-row area, nothing drawn on the map/canvas —
  costs a bit more vertical space per pill (two rows instead of one) but nothing on the
  battlefield itself, consistent with the original "shouldn't affect the map" request.
- Verified: full Babel transpile check (JSX structure — a stray duplicate closing `</div>` block
  left over from the previous session's edit was caught and removed in the process) and the
  complete existing test suite re-run — all passing.

### Standings pills: drop the human's own entry, split 3 opponents across both top corners (this session)
Requested: stop showing the human player's own pill (redundant — their own stats are already
visible at the bottom of the screen), and lay out the resulting max-3 opponents as 2 stacked at
top-right plus 1 stacked under the Menu button, so the HUD doesn't eat too much of the map in one
dense column.

- `hud.filter((s) => !s.dead)` → `hud.filter((s) => !s.dead && s.pid !== 0)` — the human (always
  `pid 0`) is now excluded outright. With a max of 4 players total, that caps this row at 3
  opponents.
- Split via `others.slice(0, 2)` (top-right, unchanged spot) and `others[2]` (the 3rd, if it
  exists — only possible in a full 4-player match with none of the first 3 opponents eliminated).
  The Top HUD's left column, which used to be just the Menu button, is now a small vertical stack:
  Menu button on top, the 3rd opponent's pill directly below it when present.
- Extracted the pill JSX into a shared `renderPill(s)` closure (previously inline in a single
  `.map`) so both the top-right stack and the under-Menu slot render identically without
  duplicating the whole per-ability-bar block.
- Verified the split logic with a standalone script across player counts and elimination states:
  2/3/4 total players, and 4-player games with various opponents eliminated — confirmed the human
  is never included, at most 2 pills ever land top-right, the 3rd slot only appears with exactly 3
  live opponents, and everything degrades gracefully as opponents die. Also ran a full Babel
  transpile check and the complete existing test suite — all passing.

### Top HUD moved off the map entirely; bottom specials bar shrunk 30% (this session)
Reported: the opponent standings pills (Menu button + hero pills) were positioned as an absolute
overlay ON TOP of the map/canvas, and could visually cover a castle near the top edge — blocking
the player from upgrading it, since even though the overlay had `pointerEvents: "none"` (clicks
technically passed through to the canvas underneath), the player couldn't SEE the castle to tap
it accurately in the first place. Requested: make the HUD a genuinely separate area from the map,
moved toward the top; and shrink the bottom specials bar 30% so the map doesn't end up much
smaller overall once the new top panel takes its own space.

- **Root layout, before this session**: `<div ref={mapRef}>` (a `flex:1` sibling) contained the
  `<canvas>` PLUS every absolute-positioned overlay — convertConfirm bubble, the Top HUD, tutorial
  hints, the outcome screen, drag-to-order UI. The bottom specials panel was already a real
  sibling (not an overlay) — see last session's "Map area ends here" comment — but the Top HUD
  never got the same treatment.
- **Fix**: extracted the entire Top HUD (Menu button, dropdown, and the opponent-pill-splitting
  IIFE from last session) out of `mapRef` and made it a genuine flex sibling placed BEFORE the map
  area, styled to match the bottom panel's existing "separate panel" look (`background: "#1c2942"`,
  a border on the touching edge, `flexShrink: 0`, `boxShadow`, safe-area-inset padding — mirroring
  the bottom panel's pattern exactly, just flipped for the top edge). The map's `flex: 1` now
  simply shrinks to make room, so nothing can ever render on top of the battlefield again — not
  just visually separated, structurally impossible for it to overlap. `pointerEvents` tricks
  (previously needed to let clicks reach the canvas through the overlay) are gone, since there's
  nothing to click through anymore.
- **Bottom specials bar sized ~30% smaller**: `minHeight` 52→36 and the outer panel's
  padding/gap 9→6 (both a clean 30% cut — these are what actually drive the panel's total height,
  which is the thing competing with the map for vertical space). Text sizes were trimmed more
  gently than a strict 30% (icon 18→14, name 12→11, countdown 10→9, not 18→13/12→8/10→7) — a
  literal 30% cut on an 8-10px label risked becoming illegible on a phone screen, so structural
  dimensions took the full cut and text took a smaller one, still shrinking the bar noticeably
  without hurting readability. The reserve (4th) segment was resized to match.
- Verified: full Babel transpile check on the complete script block passed, and the entire
  existing test suite (unaffected by a layout-only change, but re-verified regardless) still
  passes.

### Fix: map got cut off at the bottom in 4-player games (this session)
Root cause traced to last session's Top HUD change, combined with a pre-existing gap in the
resize logic:

- **The resize effect only ever recalculated the canvas on a literal `window` "resize" event**
  (plus once on mount). It never accounted for `mapRef`'s own box height changing for other
  reasons.
- **The Top HUD panel's height is NOT fixed** — it depends on `hud`, which starts as an empty
  array and only populates on the first HUD tick (~0.35s after a match starts, see the game
  loop's `hudTimer` gate). With 4 players, that first tick can add up to 3 opponent pills
  (including a 3rd one stacked under the Menu button — see last session's layout split), each
  using the taller two-row per-ability-bar design from two sessions ago. So the top panel starts
  short (no pills yet) and then grows noticeably taller a fraction of a second later — with 2 or
  fewer opponents this growth is smaller and easy to miss; with 4 players (max opponents) it's
  large enough to be the reported bug.
- **What actually broke**: the canvas's pixel buffer and inline `c.style.width`/`height` are set
  ONCE by `onResize()`, based on `mapRef`'s height AT THAT MOMENT. When the top panel grew taller
  a moment later, `mapRef` itself shrank (flexbox: the map is the only `flex: 1` sibling, so it
  absorbs whatever the top/bottom panels take), but nothing told the canvas to shrink and rescale
  to match — it kept its old, larger inline size. Since the outer wrapper has `overflow: hidden`
  and `mapRef` itself also has `overflow: hidden`, the canvas's now-too-tall fixed box simply got
  clipped at the bottom edge of the new, shorter `mapRef` box instead of ever being resized.
- **Fix**: added a `ResizeObserver` watching `mapRef.current` directly, alongside the existing
  `window` "resize" listener, both calling the same `onResize()`. A `ResizeObserver` reacts to
  ANY cause of `mapRef`'s own box size changing — the HUD populating, orientation change, font
  loading, anything — not just a literal window resize, which is what the bug actually needed.
  `mapRef`'s div is unconditionally rendered (not gated behind `screen === "play"`), so
  `mapRef.current` is always available by the time this effect runs; no feedback-loop risk either,
  since the canvas is `position: absolute` inside `mapRef` and doesn't affect `mapRef`'s own
  layout size, so resizing the canvas can't re-trigger the observer.
- Verified: full Babel transpile check on the complete script block passed, and the existing test
  suite (unaffected — this is a browser-runtime/DOM-API fix with no pure-logic surface to unit
  test in Node, so transpile-checked and reasoned through rather than simulated) still passes.

### Opponent pills are now tappable — shows full ability details (this session)
Requested: tapping a player's bar in the Top HUD should show details of their abilities.

- **New `inspectPid` state** — tracks which opponent's pill (by pid) currently has its details
  popup open, if any. Reset to `null` in `startGame` so a stale pid from a previous match can't
  linger into the next one.
- **Tapping a pill toggles a popup** anchored below it, listing that hero's full kit — icon,
  name, tier, and description for each of the 3 abilities — reusing the exact same info/format
  the menu's hero picker detail panel already shows (`ABILITY_META[kind].desc` etc.), just for
  whichever opponent you tapped instead of your own pick. A second tap on the same pill (or
  tapping anywhere outside, same "tap outside to close" pattern the Menu dropdown already uses)
  closes it.
- **Popup opens on whichever side keeps it on-screen**: right-aligned for the two top-right
  pills (since they sit near the right edge), left-aligned for the 3rd pill under the Menu button
  (since it sits near the left edge) — checked against the already-computed `leftPill` variable
  from the pill-splitting logic, not a fresh lookup.
- The tapped pill's border brightens to that player's own faction color while its popup is open,
  so it's clear which one is currently expanded when more than one pill is visible.
- Verified: full Babel transpile check on the complete script block passed, and the entire
  existing test suite (unaffected by a UI-only addition, but re-verified regardless) still passes.

### Player's own momentum shown in the reserve segment, replacing the battery icon (this session)
Requested: show the player's own momentum in their specials bar instead of the reserve segment's
🔋 icon.

- The reserve segment's underlying mechanic (fill behavior — banking capacity from the Tier-3
  threshold up to `TRAIN_MAX`) is completely unchanged; only what's rendered on top of it changed.
- The "🔋 Reserve" icon+label is now the player's own momentum: `Math.round(mine.momentum * 100)`
  pulled from `hud`'s pid-0 entry (the same `hud` array the Top HUD's opponent pills already read
  momentum from), shown as a percentage with the same color convention used everywhere else in
  the game — green above 100%, red below, neutral grey/blue-grey at exactly 100% (further tinted
  by whether the segment itself is fully loaded or not, matching the segment's existing muted-vs-
  bright text-color pattern).
- Verified: full Babel transpile check on the complete script block passed, and the entire
  existing test suite (unaffected — this reads an already-computed value, no new game logic) still
  passes.

### Momentum now only affects attacking troops; defense comes from building level instead (this session)
Requested: momentum should only affect attacking troops; a building's defensive strength should
instead be based on its own level — 1.1/1.2/1.3/1.4 for levels 1-4.

This is the core combat-math change of the whole momentum system to date. Since it was
originally built (see "Momentum: replaced the flat castle defense bonus," an earlier session),
`unitArrives`' damage formula has always been symmetric: `attackerMomentum / (defenderMomentum *
fortifyMult)`. That symmetry is gone — the defender's side no longer references momentum at all.

- **New `levelDefenseMult(t) = 1 + t.level * 0.1`** — a building's defensive strength multiplier,
  purely a function of its own level (1.1/1.2/1.3/1.4 for levels 1-4), static rather than a
  fluctuating per-player stat. Applies to neutral buildings too (they have a real level from map
  generation, same as before).
- **`unitArrives`** (the actual combat resolution, both branches — the normal capture path and
  Rolling Stones' castle-capture-blocked path): `momentumMult(g, t.owner)` in the denominator
  replaced with `levelDefenseMult(t)`. The numerator (`momentumMult(g, u.owner)`, the ATTACKER's
  momentum) is untouched — that's exactly the part the request said to keep.
- **Every other place that estimated a building's defensive strength** (there were four, all
  previously using `momentumMult(g, t.owner)` for the same reason `unitArrives` did) updated to
  match, so nothing could estimate defense differently than combat actually resolves it:
  - Second Wind's targeting calc (`castSecondWind`'s deficit tally)
  - The AI's "which teammate building is about to fall" priority calc (`aiAct`, section 1)
  - Both of the AI's attack-sizing calcs (`aiAct`, sections 2 and 3 — `currentDefense` in the
    push-more-troops check and in `evalTarget`)
- **What's unchanged**: momentum is still earned and lost by both attacker and defender exactly
  as before (`applyMomentumKill` untouched) — a successful defense still builds the defender's
  momentum, a failed attack still costs the attacker theirs. It's *used* differently now, not
  earned differently: that banked momentum only ever pays off on the attacking side of a future
  fight. Fortify (`fortifyMult`) still stacks multiplicatively on the defender's side exactly as
  before, just alongside `levelDefenseMult` instead of alongside momentum. The AI's own-momentum-
  based posture (`cautious`, attack sizing divided by `myMomentum`) is also untouched — that's the
  attacking side, which was always supposed to keep using momentum.
- Updated the How-to-play modal copy and several stale comments (`unitArrives`, the top momentum
  block, `aiAct`'s defend-priority calc) that described the old symmetric attacker/defender
  momentum ratio.
- Verified with a standalone Node script (`/tmp/test_defense_rework.js`, five cases): a
  defender's own momentum has zero effect on damage taken (confirmed by comparing a
  high-momentum vs. baseline-momentum defender under an identical attack — identical damage in
  both); an attacker's momentum still scales damage dealt (confirmed higher-momentum attacker
  deals more); `levelDefenseMult` returns exactly 1.1/1.2/1.3/1.4 for levels 1-4; a level-4
  building measurably outlasts a level-1 building against the same attack; and Fortify still
  reduces damage further on top of level defense (multiplicative stacking intact). Also ran a
  full Babel transpile check and the complete existing test suite — all passing.

### "Momentum" renamed to "Attack Strength" in the UI; troop count added alongside it (this session)
Requested: show the player's own troop count next to their momentum readout, and rename
"Momentum" to either "Attack Strength" or "Attack Multiplier" — left to judgment. Went with
**Attack Strength**: the value displays as a percentage next to itself either way ("142%"), and
"Attack Strength: 142%" reads more naturally in a casual mobile game than the more
technical-sounding "Attack Multiplier," without losing any precision — it's exactly as accurate
a description of what the stat does post-rework (see last session: it only scales attacking
damage now).

- **Only the user-facing label changed** — every internal identifier (`momentumMult`,
  `MOMENTUM_KILL_STEP`, `applyMomentumCapture`, `g.momentum`, etc.) is untouched. This was a
  display-only rename, not a mechanical change.
- **The reserve segment** (bottom-right of the specials bar, previously showing just the
  Attack Strength percentage under a "Momentum" label) now shows the player's own troop count
  too — a 🪖 icon + `mine.troops` (from the same `hud` pid-0 entry the percentage already read
  from) on top, "{pct}% ATK" below it, both pulled from a single `hud.find((h) => h.pid === 0)`
  lookup rather than two separate ones.
- **How-to-play modal** rewritten to say "Attack Strength" throughout instead of "momentum," and
  to mention it's visible both in the Top HUD (opponent pills) and the player's own specials bar
  now, not just "top-right."
- Verified: full Babel transpile check on the complete script block passed, a targeted grep swept
  for any other user-facing "Momentum" text left behind (found none — the two spots caught were
  the only ones), and the entire existing test suite (unaffected by a label/display change) still
  passes.

### Rally and Slow Down swapped between Tempo and Warlord (this session)
Requested: swap Rally and Slow Down. Both are already Tier 1, so this isn't a tier change — it's
swapping which HERO carries which ability: Tempo now has Rally (was Slow Down), Warlord now has
Slow Down (was Rally). Speed/Tower Defense (Tempo) and Rage/Fortify (Warlord) are untouched.

- **`HEROES.tempo.kit[1]`**: `"slow"` → `"rally"`. **`HEROES.warlord.kit[1]`**: `"rally"` →
  `"slow"`. The `cast____` functions themselves (`castSlow`, `castRally`) are completely
  untouched — only which hero's kit references which kind changed.
- **The tutorial needed real changes, not just the data swap.** The tutorial forces every player
  to Tempo specifically (see last relevant session: "aiSpecials runs even during the tutorial...")
  and has a scripted Tier-1 step that assumed Tempo's Tier-1 ability was Slow Down — title,
  body text, `waitFor: "castSlow"`, a `tutorialFlags.castSlow` entry, and `onEnter` logic that set
  up an enemy scout to demonstrate the slowing effect. With Tempo's Tier-1 ability now Rally, that
  step would have gotten permanently stuck: the specials bar would show Rally instead of Slow
  Down, tapping it would never set the `castSlow` flag the step was waiting on, and the tutorial
  could never advance past it. Replaced with a proper Rally step: new title/body text, `waitFor:
  "castRally"`, `tutorialFlags.castRally` (renamed from `castSlow`), and simplified `onEnter` —
  Rally doesn't need an enemy scout or `tutorialWave` setup like Slow Down did, since it's a
  self-buff with no targeting, so that scaffolding was dropped entirely rather than carried over
  unused.
- Updated a handful of comments that named Tempo's kit or the tutorial's flag set explicitly
  (`castStorm/castSpeed/castSlow` → `castStorm/castSpeed/castRally`, the `selectedHero` default
  comment, the Hero system section intro and hero grid table in this doc).
- Verified: full Babel transpile check on the complete script block passed; a standalone check
  confirmed `HEROES.tempo.kit[1] === "rally"` and `HEROES.warlord.kit[1] === "slow"` directly
  from the live constant (not just eyeballed); the existing hero/ability structural-integrity
  test (`/tmp/test_hero_structure.js`) was re-run and still confirms all 12 abilities are used
  exactly once across the 4 heroes with no duplicates; and the rest of the existing test suite
  (unaffected by a kit reassignment, but re-verified regardless) still passes.

### Population budget now based on building levels, not a flat per-building constant (this session)
Requested: total population should equal the sum of each building's own max capacity — level 1
= 25 — with towers counted the same as castles.

Previously (see "Population budget now counts marching troops too" and the original "Population
cap" session), a player's regen budget was `buildingCount(player) * MAX_POPULATION` — a flat 55
per building regardless of that building's actual level, so a player with ten level-1 buildings
had the exact same budget (550) as a player with ten level-4 ones. That's gone.

- **The budget is now `Σ towerCapacity(t)`** across every building a player owns — each
  building contributes its OWN capacity (25/35/45/55 for levels 1-4), summed. Three level-1s and
  one level-3 now budget 25+25+25+45 = 120, not a flat 4×55=220 — a low-level empire has a
  meaningfully smaller ceiling than a high-level one of the same size, and upgrading now directly
  grows your total population capacity, not just that one building's own ceiling.
- **Towers count identically to castles** — `towerCapacity(t)` was already purely level-based and
  type-agnostic (it doesn't check `t.type` at all), so this was true automatically once the
  budget switched to summing it; verified explicitly anyway (a level-2 tower + a level-2 castle
  sum to 35+35=70, same as two level-2 castles would).
- **Removed the `MAX_POPULATION` constant entirely** — it had no remaining purpose once nothing
  used a flat per-building value; the old comment describing it as "matches the highest possible
  per-building regen ceiling" was actually the design flaw being fixed (every building being
  worth the LEVEL-4 ceiling regardless of its real level).
- Renamed the local `buildingCount` array to `budgetCapacity` and changed what it accumulates
  (`+= towerCapacity(t)` instead of `++`) — everything else about the regen loop (marching troops
  still count toward `totalPop`, reinforcement still fully unbounded, Second Wind still outside
  this loop entirely) is unchanged from last session.
- Verified with a standalone Node script (`/tmp/test_population_v2.js`, five cases): a lone
  level-1 building's budget is exactly 25; a lone level-4 building's is exactly 55; three level-1s
  plus one level-3 sum to exactly 120 (confirmed via multiple regen ticks converging there, not
  overshooting); a tower and a castle of the same level contribute identically; and regen never
  exceeds the level-based budget no matter how many ticks run. Also ran a full Babel transpile
  check and the complete existing test suite — all passing. (The old `/tmp/test_population.js`
  from the original population-cap session tests the now-replaced flat-`MAX_POPULATION` formula
  and is no longer representative of the real code — `test_population_v2.js` supersedes it.)

### Cross-ally reinforcement (2v2) was silently transferring population between players — fixed with a credit/debit ledger (this session)
Reported: "if the AI is moving troops a lot it can get more than the population it is allowed
to." Investigated by auditing every place `.troops` is added to or set (there are only nine —
tutorial-only setup code, order sending/draining, Second Wind, Sabotage, upgrade/convert costs,
capture, combat damage, reinforcement, and regen) to rule out an actual double-count bug. Found
none — but found a real gap: reinforcement between TEAMMATES (2v2 only; FFA gives every player a
unique team ID, so this path never engages there) moves troops into a building the sender doesn't
own. The population budget is per-player, keyed by `t.owner` — so the moment a reinforcing unit
arrives at an ally's building, its population silently reassigns to the receiver's budget, even
though the receiver never regenerated it. An AI that reinforces its teammate a lot (core 2v2 AI
behavior — see `helperFor`) can end up holding more than its own `Σ towerCapacity` just from being
topped up by an ally, with nothing tracking that the population didn't actually originate there.

Asked how this should resolve (team-shared budget vs. strictly per-player vs. leave it) —
answer: **strictly per-player, charged to the sender**.

- **New `g.popCredit[owner]` ledger**, initialized to 0 per player at match start (same pattern as
  `g.momentum`). In `unitArrives`' reinforce branch, when `t.owner !== u.owner` (only possible via
  the `sameTeam` clause, since same-owner already matched first) — i.e. specifically a cross-ally
  reinforcement — `g.popCredit[u.owner] += strength` (sender still "pays" for this population) and
  `g.popCredit[t.owner] -= strength` (receiver doesn't get to count it as their own). Physical
  troops still move exactly as before — only the budget bookkeeping changed.
- **The regen step's `totalPop[owner]` now adds `g.popCredit[owner]`** on top of garrisoned +
  marching troops, so a sender's future regen is throttled by population they gave away, and a
  receiver's isn't inflated by population they were gifted.
- **Known, accepted limitation**: this is a ledger, not per-unit provenance — a shared troop pool
  is fundamentally fungible, so there's no way to know exactly which troops in a building are
  "the ally's contribution" once combat losses, further regen, and other reinforcements mix in.
  The credit/debit is permanent from the moment of transfer and doesn't reverse if the receiving
  building is later captured or loses those specific troops in combat. This is a deliberate,
  documented simplification (see the comment at the credit/debit site) rather than an attempt at
  full accuracy, which would require splitting each building's garrison into per-contributor
  sub-pools — a much larger, riskier change for a 2v2-only edge case.
- Verified with a standalone Node script (`/tmp/test_popcredit.js`, four cases): one cross-ally
  reinforcement correctly credits the sender +1 and debits the receiver -1; a receiver whose own
  building is far below its physical capacity still only regens up to what its budget (net of the
  debit) allows; a sender with a pre-existing credit debt gets correspondingly less regen room
  even with physical space free in its own building; and same-owner reinforcement (the ordinary,
  non-ally case) leaves `popCredit` completely untouched, confirming no regression to the common
  path. Also ran a full Babel transpile check and the complete existing test suite — all passing.

### Reversed course: 2v2 population budget pooled per TEAM instead of the popCredit ledger (this session)
Follow-up to the immediately preceding session. Asked to reconsider and simplify: instead of a
per-player ledger tracking population transferred between allies, just pool the budget per TEAM
directly — both allies draw from one combined capacity, so reinforcing a teammate is never a
"transfer" to begin with.

- **Removed `g.popCredit` entirely** — the state field, its initialization, and both adjustment
  sites in `unitArrives`. Reinforcement is back to a plain `t.troops += strength` with no
  bookkeeping beyond that, same shape it had for most of this feature's history.
- **`budgetCapacity` and `totalPop` are now keyed by `g.teams[owner]` (team id) instead of
  `owner` (player id)** in the regen step — every building and marching unit contributes to its
  TEAM's shared totals, and every building's regen room is checked against that shared budget.
  In FFA, `generateMap` already gives every player a unique team id, so this reduces to exactly
  the per-player behavior from two sessions ago — no behavior change there. In 2v2, both allies
  now draw from one combined pool: a level-1 building on one ally's side and an empty level-1 on
  the other's can still both regen to 25 each, since the pair's combined budget is 50.
- This is simpler and arguably more thematically correct than the ledger approach — a team
  fighting together plausibly shares logistics/manpower, so pooling the budget doesn't need to
  track WHO originally earned which troops the way the previous approach did, and doesn't carry
  that approach's known limitation (the ledger not reconciling if reinforced troops were later
  lost in combat) at all, since there's nothing to reconcile anymore.
- Verified with a standalone Node script (`/tmp/test_teampool.js`, four cases): two 2v2 allies
  correctly share one combined budget (an empty building on one ally can regen fully because the
  OTHER ally's building has spare room in the shared pool); the shared budget is genuinely
  exhausted at the combined total, not per-player; FFA is unaffected (each player's unique team
  id makes it behave exactly like the old per-player system); and an unevenly-distributed team
  (one building on one ally, two on the other) still fills to the correct combined total (75) via
  team pooling regardless of which specific building the troops end up in. Also re-ran the entire
  existing test suite and a full Babel transpile check — all passing.

### A literal ninja emoji added to Sabotage's slash effect (this session)
Requested: an actual ninja emoji, not just the abstract sword-slash streak.

- Added a 🥷 `fillText` draw to the existing `g.slashes` render loop, right alongside the slash
  strokes (same `sl` object, same life/dur, no new state needed). Rises upward as it fades
  (`C.y - 14*C.s - 18*C.s*p`) using the same hold-then-ease-out alpha curve the slash already
  uses, for a "leaping up and vanishing" read rather than a static icon sitting in place.
- Verified: full Babel transpile check on the complete script block passed, and the entire
  existing test suite (unaffected — this is a pure rendering addition to an existing effect, no
  game-logic surface) still passes.

### Momentum reinstated for defense + speed; "Attack Strength" renamed back to "Momentum"; level defense bonus shrunk to 1/1.05/1.1/1.15 (this session)
Requested: revert the UI label back to "Momentum," make momentum affect march speed as well as
attack damage, restore momentum's role in defense (on top of, not instead of, the level bonus),
and shrink the level-based defense multiplier to 1/1.05/1.1/1.15 (levels 1-4).

This partially reverses two earlier sessions ("Momentum only affects attacking troops" and
""Momentum" renamed to "Attack Strength"") while keeping their useful parts (the level-based
defense floor stays, just smaller and now supplementing momentum instead of replacing it).

- **Label reverted**: "Attack Strength" → "Momentum" everywhere it was user-facing — the reserve
  segment (now `{pct}% MOM` instead of `{pct}% ATK`, variables renamed `momPct`/`momTint`), the
  Rally tutorial step, and the How-to-play modal (rewritten to describe all three effects below
  instead of the attack-only framing).
- **`levelDefenseMult` formula changed**: `1 + level*0.1` (1.1/1.2/1.3/1.4) → `1 + (level-1)*0.05`
  (1/1.05/1.1/1.15). Level 1 is now a true no-op (1.0×) rather than already a +10% bonus, and the
  top end is much smaller (+15% at level 4, was +40%) — appropriate now that it's a supplement to
  momentum rather than defense's only source.
- **Momentum restored to the defender's side of every formula that had it removed**: `unitArrives`
  (both branches — normal capture path and Rolling Stones' castle-capture-blocked path),
  `castSecondWind`'s targeting deficit, and all three of the AI's defense-estimate calls (the
  teammate-defend-priority calc and both attack-sizing calcs). Each now multiplies
  `momentumMult(g, t.owner) * levelDefenseMult(t)` together for the defender's side, instead of
  just one or the other. The attacker's side (`momentumMult(g, u.owner)` in the numerator) was
  never touched by any of this — it always scaled attack damage.
- **Momentum now also scales march speed**: the movement formula's `spd` calculation gained a
  `* momentumMult(g, u.owner)` factor, multiplying together with the existing `u.speedMul` (Speed/
  Slow Down/Rolling Stones/Rage) — a losing streak now marches slower on top of hitting weaker and
  defending worse; a winning streak marches faster. `u.frozen` (Frost) still overrides everything
  and forces 0 speed regardless of momentum — checked first, unconditionally.
- **`expectedLosses`** (the AI's estimate of casualties a march will take from hostile tower fire
  en route) updated to use the sender's actual momentum-scaled march speed instead of the flat
  `UNIT_SPEED` constant — a slower (low-momentum) march now correctly predicts more losses, since
  it spends proportionally longer inside a hostile tower's range. Small, targeted fix rather than
  threading momentum through every distance/timing estimate in the file — flagged as an
  in-scope, directly-related improvement rather than scope creep.
- Verified with a standalone Node script (`/tmp/test_momentum_revert.js`, four cases):
  `levelDefenseMult` returns exactly 1/1.05/1.1/1.15 for levels 1-4; a defender with higher
  momentum now measurably takes less damage than one with lower momentum (confirming momentum's
  restored defensive role); march speed scales correctly with momentum in both directions
  (150%→108 speed, 75%→54, from a 72 baseline) while `u.frozen` still forces exactly 0 regardless
  of momentum, and stacks multiplicatively with `speedMul` (Speed special × momentum both at 1.5x
  → 162, not additive); and `expectedLosses`' momentum-scaled exposure time correctly predicts
  more losses for a lower-momentum sender than a higher-momentum one under identical exposure.
  Also ran a full Babel transpile check and the complete existing test suite — all passing. (Note:
  `/tmp/test_defense_rework.js` from the "attack-only momentum" session two sessions ago now tests
  reverted behavior and is no longer representative of the real code.)

### Soldiers now leave castles in rows of 4 instead of a random scatter (this session)
Requested: troops leaving a castle should exit in rows of 4.

- **`g.orders` gained a `spawned` counter** (starts at 0, incremented once per soldier spawned
  from that order) — added at both places an order is created (`issueOrder`, and the tutorial's
  `tutorialSendWave`).
- **The spawn-position math in the "Orders trickle soldiers out of the gate" loop replaced its
  random jitter with a deterministic formation**: `col = spawned % 4` (a 4-wide lane, perpendicular
  to the march direction, values -13.5/-4.5/4.5/13.5 — closely packed) and `row = floor(spawned /
  4) % 3` (how far back toward the gate, cycling after 3 ranks rather than growing unbounded — see
  below). A small residual jitter (±2px) is kept on top so it doesn't look perfectly robotic.
- **The row cycles at 3 instead of growing indefinitely**, specifically so a very large order
  (hundreds of troops in one wave) can't push a late-spawning soldier's initial position
  arbitrarily far behind the gate — capped at a max of 2 ranks back (`18 - 2*10 = -2`), keeping
  the spawn point always tight near the castle regardless of order size.
- **The same lateral value carries into the unit's marching-lane offset** (`off`, previously a
  fully random value in about the same range) — so the 4-wide grouping isn't just a spawn-instant
  detail, it holds as a loose formation for the "hold formation lanes until close, then converge"
  phase of the march too.
- Verified with a standalone Node script (`/tmp/test_rows4.js`, four cases): the first 4 spawns
  from an order land in one row across 4 distinct lanes; the 5th spawn correctly starts a new row
  back at column 0; a simulated 200-soldier order keeps every row/gate-distance value within the
  bounded, cycled range (never drifting arbitrarily far from the gate); and a small 3-troop order
  (matching the tutorial's own wave size) never spills past a single row. Also ran a full Babel
  transpile check and the complete existing test suite — all passing.

### Rows of 4 made more organized: synchronized batch spawning, uniform troop speed (this session)
Requested: make the rows-of-4 formation more organized, and give all troops the same speed.

Last session's rows-of-4 change assigned each soldier a row/column position, but still spawned
them one at a time via the existing trickle timer — a "row" was really just a pre-assigned
destination that filled in asynchronously over ~4 spawn ticks, and each soldier's speed varied
randomly (±15%), so even a correctly-positioned row would visibly drift apart from itself within
a second or two of marching.

- **Soldiers now spawn a full row of 4 at once**, not one at a time. The trickle loop's threshold
  changed from releasing 1 unit per `accum >= 1` to releasing an entire row per `accum >= 4` — the
  overall troops/second rate (`SPAWN_RATE`) is unchanged, so a large order still departs at the
  same overall pace, just chunked into synchronized bursts of up to 4 instead of a continuous
  drip. A smaller final row (1-3 stragglers, whatever's left in the order) still spawns together
  and is centered on the lane rather than bunched to one side (`lateral = (c - (rowSize-1)/2) *
  9`, which centers correctly regardless of row size).
- **Uniform speed**: `speed: UNIT_SPEED * (0.85 + Math.random()*0.3)` → flat `speed: UNIT_SPEED`,
  no per-unit variance. Momentum still scales this per-owner in the March step (see last session's
  momentum-affects-speed change) — it's the RANDOM variance that's gone, not momentum's effect.
  Same speed means a row marches together at the same pace instead of spreading out over time.
  Removed the residual ±2px spawn jitter for the same reason — a fully deterministic grid reads
  as more disciplined than one with per-soldier noise layered on top.
- **Synchronized sway**: each row now shares one `phase` value (rolled once per row, not once per
  soldier) for the wobble animation during marching, so all 4 members of a row sway in sync
  instead of independently wiggling out of step with each other.
- Verified with a standalone Node script (`/tmp/test_rows4v2.js`, four cases): a 12-troop order
  produces exactly 3 synchronized row-events of 4 each (not 12 individual spawn events); every
  spawned unit in a simulated run shares exactly one speed value; a 10-troop order's partial final
  row (2 stragglers) is correctly centered (lateral offsets sum to zero, not bunched left/right);
  and an order that outlives its source castle's actual troop count is correctly capped at what
  was really available, never over-spawning. Also ran a full Babel transpile check and the
  complete existing test suite — all passing.

### Row spacing halved; unit speed slowed 10% (this session)
Two pure constant changes, no logic changes:

- **Row spacing halved**: the gap between successive rows in the rows-of-4 departure formation
  (`gateDist = 18 - row * N`) — `N` 10 → 5. Row gate distances go from [18, 8, -2] to [18, 13, 8]
  across the 3 cycled ranks — tighter, and now comfortably positive at every rank (previously the
  3rd rank actually landed slightly ahead of the gate at -2; halving the spacing incidentally fixed
  that too).
- **`UNIT_SPEED` 72 → 64.8** (a flat 10% reduction). Affects march speed everywhere it's read:
  the March step's `spd` calculation, the tutorial's scripted waits, and `expectedLosses`' AI
  exposure-time estimate (which already scales off `UNIT_SPEED * momentumMult`, so it picked up
  the slower baseline automatically, no separate edit needed there).
- Verified: full Babel transpile check on the complete script block passed; a standalone check
  confirmed `72 * 0.9 = 64.8` exactly and the three cycled row gate-distances are `[18, 13, 8]`
  under the halved spacing; the existing rows-of-4 test suite (`/tmp/test_rows4v2.js`) was re-run
  and still passes (unaffected by either constant — it exercises the row-grouping/speed-uniformity
  logic, not the specific numeric values); and the complete existing test suite otherwise still
  passes.

### Starting troops raised to 10 per castle (this session)
Requested: 10 starting troops per building. Clarified: castles only (both player and neutral) —
neutral towers stay at full capacity like before.

- **`START_TROOPS` 3 → 10.** The map-generation code already applied this constant to every
  non-tower entry uniformly, player-owned or neutral (`type === "tower" ? towerCapacity(...) :
  START_TROOPS`, used at both the two places `raw` map entries get converted into real building
  objects) — so a single constant change covers player home castles, player extra castles, AND
  neutral castles all at once. Neutral towers are untouched, since they were already gated to the
  `towerCapacity` branch of that same ternary, unaffected by `START_TROOPS` either before or after.
- Verified: full Babel transpile check on the complete script block passed, and the complete
  existing test suite (unaffected — a single top-level constant with no other logic touching it)
  still passes.

### Row spacing halved again (this session)
Pure constant change: the rows-of-4 gate-distance spacing (`gateDist = 18 - row * N`) — `N` 5 →
2.5 (was 10 before the previous halving). Row gate distances across the 3 cycled ranks are now
[18, 15.5, 13] (previously [18, 13, 8]) — a much tighter formation. Verified with a full Babel
transpile check and the existing rows-of-4 test suite (unaffected by the specific spacing value,
since it exercises row-grouping/speed-uniformity logic, not this constant) plus the complete
existing test suite — all passing.

### Row spacing still too wide — found the real cause: release timing, not the static offset (this session)
Reported: still too much space between rows even after two halvings of the static gate offset.

Root cause: that static offset (`gateDist`) only sets each soldier's position at the INSTANT it
spawns — but soldiers start marching immediately, and rows release one at a time as `SPAWN_RATE`
accumulates enough for a full row of 4. At the old `SPAWN_RATE = 9`, that's an 0.44s gap between
row releases; at `UNIT_SPEED = 64.8`, that's ~28.8px of real marching distance between rows by
the time the next one appears — far more than the ~2.5px the static offset was contributing. The
two previous halvings were shrinking the smaller, mostly-irrelevant factor.

- **`SPAWN_RATE` 9 → 16.** Row release interval drops from 4/9=0.44s to 4/16=0.25s, cutting the
  real marching gap from ~28.8px to ~16.2px — addressing the actual dominant cause. Side effect,
  called out directly: orders now drain somewhat faster overall (~1.8x), since this constant also
  governs an order's overall troops/second throughput, not just row cadence — there wasn't a way
  to tighten row timing without touching that.
- **Static gate offset also reduced further** (`row * 2.5` → `row * 1`) for the residual
  contribution, even though it was never the dominant factor.
- Verified: full Babel transpile check on the complete script block passed; the existing rows-of-4
  test suite (unaffected by either constant's specific value) and the complete existing test suite
  were re-run — all passing.

### Enemy no longer attacks during the tutorial (this session)
Requested: the tutorial's AI opponent shouldn't attack the player.

- `aiAct` (the function that actually decides to attack — sizes up assaults, sends real armies at
  the player's buildings) is now skipped entirely while `g.tutorial` is true. Timers and the AI's
  specials-train still advance normally underneath, so nothing looks stuck if the tutorial's AI
  ever needs to act again later — the call itself is just gated out.
- The deliberately small, controlled enemy trickle (`tutorialAutoWave`/`tutorialSendWave`, timed
  specifically for the Tower Defense demo steps so there's something nearby for the buffed tower
  to fire on) is untouched — that's the one enemy activity the tutorial is supposed to show, and
  it was never routed through `aiAct` to begin with.
- `aiSpecials` (which still runs unconditionally, per an earlier session) was left as-is —
  Tempo's forced tutorial kit (Rally/Speed/Tower Defense) has no offensive special in it, so
  nothing it could cast during the tutorial qualifies as "attacking" the player.
- Verified: full Babel transpile check on the complete script block passed, and the complete
  existing test suite (unaffected — a single conditional gate around an existing call, no new
  logic) still passes.

### Enemy regenerates at half speed during the tutorial (this session)
Requested: halve the enemy's regen rate during the tutorial.

- Added a `tutorialRegenMult` check right at the regen step's grow calculation
  (`towerRegen(t) * dt * tutorialRegenMult`) — `0.5` when `g.tutorial` is true AND the building's
  owner is the enemy (not `0`, the human, and not `NEUTRAL`); `1` otherwise, so this has zero
  effect outside the tutorial. Scoped at the call site rather than changing `towerRegen` itself,
  since that function doesn't take `g` and didn't need to for anything else.
- Keeps the AI's economy from quietly outpacing a player who's still reading through scripted
  steps, on top of last session's "enemy doesn't attack in the tutorial" change.
- Verified with a standalone Node script (`/tmp/test_tutorial_regen.js`, four cases): the enemy
  regens at exactly half speed in the tutorial; the human player is unaffected; neutral buildings
  are unaffected; and outside the tutorial entirely, nobody is halved. Also ran a full Babel
  transpile check and the complete existing test suite — all passing.

### Enemy castle starts with half its troops during the tutorial (this session)
Requested: halve the enemy's starting castle troops in the tutorial, to make the scripted capture
step an easy win.

- Added a one-line loop in `startGame`'s existing `if (tutorial)` block (right after the
  level-forcing loop that already exists there): `for (const t of map.towers) if (t.owner === 1)
  t.troops = Math.max(1, Math.floor(t.troops / 2));`. Floored at 1 so a future drop in
  `START_TROOPS` (currently 10, halves to 5) could never round down to 0.
- The tutorial's first real objective ("Sending Troops," `waitFor: "captured"`) explicitly targets
  a rival castle and has no `onEnter` handler that touches enemy troop counts, so this halving
  applies cleanly with nothing else overriding it.
- Neutral buildings and the player's own castle are untouched — only the enemy (`owner === 1`,
  the tutorial's only AI opponent) is affected, and only during the tutorial.
- Verified with a standalone check: human troops unaffected (10), enemy halved (10 → 5), neutral
  unaffected (10). Also ran a full Babel transpile check and the complete existing test suite —
  all passing.

### Tutorial text simplified — shorter sentences, less jargon (this session)
Requested: too many words in the tutorial, dumb it down.

- Rewrote every `body` string in `TUTORIAL_STEPS` for length and simplicity — shorter sentences,
  plainer words, dropped secondary details that weren't essential to following along (e.g. exact
  conversion cost/build-time numbers, "raises capacity and speeds up regen and firing" trimmed to
  just "grows stronger"). Total body word count dropped from roughly 230 to 138 across the 8 steps.
  Titles, `hint` text, and every mechanical field (`waitFor`, `onEnter`, `settleFor`,
  `tutorialWave`) are untouched — this was a text-only pass.
- The How-to-play modal (a separate, non-tutorial help screen reachable from the menu) was left
  as-is — the request was specifically about "the tutorial," which in this codebase refers to the
  guided `TUTORIAL_STEPS` flow, not that modal.
- Verified: full Babel transpile check on the complete script block passed, a word-count check
  confirmed the reduction, and the complete existing test suite (unaffected — a pure copy change,
  no logic touched) still passes.

### How-to-play modal simplified too — dropped the ability explanation (this session)
Follow-up to the tutorial text simplification above. Requested: dumb down the How-to-play modal
too, and no need to explain abilities there.

- Rewrote every bullet for length/simplicity, same approach as the tutorial pass — shorter
  sentences, dropped secondary detail. The momentum/level-defense bullet was the worst offender
  (a dense paragraph covering exact percentages for kills/captures/upgrades/drift) — cut down to
  the two sentences that actually matter for how to play: momentum grows/shrinks from winning or
  losing fights and affects attack/speed/defense together, and higher-level buildings defend
  better on their own.
- **Dropped the detailed ability-mechanics explanation entirely** (train bar, tap-to-cast, no
  aiming, load times, death refills, "enemies get their own hero too") — replaced with one short
  line just noting a hero gives you 3 specials, since the mechanics themselves are already fully
  explained where they actually matter: the hero picker on the menu screen shows each hero's exact
  3 abilities with full descriptions when picking. No need to duplicate that here.
- Verified: full Babel transpile check on the complete script block passed, and the complete
  existing test suite (unaffected — pure copy change) still passes.

### Menu doc version drift fixed; hero picker moved to its own screen (this session)
Two unrelated small changes:

- **Doc header was stale.** The top-of-file "Currently vX.XXX" line hadn't been updated in
  several sessions (it still said v0.183 while `APP_VERSION` in the actual file had moved on
  to v0.219, and a mid-doc section even referenced v0.203 in passing) — the per-session bump
  habit was being kept for the code but not consistently for this doc's header. Corrected to
  match `APP_VERSION`. No code change.
- **Hero picker is now its own screen** (`screen === "hero"`, a new value alongside the
  existing `"menu"`/`"play"` — same top-level `screen` state, `setScreen` already existed and
  is reused as-is, no new state machine). First pass (v0.220) tried an inline expand/collapse
  toggle within the menu screen itself; this session replaced that with a dedicated screen,
  which reads cleaner and matches how the game already handles Play/Pause/Tutorial-exit
  navigation. The menu screen's HERO block is now just a compact summary chip (icon + name +
  3 ability glyphs) that calls `setScreen("hero")`; the new screen shows the full 4-hero grid
  + selected hero's ability descriptions (same JSX as before, just relocated) with a "← Back"
  button (top-left, `setScreen("menu")`) and a "Done" button at the bottom doing the same
  thing — both routes back are equivalent, purely a matter of where your thumb already is.
  `selectedHero` and `startGame`'s hero logic are untouched.
- Other menu-neatness ideas raised but not yet done: shrinking the COMBATANTS column's reserved
  height for 2v2/Random (still open, see backlog note below).
- Verified: full Babel transpile check on the complete script block passed.

### Redundant "you + N AI" caption removed from the menu (this session)
Small follow-up cleanup: deleted the `mode === "ffa" ? \`you + ${numPlayers - 1} AI\` : "\u00A0"`
caption line that sat between the HERO chip and the Deploy button. It only ever restated what
the COMBATANTS chips (FFA) or the mode's own explainer text (2v2/Random) already showed — pure
duplication, no information lost by cutting it. Deploy now sits directly under the HERO section
with one less line of vertical space in between. Verified: full Babel transpile check passed.

### Home screen retheme: dark navy → light, "user friendly" palette (this session)
Requested a full color/theme change for the home screen specifically — asked for options first
(refined dark, crimson, emerald, cyber-teal), all declined in favor of "nothing dark, something
user friendly." Scoped to exactly the two pre-match screens (`screen === "menu"` and
`screen === "hero"`, plus the How-to-play modal launched from the menu) — the in-game HUD/canvas
and the pause/outcome/tutorial overlays are untouched and stay on the original dark theme, since
those sit on top of the battlefield and weren't part of the ask.

- **New palette**: page background is a soft light-blue-to-white gradient
  (`linear-gradient(180deg, #EAF4FF 0%, #FFFFFF 60%)`) instead of the old flat dark navy overlay.
  Primary text `#1F2A44` (deep slate, not pure black — softer/friendlier), secondary text
  `#6B7684`/`#8592A8`, card/modal surfaces flat white with a light `#E3E9F3` border and a soft
  navy-tinted shadow instead of a black one. Unselected chips: pale blue-gray fill `#F4F7FC` on
  a `#D7E1EE` border. Selected/active state (MODE, COMBATANTS): light gold fill `#FFF6DC` with
  a deeper gold border/text (`#E2A100` / `#B87800`) — keeps the brand's gold identity but with
  real contrast against white, instead of the old bright `#FFD23F` text which was legible on
  dark but would've nearly disappeared on white. Deploy/Done buttons keep the bright gold
  `#FFD23F` *background* (fine — dark text sits on top of it) with a darker gold border for
  definition against the now-light page.
- **The hard part: HEROES[id].color and ABILITY_META[kind].color.** Both tables are tuned
  bright/pastel on purpose for the dark in-game UI (train bar glow, momentum chips) — using them
  directly as text color on white was the actual bug risk, e.g. Tempo's `#FFD23F` or Frost's
  `#BFE9FF` would have been nearly invisible. Rather than editing those shared tables (would've
  broken their look in-game, where they're correctly tuned) or falling back to one flat color
  for every hero/ability (loses the identity those colors are there to convey), added a new
  top-level helper `readableAccent(hex, maxLight)`: converts to HSL and clamps lightness down to
  `maxLight`, preserving hue/saturation, then converts back. A flat percentage darken was tried
  first and rejected — it left already-mid-tone colors (Warlord's `#FF6B4A`) barely touched
  while barely denting near-white ones (Frost's `#BFE9FF`), so contrast against white ended up
  wildly inconsistent hero to hero; clamping lightness instead normalizes it. Verified via a
  standalone Node contrast simulation (WCAG relative-luminance formula) against the actual
  shipped function, across the full 13-color hero/ability roster: worst case is 4.29:1 (Tempo's
  gold, right at the AA threshold for normal text, comfortable for the 13–15px **bold** labels
  it's actually used on), everything else clears 4.4:1 up to 10.9:1. Used at `maxLight=0.3` for
  text (hero name in the summary chip and grid, ability tier name) and `maxLight=0.55` for
  borders (decorative, can stay a bit lighter/more saturated).
- Other menu-neatness idea raised but not yet done: shrinking the COMBATANTS column's reserved
  height for 2v2/Random (still open, see backlog note below).
- Verified: full Babel transpile check on the complete script block passed, plus the standalone
  contrast simulation above.

### Castle body art: raster image replaces the vector castle body (this session)
Firas uploaded a 4-level x 4-view AI-rendered castle reference sheet (blue/gold, stone,
Voronoi-game style) and asked to use the front view only, with the blue portions recolored per
player rather than a flat multiply-tint over the whole image. This replaced the fully-procedural
castle body in `drawTowerSprite` — **watchtowers are untouched**, `drawWatchtowerSprite` is still
100% vector.

- **Asset prep** (done with Python/PIL, not in-game): cropped the front-view column for each of
  the 4 levels out of the reference sheet (label ribbons and neighboring back/left/right-view
  columns bled into naive fixed-window crops — had to detect per-row content bands via a
  background-color-distance mask, then hand-tune the crop window per level since levels 3-4's
  flags/shadows bridge across column boundaries and defeated clean auto-detection). Background
  removed to transparency via a distance-from-background-color threshold with a soft falloff
  (a hard threshold left a gray vignette halo — fixed by pushing the threshold band to 38-70
  distance instead of 8-30). Re-encoded PNG->WebP (quality 82) — cut the base64 payload from
  ~580KB to ~177KB total across all 4 levels with no visible quality loss (verified by eye on
  the most detailed level-4 image). Embedded as base64 data URIs (`CASTLE_IMG_SRC`), not external
  files — the game stays a single self-contained `index.html`; data-URI decode is effectively
  instant (no network round trip) so by the time a match actually starts (past the menu/hero
  screens) the images are guaranteed loaded.
- **Per-player recoloring — the actual hard part.** Firas explicitly wanted the blue portions
  hue-shifted per player rather than a multiply-blend over the whole image (which would have
  muddied the gold trim too). Solution: `recolorCastleImage(level, ownerHex)` draws the source
  image to an offscreen canvas, then per-pixel: convert to HSL, and if the pixel falls in a
  blue-family hue band, replace its hue with the target color's hue while preserving lightness
  (so the original art's shading/highlights/folds carry over) and nudging saturation toward the
  target's own. The hue band (`0.52 < h < 0.72`, with a `s > 0.15` floor to skip low-chroma
  stone/shadow/highlight pixels) wasn't guessed — sampled the actual source art's saturated-pixel
  hue histogram first and found gold/stone trim clustering at hue 0.04-0.21 and the blue
  roofs/banners at 0.54-0.63, with a completely empty gap between — so the band has real margin
  on both sides, not a guessed cutoff. Verified by simulating the exact algorithm in Python
  against the real cropped images at three target colors (the red/teal/violet faction colors)
  and inspecting the output before porting to JS — roofs/banners recolored cleanly, stone and
  gold trim stayed untouched in all three. Result is cached per level+color on an offscreen
  canvas (`castleRecolorCache`, same pattern as `soldierCache`) — the per-pixel loop runs once
  per level/owner combo (at most 4 levels x 5 owners a match ever needs), not per frame. Neutral
  castles pass `null` and keep the source art's own blue/gold as-is, rather than hue-shifting
  toward `NEUTRAL_COLOR`'s white, which has no hue to shift toward.
- **What had to change in `drawTowerSprite` beyond just drawing an image**: the old function
  hand-drew stone blocks, turrets, crenellations, windows, an arched gate, and per-level flags —
  all gone now, replaced by the recolored image (levels are told apart by the art itself, not by
  flag count anymore — see the now-stale `nFlags` comment fixed in `CASTLE_LEVEL_CFG` above). But
  several gameplay-state cues that used to be baked into that vector drawing needed a new home
  since a static raster image can't be selectively recolored per-region the way vector fills
  could:
  - **Fortify** (used to recolor the whole body metallic/gold) is now a warm rim-glow behind the
    sprite (`ctx.shadowBlur` + a second `drawImage` pass) instead of a body recolor.
  - **Tower Defense / Barrage** (used to grow and recolor the right turret specifically) are now
    a positioned radial-gradient glow anchored at an approximate "upper-right" point within the
    image's bounding box (`imgDestW * 0.27, totalH * 0.30`) — there's no literal turret geometry
    left to grow.
  - `totalH`/`topY`/`midY` (used everywhere downstream — drag/hover ring radius, build-dust clip
    rect, upgrade-ready ring/arrow position, convert-hint text position) are now derived from the
    image's own aspect ratio (`CASTLE_IMG_SCALE * baseW` for width, height from the image's
    natural h/w ratio) instead of the old `cfg.keepH`/`turretH`/`grand` vector math — every
    downstream consumer of those three variables kept working unchanged since the *names* and
    general meaning (top/mid/height of the sprite's bounding box) didn't change, just how
    they're computed.
  - Build-dust/hammer animation, drag/hover rings, upgrade-ready pulse, and the hold-to-convert
    hint text are all untouched — they only ever depended on `baseW`/`keepW`/`groundY`/`topY`/
    `totalH`/`midY`, all still valid.
- **`CASTLE_IMG_SCALE = 2.0`** (new constant, next to `CASTLE_SCALE`) is a first-pass sizing
  value — how wide the image renders relative to the old vector `baseW`. **Not yet seen running
  in an actual browser** (this environment can run Babel/Node checks but not a live canvas), so
  it's flagged as the one number to retune once actually playtested on-device if castles read
  too big or too small next to soldiers/terrain.
- Verified: full Babel transpile check on the complete script block passed. The recolor algorithm
  itself was verified twice — once via the Python/PIL visual simulation against the real source
  images (see above) before porting to JS, and once by sampling the real source art's hue
  histogram to confirm the detection band has genuine separation rather than being a guess.
- **Not done / open**: on-device visual tuning of `CASTLE_IMG_SCALE` and the buff-glow anchor
  position; the "1 flag per level" reading is gone (levels are now told apart by the art's own
  complexity instead) — worth a look once playtested to confirm level is still readable at a
  glance; grass-mound base from the source art is kept as-is (reads like a floating icon-style
  base rather than blending into the procedural terrain underneath it — a deliberate choice to
  match the reference art rather than crop the base out, but worth a second look in motion).

### Castle art follow-up: dropped the vector ground shadow, neutral castles now grey (this session)
Two quick fixes on top of last session's castle image work:

- **Removed the old flat black ground-shadow ellipse** that used to sit under the vector castle
  body (`ctx.fillStyle = "rgba(0,0,0,0.35)"` + an ellipse offset opposite `LIGHT_DIR`). The
  castle *image* already has its own grounding/shadow baked into the art, so the extra vector
  ellipse was doubling up and reading oddly underneath it. Castle-only — `drawWatchtowerSprite`'s
  own ground shadow is untouched, towers still have theirs. The 2v2 team ring (a separate
  ellipse at nearly the same size/position) is also untouched — that one carries real gameplay
  information (ally vs. enemy), the plain shadow didn't.
- **Neutral castles' blue now desaturates to grey instead of staying the source art's branded
  blue.** `recolorCastleImage`'s neutral path (`ownerHex === null`) used to just leave the image
  as-is, on the reasoning that white (`NEUTRAL_COLOR`) has no hue to shift toward — true, but
  "leave it blue" wasn't the right fallback either, since blue reads as *a* faction's color, just
  not one in play. Now the same blue-band pixels get their saturation clamped to 0 instead of
  hue-shifted (lightness preserved, so shading/highlights still carry over) — same detection
  band, same technique, just `hslToRgb(hue, 0, lightness)` instead of hue-shifting to a target.
  Verified with the same Python/PIL simulation approach as the original recolor work (rendered
  both a level-1 and level-4 example at 0 saturation before touching the JS) — roofs/banners go
  clean grey stone, gold trim and dome untouched.
- Verified: full Babel transpile check on the complete script block passed.

### Castle body art swapped for a new reference sheet (this session)
Firas uploaded a different castle reference sheet — 4 levels, single front-on view each (no
front/back/left/right columns this time), same blue/gold stone style, flat dark background.
Replaced the 4 embedded images wholesale; **no other code changed** — `recolorCastleImage`,
the blue-hue detection band, `drawTowerSprite`'s use of the images, `CASTLE_IMG_SCALE`, all
untouched, since the new art uses the same blue/gold palette family. Re-verified the hue
histogram against the new source images before assuming the existing `0.52 < h < 0.72` band
still applied rather than just trusting it would — gold/stone still clusters at 0.04-0.21, blue
still at 0.5-0.67, same clean empty gap between them.

- **New problem this sheet exposed**: the old background-removal method (distance-from-flat-
  background-color, with a soft threshold ramp) worked fine on the previous sheet but produced
  a moth-eaten, speckled look on this one — small holes punched through solid castle stone,
  worst on levels 3 and 4. Root cause: this render has deeper, darker interior shadows (window
  recesses, gaps between crenellations, the archway interior) that sit close enough to the flat
  background color to trip a pure color-distance threshold, even though they're visually "part of
  the castle," not background.
- **Fix**: switched to a flood-fill-from-border approach instead of a pure global threshold.
  Pixels within color-distance of the background color are candidates, but `scipy.ndimage.label`
  finds their connected components first, and only components that actually touch the image
  border get treated as real background/made transparent — an interior shadow pocket that's
  fully enclosed by castle geometry stays opaque even if its color happens to be background-dark,
  while the actual surrounding background (however many separate border-touching pieces the
  castle's silhouette splits it into) still gets removed correctly. A light Gaussian blur (0.6px)
  on the resulting binary alpha softens the edge instead of leaving it hard-aliased. Threshold
  tuned by checking a known-flat background corner patch first (found real background noise sits
  at distance ~18-21, so a distance-26 cutoff has real margin) rather than guessing — then
  visually confirmed the speckling was gone on the two levels that had shown it worst (3 and 4)
  before finalizing. This flood-fill method is strictly better than the old pure-threshold one
  and worth using for any future castle-sheet swap, not just this one.
- Background-removed, WebP-encoded (quality 82, same as before), and re-embedded as base64 —
  total payload actually dropped slightly, ~121KB across all 4 levels vs. ~177KB for the previous
  set (this art has more uniform flat regions that compress better).
- Verified: recolor + neutral-grey algorithms re-run via the same Python/PIL simulation approach
  against the new art (red recolor on level 1, neutral grey on level 4) before touching the game
  file, plus a round-trip decode check on the actual embedded base64 in the shipped file (all 4
  decode back to valid images at the expected dimensions) and the usual full Babel transpile
  check.
- Not done: on-device visual check that this art's proportions still suit `CASTLE_IMG_SCALE = 2.0`
  — this sheet's castles have a taller, narrower aspect ratio than the previous set (e.g. level 3
  is now ~260x436 vs. ~260x206 before), so the same width-based scale constant will render them
  noticeably taller. Worth a look once playtested; may want its own tuning pass.
  **→ Resolved this session, see below — this is exactly what happened, confirmed too big.**

### Castle sizing fix: contain-fit to the old vector footprint, not a flat width scale (this session)
Firas confirmed castles were rendering way too big — exactly the open risk flagged at the end of
last session. Root cause: sizing was "set width = `baseW * CASTLE_IMG_SCALE`, derive height from
the source art's own aspect ratio" — fine when the art's proportions roughly matched the old
vector silhouette, but this castle sheet is much taller relative to its width than the old vector
shapes were (e.g. level 3's image is ~1.7:1 h:w, the old vector L3 was 1:1), so deriving height
from width let castles balloon well past their old size without the width number itself looking
obviously wrong.

- **Fix**: replaced that with a contain-fit against the exact w x h footprint the old vector
  castle used to occupy at each level (`baseW x oldTotalH`, using the same
  `Math.max(keepH, turretH) + (grand ? 12 : 0)` formula the vector body's `totalH` used to compute
  for itself) — `fitScale = min(baseW / img.width, oldTotalH / img.height)`, applied to both
  dimensions together. This guarantees the image is never bigger than the original vector castle
  was in *either* dimension, regardless of how the source art's aspect ratio compares — the
  previous approach only controlled width and let height do whatever the art's proportions
  dictated.
- `CASTLE_IMG_SCALE` changed from `2.0` (the guessed first-pass value that turned out too big) to
  `1.0`, now meaning "exactly the old vector footprint" rather than being an unexplained width
  multiplier — still there as a deliberate size-up/down knob on top of that baseline, just with a
  meaningful default now instead of a guess.
- Verified numerically (a standalone calc mirroring the exact in-file formula, not just eyeballed)
  that every level's new destination size sits at or under the old box in both dimensions — all
  4 levels come out height-constrained given this art's proportions (L1 30px old cap, L2 38px,
  L3 58px, L4 66px — matched exactly), with width comfortably under the old cap in every case.
- Verified: full Babel transpile check on the complete script block passed.

### Castle images reverted — back to the fully-procedural vector castle (this session)
Firas's call after seeing it running for a few sessions: the original vector-drawn castle body
looked better than the raster-image approach, even with the sizing fixed. Reverted cleanly
rather than continuing to patch the image direction — per the project's usual "reversals are
clean" preference.

- **Removed entirely**: `CASTLE_IMG_SRC`/`CASTLE_IMAGES` (the base64-embedded art + loader),
  `recolorCastleImage`/`rgbToHsl`/`hslToRgb` (the selective blue-hue recolor system), and
  `CASTLE_IMG_SCALE`. `drawTowerSprite`'s body is back to the original hand-drawn stone/turret/
  crenellation/window/gate/flag vector rendering — same one that was in place before any castle
  image work started, restored from the exact original code (still had it from the first edit of
  that session, rather than reconstructing from memory). `CASTLE_LEVEL_CFG`'s comment is back to
  its original wording too (had been edited to describe the image-based approach).
- **File size**: back down to ~247KB from ~408KB — the ~161KB of embedded castle WebP art is
  gone.
- **What this means for level differentiation**: back to "levels told apart by silhouette shape
  and flag count" (nFlags, one flag per level) rather than by the art's own visual complexity —
  the vector version's original approach.
- `readableAccent` and the light-themed home/hero screens (unrelated feature from a separate
  session) were untouched by this revert — confirmed still present and wired up correctly
  afterward.
- Verified: full Babel transpile check on the complete script block passed, plus a manual
  read-through of the spliced-in vector code to confirm it flows correctly into the (unchanged)
  build-dust/hammer animation, drag/hover rings, upgrade-ready hint, and convert-hint code that
  sits after it.
- If castle art is revisited again later, the earlier session notes above (asset-prep pipeline,
  background-removal-via-flood-fill fix, the blue-hue-detection-band methodology, the contain-fit
  sizing fix) are still valid groundwork and don't need to be re-derived — just the "does the
  actual art style read well in the game" judgment call didn't land this time.

### Castle art tried again: isometric stone/wood set (Settlement/Stronghold/Fortress/Citadel) (this session)
Third castle-art attempt. Firas uploaded a 2x2 sheet (Settlement, Level 2 Stronghold, Modified
Level 3 Fortress, Citadel) — isometric view this time rather than front-on, natural stone/wood
tones with no blue/colored accent area. Re-added the raster-image body to `drawTowerSprite`
(removed entirely two sessions ago) using this new art. `drawWatchtowerSprite` still untouched/
100% vector, as always.

- **Background removal was genuinely hard this time, unlike the two previous sheets.** This
  source wasn't on a flat color — it was a checkerboard *transparency preview* (baked into the
  RGB pixels, not real alpha), and this art's stone shading lands almost exactly on the same gray
  as the checker squares (sampled actual stone pixels at things like `(110,110,102)` against a
  checker tone of `(110,110,110)` — effectively no color separation in the shaded areas). Every
  purely color-based approach either ate into the stone or left checker speckle behind. Tried,
  in order: (1) tight dual-tone color-distance threshold — left heavy speckle; (2) flood-fill-
  from-border on that threshold — swallowed most of the actual castles, since their own stone
  matched the background color criteria; (3) a periodic self-similarity test (compare each pixel
  to itself shifted by the checker's ~23px period, computed via autocorrelation) — correctly
  rejected castle content but was too noisy on the actual checker regions to threshold cleanly;
  (4) median-filter + morphological closing/opening + flood-fill + largest-connected-component —
  the version actually shipped. Settlement and the Level 2 Stronghold came out clean; the
  Modified Level 3 Fortress still has some residual checker fragments near its edges that
  survived every cleanup pass tried (they're apparently solidly connected to the main shape, not
  a thin bridge erosion could cut) — flagged as a known imperfection rather than hidden.
  **If this art direction sticks, a flat-background re-export of the same source (like the
  previous two sheets had) would make this trivial instead of hard — worth asking for if revisited.**
- **No per-player recoloring this time — different technique instead of adapting the old one.**
  The previous two art sets had a blue accent area to hue-shift; this one is uniform natural
  stone/wood with nothing to selectively tint. Asked Firas how to handle ownership given that;
  got "continue" (use judgment), so: the ground ring (previously 2v2-only, showing ally/enemy
  gold-or-red) is now shown in **every mode**, using the raw faction color when not 2v2 — it's
  the primary ownership signal now that the art itself isn't tinted. Also added a small
  procedural flag (plain triangle, faction-colored, same visual as the old vector castle's flags)
  planted at the art's approximate topmost point, since this reference sheet's buildings don't
  have flags baked in. Both are cheap, reversible additions on top of the image, not touching the
  source art's pixels.
- **Sizing**: same contain-fit-to-the-old-vector-footprint approach validated last time (fit the
  image into `baseW x oldTotalH` for each level, preserving the art's own aspect ratio) — carried
  over as-is since it's art-agnostic. Verified numerically for this art's actual proportions
  (wider/shallower than the front-view set, so all 4 levels come out width-constrained this time
  rather than height-constrained): L1 35x22, L2 52x36, L3 58x32 (undersized vertically due to the
  Fortress crop's residual edge speckle widening its bounding box — a knock-on effect of the
  background-removal imperfection above, not a separate bug), L4 66x42.
- File size: ~321KB (up from ~247KB pre-this-session; the 4 WebP images add ~58KB base64).
- Verified: full Babel transpile check on the complete script block passed. Sizing verified via
  the same standalone numeric calc approach as the previous sizing fix.
- **Open/not done**: Level 3's residual background-removal speckle (cosmetic only, doesn't block
  play); no on-device visual check yet of how the new procedural flag position/ring-always-on
  approach actually reads during a match.
  **→ Reverted this session before any on-device look — see below.**

### Isometric castle art reverted (this session)
Firas said "undo" right after the isometric set (Settlement/Stronghold/Fortress/Citadel) was
wired in, before it had been seen running. Reverted cleanly back to the fully-procedural vector
castle — same approach as the previous revert: restored `drawTowerSprite`'s body from the exact
saved pre-image code rather than reconstructing it, and removed the `CASTLE_IMG_SRC`/
`CASTLE_IMAGES` loader block entirely (no leftover references — confirmed via grep for
`CASTLE_IMG_SRC`, `CASTLE_IMAGES`, `bodyImg`, `imgDestW`, `imgReady`, `oldTotalH`, all clean).
File size back to ~247KB, matching the previous vector-only baseline exactly. `readableAccent`
and the light-themed home/hero screens (unrelated feature) confirmed still intact.

Three castle-art attempts now tried and reverted across this project (front-view set #1, front-view
set #2, isometric set) — the vector castle has won out each time. Worth treating that as a signal
rather than continuing to retry variations on the same idea if a fourth image set comes up: the
underlying tension seems to be that hand-tuned vector art integrates cleanly with this game's
per-player recoloring, buff states, and build animations in a way raster art consistently has to
work around rather than naturally support.

### Fixed: COMMIT % buttons covering a bottom-row castle's troop count (this session)
Root cause: `MAP_EDGE_MARGIN_Y` (80 world px) only accounted for the castle sprite's own upward
extent from `t.y` — but `drawGarrisonPlate` draws the troop-count plate 31 world px *below* `t.y`
(`groundY + 17`, where `groundY = t.y + 14`), plus ~9 more for the plate's own half-height. A
castle placed right at the old minimum bottom clearance left its plate sitting only ~40 world px
from the map's bottom edge — close enough that the COMMIT % buttons (a fixed HTML overlay pinned
to the bottom of the map view, unrelated to canvas world-space) could sit right on top of it.
No equivalent problem at the top edge, since there's no overlay there.

- Added `MAP_EDGE_MARGIN_Y_BOTTOM = MAP_EDGE_MARGIN_Y + 45` and used it only for the bottom side
  of the clamp in `recenterCastles` (the final safety clamp that sets a castle's actual position
  after Lloyd relaxation) — the top clamp and `generateMap`'s initial symmetric ellipse both stay
  on the base `MAP_EDGE_MARGIN_Y`, since only the bottom needed the extra room. +45 covers the
  plate's ~40 world-px downward reach past `t.y` with a small safety buffer left over for the
  COMMIT buttons themselves.
- This is a placement-time fix (keeps castles further from the bottom edge in the first place),
  not a z-index/rendering-order fix — simpler and avoids needing the COMMIT bar to know anything
  about castle positions.
- Verified: full Babel transpile check on the complete script block passed; sanity-checked the
  new margin (125 world px total) against typical map world-height — nowhere close to being able
  to invert the clamp on any realistic screen size.
- Not done: no on-device visual confirmation this fully eliminates the overlap in every case
  (map generation is randomized, so it's a "much rarer now" fix by construction rather than a
  provably-zero-collision one) — worth another look if it still happens occasionally.

### Follow-up: when the overlap does still happen, plate now wins visually (COMMIT stays clickable) (this session)
Firas's explicit ask after the placement-time fix above: don't just make the overlap rarer, also
handle the case where it still happens — the troop count should visually win over the COMMIT
buttons, but the buttons must stay tappable regardless.

- **Added a second, transparent canvas** (`overlayCanvasRef`), sized/DPI-matched identically to
  the main canvas on every resize, positioned `absolute inset:0` in the DOM **after** the COMMIT
  bar (so it paints visually on top of it) with `pointerEvents: "none"` — that's what makes it
  purely visual: taps pass straight through it to the real COMMIT buttons underneath, which still
  have their own `pointerEvents: "auto"`.
- **`draw(g)`** still draws every plate onto the main canvas exactly as before (unchanged, so
  normal play is untouched), then does one extra cheap pass: for each plate, recompute its screen
  position (`proj(g, t.x, t.y + 14 + 17)`, the same anchor `drawGarrisonPlate` uses internally)
  and if that falls within the bottom `COMMIT_BAR_ZONE_H` (64px) screen strip where the COMMIT
  bar lives, redraw that one plate again onto the overlay canvas too. Everyone else is untouched;
  only plates that actually need it get the extra draw call.
- `COMMIT_BAR_ZONE_H` is a generous CSS-px estimate of the COMMIT bar's actual footprint (not
  read from the DOM — deliberately fine to be a little too generous, since an unnecessary extra
  draw is harmless, but not fine to be too short).
- Verified the coordinate math is actually sound rather than assuming it: `CAM_ZOOM = 1/TILT`,
  so `CAM_ZOOM * TILT = 1` exactly by construction, which confirms `proj()`'s screenY equals
  worldY exactly (no perspective distortion vertically) — meaning the zone check compares
  like-for-like units, not an approximation. Also hand-checked a castle sitting right at the new
  `MAP_EDGE_MARGIN_Y_BOTTOM` boundary from the placement fix above: its plate lands ~30px clear
  of the COMMIT zone on its own, so this overlay is a genuine safety net for edge cases (resize
  rescaling, any placement path that doesn't go through `recenterCastles`) rather than doing the
  routine work every frame.
- Verified: full Babel transpile check on the complete script block passed.
- Not done: no on-device visual confirmation yet (same caveat as the placement fix above).

### Fixed: Redeploy stopped re-rolling "Random" mode after the first match (this session)
Firas's bug report: picked Random mode, played a match, hit Redeploy — got the same result
(mode + player count) every time instead of a fresh roll. Confirmed and root-caused: the Redeploy
button called `startGame(gameRef.current.numPlayers, gameRef.current.mode)`, but `g.mode` stores
the *resolved* concrete mode ("ffa" or "2v2") that "random" got resolved to for that particular
match — "random" itself was never stored anywhere, so by the time Redeploy ran, there was no way
to tell it had ever been "random" to begin with. Redeploy was faithfully repeating the resolved
result forever, not literally "random" being non-random — the raw selection just didn't survive
past the first resolution.

- Added `selectedMode`/`selectedNumPlayers` to the game object — the *raw* pre-resolution menu
  choice (so `selectedMode` can genuinely be `"random"`), stored alongside the existing
  `mode`/`numPlayers` (which stay as the resolved values and are still correctly used everywhere
  else — e.g. the 2v2 team-ring checks and the outcome screen's "Enemy team wiped out" vs. "Every
  rival eliminated" text both need the *resolved* mode, not the raw selection, and are untouched).
- Redeploy now calls `startGame(gameRef.current.selectedNumPlayers, gameRef.current.selectedMode)`
  instead — passing "random" back in re-triggers `startGame`'s own resolution logic fresh each
  time, same as picking Random from the menu would.
- The Deploy button (menu) and the tutorial's start button were already fine — Deploy reads
  straight from the menu's own `mode`/`numPlayers` React state (the actual raw selection, never
  overwritten), and tutorial is hardcoded (`startGame(2, "ffa", true)`). Only Redeploy had the bug.
- Verified with a standalone Node simulation mirroring the exact resolution logic: fed a
  Random-mode "match result" through 8 simulated Redeploys using the fixed code path — confirmed
  `selectedMode` stays `"random"` throughout and each redeploy genuinely re-rolls (mix of ffa/2v2
  and varying player counts across the 8 runs, not a repeat of the first roll).
- Verified: full Babel transpile check on the complete script block passed.

### Rage and Fortify swapped tiers (this session)
Firas's request: swap tiers and places for Rage and Fortify.

- **`ABILITY_META.rage.tier`** changed 2 → 3; **`ABILITY_META.fortify.tier`** changed 3 → 2.
  Tier is intrinsic to the ability (see the block comment above `ABILITY_META`), so this alone
  moves both abilities' train cost/position: `trainThreshold()` is derived from
  `SPECIAL_STAGE[kind] * TRAIN_STAGE`, so Rage now takes `3 * TRAIN_STAGE = 60s` to reach
  (was 40s), and Fortify now takes `40s` (was 60s). No other constant needed touching — the whole
  loading-train UI, per-tier segment fill, and cooldown timing already key off `tier`, not the
  ability name.
- **`HEROES.warlord.kit`** updated to match: `{1: "slow", 2: "fortify", 3: "rage"}` (was
  `{1: "slow", 2: "rage", 3: "fortify"}`) — Warlord's Tier-2 slot is now Fortify, Tier-3 is now
  Rage. This is the only hero carrying either ability, so no other kit needed changing.
- Updated the stale "Tier 2"/"Tier 3" mentions in the constant-block comments above `FORTIFY_MULT`
  and `RAGE_STRENGTH_MULT`, and in the `castFortify`/`castRage` function header comments, to match.
- Updated this doc's hero-kit table and ability-reference table (including re-sorting Fortify and
  Rage into their new tier groups) to match.
- Verified with a standalone Node sandbox eval of the transpiled `ABILITY_META`/`HEROES`/
  `trainThreshold` block: confirms `rageTier: 3`, `fortifyTier: 2`, `warlordKit.2 === "fortify"`,
  `warlordKit.3 === "rage"`, `trainThreshold("rage") === 60`, `trainThreshold("fortify") === 40`.
- Verified: full Babel transpile check on the complete script block passed.

### Heroes renamed: Tempo → Tactician, Saboteur → Disruptor, Siege → Juggernaut (this session)
Firas's request: swap display names (Warlord stays "Warlord"), no "The" prefix.

- Only `HEROES[id].name` (the display string) changed for `tempo`, `saboteur`, and `siege` —
  their internal `id` keys and `HEROES` object keys are untouched (still `"tempo"`/`"saboteur"`/
  `"siege"`), since those are used as stable lookup keys elsewhere (e.g. `startGame` forcing
  `heroes[0] = "tempo"` for the tutorial). All UI surfaces read `hero.name`/`meta.name`
  dynamically, so no other string literals needed touching.
- Updated this doc's hero-kit table to match.
- Verified: full Babel transpile check on the complete script block passed.

### Hero portrait art added to the hero-picker screen (this session)
Firas provided fantasy character artwork (elf fighter, hooded rogue, horned warlord, armored
dwarf) and asked to use it as hero art; confirmed he holds the rights to it before embedding.

- Cropped the source group image into 4 individual bust portraits (head/shoulders, ~220×220),
  compressed to JPEG (~8-16KB each, ~40KB total) and embedded as base64 data URIs in a new
  `PORTRAITS` constant — keeps `index.html` a single self-contained file, no external image
  assets/network fetch.
- Mapped by theme: elf → Tactician, hooded rogue → Disruptor, horned warrior → Warlord, armored
  dwarf → Juggernaut. Added as `HEROES[id].portrait`.
- Wired into the "Choose your hero" screen only: a round 52px portrait on each hero-select chip,
  and a 64px portrait in the ability-detail header for the currently-selected hero. Left every
  other UI spot (top HUD standings badge, in-game specials train, etc.) on the existing emoji
  `icon` field — those render at 11-20px, too small for a portrait to read, and reworking them
  would be a much bigger visual-language change than what was asked for.
- Verified: full Babel transpile check on the complete script block passed.

### Hero portraits extended to in-game UI; player-bar/map-space design notes (this session)
Firas: wanted the hero portraits actually visible during play (not just the picker), and asked
for design recommendations on the top standings row ("player bars") that wouldn't eat into the
map.

- Added the portrait to three more spots, all at small inline sizes chosen specifically not to
  grow any container's height:
  - **Top standings row** (opponent pills): 16px circular portrait inline with the color dot
    and name — replaces the old emoji icon there entirely. Zero height cost since it sits in
    the same row as existing text, not stacked below it.
  - **Standings pill's tap-to-inspect popup**: 28px portrait next to the hero name header. This
    popup is a `position: absolute` overlay (like it already was), so a bigger portrait here
    costs zero permanent screen space — it only appears on tap and disappears on tap-away.
  - **Main menu's hero-summary chip**: 26px portrait replacing the emoji icon, same treatment.
  - Left the specials-train icons and the tiny ability-tier badges alone — those are 11-15px,
    genuinely too small for a portrait to read as anything but a blur.
- **Design recommendation given for the standings row specifically**: the row was already fixed
  in an earlier session to be a flex sibling above the map (not an absolute overlay), so the map
  already can't be visually covered by it — the real risk is the row's own *height* growing and
  shrinking the map's flex:1 share. Two things keep that in check going forward: (1) any new
  per-player info should default to inline/on-the-same-row, not a new stacked line, and (2)
  anything that needs more space than that (like a full portrait or ability descriptions)
  belongs in the existing tap-to-inspect popup pattern, which is free real estate since it's an
  overlay that only exists while actively tapped. Recommended against e.g. always-visible large
  avatars or a second row of per-player detail in the persistent header — that's exactly the
  kind of change that would start eating map space on smaller phones.
- Verified: full Babel transpile check on the complete script block passed after each edit.

### "Tower Defense isn't working, castles aren't shooting" — investigated, fixed the real cause (this session)
Firas reported casting Tower Defense as Tactician produced zero visible change on his own
castles — no turret growth, no arrows.

- **Traced the entire mechanic end to end** — `castTowerDefense` (sets `d.rateMult`/
  `d.rateExpiresAt` on every owned building), the fire-loop's `canFire` eligibility check, range/
  cooldown math, and the visual buff checks (turret growth, range ring, arrow spawn) — and
  **verified it in a standalone Node simulation** using the actual verbatim logic: a castle with
  the buff correctly fires an arrow at a hostile in range. No bug found in the core mechanic
  itself.
- **Root cause was almost certainly the specials-train button**, not the ability: it used a
  native `disabled={!ready}` attribute. A native `disabled` button eats a tap with **zero**
  feedback of any kind — no onClick fires at all — which is indistinguishable from "the ability
  ran and did nothing." A tap that lands a moment before the tier-3 segment is actually full (or
  while it's still on its own 20s cooldown) would look and feel exactly like a broken special.
- **Fix**: removed the native `disabled` attribute. `castPlayerSpecial` now always runs and, if
  `readyFor()` says the special genuinely isn't ready yet, gives a visible "denied" shake
  (`specialDenied` keyframe, 300ms) on that specific segment instead of silently no-opping.
  "Ready to cast" vs "not ready yet, here's why your tap didn't do anything" are now always
  visually distinct outcomes.
- Verified: full Babel transpile check on the complete script block passed.

### Tower Defense follow-up: hardened against a silent-throw failure mode, added on-screen error banner (this session)
The previous fix (removing native `disabled`) ruled out the "tap didn't register" theory — Firas
confirmed no shake, meaning `readyFor()` was true and the cast genuinely proceeded — yet still
zero visible effect (no ring, no turret change, no arrows), while Rally and Speed both work fine.

- **Key clue**: `castTowerDefense`, `castBarrage`, and `captureBuilding` all did an unguarded
  `for (const d of t.defs)`. The window-resize handler already has a defensive `if (t.defs)`
  guard around its own equivalent loop — meaning `t.defs` going missing at runtime was already a
  known-possible state, just never guarded against at these three sites. Rally/Speed never touch
  `t.defs` at all, which is why they'd keep working even if this exact failure hit.
  If `t.defs` is ever falsy on a building Tower Defense reaches, the unguarded `for...of` throws
  a TypeError **inside the onClick handler**, with nothing catching it — execution just stops:
  no ring for that building or any later one in the loop, no `SoundEngine.towerDefense` call, no
  `setCd`. From the player's side that's indistinguishable from "the special did nothing."
- **Fix 1 — defensive guards**: all three sites now iterate `(t.defs || [])` instead of
  `t.defs` directly, matching the resize handler's existing pattern. A building with genuinely
  missing defs is now skipped harmlessly instead of aborting the whole cast for every other
  owned building too. Verified with a Node simulation: normal case unchanged, and a
  deliberately-broken building no longer crashes the loop — the other owned building still gets
  its ring and `rateMult`.
- **Fix 2 — visible error surface**: `castPlayerSpecial` now wraps the `fn(g, 0)` call in
  try/catch. Any exception is both `console.error`'d AND shown as a small red banner above the
  specials train for 5 seconds (`castError` state) — there's no reliable devtools access mid-game
  on a phone, so a console-only log isn't enough to actually debug this live. If the guard above
  wasn't the true root cause, this will surface whatever actually throws next time, with a
  message on-screen Firas can just relay directly instead of more back-and-forth guessing.
- Verified: full Babel transpile check on the complete script block passed.

### Tower Defense: stopped guessing, shipped a diagnostic build (this session)
Two attempted fixes (removing native `disabled`, then guarding `t.defs`) both failed to resolve
it, and both were hypotheses rather than confirmed causes. Ruled out so far, with evidence:
- **Not the tap being swallowed** — no shake fires, so `readyFor()` returns true and the cast
  genuinely runs.
- **Not a missing `SoundEngine.towerDefense`** — verified it exists at line ~1172.
- **Not the core mechanic** — a standalone Node simulation of the verbatim cast + fire-loop
  logic correctly produces an arrow from a buffed castle.
- **Not a global crash** — Rally and Speed work fine in the same session.

Rather than guess a fourth time, this build instruments the whole chain and puts the result
on screen (small blue monospace line above the specials train):
- `train N/60` — actual train progress vs the Tier-3 threshold.
- `cast:` — whether `castTowerDefense` ever ran for the player, how many of their buildings it
  matched (`matched X/total`), and how many turret `defs` it actually wrote `rateMult` onto
  (`buffed N`). Reads `never` if the function was never entered at all.
- `live:` — per-tick state from the fire loop for the player's own buildings: how many currently
  hold a live buff (`buffed`), how many pass the `canFire` check (`canFire`), cumulative count of
  ticks where a buffed building found a hostile in range (`inRange`), and cumulative arrows
  actually spawned (`shots`).

This narrows it to one stage on the next attempt:
- `cast:never` → the dispatch/readiness path, not the ability.
- `matched 0` → the ownership/`sameTeam` filter.
- `buffed 0` with `matched > 0` → missing/empty `defs` arrays.
- `buffed > 0` but `canFire 0` → the eligibility check or premature buff expiry.
- `canFire > 0` but `inRange 0` → targeting/range (nothing hostile close enough).
- `inRange > 0` but `shots 0` → the cooldown gate.
- `shots > 0` → arrows ARE spawning, so the bug is in arrow flight/rendering, not defense.

All diagnostic code is tagged `TEMP DIAGNOSTIC` in comments (`dbg*` locals, `g.tdDebug`,
`g.tdLive`, `tdDebug` state, the readout block) for clean removal once resolved.
- Verified: full Babel transpile check on the complete script block passed.

### ROOT CAUSE FOUND & FIXED: `placeDefenders` was wiping active buffs on every resize (this session)
The v0.240 diagnostic build immediately pinned it. Firas's readout:
```
train 11/60 · cast:matched 4/9 buffed 4 · live:buffed 0 canFire 0 inRange 0 shots 0
```
`cast: matched 4/9 buffed 4` — the cast ran perfectly, found all 4 owned buildings, wrote
`rateMult` onto all 4 turrets. `live: buffed 0` — by the time the fire loop looked, **zero**
buildings still held the buff. So the buff was being erased between cast and the next tick,
which is why `canFire`, `inRange`, and `shots` were all 0.

**Root cause**: `placeDefenders()` did `t.defs = [{ x, y, cd: Math.random() * ARROW_FIRE_CD }]`
— allocating a **brand-new** def object rather than repositioning the existing one. It's called
from `computeCells()`, which the resize handler runs on *any* layout change. On iOS that fires
constantly: URL-bar collapse/expand, the map box resizing as the top HUD settles, orientation
changes. Every one of those silently discarded `rateMult`/`rateExpiresAt` (Tower Defense),
`boulder`/`boulderExpiresAt` (Barrage), and the fire cooldown, replacing them with a fresh
unbuffed object.

This also explains every observation that made the earlier guesses look wrong:
- Rally and Speed kept working — they write to units/momentum, never to `t.defs`.
- The standalone simulations passed — they never simulated a resize.
- No error was ever thrown — nothing crashed; state was just quietly replaced.
- The ring/turret buff visuals never showed — they read `t.defs[0].rateMult`, already wiped.
- The resize handler's own `if (t.defs)` guard hinted `t.defs` churned, but the real problem
  wasn't it going *missing*, it was being *recreated*.

**Fix**: `placeDefenders` now repositions the existing def in place (`prev.x = p.x; prev.y = p.y`)
and only allocates when there genuinely isn't one yet (first placement at map gen). Buff flags and
cooldown now survive any number of resizes. Verified with a Node simulation reproducing the exact
sequence (map gen → cast → resize): old code gives `rateMult undefined, canFire false`; new code
gives `rateMult 1.25, canFire true`.

**Also fixed as a side effect**: Barrage had the identical latent bug, and the per-building fire
cooldown was being re-randomized on every resize.

All v0.240 `TEMP DIAGNOSTIC` instrumentation (`dbg*` locals, `g.tdDebug`, `g.tdLive`, `tdDebug`
state, the on-screen readout) has been fully removed — verified zero remaining references. The
`castError` banner from v0.239 is **kept**: it's a genuinely useful permanent safety net.
- Verified: full Babel transpile check on the complete script block passed.

### Rolling Stones reworked: real boulder sprites, +50% speed, can never capture anything (this session)
Firas: "I want the soldiers to turn into actual Rolling Stones and have an increase of 50 percent
speed. Remember, they can only kill the troops, never take over a building."

- **Actual boulder sprite** — a Rolling Stone no longer draws the soldier sprite at all. It's
  replaced by a rendered rock: shaded body, upper-left lit face matching the map's shared
  `LIGHT_DIR` convention, crack/pit detail, ground contact shadow, and a faction-colored rim so
  ownership still reads at a glance (the old grey diamond relied on the soldier sprite underneath
  for that, which no longer exists). Sized via `ROLLING_STONE_R = 6.5` world px, bulkier than the
  9x13 soldier it replaces.
  - **Rotation derived from remaining distance to destination**, which decreases monotonically as
    a unit advances — so the rock always rolls *forward* and never jitters or reverses, with no
    per-unit accumulator state to keep in sync. Sign flips with travel direction so it rolls the
    way it's actually going. (Deriving it from `u.x + u.y` instead would roll backwards whenever
    a unit moved up-left.)
  - The old rotated-diamond marker was removed entirely — it was a stand-in for exactly this.
  - The teal speed glow is now **suppressed** for stones (`&& !u.rollingStone`): the boulder is
    intrinsically fast, so the glow would read as a second redundant effect stacked under it. The
    slow/frost dashed ring is deliberately kept, since an enemy debuff landing on a stone still
    needs to be visible.
- **+50% speed** — `ROLLING_STONE_SPEED_MULT = 1.5`, written to `u.speedMul`, the same field
  Speed/Slow Down/Frost already use, so it flows through existing march math and can still be
  overwritten by an enemy Slow Down or Frost. Deliberately reuses `SPEED_BOOST`'s number rather
  than introducing a second value to tune.
- **Can never capture ANY building** — the capture-block branch in `unitArrives` was gated on
  `u.rollingStone && t.type === "castle"`, which left **towers** freely capturable by stones. Now
  just `u.rollingStone`, so it covers every building type. Damage still lands in full; the
  garrison clamps at 1 and a non-stone unit is always required to finish the capture.
- Verified with a Node simulation of `unitArrives`: 20 consecutive stone hits on both a castle
  and a tower grind each to exactly 1 troop with **zero** ownership changes, and a single normal
  soldier afterwards successfully captures both.
- Updated `ABILITY_META.rollingStones.desc` and this doc's ability table to match.
- Verified: full Babel transpile check on the complete script block passed.

### New menu option: SKILL TIMER — configurable specials-train pacing (this session)
Firas: "In the main menu, create a timer option. If I click it I should get the option of
choosing a time for skills to activate. Right now it's on 20."

- **`TRAIN_STAGE` is now a `let`, not a `const`** (default now 15 via `DEFAULT_TRAIN_STAGE`, was 20 until v0.247),
  with `TRAIN_STAGE_OPTIONS = [5, 10, 15, 20, 30, 45]`.
- **`TRAIN_MAX` became `trainMax()`**, a function. This was the one genuinely load-bearing change:
  as a const it was evaluated once at module load, so it would have frozen the *old* stage value
  forever and silently desynced the reserve segment the moment the setting changed. All 8 call
  sites updated.
- Everything else already derived from `TRAIN_STAGE` (`trainThreshold`, the per-segment UI fill
  math, the reserve segment) so it rescales automatically with no further changes.
- **UI**: a summary chip in the main menu (matching the HERO chip's pattern) showing the current
  value and the resulting `N/2N/3N` tier thresholds, opening a dedicated `screen === "timer"`
  picker. The picker shows each option labeled faster/default/slower, plus a live per-tier
  breakdown of *the player's currently-selected hero's own three abilities* and exactly when each
  becomes castable — translating an abstract "seconds per stage" number into the thing the player
  actually feels.
- **Tutorial forced back to `DEFAULT_TRAIN_STAGE`** regardless of the menu setting, for the same
  reason it forces `heroes[0] = "tempo"`: its script is timed around the default (the
  `tutorialAutoWave` enemy trickle is paced to when Tower Defense comes up, and steps wait on
  specific abilities being ready), so a 5s or 45s train would desync the whole sequence.
- `skillTimer` added to `startGame`'s `useCallback` dependency array — without it the callback
  would capture a stale value and the first match after a change would use the old pacing.
- The AI is affected identically (its `aiTrain` accrues against the same `trainThreshold`/
  `trainMax()`), so changing this stays symmetric rather than becoming a difficulty slider.
- Verified with a Node simulation across all 6 options: thresholds, train max, and segment fill
  percentages all rescale correctly, and the core design invariant holds at every setting —
  casting the Tier-3 ability from a full train always leaves exactly one stage of reserve, so the
  Tier-1 follow-up is always immediately available.
- Verified: full Babel transpile check on the complete script block passed.

### Cooldown now follows SKILL TIMER; new "no heroes" opponent option (this session)
Firas: "The cooldown timer should be the same. Also add an option to play against no hero so no
specials can be used against you."

**1. Per-special cooldown tracks the skill timer**
- `SPECIAL_COOLDOWN = 20` (a const) became `specialCooldown()` (a function returning
  `TRAIN_STAGE`), for the same reason `trainMax()` had to become one — a const would freeze the
  value at module load.
- This mattered more than it looks: with a fixed 20s cooldown, the 5s/10s/15s timer settings were
  largely cosmetic, because the cooldown — not the train — became the real bottleneck. Verified
  by simulation across all 6 options; the three fast settings were all previously cooldown-capped.
- Updated the four stale "its own 20s cooldown" code comments to match.

**2. "No heroes" opponent option**
- New OPPONENTS section in the main menu: **With heroes** (default) vs **No heroes**. The player
  always keeps their own hero and full kit either way — this only restricts the AI.
- With it off, AI players are assigned `null` instead of a hero id, and `aiSpecials` takes an
  early return on a new `g.noAiHeroes` flag. Bailing out at the top (rather than filtering
  per-ability) means no AI ever accrues a cast at all, so no downstream system — cooldown stamps,
  train spend, ready-flash — fires spuriously either. Verified: 0 special evaluations across 100
  ticks with the flag set, 300 without.
- **Standings pills render honestly**: the existing `|| "tempo"` fallback would otherwise have
  invented a hero and displayed three ability bars the AI could never actually cast. Heroless
  opponents now show a dashed "—" placeholder instead of a portrait, a muted "no specials" label
  instead of the ability bars, and the tap-to-inspect popup is disabled entirely (there'd be
  nothing to show).
- **Never applied to the tutorial**, same as SKILL TIMER — its scripted pacing assumes its one AI
  opponent behaves normally.

**Note on a near-miss during implementation**: the menu edit initially consumed the SKILL TIMER
section's wrapper `<div>` and header, orphaning its button with unbalanced divs. Babel still
parsed it fine (JSX-valid, just wrong), so the transpile check alone would NOT have caught it —
it was found by counting `<div>` vs `</div>` inside the menu block (27/27 after the fix). Worth
remembering: for JSX structural edits, a balance check is a useful complement to transpilation.
- Verified: full Babel transpile check on the complete script block passed.

### Skill timer + opponent-heroes moved into a Settings screen (this session)
Firas: "Add timer and no hero option to a settings menu."

- The standalone `screen === "timer"` screen became `screen === "settings"`, retitled and split
  into two labeled sections — **SKILL TIMER** (the 6 stage-length options, per-tier breakdown for
  the player's current hero, tutorial caveat) and **OPPONENTS** (with/without hero rivals) —
  separated by a rule. Both keep their existing explanatory copy.
- The main menu's two inline sections (OPPONENTS block + SKILL TIMER chip) collapse into a single
  **SETTINGS** chip, following the same summary-chip-into-its-own-screen pattern as HERO. The chip
  shows current values inline (`20s · hero rivals`) so checking a setting doesn't require opening
  the screen — the same principle applied earlier to keeping the in-game standings row thin.
- Rationale worth recording: the pre-match menu was growing a new section per option (mode,
  combatants, hero, opponents, skill timer) and would keep growing. Now it holds the three things
  changed most often, and Settings absorbs everything else without the menu getting taller.
- Added a note to the skill-timer copy that each ability's own cooldown matches the setting too
  (true since v0.244, but previously undocumented in-game).
- Verified: div-balance check on both screens (menu 23/23, settings 15/15) — the check added to
  the workflow last session after the near-miss where Babel happily parsed structurally-wrong
  JSX — plus a presence check for all 8 expected settings-screen elements, and a full Babel
  transpile pass. Confirmed no stale `"timer"` screen references remain (including the one in a
  constant's comment).

## v0.246 — Team-wide specials + eliminated players keep casting (this session)

Two related 2v2 changes. Both are strict no-ops in FFA, because `sameTeam()` is never true
across two different players there (FFA `teams` is `[0,1,2]`, one team per player), so every
"team-scoped" set collapses back to exactly the caster themselves.

### 1. Every special is now team-scoped

Nine of the twelve abilities were already team-scoped via the inline
`sameTeam(g, X.owner, owner) || X.owner === owner` idiom. Three were deliberately
caster-only and have now been brought in line:

- **Second Wind** — target set is now the caster's *team's* buildings, not just their own. An
  ally under siege is a valid rescue target, and a caster with no buildings left still has
  somewhere to send the troops. The hostile-tally half of the function is unchanged (it was
  already team-aware about what counts as "incoming").
- **Rally** — the momentum boost now applies to every player on the caster's team, not the
  caster alone. (Note this makes Rally slightly stronger in 2v2 than it was: two players'
  momentum move instead of one.)
- **Instant Upgrade** — eligible buildings are the team's, not just the caster's. The
  `applyMomentumBuild` credit was retargeted from `owner` to `t.owner`: upgrading an ally's
  castle should fire up *that ally's* troops, and an eliminated caster has no meaningful
  momentum of their own left to bank.

All twelve now go through one helper, `alliedTo(g, who, owner)` (`who !== NEUTRAL && (who ===
owner || sameTeam(g, who, owner))`), replacing the repeated inline idiom — a pure equivalence
swap at each of the 16 old sites, done so the team-scoping contract reads uniformly and any
future ability has an obvious thing to call.

### 2. An eliminated player keeps contributing via specials

Previously, losing your last building/unit/queued order added you to `g.eliminated` and that
was the end of your involvement — your train stopped loading and (for AI) `aiSpecials` skipped
you outright. In 2v2 that meant a dead seat for the rest of the match even though your
partner was still fighting.

New helper `stillCasting(g, pid)`: true if you're not eliminated, **or** if any teammate is
still alive. Eliminated-but-team-alive players:

- keep loading their train (`gainTrainTime`'s per-player loop, and the per-tick `aiTrain`
  accrual in the game loop, both now gate on `stillCasting` instead of `!eliminated`);
- keep casting (`aiSpecials` gates on `stillCasting`);
- take **no** `aiAct` turn — they have no buildings or troops to move. The game-loop AI block
  was restructured so the timer/`aiAct` half is inside an `!g.eliminated.has(pid)` check while
  the train tick sits outside it.

The human (player 0) needed no gate changes: `castPlayerSpecial` never checked elimination and
`g.trainProgress` was already ticking unconditionally. What was missing was somewhere for the
casts to *land* — which is exactly what change (1) fixes.

**Sabotage revival:** Sabotage's instant-capture branch can flip a building to an eliminated
caster, which would leave them owning a castle while still flagged dead (skipped by `aiAct`,
shown as dead in the players HUD). `captureBuilding` now clears `g.eliminated.delete(newOwner)`
at the top, so any capture — Sabotage's or a normal combat capture — brings a player back into
normal play. The per-tick elimination sweep re-checks `alive` from scratch and won't re-kill
them while they hold the building.

**Gotcha found and fixed while doing this:** `aiWantsToCast`'s Rally case read
`momentumMult(g, pid) < MOMENTUM_MAX`. An eliminated caster's own momentum is frozen, so once
it sat at the cap Rally would be blocked forever — permanently denying the surviving partner a
boost the caster could still hand them. It now returns true if *any* teammate is below the cap.

Verified with a standalone Node sim (`alliedTo`/`stillCasting` semantics in both modes,
Second Wind's eliminated-caster targeting, team Rally + the new readiness rule, Instant
Upgrade eligibility and momentum credit, train accrual while eliminated vs. fully-dead team,
and the capture-revives-caster path) plus the usual Babel transpile check.

## v0.247 — Default SKILL TIMER is now 15s

`DEFAULT_TRAIN_STAGE` 20 → 15. 15 was already one of `TRAIN_STAGE_OPTIONS`
(`[5, 10, 15, 20, 30, 45]`), so this only moves which option the menu starts on; everything
downstream rescales off `TRAIN_STAGE` as designed:

| | old (20s) | new (15s) |
|---|---|---|
| Tier 1 / 2 / 3 cast threshold (`trainThreshold`) | 20 / 40 / 60s | 15 / 30 / 45s |
| `trainMax()` (3 stages + reserve) | 80s | 60s |
| `specialCooldown()` | 20s | 15s |

Note this also re-paces the **tutorial**, which deliberately forces `DEFAULT_TRAIN_STAGE`
rather than the menu setting (see `startGame`) so its scripted steps aren't desynced by a 5s
or 45s pick. Those steps wait on a specific ability becoming *ready* rather than on wall-clock
timers, so they simply become ready sooner — no step can be skipped or stranded — but the
tutorial does now run noticeably faster.

## v0.248 — Tutorial closing step: "Finish Them Off"

Every earlier tutorial step teaches one mechanic in isolation and then hands the player a
wrap-up telling them they're ready. Added a second-to-last step that makes them actually do
the thing the whole game is about — wipe a rival off the board — so the tutorial ends on a
real win rather than an assertion.

**The step** (`TUTORIAL_STEPS`, index 7 of 9): `waitFor: "finished"`, `settleFor: 2`, hint
"Capture every remaining enemy castle". Its `onEnter` stacks the deck so it can't stall:
every enemy building drops to 3 troops with any in-progress build cancelled, and every one of
the player's castles is topped to `towerMax`. Deliberately 3 rather than 0 — the player should
still see a short real fight at each castle, not free-flip them with one soldier.

**Where the flag is set:** the game loop's per-tick elimination sweep, not `captureBuilding`.
Taking the last enemy *castle* isn't the same as elimination — a soldier still in flight or a
queued order keeps a player alive for a beat afterwards, and the step should only clear once
the rival is genuinely gone. The sweep already computes exactly that (`alive` =
owns-a-building OR has-a-unit OR has-a-live-order), so the flag rides along with
`g.eliminated.add(pid)` for any `pid !== 0` while `g.tutorial`.

**Win check now suppressed in tutorial:** `aliveTeams.size === 1` previously set
`over = true` + the victory screen, which would fire the instant the player finished the rival
and cut the wrap-up step off before it ever rendered. That branch is now gated on
`!g.tutorial`, matching the lose branch's existing gate. The tutorial ends only when the
player taps "Finish Tutorial" (or "Skip tutorial").

Verified with a standalone Node sim covering: step ordering (finish second-to-last, wrap-up
still `final`), the `onEnter` mutation (enemies gutted, builds cancelled, player topped up,
neutrals untouched), the flag NOT firing while an enemy unit is still marching after the last
castle falls, the 2s settle window before auto-advancing, the tutorial not raising a victory
screen, and a real (non-tutorial) match still hitting the win branch. Plus the Babel check.

## v0.249 — No towers on the tutorial map

`generateMap` always seeds at least one neutral watchtower (center, plus sometimes inner-ring
and mid-pair ones). In the tutorial that means the very first board a new player sees contains
buildings that shoot back and never regenerate, mixed in with ones that do neither — a lot to
parse while still learning the drag gesture. `startGame`'s existing `if (tutorial)`
post-processing block now flips every `type: "tower"` building to a castle, so every building
on the tutorial map behaves identically.

**Two fix-ups the flip requires**, both because `generateMap` already finished with these as
towers:

1. **Troops.** A tower spawns at `towerCapacity()` — a full garrison, since it can never
   regenerate. Left alone, a flipped level-3 center tower becomes a 45-troop neutral castle
   parked in the middle of the map. Reset to `START_TROOPS`.
2. **`defs[0]` anchor.** `defenderPoint()` is type-aware (a tower's apex beacon vs. a castle's
   right turret), and `placeDefenders` already ran inside `generateMap`, so the anchor is still
   sitting at the old tower's apex — visually wrong and wrong as an arrow origin the moment
   Tower Defense grants the building firing capability. `placeDefenders(map.towers)` is re-run
   after the flip; it mutates the existing `defs[0]` in place rather than replacing it, so the
   `cd` and any buff flags survive.

**Tutorial text updated to match:**
- The "Castles & Towers" step still teaches both types and the hold-to-convert gesture (which
  is now the only way a tower appears at all), with a clause added noting everything on this
  map is a castle.
- The Tower Defense step no longer says "your towers fire faster" — with no towers, the buff's
  visible effect is entirely the castles-start-shooting half, which it now leads with. Arguably
  a *better* demo than before: the change is dramatic rather than a 25% rate bump.

Not a concern, but worth recording: Barrage is tower-only and would no-op on this map. The
tutorial forces `heroes[0] = "tempo"` (Rally/Speed/Tower Defense) and gives its AI no hero, so
Barrage can never be cast during a tutorial run.

Verified with a standalone Node sim (flip completeness, troop reset, already-castle buildings
and ownership untouched, defender re-anchoring off the apex with `cd` preserved, every building
regenerating afterwards, and Tower Defense's `canFire` check still activating on a castle) plus
the Babel check.

## v0.250 — Eliminated players keep their HUD pill while they can still cast

Follow-on to v0.246. Since a wiped-out 2v2 player keeps loading a train and keeps casting
team-scoped specials, hiding their pill hid live information — you couldn't see what your dead
ally was charging up to help you with, or what a dead enemy was about to drop on you.

**The filter** was `hud.filter(s => !s.dead && s.pid !== 0)`; it's now
`hud.filter(s => s.pid !== 0 && (!s.dead || s.casting))`, where `casting` is a new per-player
HUD stat carrying `stillCasting(g, pid)`. Deliberately applied to allies **and** enemies — the
ally case is what prompted it, but the reasoning (their abilities are still live) is identical
either way, and a one-sided rule would be a weirder thing to explain than a symmetric one. A
player whose whole team is gone still drops off the HUD exactly as before, and FFA is entirely
unchanged since `stillCasting` collapses to `!eliminated` there.

**The pill itself**, when `s.dead`: dimmed to 62% opacity, and the troop count (permanently 0)
swapped for an `OUT` badge so there's no ambiguity about why the number never moves. The
per-tier ability bars stay at **full** brightness — they're the entire reason the pill is still
on screen, so dimming them would defeat the purpose. Momentum % stays live too, since Rally
can still move it.

Slot layout is unaffected: 2v2 has at most 3 other players, which still fits the existing
2-right-pills + 1-left-pill arrangement whether or not any of them are out.

Verified with a standalone Node sim (ally-out stays, enemy-out stays, both drop once their
team is fully gone, my-team-fully-dead case, FFA unchanged, OUT-vs-troop-count labeling, and
the pill slot split staying 2+1) plus the Babel check.

## v0.251 — Difficulty setting (Easy / Regular)

Was on the backlog; now built. New Settings block, sitting **first** on that screen (coarsest,
most consequential choice; skill timer and opponent-heroes are refinements below it).

**One lever, not a bundle.** Easy changes exactly one number: every building on a team hostile
to the player regenerates at `EASY_ENEMY_REGEN_MULT = 0.75`. The AI's decision code
(`aiAct` / `aiSpecials` / `aiWantsToCast`) is byte-identical on both settings. Easy mode is
"the rivals rebuild slower," not "the rivals play worse" — easier to reason about, easier to
tune later, and it doesn't create a second AI behavior surface to keep in sync.

**Scoping**, in the regen loop next to the existing tutorial multiplier:
- Scoped by **team** (`!sameTeam(g, t.owner, 0)`), not by `owner !== 0` the way the tutorial
  line right above it is — otherwise a 2v2 ally would be handicapped alongside the enemies.
- **Neutrals excluded.** They're nobody's economy, and slowing them would also make the map's
  free real estate easier for the *AI* to take.
- **Multiplies with** the tutorial's own 0.5 rather than replacing it, so a tutorial enemy sits
  at `0.5 * 0.75 = 0.375`. The tutorial is always forced to Easy (`g.difficulty = "easy"` when
  `tutorial`), since its pacing shouldn't shift with a menu setting.
- Towers are unaffected in the sense that matters: `towerRegen` already returns 0 for them, and
  no multiplier can revive that.

**What it's worth:** refilling a level-1 castle from empty to its 25 cap goes 25s → 33.3s. Over
a 3-minute match an enemy castle regenerates roughly 45 fewer troops (uncapped figure — the
population budget clamps the real number).

`g.difficulty` is snapshotted at match start rather than read live, so opening Settings
mid-match can't retune a game in progress.

### Pre-existing bug found and fixed while doing this
`startGame` is a `useCallback` with dep array `[selectedHero, skillTimer]`, but it also reads
`opponentHeroes` — which wasn't listed. Changing "With heroes" / "No heroes" and hitting Deploy
*without* also touching the hero picker or skill timer would start the match with the previous
setting, because the memoized closure still held the old value. Deps are now
`[selectedHero, skillTimer, opponentHeroes, difficulty]`.

Verified with a standalone Node sim (ally/neutral/player exclusions in 2v2 and FFA, Regular as
a strict no-op, tutorial stacking to 0.375, towers still at 0, and the refill-time/troops-over-
time figures above) plus the Babel check.

## v0.252 — Rolling Stones capped to the 20 nearest their target

Rolling Stones used to transform **every** allied soldier in flight. With a big push out, that
was 60+ units becoming 4x-strength, tower-immune, +50%-speed boulders at once — enough to
decide a fight on its own. Now capped at `ROLLING_STONE_MAX_UNITS = 20`.

**Which 20:** those closest to their **own destination** — the vanguard about to land. Measured
per-unit against that unit's own `dst` building, not against one shared anchor point, because
a team's marches are routinely aimed at several different targets at once. (Verified: with 15
units inbound to castle A and 15 to castle B, the cast picks the nearest 10 from *each* wave,
not the 20 nearest to whichever castle happens to be closer to the caster.)

This turns the ability from a blanket army buff into a spearhead, and gives it a real timing
skill: cast as the wave arrives, not when you happen to have the train charged.

**Implementation notes:**
- Sorts the whole allied set and slices. Fine here — runs once per cast on at most a few
  hundred units, not per frame.
- A unit whose `dst` doesn't resolve to a building sorts to `Infinity`, so it's never picked
  over a real target no matter where it physically sits.
- **Already-transformed units still occupy slots.** Deliberate: two casts in quick succession
  would otherwise stack into a 40-boulder wave, since the first cast's stones are by definition
  the ones nearest the target. A second cast re-picks the same 20.
- 2v2 unchanged in scope — still `alliedTo`, so an ally's marches are eligible and get their
  own share of the spearhead.
- Fewer than 20 marching: all of them transform, as before.

Ability description in `ABILITY_META` updated to say "your 20 marching troops nearest their
target", so the hero picker and the tap-to-inspect popup both reflect the cap.

Verified with a standalone Node sim (per-unit target measurement across two simultaneous
marches, the exact cut at the 20th-nearest, under-cap case, enemy exclusion even when enemies
are far closer, unresolvable-`dst` handling, and the no-stacking property) plus the Babel check.

## v0.253 — Graphics & UI polish pass (open brief, done solo)

Firas asked for graphics/UI improvements with no further direction ("don't ask, just do").
Ten self-contained changes — **render/UI only, zero gameplay logic touched**, every edit site
tagged `(v0.253 polish)` in the code so any single item can be found and reverted on its own.
Numbered here for easy vetoing ("revert #4"):

1. **Terrain vignette** — soft radial darkening toward the map edges, baked into
   `buildTerrainTexture` (one gradient at build time, zero per-frame cost). The battlefield
   center reads as the lit stage; the map stops ending in a flat crop.
2. **Inked cartographic borders** — every territory border now gets a wider, dark, low-alpha
   under-stroke beneath the existing crisp faction-colored line, the way printed maps do it.
   One extra stroke per cell per frame, ≤12 cells.
3. **Capture burst** — captures previously had no dedicated visual (the flag just changed
   color). `captureBuilding` now pushes two staggered rings in the NEW owner's faction color
   plus a ground puff. Data pushes only; reuses the existing ring/puff renderers. The second
   ring starts with **negative life** as a cheap delay, which required hardening the ring
   renderer: it now skips rings with `life < 0` and clamps `p` to ≤1 — the unclamped math
   would push the alpha hex above `FF` at delays ≥0.25·dur and silently corrupt the
   strokeStyle string (latent trap, now closed; verified in sim).
4. **Animated, target-aware drag arrow** — dashes march toward the pointer
   (`lineDashOffset` off `g.pulse`); a dark under-stroke keeps it legible over bright ground;
   and the whole arrow (plus a slightly larger head) turns **gold the moment the pointer is
   over a releasable region**. Uses `g.hover`, the same field the region fill-highlight
   already keys off, so the two cues can never disagree. Verified region id 0 still locks
   (null-check, not truthiness).
5. **Global button tactility** — one CSS rule pair: every `button` presses down 1px + scales
   0.985 on `:active`, 70ms transition. Global rule rather than per-callsite classes because
   `chip()` is an inline-style helper with dozens of callers. Composes safely with the
   `specialReady`/`specialDenied` keyframes (running animations win, which is correct).
   Plus `chip()` itself gains a faint resting shadow — visible on light screens, effectively
   invisible on dark chrome.
6. **Menu wordmark** — eyebrow line ("REAL-TIME TERRITORY WARFARE"), wider title tracking
   (1→3), a subtle text-shadow, and a short gold gradient rule under the title. No new
   iconography — the existing gold split carries the identity. Also: all three light screens
   (menu / hero picker / settings) get two very faint radial washes (gold upper-left, navy
   lower-right) over the original gradient, applied identically so they read as one place.
7. **Boot screen** — "LOADING DOMINATION…" restyled to gold, letterspaced, with a slow
   breathing pulse so a slow network doesn't look like a hang.
8. **Outcome banner** — wider tracking + a soft same-color glow behind SECTOR SECURED /
   OVERRUN, so the verdict reads as an event over a busy battlefield.
9. **Garrison plates** — owned plates always carry a faint faction tint on the border
   (`col + "55"`), so an ambiguous counter between overlapping castles is attributable at a
   glance. Over-capacity still promotes to full-strength color (the two states stay distinct);
   neutral grey unchanged.
10. **Range rings scan** — the dashed range circles drift slowly (`lineDashOffset`, ~6px/s)
    so armed buildings read as actively scanning. Deliberately slow: ambient life, not an
    alert.

**Motion accessibility:** the boot pulse and button press-down are both disabled under
`prefers-reduced-motion`.

**Perf posture:** nothing per-frame beyond one extra border stroke per cell, two
`lineDashOffset` assignments, and the drag arrow's second stroke (only while dragging). The
vignette is baked. No new allocations in the frame loop.

Verified with a standalone Node sim (delayed-ring lifecycle: first draw at ~0.12s, cull at
0.82s total, 2-char alpha hex throughout; demonstration that the old unclamped math corrupts
at larger delays; puff shape parity; drag-arrow lock condition including region id 0) plus
the Babel check.

## Tuning constants (top of the file, current values)

| Constant | Value | Meaning |
|---|---|---|
| `START_TROOPS` | 10 (was 3) | starting garrison for every castle, player and neutral alike — neutral towers are unaffected, they still start full at `towerCapacity` |
| `BASE_MAX` / `MAX_LEVEL` | 10 / 4 | per-level upgrade-threshold step / upgrade cap (`towerMax` max 50 — see level rebalance below) |
| `CAPACITY_BONUS` | 5 | extra regen headroom above `towerMax` — actual regen ceiling is `towerCapacity(t) = towerMax(t) + CAPACITY_BONUS` (25/35/45/55). Upgrade eligibility/cost still key off `towerMax` alone, unchanged. |
| *(population budget)* | sum of `towerCapacity(t)` across a TEAM's buildings (reduces to per-player in FFA) | no longer a flat per-building constant (`MAX_POPULATION` was removed). Pooled per TEAM, not per player — see the "2v2 population budget pooled per team" session below. The budget total counts garrisoned troops and troops currently marching (`g.units`) for everyone on that team. No per-building cap — reinforcement (including between allies) is fully unbounded; only regen is throttled by this. Second Wind (`castSecondWind`) is a direct `t.troops +=`, entirely outside the regen loop, so it's never throttled by this budget (confirmed intentional). |
| `MAX_CASTLES` | 12 | hard cap, total buildings (castles + towers) per map |
| `REGEN_LEVEL_MULT` / `FIRE_LEVEL_MULT` | [1.5, 2.3, 3.1, 4] both | per-level castle regen speed / tower-fire-rate multipliers — split into two independent tables (used to be one shared `LEVEL_MULT`); both currently hold identical numbers, but either can now be re-tuned without touching the other |
| `REGEN_RATE` / `UNIT_SPEED` / `SPAWN_RATE` | 0.6 / 64.8 / 16 | base regen (castles only, towers=0), soldier speed, deploy rate (raised from 9 this session to shrink the time gap between rows-of-4 releases — see below) |
| `ARROW_RANGE` / `TOWER_RANGE_PER_LEVEL` | 92 / 20 | tower base range (level 1) / px added per level — see `towerRange(t)` |
| `ARROW_FIRE_CD` / `ARROW_SPEED` | 1.3 / 320 | defense fire cooldown (level 1) / arrow flight speed |
| `CONVERT_COST` / `CONVERT_DUR` / `HOLD_MS` | 10 / 5 / 550 | troops spent + build seconds (same shape as `UPGRADE_DUR`, both 5s) + hold duration (ms) to flip castle↔tower, resets to level 1 |
| `MOMENTUM_KILL_STEP` | 0.002 (0.2%) | momentum shift per attacker killed by a tower/castle defense — defender up, attacker down |
| `MOMENTUM_CAPTURE_BONUS` | 0.05 (5%) | momentum gain for the CAPTURER of a building; the loser gets no corresponding penalty |
| `MOMENTUM_BUILD_BONUS` | 0.05 (5%) | momentum gain for completing an upgrade or a castle↔tower conversion |
| `MOMENTUM_REVERT_STEP` / `_INTERVAL` | 0.01 / 5 | passive drift back toward baseline (1.0) from EITHER side — 1% per 5s, applied continuously |
| `MOMENTUM_MIN` / `MOMENTUM_MAX` | 0.75 / 1.5 | clamp bounds (narrowed from an original 0.4/2.5) — keeps `momentumMult` (see `unitArrives`) sane. Affects three things for its owner: attack damage dealt, defense (multiplied together with `levelDefenseMult` below), and march speed (the movement formula) — see the "Momentum reinstated for defense + speed" session below |
| `levelDefenseMult(t)` | `1 + (level-1)*0.05` → 1/1.05/1.1/1.15 for levels 1-4 | a building's DEFENSIVE strength multiplier from its own level alone — static, not a per-player stat. Combines MULTIPLICATIVELY with the defender's own momentum in `unitArrives` (both factor into the defender's side of the damage formula) — level is a small static floor, momentum is the larger dynamic swing on top of it |
| `BOULDER_SPEED` | 200 | Barrage (formerly Tower Defense 2.0) projectile speed |
| `BOULDER_SPLASH_COUNT` / `_RADIUS` | 4 / 42 | Barrage boulder splash kill count / radius |
| `TOWER_DEF_DURATION` / `_RATE_MULT` | 10 / 1.25 | Tower Defense buff duration (was 12s; lowered to match Fortify) / fire-rate multiplier, +25% (was 2x/+100%) — also reused by Barrage's boulder-buff duration |
| `SPEED_BOOST` / `SLOW_DEBUFF` | 1.5 / 0.75 | Speed special (+50%) / Slow Down special (-25%) movement multipliers |
| `TRAIN_STAGE` / `trainMax()` | 15 (default) / 4x stage | seconds per stage / full incl. 1 reserve stage. **`TRAIN_STAGE` is a `let`, player-configurable from the menu's SKILL TIMER option** (`TRAIN_STAGE_OPTIONS = [5, 10, 15, 20, 30, 45]`, default `DEFAULT_TRAIN_STAGE = 15` as of v0.247; tutorial always forces the default). `trainMax()` is a **function**, not a const — as a const it would freeze the stage value at module load |
| `SPECIAL_STAGE` | derived from `ABILITY_META`, 12 entries | load order/cast-cost tier (×20s) for ALL 12 abilities, not just 3 — see the Hero system section |
| `specialCooldown()` | = `TRAIN_STAGE` (20 by default) | per-caster cooldown on each individual special. **Now tracks the SKILL TIMER setting** instead of being a fixed 20 — a function, not a const, for the same reason `trainMax()` is |
| `TRAIN_KILL_GAIN` | 0.1 | seconds of train progress per battlefield death, every player |
| `FORTIFY_MULT` / `_DURATION` | 1.5 / 10 | Warlord's Tier-3 ability — +50% effective defensive troop strength, 10s (equal to `TOWER_DEF_DURATION` on purpose) |
| `SECOND_WIND_AMOUNT` | 15 | Saboteur's Tier-1 ability — flat troops to caster's own most-threatened (or weakest) building |
| `RALLY_MOMENTUM_BOOST` | 0.10 (10%) | Warlord's Tier-1 ability — instant momentum to caster only |
| `RAGE_STRENGTH_MULT` | 1.5 (+50%) | Warlord's Tier-2 ability — building-arrival damage/reinforcement multiplier for Rage-boosted units, same mechanism as `ROLLING_STONE_STRENGTH_MULT` |
| `ROLLING_STONE_STRENGTH_MULT` | 4 | Juggernaut's Tier-2 ability — building-arrival damage/reinforcement multiplier |
| `ROLLING_STONE_SPEED_MULT` | 1.5 (+50%) | movement-speed multiplier written to `u.speedMul` when a unit becomes a Rolling Stone — same value as `SPEED_BOOST`, deliberately reused rather than tuned separately |
| `ROLLING_STONE_R` | 6.5 | world-px radius of the boulder sprite that replaces the soldier sprite for Rolling Stones |
| `FROST_DURATION` | 10 | Siege's Tier-3 ability — seconds a frozen (`u.frozen`) unit stays at 0 speed before auto-thaw |
| `SABOTAGE_TOTAL_DAMAGE` / `_SNEAK_TROOPS` | 30 / 5 | Saboteur's Tier-3 ability — combined troops removed across all enemy buildings / instant-capture threshold (strictly under) |
| `BATTLE_RADIUS` / `_HEAT_MAX` / `_HEAT_DECAY` | 140 / 6 / 1.8 | battle-bed proximity / cap / decay rate |
| `ATTACK_SMOKE_R` | 60 | px — hostile-troop proximity that triggers attack smoke |
| `START_HIGHLIGHT_DURATION` | 5 | seconds the "this is you" ring shows |
| `ROLLING_STONE_MAX_UNITS` | 20 | max soldiers one Rolling Stones cast transforms, picked nearest-to-their-own-destination first (v0.252; was uncapped) |
| `EASY_ENEMY_REGEN_MULT` | 0.75 (-25%) | Easy difficulty — regen multiplier for buildings on a team hostile to the player. Neutrals, the player, and a 2v2 ally are excluded; multiplies with the tutorial's own 0.5 |
| `TOWER_HIT_R` | 20 | arrival radius |

Per-castle helpers: `towerMax(t)`, `towerRegen(t)`, `towerFireCd(t)`, `fortifyMult(g,t)`. Train
helpers: `trainOf(g, owner)`, `trainThreshold(kind)`, `readyFor(g, kind, owner)`,
`cooldownRemaining`. Shared capture path: `captureBuilding(g, t, newOwner)` (used by both
`unitArrives`' combat-capture branch and Sabotage's instant-capture check).

---

## Code map (search terms inside the file)
- `overlayCanvasRef` / `COMMIT_BAR_ZONE_H` — second transparent, pointer-events-none canvas
  painted above the COMMIT % buttons; `draw(g)` redraws any garrison plate that falls in that
  screen zone onto it so the number stays visible without blocking taps on the real buttons.
- `readableAccent(hex, maxLight)` — top-level, HSL-lightness-clamp helper; derives readable
  text/border colors from HEROES[id].color / ABILITY_META[kind].color for the light-themed
  home/hero screens without touching those shared (dark-UI-tuned) color tables.
- `buildTerrainTexture` / `LIGHT_DIR` / `smoothNoise` / `noiseHash` / `projPoint` — cached
  terrain base texture (noise + unified light + AO borders), built once per map/resize.
- `g.puffs` — soft impact dust-puff effects at field clashes and boulder impacts.
- `generateMap` / `computeCells` / `recenterCastles` / `polyCentroid` / `placeDefenders` — map
  gen, Voronoi, single-pass Lloyd relaxation, turret/beacon placement. Neutral tower placement
  (center always, inner ring/mid-pair sometimes) lives inline in `generateMap`.
- `defenderPoint(t)` — type-aware: castle's right turret vs. tower's apex beacon.
- `canConvert(t)` / `startConversion(g,t)` — castle↔tower conversion: pays `CONVERT_COST` (10
  troops) up front and starts a `CONVERT_DUR` (5s) build (`t.upgrading` with `kind: "convert"`);
  the actual flip/level-reset happens in the build-completion loop, same as an upgrade.
  `handleUp`'s long-press branch (see `HOLD_MS`, `drag.t0`) sets the `convertConfirm` React
  state to open a confirm bubble instead of calling `startConversion` directly; the bubble's
  own Confirm button is what actually calls it.
- `towerCapacity(t)` — `towerMax(t) + CAPACITY_BONUS`, the actual regen ceiling. Kept deliberately
  separate from `towerMax`, which still solely governs upgrade eligibility/cost.
- `towerRange(t)` — per-level tower/castle-buff firing range, used both for the actual firing
  loop's search radius and the dashed range-circle rendering.
- `ATTACK_MARGIN` (in `aiAct`) — the AI's attack-sizing rule: require 1.5x whatever's actually
  in a target right now. Used by both the section-2 reinforce-an-ally's-attack block and
  section-3 `evalTarget`. See the "AI attack sizing rewrite" note above before touching this —
  it replaced three iterations of more "accurate" regen/travel/cap-projection math that each
  turned out to have its own bug.
- `expectedLosses(g, src, dst, isTeam)` / `pointToSegmentDist(p, a, b)` — estimates attacker
  losses to any hostile tower whose range the src→dst march route crosses (not just the
  destination). Folded into both `aiAct` attack-sizing paths.
- `SoundEngine` — top-level IIFE before the component; `ensureCtx`, `throttled`, `battleTap` /
  `scheduleBattleTick` for the battle bed.
- `TUTORIAL_STEPS` / `applyTutorialStep` — top-level, before the component.
- `sameTeam(g,a,b)` — routes all friendly/enemy logic.
- `alliedTo(g, who, owner)` — the single team-scoping helper every one of the 12 cast
  functions uses (v0.246). Neutral-safe; in FFA it matches only the caster themselves.
- `stillCasting(g, pid)` — v0.246: not-eliminated OR any teammate alive. Gates train accrual
  (`gainTrainTime`, the game loop's `aiTrain` tick) and `aiSpecials`, so a wiped-out 2v2
  player keeps supporting their partner with specials. Deliberately does NOT gate `aiAct`.
- Game loop: the big `useEffect` with `step(now)` — regen, upgrade builds, order spawning, march,
  collisions (+ `gainTrainTime`, battle heat), arrow/boulder fire + impact, arrivals, AI turns,
  train progress tick, tutorial auto-advance check, eliminations/outcome, `draw`.
- `aiAct` — per-AI decision; `incomingThreat` — used for both AI Tower Defense casting and the
  revenge-cooldown margin.
- `castTowerDefense` / `castSpeed` / `castSlow` / `castSecondWind` / `castRally` /
  `castSabotage` / `castFortify` / `castBarrage` / `castRage` / `castRollingStones` /
  `castFrost` / `castInstantUpgrade` — all 12 abilities, each `(g, owner)`. `CAST_FNS` is the
  single `{ kind: fn }` dispatch map covering all of them; `castPlayerSpecial` (human) and
  `aiSpecials`/`aiWantsToCast` (AI) both go through it instead of a hardcoded chain — see the
  Hero system section above. Also: `setCd` / `cooldownRemaining` / `readyFor` / `syncSpecials`.
- `unitArrives` — capture logic, clears Tower Defense buffs on capture.
- Rendering: `draw`, `drawTowerSprite` (castle, right-turret defense tower with base/2x/boulder
  visual states, shrunk upgrade dust plume), `drawAttackSmoke` (churning grey cloud, shared
  algorithm with upgrade dust), the "this is you" ring block (search `START_HIGHLIGHT_DURATION`).
- React component: `showPlayers`/`menuOpen` (HUD dropdowns), `tutorialStep`/`tutorialStepRef`,
  `soundOn`, `paused`/`pausedRef`, the merged specials segmented-control JSX, the commit-% map
  overlay, the How-to-play modal JSX.

---

## Ideas / backlog (not yet built)
- Human 2-player / online multiplayer — **now in progress**, see the "Online multiplayer" section
  near the top of this doc for the phased plan and current status (Phase 1 done).
- Show enemy/ally upgrade rings so you can spot a rival mid-upgrade (vulnerable).
- A second unit type (fast/weak raider vs. standard soldier).
- Daily seeded challenge map (fix the RNG seed in `generateMap`).
- Possibly hide the commit-% overlay while the pause screen is showing (currently floats on top
  of it — functionally harmless, flagged as a maybe-fix, not done).
- Menu screen still has a bit of room to tighten: the COMBATANTS column reserves a fixed 140px
  height sized for FFA's 3-chip case even in 2v2/Random, where it's mostly empty space. Flagged,
  not done yet.
- Copyright/ownership question came up this session: no code-level protection was added (agreed
  it's not meaningfully enforceable for a client-side single-file app) — if it matters later,
  the practical options discussed were a private/unlisted deploy, auth-gating (would need a real
  backend, e.g. Supabase), or just relying on chat history / commit timestamps as proof of
  authorship.

---

*Note: this game lives as an in-chat artifact; there's no server-side save of match state. "Saving"
here means keeping `index.html` + these notes so a new chat can pick up exactly where we left off.
Deployed copy lives on GitHub Pages if you've pushed it there.*
