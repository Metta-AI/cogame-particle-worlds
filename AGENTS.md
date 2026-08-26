# Agent operating guide — coworld-particle-worlds

Orientation for coding agents (Claude Code, Codex, etc.) working in this
repo. Gameplay rules live in [docs/RULES.md](docs/RULES.md); this file
covers the workflows that are easy to get wrong.

[docs/ENV_VARIATION.md](docs/ENV_VARIATION.md) is the catalog of every knob
that varies a level (all `GameConfig` fields + `MapGenOverrides` + the
envelope consts, each cited to `file:line`) — the reference for generating
new levels/curricula. **Keep it current:** whenever you add, remove, rename,
or re-bound a `GameConfig` field, a `mapGen` override, or a gameplay const
(motion/combat/vision/scoring/item), update the matching row in that file in
the same change.

## Before you start — pull the branch

**Always update the branch against `origin/main` before touching code.** This
repo moves fast and keeps many worktrees around, so a branch (or a worktree's
checkout) is easily tens of commits behind `main`. Building on a stale base
silently wastes the work: a `GameVersion` bump becomes a *regression*, fixtures
regenerate against old rules, and the diff reverts everything merged in the
meantime.

At the start of every task, and again before you commit:

```bash
git fetch origin
git rev-parse --abbrev-ref HEAD                 # confirm you're on the branch you think
git rev-list --left-right --count HEAD...origin/main   # "<ahead> <behind>"; behind must be 0 before you build
git merge origin/main    # or: git rebase origin/main — bring the branch current, resolve conflicts
```

If `behind` is non-zero, merge/rebase `origin/main` **first**, then start.
Re-derive version-sensitive work (the `GameVersion` const, replay fixtures)
against the *updated* code, never the base you happened to check out. When
working in a worktree, also confirm you're editing files under that worktree's
path — not a sibling checkout on an unrelated branch.

### A GameVersion number is claimed across BRANCHES, not just against main

Being current with `main` is **not** enough to make a version bump safe. Two
long-lived branches can each be perfectly up to date and still pick the *same*
next number, because neither can see the other's choice — nothing in the build
enforces uniqueness, so the collision lands silently and only shows up as
replays whose recorded version no longer identifies the rules that produced
them.

It has happened. An (abandoned, never-merged) mapgen branch authored a bump as
"GV38", found main had independently spent 38-41, and renumbered to GV42;
separately the heart-grab hotfix (#264) later took GV42 on main for an unrelated
rule (grab radius). Nothing broke, because only one of the two ever landed — but
neither branch could see the other's claim, and both were current with `main` at
the time. That is the trap: being up to date is not what protects you.

So **before you claim a version, scan the open PRs, not just `main`**:

```bash
git fetch origin
MAIN=$(git show origin/main:src/mpe/sim_types.nim |
  grep -m1 'GameVersion\* =' | grep -o '"[0-9]*"' | tr -d '"')
echo "main has spent: GV$MAIN"
# Every branch CLAIMING >= what main spent — the part `main` cannot tell you.
# Filtered to >= MAIN because ~150 stale branches sit on old versions and are
# just noise; a claim BELOW main's is somebody else's problem, not a collision.
git for-each-ref --format='%(refname:short) %(symref)' refs/remotes/origin |
while read b sym; do
  [ -n "$sym" ] && continue    # skip origin/HEAD, which is a symref not a branch
  v=$(git show "$b:src/mpe/sim_types.nim" 2>/dev/null |
    grep -m1 'GameVersion\* =' | grep -o '"[0-9]*"' | tr -d '"')
  [ -n "$v" ] && [ "$v" -ge "$MAIN" ] && echo "  GV$v  $b"
done | sort -u
```

Take the next number above **every** claim you find, and say in the PR body
which number you took and what you saw claimed, so a reviewer can spot a race
that opened after you looked. If you are the SECOND to merge, renumbering is
yours to do: bump to the next free number and re-record fixtures against
merged `main` — fixtures cut against your old number fail the version gate the
moment the other change lands.

**Check it with one command**, locally or in CI:

```bash
tools/ci/check_gameversion.sh origin/main          # checks your working HEAD
tools/ci/check_gameversion.sh origin/main <branch> # checks another branch
```

It exits non-zero when your version reuses the base's number **for a different
rule**, and stays quiet when `GameVersion` is untouched (every PR that does not
change the gameplay rules). Note what it compares: **the number alone cannot
detect the collision**, because the colliding branch and the base BOTH read
"42". What distinguishes them is the RULE the number is attached to, so the
script diffs the headline on the changelog comment, not the digits.

It is **not yet wired into CI** — that needs a human, because cubi tokens lack
GitHub's `workflows` permission and a bot cannot modify `.github/workflows/`.
To wire it up, add this to the `build` job in
`.github/workflows/build.yml` (details:
https://github.com/Metta-AI/coworld-particle-worlds/issues/268 — cite full URLs here, not a
bare `#N`: softmax runs both GitHub and Forgejo with independently numbered
issues, so a bare number resolves against whichever host the reader is on):

```yaml
      - name: GameVersion is not a number the base already spent
        if: github.event_name == 'pull_request'
        run: |
          git fetch --no-tags --depth=1 origin '${{ github.base_ref }}'
          tools/ci/check_gameversion.sh FETCH_HEAD
```

Until that lands, run the script by hand before you claim a version.

The changelog comment on `GameVersion` is the other half of this: it is a
prepend-only history, so **say what the number means and what it obsoletes**.
Keep the `GVnn (short rule name): HEADLINE` shape — that first line is what
makes two claims on one number distinguishable at a glance, and it is what the
pending guard diffs. That comment is what let the near-miss above be spotted at
all: the branch's own note recorded its earlier renumber ("authored as GV38 …
renumbered at the T0 merge"), which is how the second claim on 42 became visible
instead of blending in.

## Layout

- `src/particle_worlds.nim` — server entrypoint (seed randomization happens HERE,
  before `config.update`, so seed-derived draws — including the terrain
  pick — follow the final seed).
- `src/mpe/` sim modules (split per `docs/plans/2026-08-01-sim-split.md`;
  `sim.nim` imports and RE-EXPORTS all of them, so `import mpe/sim` still
  sees everything): `sim_types.nim` — consts (incl. `GameVersion`, which
  gates replay compatibility), types (flatty wire format — field order is
  sacred), map globals; `rig_art.nim` — broadcast-only art;
  `arena.nim` — map geometry, the terrain generator/validators, mapSpec,
  the process-global map install, pixel queries; `map_art.nim` — the map
  bake; `sim_config.nim` — GameConfig lifecycle; `sim_state.nim` — logging,
  gameHash, events, spawn placement; `roster.nim` — join/auth/rewards;
  `sim.nim` — the gameplay core and step loop.
- `src/mpe/map_pool.nim` — GENERATED curated terrain-pool seeds; rewrite it
  only via `tools/gen_map_pool.nim`, never by hand.
- Paintball King of the Hill — a config-gated squad mode merged back from
  Metta-AI/cogame-paintball (docs/paintball/: RULES, PROTOCOL, COMMANDING,
  the design note). Every gate defaults OFF and a gate-off config plays the
  classic rules byte-identically; the `paintball` manifest variant turns it
  on. Mode modules in `src/mpe/`: `paint.nim` (paint grid + hill),
  `control.nim` (directive -> actuator masks), `directives.nim` (the reply
  schema), `baselines.nim` (holdline/sprayer), `llm.nim` (Bedrock/Anthropic
  transport), `decide.nim` (the per-turn batch); `src/particle_worlds_player.nim`
  is the thin seat registrar (`/bin/particle-worlds-player`). Its tests are
  `tests/test_pb_*.nim` (+ `pb_helpers.nim`), sharded like everything else.
- `tools/map_render.nim` — the shared map rasterizer behind both
  `render_map_pool.nim` and the map editor. It is a PURE function of a
  `MpeMap`: it must never install a map or read the process-global arena
  (`MapWidth`, `ArenaObstacles`, `obstacleWallAtF`, …), because the editor
  service renders arbitrary specs from multiple threads.
- `tests/` — run `nim c -r tests/tests.nim` from the repo ROOT (assets
  resolve via `data/`). Use `-d:release` for anything heavy; debug builds
  are 10-50x slower through the per-pixel map code.
- Dependencies come from nimby (`nimby --global sync nimby.lock`; the
  Dockerfile is the canonical build recipe).

## Interaction radii must be derived from the art (learned 3x on the heart)

An interactable's SIM radius and its DRAWN size are two numbers in two
modules (`sim_types.nim` vs `global.nim`), and nothing structurally ties
them. When they disagree the game lies to the player: the art says "you are
on it", the sim says "you are not", and there is no feedback distinguishing
"not close enough" from "this does not work".

The planted heart took THREE fixes to get right, and the first two were
render-only because the sim side was never questioned:

1. #259 — the object's center sat 28px off the grab point. Unpickable at any
   precision. Fixed by sinking the gem into the pedestal.
2. #261 — restored the erect stance by padding the canvas, keeping #259's
   center contract.
3. #264 (GV42) — the radius itself was still 12px against a 60px-wide gem on
   a 96px disc: a FIFTH of the art. Players stood plainly on the heart and
   got nothing. This was present the whole time and survived both fixes.

So: **when you touch an interactable's art or its radius, check the other
one, and assert the relationship in a test** rather than leaving it as prose
in a doc comment. GV42 exports `PlantedFlagW` from `global.nim` purely so
`test_mpe_game.nim` can assert `FlagPickupRange >= PlantedFlagW div 2` —
shrinking the art now fails a test instead of silently restoring the bug.
Note `sim_types.nim` cannot import `global.nim` (the dependency runs one
way), so the derivation lives as prose on the constant and the *assertion*
lives in the test — that test is the enforcement, so do not delete it.

Also, radius is keyed to the gem's WIDTH, not its height: since #261 the gem
stands erect ABOVE the grab point, so the art is not vertically symmetric
about it. What a player's feet are on is the 96px pedestal disc.

The other five pickups (grenade, med kit, shield, spray can, barrier) still
use 12px against 18-26px sprites — a milder version of the same mismatch (at
worst ~2x, vs the heart's 5x), deliberately left alone by GV42's scope. Filed
as https://github.com/Metta-AI/coworld-particle-worlds/issues/266 with the measurements.

## Terrain

- The **default league map is the hand-tuned arena** (`config.json`
  `mapPath: "arena"`). Do not flip it without an explicit ask.
- **Procedural terrain is config-gated**: `mapPath: "pool"` draws from the
  curated pool (`mapPoolIndex` pins an entry; otherwise the pick derives
  from the randomized game seed), `mapPath: "gen"` + `mapSeed` generates
  directly. Individual draws lock via `mapSize`, `mapSymmetry`
  (`mirror`/`rot180`), `mapColumns`, `mapWindows`, `mapCenterFeature`,
  `mapEndzone` (+ `mapEndzoneRadius` / `mapBaseDepth`).
  Tools accept `gen:<seed>` / `pool:<idx>` map paths.
- **Endzone archetypes** are drawn per seed from a SEPARATE RNG stream
  (`seed xor const`) so the main draw order never shifts: a seed that lands
  on the classic `column` generates byte-for-byte the map it always did,
  and only `disc` / `square` seeds are new terrain. Keep that property when
  adding draws — it is what makes an archetype addition reviewable.
- Replays pin the resolved geometry as `mapSpec` in their config JSON —
  playback never re-runs the generator, so generator changes cannot break
  existing replays.
- Generator design intent lives in the VALIDATORS: sightlines, corridor
  connectivity, cover budget. Change behavior there, not by hand-tuning
  draws. The measurements live in `mapDiagnostics`;
  `validateGeneratedMap` is a thin consumer that reports the first failure,
  and `mapValidationReason` turns a completed diagnostic pass into the same
  string. Diagnostics are collected in STAGES: the validator asks for
  first-failure mode so a rejected attempt never pays for the distance
  transform and flood fill, and full-board masks are opt-in
  (`MapDiagnosticArtifact`) because retaining them costs ~88 MB on a
  colossal board. Preserve both properties — `generateMpeMap` runs the
  validator up to 100 times per map.

## Pool review page

[docs/pool-review.html](docs/pool-review.html) is a self-contained,
zoomable review page showing every curated pool map (open it locally or
from any static host; images are inlined). **Regenerate it whenever
`map_pool.nim` or the generator changes**:

```bash
nim c -r tools/gen_map_pool.nim              # only when re-curating seeds
nim c -r tools/render_map_pool.nim pool-preview
python3 tools/build_pool_review.py pool-preview
```

Commit the refreshed `docs/pool-review.html` together with the pool/
generator change — a stale page misrepresents what the pool serves.

## Map editor

A local service + browser UI for inspecting and authoring map geometry against
the REAL validators — the interactive counterpart to the static pool-review
page. Every validator failure is locatable on the board, which makes it the
fastest way to answer "why was this seed rejected".
Design: [docs/designs/map-editor.md](docs/designs/map-editor.md).

```bash
nim c --threads:on --mm:orc -r tools/map_editor.nim 8099   # then open localhost:8099
```

It needs `--threads:on --mm:orc` because it serves over mummy; the request
handlers are deliberately split from the mummy adapter (which is behind
`when isMainModule`) so `tests/test_map_editor.nim` can exercise the API
without a socket or a threaded test build.

Loads any pool entry, `gen` seed + overrides, or pasted `mapSpec`, and
returns a Nim-rendered board plus live validation, and edits it: obstacles,
trenches, med kits, and the tier-1 map parameters, with undo/redo.

Authoring places a seed item ONCE; `POST /api/symmetry` returns its full
deduplicated orbit and the editor writes that into the spec. Trench authoring is
refused on rot90 maps because `finalizeTrenches` never places them there.

Two invariants to keep if you touch it:

- **The browser never owns geometry.** It renders what the service sends and
  draws markers on top; it must not compute walls, symmetry images, or
  capture zones. The map code's fairness invariants (doubled rot90
  coordinates, `int64` in the diagonal test for wasm, integer-offset diamond
  sampling) fail silently as team unfairness when reimplemented.
- **No map installation on the request path.** See `tools/map_render.nim`
  above.

## Map generation (mapkit)

`tools/mapkit.nim` generates and hand-edits maps in the native `mapSpec`
format from the command line — the batch/LLM counterpart to the map editor.
Terrain styles (`bsp`, `caves`, `maze`, `scatter`) live in
`src/mpe/mapgen_styles.nim` as pure `(rng, region, params) -> seq[ArenaShape]`
generators that emit only MPE shapes into the seed half; the sim mirrors,
carves, and validates. No sim change, no replay risk. Playbook + the
generate → render → validate → edit loop: [docs/MAPKIT.md](docs/MAPKIT.md).

```bash
nim c -d:release -o:/tmp/mapkit tools/mapkit.nim
```

Generators must stay pure and fairness-agnostic: they never reason about
symmetry, protected floor, or endzones — those live in `arena.nim`. Raw
generation passes the validator ~55–65% of the time by design; the workflow is
generate-many-then-curate/edit, not one-shot.

Obstacles and trenches are `ArenaShape`s in five kinds: `rect`/`disc`/`diamond`/
`diagonal` and (GV37) `polygon` — a closed ring of INTEGER vertices for curved
terrain. Curves are flattened to polygons in the authoring tools; the sim only
ever runs integer even-odd `pointInPolygon` (see the STRICT-STRADDLE convention
that keeps mirror/rot180 masks bit-exact — fairness rests on it, so do not swap
in a boundary convention without re-checking the parity test). Runtime is
unaffected: LoS/nav read the baked `wallMask` bitmap, shapes only stamp it at
load. Design: [docs/plans/2026-08-04-vector-obstacles-design.md](docs/plans/2026-08-04-vector-obstacles-design.md).

## Replay fixtures

`tests/fixtures/*.bitreplay` + `tests/replays/mpe.bitreplay` are recorded
against the CURRENT rules and must be re-recorded on every GameVersion
bump (`tools/record_fixture.sh`; exact recipes in
`tests/test_broadcast_state.nim`).

**ALL SIX, every time — the shards only read four.** `gen-small-pits` and
`gen-colossal-4team` are read by NO native test; only the CI
`wasm-replay-viewer` smoke job loads them, so a re-record pass that works
from the test files alone misses them and CI fails on a job that looks
unrelated (GV44 shipped exactly this way). The full set and its recipes:

| fixture | recipe |
|---|---|
| `tests/fixtures/capture-seed1` | `record_fixture.sh <out> 1` |
| `tests/fixtures/wipe-lives1` | `record_fixture.sh <out> 3 10000 '{"lives":1,"hitPoints":1,"carrierSpeedPct":1}'` |
| `tests/fixtures/draw-nokill` | `record_fixture.sh <out> 7 1500 '{"hitPoints":1000,"carrierSpeedPct":1,"barrageMaxPerSec":0}'` |
| `tests/replays/mpe` | `record_fixture.sh <out> 907 10000 '{"lives":9}'` |
| `tests/fixtures/gen-small-pits` | `record_fixture.sh <out> 4242 1500 '{"mapPath":"gen","mapSeed":4242,"mapSize":"small"}'` |
| `tests/fixtures/gen-colossal-4team` | `record_colossal_demo.sh <out> 4242 1500 16` |

`test_replay`'s "EVERY committed .bitreplay carries the current
GameVersion" sweeps `tests/` and fails on any straggler, so a miss now
shows up in the native shards rather than three jobs later. A fixture's
own recipe is also recoverable from its header — the replay embeds the
full config JSON it was recorded with. Gotchas:

- Record on an **idle machine** — a CPU-starved speed-16 server drops its
  bots and produces degenerate endings (e.g. no capture).
- The script prefixes `$PWD`: pass **repo-relative** output paths.
- After re-recording, re-pin the capture fixture's asserted winner/ending
  and verify the required beats (capture/steal/gameover) actually occur —
  scan a few seeds if needed.
- **A RECIPE CAN GO STALE WITHOUT ANY RULE CHANGE**, because it inherits
  `config.json`. A recipe only overrides the fields it names, so a later
  edit to the repo config silently changes what the recording *is*. GV42
  hit this: the barrage params landed in `config.json` after the GV41
  fixtures were cut, and a barrage game has NO draw ceiling — so
  `draw-nokill`, recorded to its documented recipe, ran 109530 ticks
  against a 1500-tick limit and ended with a WINNER. Two draw-verdict
  tests were asserting against a fixture that could not contain a draw.
  If a fixture's re-recording comes out wildly larger/longer than the
  version it replaces, suspect an inherited config field before you
  suspect your own change; a fixture must pin every field its ending
  depends on (`draw-nokill` now pins `barrageMaxPerSec: 0`).
- **A SEED DOES NOT PIN THE OUTCOME.** The bots are separate processes, so
  two recordings of one seed differ. Rare events (a grenade kill: ~5 of
  ~105 kills) are present in one take and absent in the next — the first
  GV42 take of seed 907 lost its grenade kill, and the second had it. On a
  miss, RE-RECORD the same seed (`tools/scan_event_seeds.sh <seed>` reports
  the mix and leaves its recording in `.scan/`) instead of moving the seed;
  the comment history in `test_extract_events.nim` shows the seed walking
  902 → 905 → 908 → 907, and some of that walking was probably this
  nondeterminism, not the rule changes it was blamed on.

## Debugging prod league replays (don't drive the Observatory UI)

To investigate a prod replay issue, download the replay bytes directly —
never try to navigate softmax.com/observatory in a browser (sign-in wall,
and the UI adds nothing). The Observatory URL carries everything needed:
`?tab=coworlds&logscope=league:league_<uuid>&detail=league:league_<uuid>` —
the `detail` param is the league being viewed (strip the `league_` prefix
for SQL; `leagues.id` is the bare uuid).

1. Query the prod DB via the read-only `/sql` endpoint (token from
   `~/.softmax/credentials.yaml`, key `https://softmax.com/api`; add headers
   `Authorization: Bearer $TOKEN` and `X-Use-Elevated-Privileges: true`,
   POST to `https://softmax.com/api/observatory/sql/query`):

   ```sql
   -- league -> divisions -> rounds -> episode requests -> job ids
   SELECT era.job_request_id, er.created_at,
          er.game_config->>'teams' AS teams
   FROM episode_requests er
   JOIN episode_request_attempts era ON era.episode_request_id = er.id
   JOIN rounds r ON r.id = er.round_id
   JOIN divisions d ON d.id = r.division_id
   WHERE d.league_id = '<league uuid without prefix>'
   ORDER BY er.created_at DESC;
   ```

2. Every job's replay is public:
   `https://softmax-public.s3.amazonaws.com/replays/<job_request_id>.replay`
   (equivalently `episodes.replay_url`, joined via `episode_jobs`).

3. The file is `COWLDMPE` deterministic format: a JSON config (brace-match
   from the first `{`; includes `mapSpec` dims/layout, teams, player names)
   plus recorded inputs — `parseReplayBytes` + `initReplayRuntime` replays
   it locally, exactly like the wasm viewer.

4. To reproduce the hosted viewer itself:
   `POST https://softmax.com/api/observatory/v2/coworlds/replays/session`
   with `{"coworld_id": "<episode_requests.coworld_id>", "replay_uri": "<s3 url>"}`
   returns the exact static-bundle `viewer_url` prod serves (its
   `broadcast_core.js` / wasm files are directly downloadable, and the
   wasm bundle runs headless under Node — see `tools/wasm_replay_smoke.cjs`).
