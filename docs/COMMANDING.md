# Writing a particle-worlds prompt

A policy here is a **prompt**. You do not write code, you do not train anything, and you do not
control motors: you write the paragraph that a Claude model reads once every 4.5 seconds, alongside
a JSON report of the board, before it issues one order for one particle.

```bash
coworld upload-policy coworld-particle-worlds:latest \
  --name my-particles --run /bin/particle-worlds-player \
  --secret-env PLAYER_PROMPT="<your strategy>"
```

That is the whole interface. `PLAYER_PROMPT` makes the seat an LLM seat; `PLAYER_SCRIPTED=drifter`
or `beeline` makes it one of the two published baselines instead.

---

## What the model already knows

You do not have to teach it the rules. The system prompt already states the field size, the cruise
speed, the four-round structure, the 4.5 s cadence, the whole nine-value radio, every mode's
scoring rule, the six intents and the exact reply schema. Repeating any of that wastes the tokens
you could spend on judgement.

Your prompt arrives under a heading that says to weight it heavily but never above the rules. It is
**never** written to the replay or the results — only the resulting order is.

## What is actually hard

Moving is nearly free. A particle reaches any mark in a few seconds and the walls only bounce it.
**Information is the whole game**, and there are exactly three levers:

1. **Which mark you sit on.** Every mode pays for closeness, so a particle in transit is a particle
   not scoring. The default answer in almost every round is `cover` something.
2. **What you say.** One symbol out of nine, once per turn, heard by everyone. A symbol has no
   meaning until the four of you give it one, and whoever proposes a convention on turn 1 usually
   gets it adopted — including by the seat it hurts.
3. **What your movement says.** Every seat sees every position, and `beliefs` publishes each mobile
   agent's nearest mark and how long it has sat there. You cannot move secretly. You can only move
   in a way that means something other than what you intend.

## Mode by mode

**`spread`** is a claiming problem, not a driving problem. Four particles on four different marks
scores about 0.95; four on one mark about 0.30. Nobody is told which mark is whose, so the
cheapest solution is a naming scheme announced on turn 1 — and then **not changing your mind**. Two
particles trading marks all round covers two and leaks two. The bump penalty is small (1 permille a
tick, capped at 250) but it is pure loss, so keep 40 px of clearance.

**`deceive`** is where the public radio bites. You are told the goal, the adversary is not, and it
can hear everything you say and see everything you do. Walking straight there tells it where there
is. The good agents' score pays for the adversary being **far** as much as for you being on the
goal, so two of you are worth more as bait than as company. As the adversary: the goal is the mark
somebody quietly stopped on. Three agents pretending are three agents in motion.

**`crypto`** is the round the site did not have. The key is redrawn every round, so a symbol tells
an eavesdropper nothing — but the listener's *movement* tells it everything. The speaker cannot
move at all; her only decision is what to say and how often. The listener's problem is not decoding,
it is **arriving without being followed**: it is paid for the Eves being far, so a straight run from
turn 1 is usually worth less than two turns of misdirection. As an eavesdropper you have no key and
should not pretend to: you are paid for being on the goal, not for being right about the cipher.

**`tag`** is the only round where speed decides anything. The evader is genuinely faster (94 px/s
against 70) and a lone pursuer on its tail will never close. The tag lands on an **interception** —
somebody standing where the evader is going — or in a corner. Three particles all `shadow`ing the
same tail is three particles losing.

## Prompt craft that measures

* **Say what to do on turn 1.** The first order sets the round; a prompt that only describes
  principles gets a first turn of drifting.
* **Give tie-breaks by colour, not by "whoever is closest".** All four seats are reading their own
  prompt at the same instant; a rule that needs agreement needs an ordering both sides can compute
  alone. `RED, BLUE, GREEN, YELLOW` is one both sides have.
* **Name the symbol convention explicitly.** "Use symbols to coordinate" produces noise. "E = I am
  holding still, F = I am committing, G = I am faking, H = ignore me" produces a protocol.
* **Decide when to be silent.** Silence renders as an em dash in the replay, so a spectator can see
  that saying nothing was a choice. Sometimes it is the strongest one.
* **Do not ask for information you already have.** `beliefs`, `radio`, `marks` and `agents` are all
  in the report every turn; a prompt that tells the model to "watch the listener" is telling it to
  read a field it is already given.
* **Budget your own words.** The reply is capped at 900 runes of serialized record and the note at
  160; a model spending its output on prose spends it on nothing a seat can act on.

## The two shipped champions

Both are `PLAYER_PROMPT` policies in the same image, and both are published in full in
`tools/ci/policies.json`.

* **`particle-worlds-swarm`** takes the position first and talks second: claim, announce, and never
  change marks. Its whole thesis is that a particle sitting on a mark scores and a particle in
  transit does not.
* **`particle-worlds-cipher`** wins the information game and lets the positions follow. It treats
  the radio as a protocol it is negotiating in public and assumes every other particle is reading
  it — including the trick of having *everybody* claim to be faking.

They disagree about which lever matters, which is the point: read both, then write the one that
beats them.

## Debugging your policy

* The replay's match feed shows your `note` verbatim, once per turn. That is the fastest read on
  whether the model understood the round.
* `results.llmTurns` and `results.fallbackTurns` are per seat. A high fallback count means your
  replies are not parsing — check that the reply begins with `{` and carries exactly one `cogs`
  entry.
* `tools/replay_summary.py <file>.replay` prints one strict-UTF-8 JSON object with every directive,
  every symbol and the results, with no Nim and no Docker needed.
* The engine settles at 690 s and a budget guard switches the remaining turns to the scripted layer
  rather than overrunning, so a slow model costs you turns, not the episode.
