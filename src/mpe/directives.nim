## The directive schema: what a commander (LLM or scripted) may say, how a
## reply is parsed TOLERANTLY, and how an illegal reply is repaired instead of
## rejected.
##
## Both policy kinds emit the SAME object, so the two are strictly comparable
## and one validator covers both — that is what makes the bounded-orders test
## in tests/test_control.nim meaningful.
##
## RUNE DISCIPLINE. Every cap in this file is measured in RUNES (Unicode
## codepoints) and every truncation lands on a rune boundary (`runeLen` /
## `runeSubStr`). Slicing a string by BYTE index anywhere on the path to the
## replay is forbidden: a byte-truncated multi-byte character renders fine in a
## browser and then fails a strict UTF-8 parser, which is exactly the class of
## bug that makes a replay unreadable to everything except the one viewer that
## happened to be lenient.

import
  std/[json, strutils, unicode],
  sim_types

type
  Intent* = enum
    ## What a particle is being told to do for the next turn. A closed enum: an
    ## unrecognised intent is repaired to `go`, never dropped, so a particle is
    ## never left unactuated.
    intGo = "go"
    intHold = "hold"
    intCover = "cover"
    intShadow = "shadow"
    intEvade = "evade"
    intOrbit = "orbit"

  CogOrder* = object
    ## One commanded cog's orders for the next turn.
    cogIndex*: int             ## the live cog this order drives.
    id*: string                ## the cog's anonymous alias, e.g. "RED-alpha".
    intent*: Intent
    targetX*, targetY*: int    ## clamped into the map box.
    hasFace*: bool
    faceX*, faceY*: int
    symbol*: int               ## 0 = silence, 1..8 = A..H. THE ONLY thing a
                               ## seat can say to another seat, and it is
                               ## broadcast to the whole field.
    fromReply*: bool           ## a reply entry really named this particle.
                               ## False means the parser filled it in, and the
                               ## caller repairs it from last turn's directive
                               ## (else `drifter`'s) — never from a default.

  DirectiveSource* = enum
    dsLlm = "llm"
    dsScripted = "scripted"
    dsFallback = "fallback"

  SquadDirective* = object
    ## One seat's whole order set for one turn.
    note*: string              ## <= MaxNoteRunes; the commander's own line.
    orders*: seq[CogOrder]
    source*: DirectiveSource
    latencyMs*: int

  DirectiveError* = object of ValueError

proc truncateRunes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` RUNES, on a rune boundary. The single
  ## place any recorded string is shortened.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc parseSymbol*(text: string): int =
  ## The radio's whole vocabulary, parsed tolerantly: take the FIRST rune,
  ## upper-case it, and accept it only if it is one of A..H. Anything else —
  ## a lower-case letter that is not in the alphabet, a two-character string,
  ## an emoji, an empty string, a missing field — is silence.
  ##
  ## Taking the first RUNE rather than the first byte matters: a reply whose
  ## symbol field is a multi-byte character must not be sliced mid-codepoint on
  ## its way to the replay.
  if text.len == 0:
    return 0
  var first = ""
  for rune in text.strip().runes:
    first = toUpper(rune).toUTF8()
    break
  if first.len != 1:
    return 0
  for i in 0 ..< SymbolAlphabet.len:
    if SymbolAlphabet[i] == first[0]:
      return i + 1
  0

proc symbolTextOf*(index: int): string =
  ## The wire text of one symbol index: 0 is silence ("-"), 1..8 are A..H.
  if index <= 0 or index > SymbolAlphabet.len:
    SymbolSilence
  else:
    $SymbolAlphabet[index - 1]

proc sanitizeNote*(text: string): string =
  ## The commander's own line, as it reaches the replay and the match feed.
  ## Newlines collapse to spaces so one record stays one line.
  text.replace("\n", " ").replace("\r", " ").strip().truncateRunes(MaxNoteRunes)

proc parseIntent*(text: string): Intent =
  ## Tolerant: case-insensitive, hyphens and spaces normalised to
  ## underscores. Anything still unknown becomes `go` — the intent that always
  ## has somewhere to be.
  let key = text.strip().toLowerAscii().replace("-", "_").replace(" ", "_")
  for intent in Intent:
    if $intent == key:
      return intent
  intGo

proc extractJsonObject*(text: string): JsonNode =
  ## The outermost balanced `{...}` in a model reply, tolerating markdown
  ## fences and any prose the model prefixed or suffixed. Falls back to
  ## first-brace..last-brace when the scan finds no balanced pair, which is
  ## what recovers a reply whose braces sit inside a quoted string.
  var
    depth = 0
    start = -1
    inString = false
    escaped = false
  for i, ch in text:
    if inString:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': inString = false
      continue
    case ch
    of '"': inString = true
    of '{':
      if depth == 0: start = i
      inc depth
    of '}':
      if depth > 0:
        dec depth
        if depth == 0 and start >= 0:
          try:
            return parseJson(text[start .. i])
          except CatchableError:
            start = -1
    else: discard
  let
    first = text.find('{')
    last = text.rfind('}')
  if first < 0 or last <= first:
    var head = text.strip()
    if head.runeLen > 160:
      head = head.truncateRunes(160) & "..."
    raise newException(
      DirectiveError, "no JSON object in reply: " & head.replace("\n", " "))
  parseJson(text[first .. last])

proc readCoord(node: JsonNode): tuple[ok: bool, value: int] =
  ## One target/face coordinate: an int, a float, or a numeric string.
  ## Anything non-finite or unparseable reports `ok = false` so the caller
  ## can apply its own default rather than inventing a position.
  if node.isNil:
    return (false, 0)
  case node.kind
  of JInt:
    (true, int(node.getBiggestInt()))
  of JFloat:
    let f = node.getFloat()
    if f != f or f > 1.0e9 or f < -1.0e9: (false, 0)
    else: (true, int(f))
  of JString:
    try: (true, int(parseFloat(node.getStr().strip())))
    except CatchableError: (false, 0)
  else:
    (false, 0)

proc readPoint(
  node: JsonNode, defaultX, defaultY, maxX, maxY: int
): tuple[given: bool, x, y: int] =
  ## A `[x, y]` pair (an object with x/y keys is accepted too), clamped into
  ## the map box. A missing or non-finite pair reports `given = false` and
  ## returns the caller's default.
  result = (false, defaultX, defaultY)
  if node.isNil or node.kind == JNull:
    return
  var
    rx = (ok: false, value: 0)
    ry = (ok: false, value: 0)
  if node.kind == JArray and node.len >= 2:
    rx = readCoord(node[0])
    ry = readCoord(node[1])
  elif node.kind == JObject:
    rx = readCoord(node{"x"})
    ry = readCoord(node{"y"})
  if not rx.ok or not ry.ok:
    return
  result = (
    true,
    clamp(rx.value, 0, max(0, maxX)),
    clamp(ry.value, 0, max(0, maxY))
  )

proc cogEntries(payload: JsonNode): seq[tuple[id: string, node: JsonNode]] =
  ## The reply's `cogs` collection, accepted either as an ARRAY of objects or
  ## as an OBJECT keyed by cog id (both shapes are things models actually
  ## emit). Entries that are not objects are dropped.
  let node = payload{"cogs"}
  if node.isNil:
    return @[]
  if node.kind == JArray:
    for item in node:
      if item.kind == JObject:
        result.add((item{"id"}.getStr(), item))
  elif node.kind == JObject:
    for key, item in node:
      if item.kind == JObject:
        let id = if item{"id"}.getStr().len > 0: item{"id"}.getStr() else: key
        result.add((id, item))

proc parseSquadDirective*(
  payload: JsonNode,
  commandedIds: seq[string],
  commandedCogs: seq[int],
  defaultX, defaultY, maxX, maxY: int
): SquadDirective =
  ## Turns one parsed reply into a legal directive, REPAIRING every field the
  ## schema bounds rather than rejecting the reply:
  ##
  ## * `note`      truncated to MaxNoteRunes on a rune boundary;
  ## * `cogs`      extra entries dropped, a missing cog left for the caller to
  ##               fill from last turn (or from `holdline`);
  ## * `cogs[].id` matched case-insensitively and suffix-wise; an unmatched
  ##               entry is assigned to the next unclaimed commanded cog BY
  ##               POSITION, which is what rescues a model that invented its
  ##               own naming;
  ## * `intent`    unknown -> go;
  ## * `target`    missing / non-finite -> the caller's default (the field
  ##               centre); otherwise clamped to the field box;
  ## * `face`      same clamp, absent -> none;
  ## * `symbol`    first rune, upper-cased; anything outside A..H -> "-".
  ##
  ## Raises DirectiveError only when NO usable cog entry can be recovered —
  ## that is the one condition the retry and then the scripted fallback exist
  ## for.
  doAssert commandedIds.len == commandedCogs.len
  result.note = sanitizeNote(payload{"note"}.getStr())
  result.source = dsLlm
  var
    claimed = newSeq[bool](commandedIds.len)
    byPosition = 0
    matched = 0
    orders = newSeq[CogOrder](commandedIds.len)
  for i in 0 ..< commandedIds.len:
    orders[i] = CogOrder(
      cogIndex: commandedCogs[i],
      id: commandedIds[i],
      intent: intGo,
      targetX: defaultX,
      targetY: defaultY,
      symbol: 0
    )
  for entry in cogEntries(payload):
    var slot = -1
    let wanted = entry.id.strip().toLowerAscii()
    if wanted.len > 0:
      for i, id in commandedIds:
        if claimed[i]:
          continue
        let mine = id.toLowerAscii()
        if mine == wanted or mine.endsWith(wanted) or wanted.endsWith(mine):
          slot = i
          break
    if slot < 0:
      while byPosition < claimed.len and claimed[byPosition]:
        inc byPosition
      if byPosition >= claimed.len:
        continue                     ## extra entries are dropped, never fatal
      slot = byPosition
    claimed[slot] = true
    inc matched
    orders[slot].fromReply = true
    let node = entry.node
    orders[slot].intent = parseIntent(node{"intent"}.getStr())
    let target = readPoint(node{"target"}, defaultX, defaultY, maxX, maxY)
    orders[slot].targetX = target.x
    orders[slot].targetY = target.y
    let face = readPoint(node{"face"}, 0, 0, maxX, maxY)
    orders[slot].hasFace = face.given
    orders[slot].faceX = face.x
    orders[slot].faceY = face.y
    orders[slot].symbol = parseSymbol(node{"symbol"}.getStr())
  if matched == 0:
    raise newException(DirectiveError, "reply named no commanded cog")
  result.orders = orders

proc directiveRecord*(
  directive: SquadDirective,
  roundIndex, turn, seat: int,
  mode, alias, role: string
): JsonNode =
  ## The replay chat record for one turn's directive. Re-applied at playback
  ## into NON-HASHED sim fields only (the feed and the radio strip), so it
  ## drives the broadcast and tools/replay_summary.py and can never affect the
  ## simulation.
  var cogs = newJArray()
  for order in directive.orders:
    var item = %*{
      "id": order.id,
      "intent": $order.intent,
      "target": [order.targetX, order.targetY],
      "symbol": symbolTextOf(order.symbol)
    }
    if order.hasFace:
      item["face"] = %[order.faceX, order.faceY]
    else:
      item["face"] = newJNull()
    cogs.add(item)
  %*{
    "k": "directive",
    "round": roundIndex,
    "mode": mode,
    "turn": turn,
    "seat": seat,
    "alias": alias,
    "role": role,
    "source": $directive.source,
    "latency_ms": directive.latencyMs,
    "note": directive.note,
    "cogs": cogs
  }

proc boundedDirectiveRecord*(
  directive: SquadDirective,
  roundIndex, turn, seat: int,
  mode, alias, role: string
): string =
  ## The serialized directive record, guaranteed <= MaxDirectiveRunes. The
  ## note is the only unbounded-in-practice field, so it is the one that
  ## shrinks; the cut still lands on a rune boundary.
  var trimmed = directive
  result = $trimmed.directiveRecord(roundIndex, turn, seat, mode, alias, role)
  var guard = 0
  while result.runeLen > MaxDirectiveRunes and guard < 12:
    inc guard
    let keep = max(0, trimmed.note.runeLen - max(8, trimmed.note.runeLen div 2))
    trimmed.note = trimmed.note.truncateRunes(keep)
    result = $trimmed.directiveRecord(
      roundIndex, turn, seat, mode, alias, role)
  # The loop always converges: with an empty note the record is a few hundred
  # runes of fixed structure. Never cut the SERIALIZED string — that would emit
  # broken JSON, which is the exact failure the rune rule exists to prevent.
