## The particle-worlds ordinary player. The game sends a private seat view
## each turn; this process returns one complete squad directive.
##
##   PLAYER_PROMPT        a strategy in plain English -> prompt policy
##   PARTICLE_WORLDS_JEV=1                 -> Jev policy
##   PLAYER_SCRIPTED      drifter | beeline          -> this seat is scripted
##   PLAYER_POLICY_LABEL  a free label for the replay's `register` record
##
## A seat that sets neither is `drifter`. To field your own policy, reuse
## this image and set PLAYER_PROMPT:
##
##   coworld upload-policy coworld-particle-worlds:latest \
##     --name my-particles --run /bin/particle-worlds-player \
##     --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os, strutils, uri],
  bitworld/spriteprotocol,
  curly,
  mpe/[llm, directives],
  whisky

const
  ConnectAttempts = 240      ## 240 x 500 ms = 2 minutes of dialling.
  ConnectRetryMs = 500
  RegistrationResends = 10   ## re-sends after the first, ~1 s apart.
  ResendEveryFrames = 24     ## ~1 s of frames at 24 Hz.
  ReconnectAttempts = 6      ## 6 x 500 ms of re-dialling after a live socket
                             ## dies, before accepting the game is gone.

type PolicyReply = object
  ok: bool
  action: JsonNode
  cause: string
  error: string

proc registrationBlob(kind, scripted, policy: string): string =
  ## The one registration message. `scripted` is JSON null when the seat is
  ## an LLM seat, so the server can tell "no baseline named" from "drifter
  ## named explicitly".
  var node = %*{
    "type": "register",
    "kind": kind,
    "policy": policy
  }
  if scripted.len > 0:
    node["scripted"] = %scripted
  else:
    node["scripted"] = newJNull()
  blobFromSpriteChat($node)

proc bestChoice(answer: JsonNode, count: int): int =
  if answer["type"].getStr() != "choice" or
      answer["probabilities"].len != count:
    raise newException(ValueError, "invalid Jev choice distribution")
  var best = -1.0
  var total = 0.0
  for i in 0 ..< count:
    let probability = answer["probabilities"][$i].getFloat()
    if probability < 0 or probability > 1:
      raise newException(ValueError, "invalid Jev probability")
    total += probability
    if probability > best:
      best = probability
      result = i
  if abs(total - 1.0) > count.float * 0.005 + 0.000001:
    raise newException(ValueError, "Jev probabilities do not sum to one")

proc chooseJev(view: JsonNode, prompt: string, seat, timeoutSeconds: int): PolicyReply =
  let
    sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME")
    endpoint = if sidecar.len > 0: sidecar
               else: getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
    model = if sidecar.len > 0: "typesafe/jev-1.13"
            else: getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
  var questions = newJObject()
  for (name, values) in [
    ("mark", @["0", "1", "2", "3"]),
    ("intent", @["go", "hold", "cover", "shadow", "evade", "orbit"]),
    ("symbol", @["-", "A", "B", "C", "D", "E", "F", "G", "H"])
  ]:
    var criteria = newJObject()
    for i, value in values:
      criteria[$i] = %value
    questions[name] = %*{
      "type": "choice", "instructions": "Choose this squad directive's " & name,
      "criteria": criteria
    }
  let body = $(%*{
    "model": model,
    "state": {"policy": SystemPrompt & operatorBlock(prompt), "summary": $view},
    "questions": questions
  })
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if sidecar.len > 0:
    headers["x-coworld-player-slot"] = $seat
  else:
    headers["authorization"] = "Bearer " & getEnv("TYPESAFE_API_KEY")
  var batch: RequestBatch
  batch.post(endpoint.strip(chars = {'/'}, leading = false) & "/v1/systemone",
    headers, body, $seat)
  let reply = newCurly().makeRequests(batch, timeoutSeconds)[0]
  if reply.error.len > 0:
    return PolicyReply(cause: "transport_error", error: reply.error)
  if reply.response.code == 429:
    return PolicyReply(cause: "throttled", error: "Jev provider throttled")
  if reply.response.code == 401 or reply.response.code == 403:
    return PolicyReply(cause: "no_credentials", error: "Jev credential rejected")
  if reply.response.code < 200 or reply.response.code >= 300:
    return PolicyReply(cause: "transport_error", error: "Jev provider returned " &
      $reply.response.code)
  let answers = parseJson(reply.response.body)["answers"]
  let
    mark = bestChoice(answers["mark"], 4)
    intent = bestChoice(answers["intent"], 6)
    symbol = bestChoice(answers["symbol"], 9)
  result.ok = true
  result.action = %*{
    "note": "Jev chose from my private seat view.",
    "cogs": [{
      "id": view["you"]["id"],
      "intent": @["go", "hold", "cover", "shadow", "evade", "orbit"][intent],
      "target": view["marks"][mark]["pos"],
      "face": newJNull(),
      "symbol": @["-", "A", "B", "C", "D", "E", "F", "G", "H"][symbol]
    }]
  }

proc choosePrompt(view: JsonNode, prompt: string, timeoutSeconds: int): PolicyReply =
  let client = newLlmClient()
  if client.disabled:
    return PolicyReply(cause: "no_credentials", error: "prompt credential unavailable")
  let request = client.requestFor(SystemPrompt, userMessage(prompt, $view))
  var batch: RequestBatch
  batch.post(request.url, request.headers, request.body, "player")
  let reply = client.curl.makeRequests(batch, timeoutSeconds)[0]
  if reply.error.len > 0:
    return PolicyReply(cause: "transport_error", error: reply.error)
  if reply.response.code == 429:
    return PolicyReply(cause: "throttled", error: "prompt provider throttled")
  if reply.response.code == 401 or reply.response.code == 403:
    return PolicyReply(cause: "no_credentials", error: "prompt credential rejected")
  if reply.response.code < 200 or reply.response.code >= 300:
    return PolicyReply(cause: "transport_error", error: "prompt provider returned " &
      $reply.response.code)
  result.ok = true
  result.action = extractJsonObject(
    client.textOf(reply.response, reply.error, request.url))

proc readyBlob(): string =
  ## The Sprite v1 player-ready packet (0x85). Legitimate here in a way it is
  ## not for an ordinary player client: this seat sends NO inputs at all (the
  ## server computes every actuator mask), so the dead-reckoning hazard
  ## docs/PROTOCOL.md warns about cannot arise, and a fastMode server can
  ## advance the tick as soon as every seat has acknowledged the frame.
  result = newString(1)
  result[0] = char(0x85)

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL", getEnv("COGAMES_ENGINE_WS_URL"))
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var seat = -1
  for key, value in decodeQuery(parseUri(url).query):
    if key == "slot":
      seat = parseInt(value)
  if seat < 0:
    quit("player socket URL has no slot", 1)
  let
    prompt = getEnv("PLAYER_PROMPT").strip()
    scripted = getEnv("PLAYER_SCRIPTED").strip()
    jev = getEnv("PARTICLE_WORLDS_JEV") == "1"
    kind = if jev or prompt.len > 0: "external" else: "scripted"
    label = block:
      let explicit = getEnv("PLAYER_POLICY_LABEL").strip()
      if explicit.len > 0: explicit
      elif jev: "jev"
      elif prompt.len > 0: "prompt"
      elif scripted.len > 0: scripted
      else: "drifter"
  echo "particle-worlds player: kind=",
    kind,
    " baseline=", (if scripted.len > 0: scripted else: "drifter"),
    " label=", label

  proc dial(attempts: int): WebSocket =
    ## Bounded dialling. The game bakes its supersampled board render caches
    ## BEFORE it opens the listener (a viewer's first-message clock starts at
    ## connect, so nothing may be accepted until every frame can be assembled
    ## instantly), and the episode runner starts the players at the same
    ## instant as the game — so the first dial always lands on a closed port.
    for attempt in 0 ..< attempts:
      try:
        return newWebSocket(url)
      except CatchableError as error:
        if attempt == 0:
          echo "particle-worlds player: game not listening yet (", error.msg,
            "); retrying"
        sleep(ConnectRetryMs)
    nil

  var socket = dial(ConnectAttempts)
  if socket == nil:
    quit("particle-worlds player: game never accepted a connection", 1)
  echo "particle-worlds player: connected"

  # Each session is wrapped: whisky's receiveMessage RAISES on a close frame or
  # a truncated read (only a timeout returns none), and mummy's send only
  # QUEUES — so the game's own quit(0) can outrun the flushed frame. A naive
  # player exits 1 on that race and fails certification intermittently
  # (cogame-raid 0.1.3). Exiting 0 on a dead socket is the fix.
  #
  # REGISTRATION IS RE-SENT, NOT SENT ONCE. Joins are slot-sequential, so a
  # seat whose slot is not the next open one is not admitted until the lower
  # slots have joined — and the lobby sends frames to a socket before it is
  # admitted, so the first registration AND a single re-send keyed on the first
  # received frame can both land while the seat has no index yet. The server
  # dropped them and the champion played the scripted baseline for the whole
  # episode (the inherited round-3 scar, inherited from coworld-ctf). The server now holds an
  # unappliable registration, and this end keeps re-sending it for the first
  # ~10 s of frames, which covers the lobby whichever seat connects first.
  # Registering twice is harmless: the server just re-reads the same fields.
  var reconnects = 0
  while true:
    var sessionFrames = 0
    try:
      socket.send(registrationBlob(kind, scripted, label), BinaryMessage)
      var resends = 0
      while true:
        let received = socket.receiveMessage()
        if received.isNone:
          continue                    ## a read timeout, not a closed socket
        if received.get().kind == TextMessage:
          let frame = parseJson(received.get().data)
          if frame{"type"}.getStr() == "turn":
            let callTimeout = max(1, frame["timeout_seconds"].getInt() - 1)
            let answer =
              if jev and getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").len == 0 and
                  getEnv("TYPESAFE_API_KEY").len == 0:
                %*{"type": "decision", "id": frame["id"],
                   "cause": "no_credentials", "error": "Jev credential unavailable"}
              elif prompt.len > 0 and not jev and
                  getEnv("ANTHROPIC_API_KEY").len == 0 and
                  getEnv("ANTHROPIC_API_KEY_URI").len == 0 and
                  getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").len == 0:
                %*{"type": "decision", "id": frame["id"],
                   "cause": "no_credentials", "error": "prompt credential unavailable"}
              else:
                let choice =
                  if jev: chooseJev(frame["view"], prompt, seat, callTimeout)
                  else: choosePrompt(frame["view"], prompt, callTimeout)
                if choice.ok:
                  %*{"type": "decision", "id": frame["id"], "action": choice.action}
                else:
                  %*{"type": "decision", "id": frame["id"],
                     "cause": choice.cause, "error": choice.error}
            socket.send($answer, TextMessage)
          continue
        inc sessionFrames
        if resends < RegistrationResends and
            sessionFrames mod ResendEveryFrames == 1:
          inc resends
          socket.send(registrationBlob(kind, scripted, label), BinaryMessage)
        socket.send(readyBlob(), BinaryMessage)
    except CatchableError as error:
      echo "particle-worlds player: socket closed (", error.msg, ")"
    # NEVER exit while the game is still serving: a seat that drops keeps its
    # cogs for the whole episode and revives on reconnect, so a dropped socket
    # mid-episode is worth re-dialling and re-registering. Bounded on both
    # counts — a session that never received a frame means the game is winding
    # down (its shutdown grace still answers the route), and the re-dial is
    # capped — so this can never outlive the game or spin: the runner waits on
    # process exit either way.
    if sessionFrames == 0 or reconnects >= ReconnectAttempts:
      break
    inc reconnects
    echo "particle-worlds player: re-dialling the seat (attempt ", reconnects, ")"
    socket = dial(ReconnectAttempts)
    if socket == nil:
      echo "particle-worlds player: game is no longer listening, exiting cleanly"
      break
    echo "particle-worlds player: reconnected, re-registering"
  quit(0)
