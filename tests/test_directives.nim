## Tolerant parsing and repair. Every field the schema bounds is REPAIRED, not
## rejected: only a reply from which no usable entry can be recovered raises,
## and that is the one condition the retry and then the scripted fallback exist
## for.
##
## The rune rule is pinned here with a 4-byte emoji sitting exactly on the note
## cap: a byte-truncated multi-byte character renders fine in a browser and then
## fails a strict UTF-8 parser, which is the class of bug that makes a replay
## unreadable to everything except the one viewer that happened to be lenient.

import std/[json, strutils, unicode, unittest]
import ../src/mpe/[directives, sim_types]

const
  Ids = @["BLUE-alpha"]
  Cogs = @[1]
  Cx = 617
  Cy = 329
  MaxX = 1234
  MaxY = 658

proc parse(text: string): SquadDirective =
  parseSquadDirective(extractJsonObject(text), Ids, Cogs, Cx, Cy, MaxX, MaxY)

suite "directive parsing":

  test "prose-prefixed and fenced JSON are both recovered":
    for text in [
        """Sure! Here is my order:
{"note":"go","cogs":[{"id":"BLUE-alpha","intent":"cover","target":[10,20],"symbol":"F"}]}
Hope that helps.""",
        """```json
{"note":"go","cogs":[{"id":"BLUE-alpha","intent":"cover","target":[10,20],"symbol":"F"}]}
```"""]:
      let directive = parse(text)
      check directive.orders.len == 1
      check directive.orders[0].intent == intCover
      check directive.orders[0].targetX == 10
      check directive.orders[0].symbol == symbolIndexOfText("F")

  test "cogs as an id-keyed object is accepted":
    let directive = parse(
      """{"cogs":{"BLUE-alpha":{"intent":"orbit","target":[1,2],"symbol":"c"}}}""")
    check directive.orders.len == 1
    check directive.orders[0].fromReply
    check directive.orders[0].intent == intOrbit
    check directive.orders[0].symbol == symbolIndexOfText("C")

  test "unknown and hyphenated intents normalise, unknown falls to go":
    check parseIntent("Cover") == intCover
    check parseIntent(" hold ") == intHold
    check parseIntent("SHADOW") == intShadow
    check parseIntent("e-vade") == intGo      ## not a legal name once normalised
    check parseIntent("go") == intGo
    check parseIntent("teleport") == intGo
    check parseIntent("") == intGo

  test "absent, NaN and off-map targets are repaired, never rejected":
    var directive = parse("""{"cogs":[{"id":"BLUE-alpha","intent":"go"}]}""")
    check directive.orders[0].targetX == Cx
    check directive.orders[0].targetY == Cy
    directive = parse(
      """{"cogs":[{"id":"BLUE-alpha","target":[1e30,-1e30]}]}""")
    check directive.orders[0].targetX == Cx
    check directive.orders[0].targetY == Cy
    directive = parse(
      """{"cogs":[{"id":"BLUE-alpha","target":[99999,-500]}]}""")
    check directive.orders[0].targetX == MaxX
    check directive.orders[0].targetY == 0
    directive = parse(
      """{"cogs":[{"id":"BLUE-alpha","target":{"x":"42","y":"7.9"}}]}""")
    check directive.orders[0].targetX == 42
    check directive.orders[0].targetY == 7

  test "three cogs are trimmed to one and an unmatched id lands by position":
    let directive = parse("""{"cogs":[
      {"id":"RED-alpha","intent":"hold","target":[1,1],"symbol":"A"},
      {"id":"GREEN-alpha","intent":"go","target":[2,2]},
      {"id":"YELLOW-alpha","intent":"go","target":[3,3]}]}""")
    check directive.orders.len == 1
    check directive.orders[0].id == "BLUE-alpha"
    check directive.orders[0].fromReply
    check directive.orders[0].intent == intHold

  test "zero cogs raises so the caller can retry then fall back":
    expect DirectiveError:
      discard parse("""{"note":"nothing to say","cogs":[]}""")
    expect DirectiveError:
      discard parse("""{"note":"nothing to say"}""")
    expect DirectiveError:
      discard parse("""I refuse to answer in JSON.""")

  test "an id belonging to another seat still drives THIS seat's particle":
    let directive = parse(
      """{"cogs":[{"id":"GREEN-alpha","intent":"evade","target":[5,5]}]}""")
    check directive.orders.len == 1
    check directive.orders[0].cogIndex == 1
    check directive.orders[0].id == "BLUE-alpha"
    check directive.orders[0].intent == intEvade

  test "the symbol takes the first rune, upper-cases it, and gates on A..H":
    check parseSymbol("f") == symbolIndexOfText("F")
    check parseSymbol("FF") == symbolIndexOfText("F")
    check parseSymbol("Z") == 0
    check parseSymbol("-") == 0
    check parseSymbol("") == 0
    check parseSymbol("   ") == 0
    check parseSymbol("\u2014") == 0            ## an em dash is not a symbol
    check parseSymbol("\u{1F680}") == 0         ## a 4-byte emoji is not either
    check symbolTextOf(0) == SymbolSilence
    for i in 1 .. SymbolAlphabet.len:
      check parseSymbol(symbolTextOf(i)) == i

  test "a 300-character note is truncated on a RUNE boundary":
    var long = ""
    for i in 0 ..< 300:
      long.add('x')
    let directive = parse(
      """{"note":"""" & long & """","cogs":[{"id":"BLUE-alpha"}]}""")
    check directive.note.runeLen == MaxNoteRunes
    check directive.note.validateUtf8() == -1

  test "a 4-byte emoji sitting ON the cap survives whole":
    ## 159 ASCII runes then one 4-byte emoji: the 160th rune. Truncating by
    ## BYTES would cut the emoji in half, and the record would render in a
    ## browser and fail a strict parser.
    var head = ""
    for i in 0 ..< MaxNoteRunes - 1:
      head.add('a')
    let note = head & "\u{1F680}" & "TAIL"
    check note.runeLen == MaxNoteRunes + 4
    let directive = parse(
      """{"note":"""" & note & """","cogs":[
        {"id":"BLUE-alpha","intent":"cover","target":[3,4],"symbol":"G"}]}""")
    check directive.note.runeLen == MaxNoteRunes
    check directive.note.validateUtf8() == -1
    check directive.note.endsWith("\u{1F680}")
    ## And the whole serialized record round-trips through %$ -> parseJson and
    ## decodes as UTF-8.
    let record = directive.boundedDirectiveRecord(
      1, 0, 1, "crypto", "BLUE-alpha", "listener")
    check record.runeLen <= MaxDirectiveRunes
    check record.validateUtf8() == -1
    let reparsed = parseJson(record)
    check reparsed["note"].getStr().validateUtf8() == -1
    check reparsed["cogs"][0]["symbol"].getStr() == "G"
    check reparsed["k"].getStr() == "directive"
    check reparsed["role"].getStr() == "listener"

  test "the bounded record shrinks the NOTE, never the serialized string":
    var directive = SquadDirective(source: dsLlm)
    var note = ""
    for i in 0 ..< MaxNoteRunes:
      note.add("\u{1F680}")            ## 160 four-byte runes: 640 bytes
    directive.note = note
    directive.orders = @[CogOrder(
      cogIndex: 1, id: "BLUE-alpha", intent: intCover,
      targetX: 100, targetY: 200, symbol: 6)]
    let record = directive.boundedDirectiveRecord(
      4, 9, 1, "crypto", "BLUE-alpha", "listener")
    check record.runeLen <= MaxDirectiveRunes
    check record.validateUtf8() == -1
    let reparsed = parseJson(record)      ## still legal JSON, never cut
    check reparsed["cogs"][0]["intent"].getStr() == "cover"

  test "sanitizeNote collapses newlines and honours the cap":
    check sanitizeNote("a\nb\r\nc") == "a b  c"
    var long = ""
    for i in 0 ..< 500:
      long.add("\u00e9")                  ## 2-byte runes
    let note = sanitizeNote(long)
    check note.runeLen == MaxNoteRunes
    check note.validateUtf8() == -1

  test "extractJsonObject rescues braces inside a quoted string":
    let node = extractJsonObject(
      """prose {"note":"a { b } c","cogs":[{"id":"BLUE-alpha"}]} more""")
    check node["note"].getStr() == "a { b } c"
