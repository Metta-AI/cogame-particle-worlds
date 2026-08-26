# Agent operating guide — cogame-particle-worlds

Orientation for coding agents working in this repo. The game's rules live in
[docs/RULES.md](docs/RULES.md), the wire formats in
[docs/PROTOCOL.md](docs/PROTOCOL.md), and the design note this repo implements
in [docs/plans/2026-08-26-particle-worlds-design.md](docs/plans/2026-08-26-particle-worlds-design.md).
This file covers the things that are easy to get wrong.

## The one rule that matters most

**CI is the harness.** The environment this repo is usually edited from has no
Docker, no Nim and no emsdk, so `.github/workflows/ci.yml` is the only verdict:
the Nim suite in both debug and release, a raw-Docker episode in the production
image, and the static replay bundle opened in a real headless browser. "It
should work" is not evidence; a green run id is.

## Lineage

Forked from [`Metta-AI/coworld-ctf`](https://github.com/Metta-AI/coworld-ctf)
(paintbot). Everything under `src/mpe/` is that repo's engine with the `ctf` →
`mpe` rename sweep applied. **Carry the starter's conventions across; do not
rewrite them.** In particular:

* `client/chrome_common.js` is byte-for-byte the starter's apart from the one
  `window.MPE_WIRE` identifier, and its sha256 is pinned by
  `tests/test_viewer.nim`. `client/broadcast_core.js` is the same deal.
* `client/replay_broadcast.html` is the starter's page **plus one appended game
  block** under the banner
  `particle-worlds additions to the inherited coworld-ctf chrome`. A page
  written from scratch that reuses the starter's ids is a rewrite, not a fork.
* `replay-viewer/{config.nims,mpe_replay.nim,static_replay.js,static_replay_worker.js}`
  come from ONE starter and stay one piece: the emscripten link flags and the JS
  bootstrap are a matched pair, and splicing one shell onto another's flags
  deadlocks the viewer silently, with every file present and every asset 200.

## GameVersion

`GameVersion` is `"1"` and it is renumbered from the starter's history on
purpose — no ctf replay re-simulates here. Bump it, with a headline describing
the RULE that changed, whenever a change makes an existing replay re-simulate
differently: anything in `gameHash`, anything in the integer motion model,
anything in the seeded draw order in `src/mpe/field.nim`. A number is claimed
across branches, so `tools/ci/check_gameversion.sh <base-ref>` fails a PR that
reuses one for a different rule.

## What is HASHED and what is not

`sim_state.gameHash` is the integrity chain the wasm viewer checks every tick.
Everything the viewer re-derives from the recorded actuator masks must be in it;
nothing the viewer cannot re-derive may be.

* **Hashed:** every particle's position, carry, velocity and aim; `bumps`,
  `roundAccum`, `tagCredit`, `nearestMark`, `settledTicks`, `decodedMark`,
  `onPointDone`, `tagContact`; `roundIndex`, the mode, `roleIndex`, `perm`,
  `spawnOffsetBrads`, `goalLandmark`, `keySymbols`, the landmarks, `coverAccum`,
  `tagTicks` and every banked `roundLog` entry.
* **Not hashed:** `commSymbol` / `commPrev` / `commTurn`, the directive, the
  `note` — the starter's rule for anything a commander SAYS — and every
  cosmetic FX family.

Two traps that cost real time here:

1. **Per-round state has to advance INSIDE the step.** `roundIndex` is bumped by
   `resetToLobby`, which `step` reaches from its GameOver branch, so the
   replayed sim re-derives it. A server-loop counter (the starter's
   `gameIndex`) cannot be hashed.
2. **New fields go at the END of `SimServer`.** Replay keyframes are
   flatty-POSITIONAL.

## Integer only

`src/mpe/{field,motion,scoring,beliefs,control}.nim` and the hashed path in
`sim*.nim` are integer-only, and `tests/test_motion.nim` greps for it. Nim's
`int` is 32-bit under `--cpu:wasm32` and the wasm viewer re-derives every tick,
so a compile-time `cos`/`sin` would be evaluated by whichever libm the build
container ships and could differ by an ulp between the amd64 game image and the
emscripten viewer image. Accumulators use `int64` where a 1080-tick sum of
permille could approach the 32-bit range.

## Strings

Every string that reaches the replay is truncated on **rune** boundaries
(`truncateRunes`), never bytes: `note` ≤ 160, `register.policy` ≤ 48,
`fallback.detail` ≤ 200, the whole serialized `directive` record ≤ 900. A
byte-truncated multi-byte character renders fine in a browser and then fails a
strict UTF-8 parser, and `tests/test_directives.nim` pins it with a 4-byte emoji
sitting exactly on the note cap.

## The two name spaces

Agents see anonymous aliases (`RED-alpha` …) and nothing else. Real policy names
appear only in the replay config JSON, `roster[].name`, the DOM scorebug and
`results.names`. `tests/test_identity_privacy.nim` asserts it from both sides
with a sentinel address, so a leak is a substring match rather than a judgement
call.

## Degrade, never hang

The game container does **not** receive `COWORLD_TIMEOUT_SECONDS`; assume
`episodeTimeoutSeconds` = 1200 and settle inside 60 % of it. Every wait is
bounded: `attempt1Ms` 6000 and `retryMs` 3000 (both whole seconds, because
curly hands the deadline to `CURLOPT_TIMEOUT`, whose granularity is whole
seconds), an outer monotonic `turnBudgetMs` of 10 000, `lobbyJoinTimeoutTicks`
on the connect wait, the 690 s engine stop, and a bounded post-artifact
shutdown grace. The budget guard switches the remaining turns to the scripted
layer rather than overrunning.

## Editing the manifest

Do not hand-edit `coworld_manifest_template.json`. `game.docs` and
`game.protocols` ship as inline TEXT, so the manifest carries a copy of
`README.md` and `docs/*.md`; `tools/build_manifest.py` is the single source and
`ci.yml` runs it with `--check`. Run it and commit the result.

`num_agents` must be 4 in **every** variant and in the certification fixture,
and `tools/ci/docker_smoke.sh` cross-checks it against `SMOKE_SEATS`.

## Executable bits

`tools/build_replay_viewer.sh` and `tools/ci/docker_smoke.sh` are committed
mode 100755 and `ci.yml` asserts it before invoking either by path.
`coworld build` hard-requires `os.X_OK` on the replay-viewer hook, so a
mode-0644 hook that slipped past CI would fail at release time instead. Set it
with `git update-index --chmod=+x <path>`.

## Where to look

| Question | File |
| --- | --- |
| what a round rewards | `src/mpe/scoring.nim` |
| what a round draws, and in what order | `src/mpe/field.nim` |
| how a particle moves | `src/mpe/motion.nim` + `applyMomentumAxis` in `sim.nim` |
| what an eavesdropper can infer | `src/mpe/beliefs.nim` |
| what a seat is told | `seatViewJson` in `src/mpe/decide.nim` |
| how one order becomes button masks | `src/mpe/control.nim` |
| what the two baselines do | `src/mpe/baselines.nim` |
| what the spectator frame carries | `buildStateJson` in `src/mpe/broadcast.nim` |
| what the board draws | `addSeatLandmarks` / `addSeatSymbolBubbles` in `src/mpe/global.nim` |
| the replay bytes | `src/mpe/replays.nim`, `tools/replay_summary.py` |
