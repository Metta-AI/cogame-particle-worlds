## Private engine-owned decision evidence; never included in spectator records.
import std/[base64, json, options, os, tables, unicode]
import decision_trajectory
import curly
export decision_trajectory, options

type
  CapturedDecision* = object
    observation*: JsonNode
    attempts*: seq[DecisionAttempt]
  RuntimeCapture* = ref object
    trajectory*: DecisionTrajectory
    turn*: seq[CapturedDecision]

proc newRuntimeCapture*(game: string, seed: int): RuntimeCapture =
  if getEnv(CogameSaveTrajectoryUriEnv).len == 0: return nil
  RuntimeCapture(trajectory: newDecisionTrajectory(getEnv("COWORLD_EPISODE_ID"),
    game & "-" & $seed, game, getEnv("COWORLD_GAME_VERSION"),
    getEnv("COWORLD_SOURCE_REVISION")))

proc beginTurn*(capture: RuntimeCapture, observations: seq[JsonNode]) =
  if capture == nil: return
  capture.turn = newSeq[CapturedDecision](observations.len)
  for seat, observation in observations:
    capture.turn[seat].observation = copy(observation)

proc modelAttempt*(identity, policy, model, url, body: string,
    response: Response, error: string, latency: int): DecisionAttempt =
  result = newDecisionAttempt(identity, policy, aoModel)
  result.model = some(model)
  let request = parseJson(body)
  result.prompt = %*[{"role": "system", "content": request["system"]},
    {"role": "user", "content": request["messages"][0]["content"]}]
  result.request = copy(request)
  result.decoder = %*{"max_tokens": request["max_tokens"]}
  for key in ["temperature", "top_p", "top_k", "output_config"]:
    if request.hasKey(key): result.decoder[key] = request[key]
  result.latencyMs = some(float(latency))
  if response.body.validateUtf8() == -1: result.rawResponse = %response.body
  result.responseBodyB64 = some(encode(response.body))
  result.responseComplete = some(error.len == 0)
  if response.code >= 100 and response.code <= 599: result.httpStatus = some(response.code)
  var received = initTable[string, string]()
  for (key, value) in response.headers: received[key] = value
  result.responseHeaders = some(received)
  if response.headers.contains("X-Softmax-Llm-Call-Id"):
    result.platformCallId = some(response.headers["X-Softmax-Llm-Call-Id"])
  for key in ["request-id", "x-request-id"]:
    if response.headers.contains(key):
      result.providerRequestId = some(response.headers[key])
      break
  if error.len > 0: result.rejectionReason = some(error)
  try:
    let payload = parseJson(response.body)
    if payload{"model"}.getStr().len > 0: result.model = some(payload["model"].getStr())
    if payload{"stop_reason"}.getStr().len > 0:
      result.stopReason = some(payload["stop_reason"].getStr())
    if payload.hasKey("usage"):
      if payload["usage"].hasKey("input_tokens"):
        result.inputTokens = some(payload["usage"]["input_tokens"].getInt())
      if payload["usage"].hasKey("output_tokens"):
        result.outputTokens = some(payload["usage"]["output_tokens"].getInt())
  except CatchableError: discard # Original bytes remain authoritative for malformed/error responses.

proc recordAttempt*(capture: RuntimeCapture, seat: int, evidence: DecisionAttempt) =
  if capture != nil: capture.turn[seat].attempts.add(evidence)

proc applied*(capture: RuntimeCapture, seat, tick: int, action: JsonNode,
    origin: AttemptOrigin, policy: string) =
  if capture == nil: return
  var attempts = capture.turn[seat].attempts
  var selected = none(string)
  for attempt in attempts:
    if attempt.accepted: selected = some(attempt.attemptId)
  let fallback = origin == aoFallback or (origin == aoModel and selected.isNone)
  if origin != aoModel or fallback:
    var actual = newDecisionAttempt($tick & "-" & $seat & "-engine", policy,
      if fallback: aoFallback else: origin)
    actual.parsedAction = copy(action)
    actual.accepted = true
    selected = some(actual.attemptId)
    attempts.add(actual)
  capture.trajectory.recordDecision($tick & "-" & $seat, $seat,
    capture.turn[seat].observation, attempts, selected, action,
    if fallback: asFallback else: asAccepted,
    fallbackOrigin = (if fallback: some(policy) else: none(string)))

proc finishCapture*(capture: RuntimeCapture, outcome: JsonNode) =
  if capture == nil: return
  let reason = outcome{"reason"}.getStr()
  let status = case reason
    of "complete": esCompleted
    of "deadline": esTruncated
    else: esFailed
  capture.trajectory.finish(status, outcome, outcome{"scores"})
  capture.trajectory.writeEventsToUri(getEnv(CogameSaveTrajectoryUriEnv))
