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
##   Bedrock sidecar (AWS_ENDPOINT_URL_BEDROCK_RUNTIME + AWS_BEARER_TOKEN_BEDROCK)
##   ANTHROPIC_API_KEY
##   ANTHROPIC_API_KEY_URI
## With none of them the client disables itself and every turn falls back to
## the scripted layer INSTANTLY, with no network wait — which is what lets
## offline certification finish in seconds.

import
  std/[json, os, strutils, unicode],
  bitworld/runtime,
  curly,
  sim_types, directives

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  LlmTransport* = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl*: Curly
    transport*: LlmTransport
    apiKey: string
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
  client: LlmClient, system, user: string
): tuple[url: string, headers: HttpHeaders, body: string] =
  ## One Messages-API request, shaped for whichever transport is live.
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
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

const SystemPrompt* = """
You are ONE particle on a flat field 1235 by 659 pixels, with four coloured
marks on it (amber, teal, violet, bone). Four particles play: RED, BLUE, GREEN
and YELLOW. You accelerate; you do not teleport. You cruise at about 94 pixels
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
THIS ROUND IS <MODE> AND YOU ARE THE <ROLE>.
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
Reply with a single JSON object and NOTHING else. Your reply MUST begin with '{'.
Schema:
{"note":"<=160 chars, audience only","cogs":[{"id":"<your own id>",
  "intent":"go|hold|cover|shadow|evade|orbit",
  "target":[x,y],
  "face":[x,y] or null,
  "symbol":"-" or one of A B C D E F G H}]}
Intents: go = drive to `target` and stop there; hold = brake and stay where you
are; cover = drive onto the mark nearest `target` and sit on it; shadow = close
to 60 pixels of the particle nearest `target` and stay there, EXCEPT in TAG,
where a pursuer always shadows the EVADER whatever `target` says and closes to
inside the 20-pixel tag radius rather than standing off; evade = drive away
from the nearest particle, staying inside the walls; orbit = circle `target` at
120 pixels. `face` only turns your sprite. `symbol` is BROADCAST.
"""

proc systemPromptFor*(mode, role: string): string =
  ## The system prompt with its one PER-TURN line filled in: the design note
  ## reserves `THIS ROUND IS <MODE> AND YOU ARE THE <ROLE>.` for the two facts
  ## that change under the seat every round. They are in the seat's view as
  ## well, but a rule the model has to go and look up in a JSON report is not
  ## the same as a rule stated in the rules.
  SystemPrompt
    .replace("<MODE>", mode.toUpperAscii())
    .replace("<ROLE>", role.toUpperAscii())

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
