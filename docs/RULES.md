# particle-worlds — rules

Four particles, four landmarks, four scenarios, one radio that can say nine things.

An episode is **four rounds of 45 seconds** on the same board with the same four seats. What
changes between rounds is what the round rewards and who is told what.

---

## The field

* `1235 x 659` map pixels, **border walls only** — no interior obstacle at all.
* Four **landmarks** ("marks"), 18 px radius, drawn as coloured discs in the palette
  `amber / teal / violet / bone`. That palette is deliberately disjoint from the four particle
  colours, so a spectator never confuses a particle with a mark.
* Marks are **never solid**: a particle glides over one in every mode.
* The layout is **seeded and redrawn every round** by bounded rejection sampling: four marks at
  least 300 px apart (relaxed toward a 120 px floor if the sampler has to work), each on non-wall
  floor, at least 140 px from every edge.
* Mark colours are a seeded permutation of the four palette colours, drawn per round.
* The clock is 24 ticks/second. One round is **1080 ticks = 45 s**; one episode is **4 rounds**.

## The seats

`num_agents` = **4**. One seat drives exactly one particle. No seat drives more than one body and
no body is uncommanded.

| Seat | Colour | Alias (the only name in the game) |
| --- | --- | --- |
| 0 | red | `RED-alpha` |
| 1 | blue | `BLUE-alpha` |
| 2 | green | `GREEN-alpha` |
| 3 | yellow | `YELLOW-alpha` |

The four teams are **colours, not sides**: who is allied with whom is a property of the round.

## Roles rotate

One seeded permutation `perm[0..3]` is drawn per episode. In round `r` (1-based) seat `s` holds
**role index** `(perm[s] + r) mod 4`, so over four rounds each seat holds each role index exactly
once. Nobody is stuck with the cheap seat.

| Role index | `spread` | `deceive` | `crypto` | `tag` |
| --- | --- | --- | --- | --- |
| 0 | cooperator | **adversary** | **speaker** (anchored) | **evader** (fast) |
| 1 | cooperator | good | **listener** | pursuer |
| 2 | cooperator | good | **eavesdropper** | pursuer |
| 3 | cooperator | good | **eavesdropper** | pursuer |

Roles are **public** in every mode. What is secret is the round's goal and its key.

## Physics

MPE integrates `p_vel = p_vel * (1 - damping) + action * accel * dt` and clamps to `max_speed`.
Particle worlds does the same thing in integers, in this order, every tick:

1. **Damp both axes.** `vel = vel * 192 / 256` — 0.75 retention, i.e. MPE's `damping = 0.25`
   exactly — then snap to 0 below 8 motion units.
2. **Impulse.** `vel += input * accel`, clamped per axis to `±maxSpeed`.
3. **Integrate** with the inherited sub-pixel carry accumulator at `motionScale` 256, the
   per-pixel wall test, the wall slide, and particle-on-particle restitution at 40 %.

| | accel | maxSpeed | cruise | px/s |
| --- | --- | --- | --- | --- |
| every particle in `spread`, `deceive`, `crypto`; the **evader** in `tag` | 250 | 1100 | 1000 units | **94** |
| a **pursuer** in `tag` (75 % / 77 %) | 187 | 847 | 748 units | **70** |

The pursuer ratios are MPE `simple_tag`'s own (adversary accel 3.0 vs good 4.0; adversary
max_speed 1.0 vs good 1.3). In `simple_tag` the single good agent is the **faster** one, and this
game follows the source: one fast evader against three slow pursuers is the matchup that has a
chase in it.

Two deliberate deviations from MPE, both stated: the per-axis speed clamp means a diagonal cruise
is √2 faster than an axis-aligned one (identical for every role, so it is a property of the world,
not an advantage); and `crypto`'s speaker is **anchored** — her d-pad bits are ignored, as MPE's
`simple_crypto` speakers are immovable. Her aim still turns, so her sprite reads as looking at
whoever she is talking to.

## The radio — nine values, global, once per turn

The **only** channel from one seat to another. Every 4.5 s (108 ticks) each seat's order carries one
`symbol` out of `{-, A, B, C, D, E, F, G, H}`; `-` is silence. The symbol becomes that particle's
broadcast token for the whole turn and is **audible to every seat regardless of distance** — MPE's
channel is global, there is no earshot.

A symbol means **nothing** by itself. It means what the four of you make it mean, this round.

There is **no free-text channel between seats**. The order's `note` is spectator-only: it reaches
the match feed and the replay and is never shown to another seat.

## Scoring

One helper: `closeness(d) = 1000 - min(1000, d * 1000 / 500)`, so a particle sitting on a mark
scores 1000 and one 500 px away scores 0. Every per-tick term is accumulated as an integer and
divided by the round's tick count at round end. **Every round score is a permille in [0, 1000] and
no term is ever negative.**

### `spread` — cover the marks

```
cover(t)  = ( sum over the 4 marks of closeness(nearest agent's distance) ) / 4
bumps[s] += 1 for each tick s is within 14 px of any other agent
base      = mean over ticks of cover(t)
roundP[s] = max(0, base - min(250, bumps[s] * 1))
```

All four seats share `base`; only the collision debit is personal, and it is floored at 0. Four
particles each parked on a different mark scores about 950; four clumped on one mark about 300.

### `deceive` — hide the goal

One mark is the GOAL. The three good agents are told which; the adversary is not.

```
gc(t) = closeness(nearest good agent's distance to the goal)
vc(t) = closeness(the adversary's distance to the goal)
goodP = clamp(500 + (gc - vc) / 2, 0, 1000)     # the same value for all three
advP  = clamp(500 + (vc - gc) / 2, 0, 1000)
```

`goodP + advP = 1000` on every tick where neither clamps, so the round is zero-sum by
construction. The adversary sees everything and hears every symbol, so walking straight to the goal
tells it where the goal is.

### `crypto` — talk past the eavesdroppers

One mark is the GOAL. A seeded **key** maps each of the four mark colours to one distinct symbol
from `A..H`, redrawn every round.

* **Speaker (Alice)** is told the goal, its colour and the whole key. She cannot move.
* **Listener (Bob)** is told the key, not the goal.
* **Eve-1 and Eve-2** are told neither. They hear every symbol, including each other's.

```
bc(t)     = closeness(Bob's distance to the goal)
ec(t)     = max(closeness(Eve-1), closeness(Eve-2))
pairP     = clamp(500 + (bc - ec) / 2, 0, 1000)     # Alice and Bob both get this
eveP_k    = clamp(500 + (closeness(Eve-k) - bc) / 2, 0, 1000)
```

Alice may use the key honestly, lie, or invent a code with Bob inside the round — the reward does
not care how the colour arrives, only that Bob ends up on the mark and the Eves do not. Since a
symbol has four a-priori-equal meanings, the Eves' only other move is to **tail Bob**, which is why
Bob is paid for the Eves being far. Every seat can see each mobile agent's `nearest_mark` and
`settled_ticks`: public behaviour is the legitimate signal an Eve reads and Bob must confound.

### `tag` — one runner, three hooks

Landmarks are inert decoration. `tagPx` = 20 px is contact.

```
tagTicks += 1 for each tick with at least one contact
credit[p] += 1 for each tick pursuer p is in contact
roundP[pursuer p] = min(1000, credit[p] * 1000 / 120)     # 5 s of contact = full score
roundP[evader]    = (ticks - tagTicks) * 1000 / ticks
```

### The episode

```
scores[s] = ( sum over rounds actually played of roundP[s][r] ) / (1000 * roundsPlayed)
win[s]    = scores[s] >= 0.5
```

**Higher is better, every term is non-negative, and every seat's score lies in [0, 1].** The
league ranks by `results.scores[s]`. A round the wall clock never reached is **excluded from the
mean**, not scored 0 — a truncated episode reports what was actually measured.

## Orders

Every 4.5 s a seat issues one order for itself:

```json
{"note": "hold at teal's south flank until the greens commit",
 "cogs": [{"id": "BLUE-alpha", "intent": "cover", "target": [880, 210],
           "face": [700, 420], "symbol": "F"}]}
```

| Field | Cap / legal values | Repair when violated |
| --- | --- | --- |
| `note` | ≤ 160 runes, **spectator-only** | truncated on a rune boundary; newlines collapse to spaces |
| `cogs` | exactly 1 entry, your own particle | extra entries dropped; empty keeps last turn's order, else `drifter`'s |
| `cogs[].id` | your own alias, matched case-insensitively and suffix-wise | an unmatched entry is assigned by position |
| `cogs[].intent` | `go` `hold` `cover` `shadow` `evade` `orbit` | normalised; still unknown → `go` |
| `cogs[].target` | `[int, int]`, clamped to `[0,1234] x [0,658]` | missing / non-finite → the field centre |
| `cogs[].face` | `[int, int]` or `null` | → `null` (the controller picks the facing) |
| `cogs[].symbol` | exactly one rune from `{-,A..H}` | first rune upper-cased; outside the alphabet → `-` |

A deterministic controller executes the order for the next 4.5 s:

* `go` — drive to `target` and stop there.
* `hold` — brake and stay where you were when the order was installed.
* `cover` — drive onto the mark nearest `target` and sit on it.
* `shadow` — close to 60 px of the particle nearest `target` and hold station there. A `tag`
  pursuer shadows to **contact** instead: its whole job is to be inside 20 px.
* `evade` — of 16 walkable probe points 200 px around you, take the one that maximises the minimum
  distance to any other particle.
* `orbit` — circle `target` at 120 px, counter-clockwise.

`face` only turns your sprite. The controller never sets a weapon button, because there are none:
nothing in particle worlds can be destroyed.

## The published baselines

Both emit the same order object an LLM does, on the same cadence, so the two policy kinds are
strictly comparable. Both are pure functions of the world state plus the seat's own entitlements.

**`drifter`** — the certification player, the per-turn LLM fallback, the driver of a no-show or
disconnected seat, and the default for a seat that sets neither `PLAYER_PROMPT` nor
`PLAYER_SCRIPTED`:

* `spread` — `cover` the mark whose index equals your role index, and say the letter at that index
  (`A`..`D`). Four `drifter` seats therefore cover four distinct marks: the correct cooperative
  solution, and a real bar for a champion to clear.
* `deceive` — good agents: role 1 covers the goal, role 2 covers the mark furthest from it, role 3
  the second furthest; silence. Adversary: `cover` the mark nearest the centroid of the three good
  agents, re-evaluated every turn.
* `crypto` — Alice `hold`s and speaks the key symbol for the goal colour, every turn, without
  variation. Bob decodes any symbol heard this round against the key and `cover`s that colour's
  mark, else holds. Each Eve `shadow`s Bob.
* `tag` — the evader `evade`s. Pursuers `shadow` the evader (to contact).

**`beeline`** — deliberately weaker and different in shape: every seat, every mode, `cover` the
mark nearest to itself and say nothing. It never speaks, never decodes, never flees, and its
pursuers chase nothing. It loses to `drifter` on the mean episode score at the pinned seed.

## End conditions

`results.reason` is a closed enum of three values; `results.endRule` carries the detail of the last
round played and is a closed enum of four.

| `reason` | `endRule` | When |
| --- | --- | --- |
| `complete` | `full_time` | all four rounds ran their 1080 ticks — the normal path. |
| `deadline` | `wall_clock` | the 690 s engine stop fired first. Rounds already banked keep their permille; the round in progress banks from the ticks it ran and **counts**; rounds never started are excluded from the mean. |
| `fault` | `sim_fault` | the sim guard tripped. Scored from the banked rounds, `win` false everywhere, partial replay written. |
| `fault` | `host_error` | an unexpected server-side exception. Same treatment. |

A seat that never connects does **not** end the episode: the lobby budget expires, the no-show is
reported, its particle plays `drifter` for the whole episode, and all four rounds run. A seat that
drops mid-episode keeps playing on `drifter` and revives on reconnect.
