# particle-worlds — wire protocol

Two audiences, two frames. A **seat** gets the player websocket and a Sprite v1 binary frame per
tick; a **spectator** gets the global websocket and one JSON state object per presentation frame.
Both are produced by the same server from the same sim, so live and replay are identical.

---

## Routes

| Route | Purpose |
| --- | --- |
| `GET /healthz` | liveness. Answers for a bounded ~20 s grace after the artifacts are written. |
| `GET /player?slot=N&token=T` | the seat websocket. A bad slot or token is **403**. |
| `GET /global` | the spectator websocket. Answers a WebSocket Ping with a Pong. |
| `GET /client/global` | a real spectator page. Registered before any catch-all asset route, and it never opens the player socket. |
| `GET /client/player` | a real seat page. Same two rules. |
| `GET /client/replay` | the replay page. |
| `GET /replay-data` | the replay bytes of the episode in progress. |
| `GET /reward` | the live per-seat reward stream. |

## Runtime contract

`COGAME_CONFIG_URI`, `COGAME_RESULTS_URI`, `COGAME_SAVE_REPLAY_URI`,
`COGAME_PLAYER_FAILURE_URI`, `COGAME_LOAD_REPLAY_URI`, `COGAME_EVENTS_URI`,
`COGAME_METRICS_URI`, `COGAME_HOST`, `COGAME_PORT`. The game container also reads
`ANTHROPIC_API_KEY_URI` (`secret://coworld/particle-worlds/anthropic_api_key`) — the decision
layer runs **in the game server**, so that is the only container that needs a key.

---

## The seat side

### Registration

A seat sends **one Sprite v1 chat message** (`0x81`) carrying its registration, and re-sends it ten
times about a second apart over the first ~10 s of frames. Joins are slot-sequential, so a seat
whose slot is not the next open one is not admitted until the lower slots have joined; the server
holds an unappliable registration and re-reads it when the slot lands.

```json
{"type":"register","prompt":"<strategy text or empty>",
 "scripted":"drifter"|"beeline"|null,"policy":"<free label>"}
```

The prompt is a **secret**: it is consumed as registration, never applied as a bubble and never
written to the replay. What the replay gets is a redacted `register` record — the policy label and
kind only. Any other chat text from a seat is dropped: particles emit symbols, seats do not chat.

A seat that never registers, or registers with neither field, is `scripted: "drifter"`.

### What a seat sends and receives

A seat **sends no inputs at all** — every actuator mask is computed by the server's control layer.
It sends the Sprite v1 Ready packet (`0x85`) after each received frame, which is legitimate
precisely because it never dead-reckons an input of its own, and it lets a `fastMode` server
advance as soon as every seat has acknowledged the frame.

The frame a seat receives is the inherited Sprite v1 stream: the static board, the walkability
sprite, all four particles, all four marks, and the four symbol bubbles. With
`fullyObservable: true` the per-seat visibility mask is **all-visible**: MPE is a fully observable
environment, so hiding positions would add a search puzzle the game never asks for and subtract the
one it does — inference from behaviour and from symbols.

### The per-seat view the decision layer builds

Numbers are map pixels, rounded to integers. This is a `crypto` round as Bob:

```json
{"round": 3, "of": 4, "mode": "crypto",
 "turn": 5, "turns": 10, "clock": {"played_s": 22, "left_s": 23},
 "field": {"w": 1235, "h": 659, "centre": [617, 329]},
 "you": {"id": "BLUE-alpha", "role": "listener", "anchored": false,
         "pos": [640, 300], "vel": [-40, 210], "speed_px_s": 51,
         "accel_px_s2": 229, "max_px_s": 103},
 "marks": [{"i": 0, "pos": [300, 180], "colour": "amber", "r": 18}, "… 4 …"],
 "agents": [{"id": "RED-alpha", "role": "speaker", "anchored": true,
             "pos": [617, 79], "vel": [0, 0], "colour": "red"}, "… 4 …"],
 "radio": [{"id": "RED-alpha", "now": "F", "last": "F"}, "… 4 …"],
 "secret": {"goal": null, "goal_colour": null,
            "key": [["D", "amber"], ["F", "teal"], ["B", "violet"], ["G", "bone"]]},
 "beliefs": [{"id": "BLUE-alpha", "nearest_mark": 1, "settled_ticks": 12}, "…"],
 "score": {"this_round_so_far": 0.58, "rounds_banked": [0.83, 0.44],
           "episode_so_far": 0.62},
 "your_last_directive": "wait for F, then break for teal from the far side"}
```

`secret` is the **only** mode-conditional block, and a seat that is not entitled sees `null` in it —
never an absent key, so a model never has to distinguish "hidden" from "malformed".

| mode | who sees `goal` | who sees `key` | extra |
| --- | --- | --- | --- |
| `spread` | nobody | nobody | `cover_pct`, your own `bumps` |
| `deceive` | the three good agents | nobody | the adversary also gets `goal_is_one_of: [0,1,2,3]` |
| `crypto` | the speaker only | the speaker and the listener | — |
| `tag` | nobody | nobody | `contact` flags, `tag_ticks` |

**Hidden from every seat, always:** the other seats' orders for the turn being decided (all four
decide simultaneously — which is exactly why the radio matters); every seat's `note`, ever; every
seat's `PLAYER_PROMPT`; the identity of any policy; the episode seed; the RNG state, and therefore
the next round's mode, mark layout, colour permutation, goal and key.

### Reply

See `docs/RULES.md` §Orders for the schema and the per-field caps. Parsing is tolerant: markdown
fences are stripped, the outermost balanced `{…}` is taken if the model prefixed prose, `cogs` is
accepted as an id-keyed object, numeric strings are accepted for coordinates, and the intent is
normalised. Only when no object with at least one usable entry can be recovered do the single retry
and then the scripted fallback fire.

Every recorded string is truncated on **rune** (Unicode codepoint) boundaries, never bytes:
`note` ≤ 160 runes, `register.policy` ≤ 48, `fallback.detail` ≤ 200, the whole serialized
`directive` record ≤ 900, and `register.prompt` ≤ 4000 at the transport (truncated, never
rejected, and never written to the replay or the results).

---

## The spectator side

### The state JSON

One object per presentation frame, and the **only** thing the renderer reads. The inherited keys are
unchanged: `t` (tick), `mt`, `ph`, `lob`, `pl`, `sp`, `mx`, `st`, `lp`, `sk`, `ff`, `en`,
`mm` (hash-mismatch tick), `bs` (board scale), `pov`, `teams`, `roster` (per particle: `s`, `team`,
`name` — the **real** policy name, spectator side — `pol`, `col`, `alias`, `seat`), `events`,
`directives`, `lead` (sent once), and the static minimap silhouette. Particle worlds adds:

```json
{"round": 3, "rounds": 4, "mode": "crypto", "turnTicks": 108, "turn": 5, "turns": 10,
 "marks": [{"i":0,"x":300,"y":180,"c":"amber","near":142,"close":716,"goal":false}, "… 4 …"],
 "comm": [{"seat":0,"sym":"F","since":432}, "… 4, seat order …"],
 "cover": 0,
 "crypto": {"goal": 1, "colour": "teal",
            "key": [["D","amber"],["F","teal"],["B","violet"],["G","bone"]],
            "beliefs": [{"seat":1,"mark":1,"settled":12,"right":true}, "…"]},
 "tag": {"contact": [false,false,false,false], "ticks": 0},
 "roundScores": [[912,688,402],[907,301,771],[884,702,771],[869,694,108]],
 "livePermille": [612, 388, 500, 500],
 "episodePermille": [641, 598, 487, 410],
 "bumps": [14, 9, 22, 6],
 "roles": ["eavesdropper","listener","speaker","eavesdropper"]}
```

`crypto` is present only in a `crypto` round, `tag` only in a `tag` round, `cover` only in
`spread`; `marks`, `comm`, `roundScores`, `roles`, `livePermille`, `episodePermille` and `bumps`
are on every frame. The `crypto` block is the **spectator's** view — the key and the goal are
revealed to the audience, which is why it is in the frame and in no seat's observation.

### Derived broadcast events

`stepEvents` derives these from state deltas during playback, so they cost no replay bytes and are
identical live and in replay:

`phase`; `roundstart` `{round, rounds, mode, roles}`; `word` `{by, alias, symbol, turn}`;
`firstword` (the first non-silent symbol of a round); `bump` `{a, b}` (throttled one per pair per
12 ticks); `cover` `{pct}` (`spread` only, on crossing a 10 % band); `onpoint`
`{who, mark, markColour}`; `decode` `{who, mark, markColour, right, settled}`;
`tag` `{by, seconds, tick}` (a contact after ≥ 12 quiet ticks, throttled to one beat per 48 ticks);
`roundover` `{round, mode, permille[4]}`.

**Scrubber beats** — the only kinds the appended chrome block emits, and the only kinds it ships CSS
for: `roundstart`, `firstword`, `onpoint`, `tag`, `roundover`. Bounded by construction:
4 + ≤ 4 + ≤ 8 + ≤ 22 + 4.

### Tier-2 analysis stream

`COGAME_EVENTS_URI` gets JSON lines. Particle worlds emits `phase`, `directive`, `symbol`, `bump`,
`tag`, `onpoint`, `decode` and `roundover`, plus the mandatory trailing summary row
(`type`, `ticks`, `events`, `gameVersion`).

---

## The replay

A binary `COWLDMPE` file, self-sufficient: everything the viewer needs is in the bytes and no
server is contacted except S3 for the file.

| Content | Carries |
| --- | --- |
| header | magic `COWLDMPE`, format version, game name `particle-worlds`, game version |
| config JSON | `seed`, `num_agents`, `mapSpec` (the full resolved field geometry), `maxTicks`, `maxGames`, `rounds`, `turnTicks`, every physics/scoring constant, `players[].name` (real names), `slots[]`, `tokens[]`, `fastMode`, `fullyObservable` |
| joins | per seat: `name` (real policy name), `slot`, `token` |
| inputs | per particle (0..3), on change: the `uint8` actuator mask — the action log |
| chats | `roundcard` / `register` / `directive` / `fallback` / `budget_guard` / `result` records |
| hashes | one `gameHash` per tick — the integrity chain the viewer checks |

### Chat records

| `k` | Fields |
| --- | --- |
| `register` | `seat`, `alias`, `colour`, `policy` (≤ 48 runes), `kind` (`llm`\|`scripted`), `baseline` |
| `roundcard` | `round`, `mode`, `roles` (4 role names, seat order), `goal`, `goal_colour`, `key` (4 `[symbol, colour]` pairs, `null` outside `crypto`), `marks` (4 `[x, y, colour]`) |
| `directive` | `round`, `mode`, `turn`, `seat`, `alias`, `role`, `source` (`llm`\|`scripted`\|`fallback`), `latency_ms`, `note`, `cogs`:[{`id`, `intent`, `target`, `face`, `symbol`}] |
| `fallback` | `round`, `turn`, `seat`, `attempt` (1\|2), `cause`, `detail` (≤ 200 runes) |
| `budget_guard` | `turn`, `remaining_s` |
| `result` | the full results document, written once at episode end — this is what makes the bytes self-sufficient |

Chat records are re-applied at playback into **non-hashed** sim fields only: they drive the
broadcast feed, the radio strip and `tools/replay_summary.py`, and can never affect the simulation.

The mark layout, the colour permutation, the mode/role schedule, the goal and the key are all
**re-derived** from the seeded RNG rather than being load-bearing records (the `roundcard` record is
a convenience, and the viewer cross-checks it against its own re-derivation). That is why the file
stays around 300 KB and why a hash mismatch is a real integrity signal rather than a rendering nit.

### Determinism

The server writes one `gameHash` per tick. In the browser the wasm bundle re-steps the **same**
sim module from the recorded masks and compares its own `gameHash()` against the recorded one every
tick, so a single divergent bit is caught at the tick it happens and surfaced as `mismatchTick` in
`#mmwarn`.

`gameHash` carries, appended after the inherited mixes so their ordering stays stable: per particle
`(x, y, carryX, carryY, velX, velY, aimBrads, bumps, roundAccum, tagCredit, nearestMark,
settledTicks, decodedMark, onPointDone, tagContact)`; `roundIndex`, `modeCode`, `roleIndex[0..3]`,
`perm[0..3]`, `spawnOffsetBrads`, `goalLandmark`, `keySymbols[0..3]`,
`landmarks[i].(x, y, colourCode)`, `coverAccum`, `tagTicks`, and every banked `roundLog` entry.
`commSymbol` / `commTurn`, the directive and the `note` are **excluded** — the starter's rule for
anything a commander says.

All new sim arithmetic is integer only. Nim's `int` is 32-bit under `--cpu:wasm32` and the wasm
build re-derives every tick, so accumulators use `int64` intermediates where a 1080-tick sum of
permille could approach the 32-bit range.

## Results

Written to `COGAME_RESULTS_URI`, and equal to the manifest's `results_schema` key for key — that
schema is `additionalProperties: false`. Exactly 22 keys; see the manifest and
`src/mpe/roster.nim`'s `particleResultsJson`. The ten seat-indexed arrays have exactly
`num_agents` = 4 entries; the six round-indexed arrays carry one entry per round played (1..4).
