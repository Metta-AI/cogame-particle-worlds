## Claude-backed particle command. A policy is just a prompt: the game server
## composes the seat's view plus that seat's PLAYER_PROMPT and asks Claude what
## its particle does for the next 4.5 seconds.
##
## Ported from `cogame-bullwhip/src/bullwhip/llm.nim`, behaviour for
## behaviour — the credential ladder, the Bedrock model rotation, the
## fence-tolerant JSON extraction and the rune-boundary truncation are all
## that file's, because they are all scar tissue from real hosted failures.
##
## Particle worlds is a SIMULTANEOUS-decision game, so ALL FOUR seats' calls go
## out as ONE parallel batch per turn (`curly.makeRequests`). Seats are never
## queried sequentially: that is what keeps 40 turns inside the wall-clock
## budget.
##
## Credentials, in order of preference:
##   COWORLD_LLM_ENDPOINT (hosted), or local Bedrock bearer token
##   ANTHROPIC_API_KEY
##   ANTHROPIC_API_KEY_URI
## With none of them the client disables itself and every turn falls back to
## the scripted layer INSTANTLY, with no network wait — which is what lets
## offline certification finish in seconds.

import
  std/[json, os, strutils, unicode],
  bitworld/runtime,
  curly,
  sim_types, directives, prompts

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  LlmTransport* = enum
    ltNone, ltSidecar, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl*: Curly
    transport*: LlmTransport
    apiKey: string
    sidecarEndpoint: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model*: string
    maxOutputTokens*: int
    disabled*: bool
    throttled*: bool
      ## The provider answered 429 and there is no other candidate model to
      ## rotate to. Set per turn, cleared by the turn loop: retrying inside
      ## the same turn cannot succeed, so the seat fails fast to the scripted
      ## fallback instead of spending the turn budget on a call that will be
      ## refused again (the paintbot round-2 scar, inherited).

  LlmError* = object of ValueError

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "particle-worlds llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order; BEDROCK_MODEL pins
  ## one. There is exactly ONE candidate — haiku — because every sonnet
  ## inference profile times out on every sidecar call.
  ##
  ## `us.anthropic.claude-sonnet-4-6` was never a candidate (cogame-raid round
  ## 2, 2026-08-23) and `us.anthropic.claude-sonnet-4-5-20250929-v1:0` is not
  ## one either: it was the ladder fallback for paintbot 0.1.2 and the hosted round-2 game log recorded 133 calls to it, every single one returning
  ## "Timeout was reached" and none returning text. One haiku throttle then
  ## cascaded into a whole episode of scripted fallbacks — the retry is what
  ## burned the turn, not the throttle. With no second candidate a throttle
  ## fails fast (see LlmClient.throttled) and the seat plays the scripted
  ## fallback for that turn only.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @["us.anthropic.claude-haiku-4-5-20251001-v1:0"]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "particle-worlds llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: (if config.model.len > 0: config.model
            else: "claude-haiku-4-5-20251001"),
    maxOutputTokens: max(1, config.maxOutputTokens)
  )
  let sidecarEndpoint = getEnv("COWORLD_LLM_ENDPOINT").strip()
  if sidecarEndpoint.len > 0:
    result.transport = ltSidecar
    result.sidecarEndpoint = sidecarEndpoint.strip(chars = {'/'}, leading = false)
    result.model = getEnv("COWORLD_LLM_MODEL", "anthropic/claude-haiku-4.5")
    result.curl = newCurly()
    return
  let
    bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
    bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "particle-worlds llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel]
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "particle-worlds llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    ## The exact phrase phase 60 greps the GAME log for, alongside "falling
    ## back" below: "LLM provider is unavailable".
    echo "particle-worlds llm: no credentials — the LLM provider is unavailable; ",
      "every turn is falling back to the scripted layer"

proc requestFor*(
  client: LlmClient, system, user: string, slot: int
): tuple[url: string, headers: HttpHeaders, body: string] =
  ## One Messages-API request, shaped for whichever transport is live.
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  if client.transport == ltSidecar and slot >= 0:
    headers["X-Coworld-Player-Slot"] = $slot
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  elif client.transport == ltSidecar:
    body["model"] = %client.model
    headers["anthropic-version"] = AnthropicVersion
    result.url = client.sidecarEndpoint & "/v1/messages"
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf*(
  client: LlmClient, response: Response, error, url: string
): string =
  ## The text of one batched reply, or an LlmError describing why there is
  ## none. Auth failure disables the client for the rest of the episode;
  ## model-access denial and throttling rotate the Bedrock model for the next
  ## batch instead.
  if error.len > 0:
    raise newException(LlmError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    ## RUNE-safe: this text becomes `fallback.detail` in the replay, and a
    ## provider body is arbitrary bytes. A byte slice can cut a codepoint in
    ## half, and truncateRunes downstream only SHORTENS — it cannot repair a
    ## broken one.
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(LlmError, "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(
      LlmError, "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if not client.tryNextBedrockModel("throttled"):
      ## Nothing left to rotate to: a second call this turn would be refused
      ## the same way, so the turn loop must not spend its retry on it.
      client.throttled = true
    raise newException(LlmError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(LlmError, "anthropic error " & $response.code & ": " &
      response.body.truncateRunes(MaxFallbackDetailRunes))
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(LlmError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(LlmError, "reply cut off at max_tokens before any " &
      "JSON: " & result.truncateRunes(160).replace("\n", " "))

const CanonicalIntroduction = "You are ONE particle on a flat field 1235 by 659 pixels, with four coloured\nmarks on it (amber, teal, violet, bone). Four particles play: RED, BLUE, GREEN\nand YELLOW. "

const Rules = """You accelerate; you do not teleport. You cruise at about 94 pixels
per second and it takes you about a second to turn a drift around. The walls
bounce you. Bumping another particle bounces you both.
An episode is FOUR ROUNDS of 45 seconds. Every 4.5 seconds you issue ONE order
for yourself. A deterministic controller executes it for the next 4.5 seconds:
it steers you where you asked, turns you to face what you asked, and never
touches a weapon, because there are none. You never control motors directly.
THE ONLY THING YOU CAN SAY TO ANOTHER PARTICLE IS ONE SYMBOL, chosen from
A B C D E F G H, or "-" for silence. Everyone on the field hears every symbol
instantly, whatever the distance. A symbol means NOTHING by itself: it means
what the four of you make it mean, this round. Your "note" is for the audience
watching the replay; no other particle ever sees it.
THIS ROUND IS NAMED IN THE REPORT BELOW, AND SO IS YOUR ROLE.
SPREAD: all four of you are on the same side. Score = how well the four marks
are covered, averaged over every tick, minus a small penalty for every tick you
spend touching another particle. Four particles on four different marks is a
perfect score; four particles on one mark is a bad one. Nobody is told which
mark is whose - work it out, with symbols if it helps.
DECEIVE: one mark is the GOAL. Three of you are told which; the ADVERSARY is
not. The three score for being ON the goal AND for the adversary being FAR from
it; the adversary scores for being ON it. The scores add to 1.000 every tick.
The adversary can see everything you do and hear every symbol you send, so
walking straight to the goal tells it where the goal is. Bait it.
CRYPTO: one mark is the GOAL. The SPEAKER is told which, and cannot move at
all. The LISTENER can move and shares a secret KEY with the speaker: a private
table of which symbol means which colour. Two EAVESDROPPERS can move, hear
every symbol, and have no key. Speaker and listener score for the listener
being ON the goal AND both eavesdroppers being FAR from it; each eavesdropper
scores for being on the goal itself. The key is redrawn every round, so a
symbol tells an eavesdropper nothing - but WATCHING THE LISTENER MOVE tells it
everything. The listener's problem is arriving without being followed.
TAG: one EVADER, three PURSUERS. The evader is faster (94 px/s against 70) and
scores for every tick no pursuer is within 20 pixels of it. Each pursuer scores
for the ticks it is itself within 20 pixels, and needs 5 seconds of contact for
a full score. The marks are decoration in this round; the walls are not.
"""

const ScoreRules = """Scoring detail: closeness decreases linearly from full credit at a mark to zero
at 500 pixels away. SPREAD uses the nearest particle to each mark, averages
coverage over marks and ticks, then subtracts your own contact penalty, capped
at 0.25; your round score cannot be negative. DECEIVE compares the closest good
agent to the adversary: each good agent gets 0.5 plus half their closeness
advantage; the adversary gets the complementary score. CRYPTO compares the
listener to the closest eavesdropper for the pair's score, and each eavesdropper
to the listener for its own score, using the same 0.5 plus half-advantage rule.
These proximity rewards are averaged over ticks, not just measured at the end.
The final score is the mean of rounds actually played, in [0,1].
"""

const ReplyRules = """Reply with a single JSON object and NOTHING else. Your reply MUST begin with '{'.
Schema:
{"note":"<=160 chars, audience only","cogs":[{"id":"<your own id>",
  "intent":"go|hold|cover|shadow|evade|orbit",
  "target":[x,y],
  "face":[x,y] or null,
  "symbol":"-" or one of A B C D E F G H}]}
Intents: go = drive to `target` and stop there; hold = brake and stay where you
are; cover = drive onto the mark nearest `target` and sit on it; shadow = close
to 60 pixels of the particle nearest `target` and stay there, EXCEPT as a TAG
pursuer, where it closes on the evader to contact range (10 pixels) whatever
`target` says; evade = drive away from the nearest particle, staying inside the
walls; orbit = circle `target` at 120 pixels. `face` only turns your sprite. `symbol` is BROADCAST.
"""

proc systemPrompt*(selection: PromptSelection): string =
  if selection.selectedVariant == pvCanonical:
    return CanonicalIntroduction & Rules & ScoreRules & ReplyRules
  let field = "Control one particle among RED, BLUE, GREEN and YELLOW on a 1235 by 659 pixel field. " &
    "The four marks are amber, teal, violet and bone. Motion accelerates rather than teleporting; " &
    "cruising speed is about 94 pixels/second, and reversing a drift takes about a second. " &
    "Walls bounce particles, and particle collisions bounce both participants."
  let timing = "An episode contains four 45-second rounds. Every 4.5 seconds, submit one order " &
    "for yourself. A deterministic controller handles movement and facing until your next order. " &
    "There are no weapons and you never command motors directly. The report identifies the current round and your role."
  let radio = "Your only communication to other particles is one broadcast symbol: A through H, " &
    "or '-' for silence. All particles hear it instantly regardless of distance. Symbols have no " &
    "inherent meaning; their meaning is established within the round. Your note is audience-only " &
    "and never visible to another particle."
  let spread = "SPREAD: All four particles cooperate. Score averages landmark coverage over every " &
    "tick, with a small penalty for each tick touching another particle. Occupying four distinct " &
    "marks gives perfect coverage; crowding one mark does not. No particle is assigned a mark, " &
    "so coordinate assignments, using symbols if helpful."
  let deceive = "DECEIVE: Three good agents know the goal mark; the adversary does not. The good " &
    "side earns for occupying the goal and keeping the adversary far away. The adversary earns " &
    "for occupying the goal, and the two sides' scores sum to 1.000 each tick. It sees movement " &
    "and hears every symbol: heading directly to the goal reveals it, while movement can also bait it elsewhere."
  let crypto = "CRYPTO: The immobile speaker knows the goal. The mobile listener shares the speaker's " &
    "private symbol-to-colour key. Two mobile eavesdroppers hear all symbols but lack the key. " &
    "Speaker and listener earn for the listener reaching the goal while both eavesdroppers stay far " &
    "away; each eavesdropper earns for reaching the goal itself. The key changes each round, " &
    "so symbol meanings are secret, but following the listener can expose the destination."
  let tag = "TAG: One evader moves at 94 pixels/second; three pursuers move at 70. The evader " &
    "earns each tick with no pursuer within 20 pixels. Each pursuer earns for its own ticks " &
    "within 20 pixels, reaching full score after five seconds of contact. Marks do not matter " &
    "in this round, but walls still constrain movement."
  let briefing = case selection.selectedVariant
    of pvPlain: field & "\n\n" & timing & "\n\n" & radio & "\n\n" & spread & "\n\n" & deceive & "\n\n" & crypto & "\n\n" & tag
    of pvNumbered: """1. Setting: command one of four particles, RED, BLUE, GREEN, and YELLOW.
The field measures 1235 by 659 pixels and contains amber, teal, violet, and bone marks.
Acceleration produces roughly 94 px/s cruising motion; allow about a second to reverse drift.
Walls rebound you, and collisions rebound both particles.
2. Orders: four rounds last 45 seconds apiece. Once every 4.5 seconds, choose your own order; a
deterministic controller moves and faces you for that interval. There are no weapons or direct
motor commands. Read the report for the current scenario and your role.
3. Radio: send a single A–H symbol, or '-' to remain silent. It reaches everyone immediately at
any distance. Players establish meanings anew during the round; symbols have no built-in
meaning. Notes go only to spectators.
4. SPREAD: cooperate to cover four distinct marks, rather than cluster on one. Coverage is
averaged each tick, less a small personal penalty for touching another particle. Marks have no
assigned owners, so arrange assignments with symbols if useful.
5. DECEIVE: three teammates learn the goal mark; the adversary does not. The teammates benefit
from reaching it while the adversary stays away; the adversary benefits from reaching it
instead. Opposing scores total 1.000 per tick. It observes every movement and broadcast, so a
direct approach reveals the goal; bait it elsewhere.
6. CRYPTO: the speaker knows the goal but is anchored. The moving listener shares the speaker's
private symbol-to-colour key. Two moving eavesdroppers receive broadcasts without that key. The
pair wants the listener on the goal and both spies far away; each spy wants the goal for itself.
Keys change each round, but visible listener movement can disclose the destination, so avoid
being followed.
7. TAG: the single evader cruises at 94 px/s, versus 70 for three pursuers. The evader earns
each tick outside every pursuer's 20-pixel reach. A pursuer earns its own contact ticks within
20 pixels, reaching full credit at five seconds. Marks are irrelevant; walls still matter."""
    of pvQuestions: """Where am I? You are one member of a four-particle field, 1235 by 659
pixels across. RED, BLUE, GREEN, and YELLOW are the particles; amber, teal, violet, and bone
label the marks. You accelerate to about 94 pixels per second rather than teleport, and
reversing a drift takes about a second. You bounce off walls; particle collisions bounce both
bodies.
How do I act? Submit an order for yourself every 4.5 seconds during four 45-second rounds. The
deterministic controller translates it into movement and facing until the next decision. Motors
are not directly exposed, and weapons do not exist. Your report supplies the active round and
role.
Can I talk? Only through one symbol: A through H, or '-' for silence. All players hear it
instantly, wherever they stand. Establish its meaning within the round; it has none inherently.
Other players never see your audience-facing note.
What helps in SPREAD? All four players cooperate on coverage averaged over ticks, with a small
individual contact deduction. Four separate occupied marks cover the field perfectly; piling
onto one does not. No mark belongs to anyone by assignment: negotiate using symbols if helpful.
What helps in DECEIVE? Three informed teammates know a goal that the adversary must discover.
They seek the goal while keeping that adversary distant; it seeks the goal itself. Their
opposing per-tick scores sum to 1.000. Since all movements and symbols are observable, going
straight there gives the secret away; misleading movement can lure the adversary away.
What helps in CRYPTO? A stationary speaker knows the target and shares a private symbol/colour
key with a mobile listener. Two mobile eavesdroppers hear the transmissions but lack the key.
The pair benefits when the listener reaches the goal without either eavesdropper nearby; each
eavesdropper benefits from reaching it. A fresh key each round conceals symbol meanings, but
tailing the listener reveals where to go. Arrive without leading them there.
What helps in TAG? One evader, moving at 94 px/s, faces three 70 px/s pursuers. It gains credit
for ticks when none is within 20 pixels. Each pursuer collects its own ticks inside that radius
and needs five seconds in total for a full score. Ignore the marks, but account for the
walls."""
    of pvReordered: """OBJECTIVES — SPREAD rewards cooperation: cover all four marks with
separate particles instead of crowding one, maintaining coverage across ticks. Touching another
particle incurs a small personal deduction. Assignments are not given; use symbols to divide the
marks if useful.
DECEIVE gives three players a goal location hidden from one adversary. Seek that mark while
leaving the adversary far away; its objective is to reach the same mark. The two sides receive
complementary scores totalling 1.000 each tick. Every symbol and movement is public, so
approaching directly betrays the location. Consider drawing the adversary elsewhere.
CRYPTO gives the goal to an immobile speaker. A mobile listener shares its secret
symbol-to-colour table; two mobile eavesdroppers hear the radio without that table. Speaker and
listener share the objective of listener proximity and eavesdropper distance; each eavesdropper
seeks proximity for itself. The table is replaced every round. It protects the meaning of a
symbol, not the listener's visible path: do not lead followers to the goal.
TAG rewards a lone 94 px/s evader for each tick with no pursuer within the 20-pixel contact
range. Three pursuers travel at 70 px/s and accumulate individual contact time; five seconds
yields full credit. Landmarks have no role here, while walls remain boundaries.
COMMUNICATION — You may transmit one letter A–H, or '-' for no sound. Reception is instant and
global. Meanings must be established during the round rather than assumed. Your note reaches the
audience alone.
DECISIONS — Four 45-second rounds make an episode. Issue your own order every 4.5 seconds;
deterministic execution controls movement and facing during the ensuing interval. You cannot
drive motors directly, and no weapons are present. Consult the report for round type and role.
GEOMETRY — Four particles named RED, BLUE, GREEN, and YELLOW share a 1235-by-659-pixel field
with amber, teal, violet, and bone marks. Acceleration leads to about 94 px/s cruise, and
reversing drift takes roughly one second. Walls cause rebounds; two colliding particles both
rebound."""
    of pvHeldoutBriefing: """Take charge of your particle on a rectangular field measuring 1235
by 659 pixels. The four bodies are RED, BLUE, GREEN, and YELLOW, while the four landmark colours
are amber, teal, violet, and bone. Motion builds through acceleration to approximately 94
pixels/second; a drift needs roughly a second to reverse. Expect rebounds at walls and for both
participants in a collision.
Plan for four rounds, each lasting 45 seconds. At 4.5-second intervals you set one order for
your body, and a deterministic mechanism carries out its movement and facing over the following
interval. You neither operate motors yourself nor use weapons. Identify your role and the
current round from the report.
Communicate through the public radio using one of A–H or silence '-'. Every body receives the
token immediately, independent of separation. Its interpretation comes from this round's
convention, not from a built-in meaning. Any note you write is visible only to the watching
audience.
For SPREAD, distribute the team across different landmarks. Continuous coverage earns the
cooperative reward, reduced by a small penalty for your own contact with another body. One body
per mark produces perfect coverage; a group at one mark does not. Decide who covers which,
optionally with radio tokens, because assignments are not supplied.
For DECEIVE, three players receive the goal and one adversary must infer it. The informed team
wants to occupy that mark while keeping the adversary distant; the adversary wants to occupy it
too. Each tick gives the two sides scores summing to 1.000. The adversary watches travel and
hears all tokens, so conceal the destination through misleading movement instead of heading
straight there.
For CRYPTO, a speaker that cannot move is told the goal. A listener that can move shares its
private colour/symbol dictionary, whereas two mobile eavesdroppers hear the tokens without the
dictionary. Reward the pair by taking the listener to the goal with both eavesdroppers far from
it; an eavesdropper instead benefits from its own arrival. A replacement dictionary each round
protects the code, but the listener's route can reveal the answer. Keep pursuers from following
you there.
For TAG, avoid three pursuers as the single faster evader: 94 versus 70 pixels/second. Evader
credit accumulates whenever nobody pursues within 20 pixels. Pursuers earn their individual time
in that contact range, with five seconds sufficient for full reward. Landmarks are merely
scenery in this scenario; walls still affect motion."""
    of pvHeldoutReference: """Transmission limits: an order can carry exactly one A–H token, or
'-' indicating silence. Distance does not delay or prevent anyone hearing it. A token acquires
its meaning from the current round's shared convention. Free-form notes are spectator
information and never sent to other particles.
Spatial model: RED, BLUE, GREEN, and YELLOW occupy a field of 1235 by 659 pixels with four
differently coloured marks: amber, teal, violet, bone. Control applies acceleration, not
instantaneous relocation. Typical cruise is about 94 pixels per second, with about one second
needed to invert drift. Boundary impacts bounce the particle; body impacts bounce both bodies.
Decision schedule: the episode spans four rounds of 45 seconds. An order applies to your own
particle for 4.5 seconds before the next order. The deterministic controller supplies steering
and facing, with neither weapons nor direct motor access. The observation report names your
current role and round.
SPREAD objective: all seats cooperate on tick-averaged landmark coverage, minus a small debit
for each tick of personal contact. Spread four particles among four marks to cover them
perfectly; concentrating on one leaves poor coverage. There are no predetermined mark owners.
Symbols can help agree on a division.
DECEIVE objective: three seats learn which mark is the goal, while the adversary is not told.
Good seats want themselves close and the adversary far; the adversary wants itself close. Their
opposed tick rewards add to 1.000. Since it can inspect all movement and hear all transmissions,
a direct route reveals the answer. Baiting it away can protect the goal.
CRYPTO objective: only the anchored speaker is given the goal; the listener is mobile and shares
the speaker's private key relating symbols to colours. Two mobile eavesdroppers receive symbols
without access to that key. Speaker/listener rewards favour the listener at the goal and both
eavesdroppers distant. Each eavesdropper profits by approaching the goal itself. The key is
newly drawn each round, concealing symbol interpretation; public listener motion remains a clue.
Reaching the destination without followers is the listener's challenge.
TAG objective: three slower pursuers at 70 px/s chase one 94 px/s evader. Contact uses a
20-pixel radius. The evader earns for ticks free of all contact; a pursuer earns only its own
contact ticks, saturating after five seconds. Walls still bound travel, and marks contribute
nothing."""
    of pvCanonical, pvMixed: raise newException(ValueError, "alternate wording must resolve")
  briefing & "\n\n" & ScoreRules & ReplyRules

proc operatorBlock*(prompt: string): string =
  ## The seat's own PLAYER_PROMPT, under a heading that tells the model how
  ## much weight it carries. Never echoed into the replay or the results.
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" &
    prompt.truncateRunes(MaxPromptRunes) & "\n\n"

proc userMessage*(operatorPrompt: string, viewJson: string): string =
  ## The user message: the operator's guidance, a blank line, then the seat's
  ## view. The view is built server-side from the seat's fog (see decide.nim).
  operatorBlock(operatorPrompt) & viewJson

proc requestedModel*(client: LlmClient): string =
  if client.transport == ltBedrock: client.bedrockModels[client.bedrockModel]
  else: client.model
