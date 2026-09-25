# cogame-particle-worlds

**Four particles, four landmarks, four scenarios, one radio that can say nine things.**

Four coloured particles glide on a bounded 1235 x 659 field around four coloured landmarks, and
across one episode they play four Multi-Agent Particle Environment scenarios back to back: cover
the landmarks together, hide a goal from an adversary, smuggle a colour past two eavesdroppers, and
run a three-on-one chase. Moving is nearly free — a particle reaches any mark in a few seconds and
the walls only bounce it. **The only thing a seat can say to another seat is one symbol out of nine,
once every 4.5 seconds, broadcast to the whole field.** That asymmetry is the game: cheap physics,
expensive words.

Watch it at **https://softmax.com/particle-worlds**.

A player receives a private turn view and returns one squad directive. The
bundled prompt player is described in [`docs/COMMANDING.md`](docs/COMMANDING.md).

```bash
coworld upload-policy coworld-particle-worlds:latest \
  --name my-particles --run /bin/particle-worlds-player \
  --secret-env PLAYER_PROMPT="Claim the nearest mark on turn 1 and announce it. Never move again."
```

---

## The four rounds

| Round | Mode | MPE ancestor | Roles at 4 seats |
| --- | --- | --- | --- |
| 1 | `spread` | `simple_spread`, N = 4 | four symmetric cooperators, penalised for collisions |
| 2 | `deceive` | `simple_adversary` | 1 adversary + 3 good agents |
| 3 | `crypto` | `simple_crypto` | speaker + listener + **two** eavesdroppers |
| 4 | `tag` | `simple_tag` | 1 fast evader + 3 slow pursuers |

Roles rotate on a seeded permutation, so over four rounds every seat holds every role index exactly
once and nobody is stuck with the cheap seat. Full rules, formulas and end conditions:
[`docs/RULES.md`](docs/RULES.md). Wire formats, the per-seat entitlement matrix and the replay
layout: [`docs/PROTOCOL.md`](docs/PROTOCOL.md). The design note this repo implements:
[`docs/plans/2026-08-26-particle-worlds-design.md`](docs/plans/2026-08-26-particle-worlds-design.md).

## Where things are

| Path | What it is |
| --- | --- |
| `src/particle_worlds.nim` | the game entrypoint, built to `/bin/particle-worlds` |
| `src/particle_worlds_player.nim` | the seat registrar, built to `/bin/particle-worlds-player`; **every** policy runs this one binary and is switched by env |
| `src/mpe/field.nim` | the seeded round setup: mark layout, colour permutation, mode/role schedule, crypto key, spawn ring |
| `src/mpe/motion.nim` | damp-both-axes-then-drive, the bump counter and the tag contact counter |
| `src/mpe/scoring.nim` | `closeness`, the four per-tick terms, the round bank and the episode mean |
| `src/mpe/beliefs.nim` | `nearestMark` / `settledTicks` and the `onpoint` / `decode` detectors |
| `src/mpe/{decide,directives,baselines,llm,control}.nim` | the per-turn decision layer: one parallel batch, two bounded deadlines, tolerant parsing, rune caps, the two published baselines, and the deterministic controller that compiles one order into per-tick actuator masks |
| `src/mpe/{sim,sim_types,sim_config,sim_state}.nim` | the sim, its config surface, `gameHash` and the sim guard |
| `src/mpe/{server,replays,replay_runtime,broadcast,global,roster,events}.nim` | the mummy server, the `COWLDMPE` replay codec, the spectator frame and the sprite protocol |
| `client/` | the broadcast chrome: the starter's page plus one appended `mpe-` game block |
| `replay-viewer/` | the emscripten wasm entry, its link flags and the static shell |
| `tools/build_replay_viewer.sh` | the `coworld build` hook that produces the static replay bundle |
| `tools/replay_summary.py` | Python 3 stdlib only: `.replay` → one strict-UTF-8 JSON summary |
| `tools/ci/` | the CI harness: the raw-docker episode smoke, the browser viewer smoke, the policy set |
| `tests/` | the Nim suite `ci.yml` runs in both debug and release |

## Build and run

The sandbox this repo is developed from has no Docker, no Nim and no emsdk: **`.github/workflows/ci.yml`
is the harness.** Locally, with Nim 2.2.4 and the `nimby.lock` package tree:

```bash
nim c -d:release --out:particle-worlds src/particle_worlds.nim
nim c -d:release --out:particle-worlds-player src/particle_worlds_player.nim
nim r --path:src tests/test_scoring.nim
```

In Docker — one image, two entrypoints:

```bash
docker build --platform=linux/amd64 -t coworld-particle-worlds:ci .
./tools/ci/docker_smoke.sh coworld-particle-worlds:ci   # one full episode, four seats
./tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
node tools/ci/viewer_smoke.mjs --bundle dist/static-replay-viewer \
  --replay dist/smoke/replay.json --timeout 90 --soak --strict-text-bounds
```

## Replays

Replays are a **static file plus a browser wasm viewer** — never a pod. The manifest declares
`"replay_viewer": {"bundle": "static-replay-viewer"}`; `tools/build_replay_viewer.sh` compiles the
*same* sim module to WebAssembly (`replay-viewer/mpe_replay.nim`) and bundles it with the chrome and
the art. In the browser the module re-steps the sim from the recorded actuator masks and checks its
own `gameHash` against the recorded one **every tick**, so a single divergent bit is caught at the
tick it happens.

The viewer shows the symbol bubbles, a landmark coverage heatmap baked into the board, the crypto
decode panel (what each eavesdropper has settled on, and whether it is right), the four-seat
scorebug, and the commander lines — which is where a spectator actually sees the LLM playing.

## Policies

Both champions are LLM prompt policies and both fillers are scripted baselines, all four in the
**same image**, switched by env (`tools/ci/policies.json`):

| name | env | role |
| --- | --- | --- |
| `particle-worlds-swarm` | `PLAYER_PROMPT` | champion #1 — take the position first, talk second |
| `particle-worlds-cipher` | `PLAYER_PROMPT` | champion #2 — win the information game, positions follow |
| `particle-worlds-drifter` | `PLAYER_SCRIPTED=drifter` | filler — the published mode-aware baseline |
| `particle-worlds-beeline` | `PLAYER_SCRIPTED=beeline` | filler — nearest mark, always, silent |

Both baselines are documented in [`docs/RULES.md`](docs/RULES.md), so "playing beside a partner you
did not write" here means "a partner whose published rules you know".

## Lineage

Forked from [`Metta-AI/coworld-ctf`](https://github.com/Metta-AI/coworld-ctf) (paintbot). The 24 Hz
tick loop, the Sprite v1 button-mask input, the fixed-point integer motion model, the per-pixel wall
mask, the `COWLD*` replay codec with its per-tick hash chain, the seat/cog split and its two
name spaces, the whole server-side decision layer, the mummy server and its `COGAME_*` contract, the
broadcast chrome and the emscripten static replay bundle are all inherited. What is new is the
landmark rules, the nine-value radio, the four scenario scoring terms and the belief state.

MIT licensed. This is an **adaptation** of MPE, not a bit-exact port: MPE is float64 world units
with per-step vector actions and a soft boundary penalty, and particle worlds is integer fixed point
on a wall-bounded pixel field with a 4.5 s directive cadence. What is carried over is MPE's shape —
particles, landmarks, a discrete comm channel and the four scenario motives — not its numerics.
