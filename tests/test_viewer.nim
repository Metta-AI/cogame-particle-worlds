## The STATIC half of the viewer smoke (no browser). `tools/ci/viewer_smoke.mjs`
## is what proves the bundle really renders; this is what proves the chrome is
## the STARTER'S chrome plus one appended game block, that the transport rules
## hold, and that the beat CSS is exactly the set the sim emits.

import std/[json, os, strutils, unicode, unittest]
import crunchy/sha256
import ../src/mpe/[sim, broadcast, directives]
import ../tools/fixture_frame
import fixture

proc sha256Hex(text: string): string =
  for b in sha256(text):
    result.add(toHex(b, 2).toLowerAscii())

let
  page = sourceOf("client/replay_broadcast.html")
  chrome = sourceOf("client/chrome_common.js")
  core = sourceOf("client/broadcast_core.js")

const
  Banner = "particle-worlds additions to the inherited coworld-ctf chrome"
  ## The five beat kinds the sim emits, and the ONLY five the block styles.
  BeatKinds = ["roundstart", "firstword", "onpoint", "tag", "roundover"]
  ## Kinds the starter styled that particle worlds can never emit.
  DeadBeatKinds = ["kill", "steal", "return", "capture", "hillflip",
                   "hillhold", "tagout", "gamestart"]

suite "the broadcast chrome":

  test "the inherited transport, scorebug, feed and endcard are all present":
    check page.containsAll([
      "id=\"viewport\"", "id=\"stage\"", "id=\"board\"", "id=\"lightpool\"",
      "id=\"grain\"", "id=\"lockerroom\"", "id=\"chrome\"", "id=\"scorebug\"",
      "id=\"plates-l\"", "id=\"plates-r\"", "id=\"clock\"",
      "id=\"clock-time\"", "id=\"clock-caption\"", "id=\"bannerlane\"",
      "id=\"killfeed\"", "id=\"fpv\"", "id=\"povBadge\"", "id=\"mmwarn\"",
      "id=\"transport\"", "id=\"scrub\"", "id=\"momentum\"", "id=\"lulls\"",
      "id=\"scrub-fill\"", "id=\"scrub-win\"", "id=\"scrub-head\"",
      "id=\"speedchips\"", "id=\"ffwd-chip\"", "id=\"win-chip\"",
      "id=\"tick-clock\"", "id=\"endcard\""])

  test "the zoom bar and the minimap are GONE (a fixed arena drops them)":
    ## Markup, CSS and wiring alike. Comments naming what was dropped are
    ## deliberately allowed -- they are the record of the decision -- so the
    ## check runs over the code with the comment lines removed.
    var code = ""
    for line in page.splitLines():
      let trimmed = line.strip()
      if trimmed.startsWith("//") or trimmed.startsWith("/*") or
          trimmed.startsWith("*") or trimmed.startsWith("<!--"):
        continue
      code.add(line)
      code.add("\n")
    ## The WIRING goes with the panel, not just its markup: a fixed arena that
    ## keeps ctrl+wheel, the Safari gesture pair or a two-finger pinch still
    ## zooms a board that is always fitted, with no control left to undo it.
    for gone in ["id=\"viewpanel\"", "id=\"zoombar\"", "id=\"zoom-in\"",
                 "id=\"zoom-out\"", "id=\"zoom-slider\"", "id=\"zoom-read\"",
                 "id=\"minimap\"", "id=\"minimap-canvas\"",
                 "#viewpanel", "#zoombar", "#zoom-slider", "#zoom-read",
                 "attachMinimap(", "ZOOM_STEP", "SLIDER_TRAVEL",
                 "core.zoomAt(", "core.setZoom(", "core.panBy(",
                 "core.panByMap(", "'gesturestart'", "'gesturechange'",
                 "'gestureend'", "'wheel'"]:
      if gone in code:
        echo "still present: ", gone
      check gone notin code

  test "relayout owns --hudscale / --topband / --band on :root":
    check page.containsAll([
      "setProperty('--hudscale'", "setProperty('--topband'",
      "setProperty('--band'", "root.style.setProperty",
      "classList.toggle('tiny', boardW <= 620)"])
    ## The --hudscale clamp: chrome authored against a ~760 px reference board,
    ## clamped so a huge embed does not bloat it and a 360 px floor stays
    ## legible.
    check "Math.max(0.5, Math.min(1.6, boardW / 760))" in page

  test "the endcard stops at the transport band and every seek dismisses it":
    check "#endcard {" in page
    check "bottom: var(--band, 0px)" in page
    check "$('endcard').classList.remove('on')" in page

  test "no overlay sits inside the transport band":
    ## Every particle-worlds addition is positioned from the TOP band or inside
    ## the board region, never from the bottom, which is where the transport
    ## lives.
    for panel in ["#mpe-rail {", "#mpe-radio {", "#mpe-crypto {"]:
      check panel in page
      let start = page.find(panel)
      let body = page[start ..< page.find('}', start)]
      check "top:" in body
      check "bottom:" notin body

  test "the scorebug degrades under .tiny and .plate-name never collapses":
    ## The embedded featured-match iframe is ~360 px wide, so a policy name has
    ## to grow into whatever room the plate has and ellipsise only when it
    ## genuinely runs out -- never collapse to a bare ellipsis.
    check ".plate-name {" in page
    let rule = page[page.find(".plate-name {") ..<
      page.find('}', page.find(".plate-name {"))]
    check "flex: 1 1 auto" in rule
    check "min-width: 3.2em" in rule
    check "overflow: hidden" in rule
    check "text-overflow: ellipsis" in rule
    ## Under .tiny each plate keeps glyph + name + episode score: the round
    ## permille and the role word are hidden rather than allowed to overflow.
    check "#stage.tiny .plate .mpe-round," in page
    check "#stage.tiny .plate .mpe-lbl { display: none; }" in page
    ## And the two collapsing readouts.
    check "#stage.tiny #mpe-rail .rail-name { display: none; }" in page
    check "#stage.tiny #mpe-crypto .cy-h," in page

  test "the mark rail, the radio strip and the crypto panel are all there":
    check page.containsAll([
      "'mpe-rail'", "'mpe-radio'", "'mpe-crypto'",
      "#mpe-rail {", "#mpe-radio {", "#mpe-crypto {",
      "renderRail", "renderRadio", "renderCrypto",
      "rail-cover", "rad-sym", "cy-key"])
    ## Silence renders as an em dash, never as an empty cell.
    check "'\\u2014'" in page

  test "the game block is APPENDED under its banner, and there is only one":
    check Banner in page
    check page.count(Banner) == 1
    ## The starter's own appended PAINTBALL block is removed with the paintball
    ## mechanics, so the page carries exactly one game block.
    check "PaintballChrome" notin page
    check "PB_MODE" notin page
    check "PB_CTX" notin page
    ## The block installs through the SAME context object the starter's did.
    check "window.MpeChrome" in page
    check "MpeChrome.install(MPE_CTX)" in page
    ## And everything the block adds really is BELOW the banner.
    let below = page[page.find(Banner) .. ^1]
    for added in ["mpe-rail", "mpe-radio", "mpe-crypto", "mpeBeat",
                  "renderRail", "mpeEvent", "mpeFrame"]:
      check added in below

  test "the beat builder cannot be shadowed by the chrome alias block":
    ## The chrome alias block declares the shared builder with a HOISTED `var`,
    ## so a game-block function of the same name is silently swallowed by it and
    ## the scrubber ends up with unlabelled div markers that never seek
    ## (cogame-tandem, 2026-08-23). The game block's builder is mpeBeat.
    check "function mpeBeat(" in page
    let below = page[page.find(Banner) .. ^1]
    check "function markBeat(" notin below
    ## No identifier the game block defines may collide with the alias list.
    let aliasStart = page.find("MPE_CTX = {")
    let aliases = page[aliasStart ..< page.find("};", aliasStart)]
    var aliasNames: seq[string]
    for part in aliases.split(','):
      let pair = part.split(':')
      if pair.len == 2:
        let name = pair[0].strip()
        if name.len > 0 and name[0].isAlphaAscii():
          aliasNames.add(name)
    check aliasNames.len >= 8
    for name in aliasNames:
      check ("function " & name & "(") notin below
      check ("var " & name & " =") notin below

  test "every beat kind the sim emits has CSS, and no kind it does not":
    ## The block styles EXACTLY the five kinds `replays.nim` promotes to
    ## scrubber beats.
    let replays = sourceOf("src/mpe/replays.nim")
    var declared: seq[string]
    let listStart = replays.find("if scan.sim.config.numAgents > 0:")
    let list = replays[listStart ..< listStart + 400]
    for kind in BeatKinds:
      check ("\"" & kind & "\"") in list
      declared.add(kind)
    check declared.len == BeatKinds.len
    for kind in BeatKinds:
      check (".beat-marker." & kind) in page
    for kind in DeadBeatKinds:
      if (".beat-marker." & kind) in page:
        echo "dead beat CSS survives: ", kind
      check (".beat-marker." & kind) notin page
    ## Beats are labelled, clickable BUTTONS that seek.
    check "button.beat-marker {" in page
    check "document.createElement('button')" in page
    check "el.setAttribute('aria-label', label)" in page
    check "CTX.send('s:' + tick)" in page

  test "chrome_common.js is the starter's, and its sha256 is pinned":
    ## Copied byte-for-byte from coworld-ctf apart from the ONE wire identifier
    ## the generator emits. Not edited, not reformatted -- everything particle
    ## worlds adds lives in the appended game block.
    check chrome.count("window.MPE_WIRE") == 1
    check "CTF_WIRE" notin chrome
    check "window.ChromeCommon" in chrome
    for inherited in ["markBeat", "renderBeatMarkers", "ingestBeats",
                      "setVerdict"]:
      check inherited in chrome
    check chrome.sha256Hex() ==
      "44cfecde990a67d87872ab2cd6e1c8798e904c8685d7fa2e4ffa41256ea61d13"

  test "broadcast_core.js differs from the starter's only in MPE_WIRE":
    check core.count("window.MPE_WIRE") == 2
    check "CTF_WIRE" notin core
    check core.sha256Hex() ==
      "0b53e69704d238969098b05ec5fe0de8e1f751ff04ad624324687491f182fce0"

  test "no ctf_/CTF_/PB_ identifier survives in client/, replay-viewer/ or src/":
    var files: seq[string]
    for kind, path in walkDir(repoRoot() / "client", relative = false):
      if kind == pcFile and (path.endsWith(".js") or path.endsWith(".html")):
        files.add(path)
    for kind, path in walkDir(repoRoot() / "replay-viewer", relative = false):
      if kind == pcFile:
        files.add(path)
    for kind, path in walkDir(repoRoot() / "src" / "mpe", relative = false):
      if kind == pcFile:
        files.add(path)
    for path in walkFiles(repoRoot() / "src" / "*.nim"):
      files.add(path)
    check files.len > 20
    for path in files:
      let text = readFile(path)
      for banned in ["ctf_", "CTF_", "PB_"]:
        if banned in text:
          echo path, " contains ", banned
        check banned notin text

  test "the wire constants the chrome reads are the sim's own":
    check "window.MPE_WIRE={speeds:" in sourceOf("src/mpe/wire_constants.nim")
    check "grep -q '^window.MPE_WIRE={'" in
      sourceOf("Dockerfile.replay-viewer")

  test "the state JSON the renderer reads carries every readout it draws":
    var sim = seatedSim(fixtureConfig(@[modeCrypto]))
    let frame = sim.buildStateJson(
      newJArray(), playing = true, speed = 1, maxTick = 240, looping = false,
      transportEnabled = true, mismatchTick = -1, povSlot = -1)
    for key in ["\"round\"", "\"rounds\"", "\"mode\"", "\"turnTicks\"",
                "\"turn\"", "\"turns\"", "\"marks\"", "\"comm\"",
                "\"roles\"", "\"roundScores\"", "\"livePermille\"",
                "\"episodePermille\"", "\"bumps\"", "\"crypto\""]:
      check key in frame
    ## And the chrome really reads them.
    for key in ["s.marks", "s.comm", "s.crypto", "s.mode", "s.round"]:
      check key in page

  test "the worst-case renderer fixture loads the SHIPPED page and frame":
    ## Checklist item 15's fixture is only evidence if it runs the code that
    ## ships. This one boots dist/static-replay-viewer/index.html -- the real
    ## page, spliced with the real chrome_common.js -- with nothing replaced
    ## but the wasm shell, and feeds it a frame the SERVER built.
    let fixture = sourceOf("tools/ci/renderer_fixture.html")
    check "fetch('./index.html')" in fixture
    check "renderer_fixture_frame.json" in fixture
    check "window.MpeStaticReplay" in fixture      ## the one substitution
    check "data-replay-loaded" in fixture
    check "data-replay-error" in fixture
    ## The frame is regenerated from broadcast.buildStateJson here, so a
    ## committed frame that drifted away from the server (and would render as
    ## an empty page, measuring nothing) fails in this suite rather than
    ## passing silently in the browser.
    let committed = sourceOf("tools/ci/renderer_fixture_frame.json")
    check committed == worstCaseFramesText()
    let frame = parseJson(committed)
    ## And it is still the WORST case: a full-cap note on every seat, a
    ## non-silent symbol on all four particles, the crypto panel populated,
    ## every feed-row kind at once and four endcard cards.
    check frame["playing"]["directives"].len >= 4
    for record in frame["playing"]["directives"]:
      check record["note"].getStr().runeLen == MaxNoteRunes
    check frame["playing"]["comm"].len == 4
    for entry in frame["playing"]["comm"]:
      check entry["sym"].getStr().runeLen == 1
      check entry["sym"].getStr() != SymbolSilence
    check frame["playing"]["mode"].getStr() == $modeCrypto
    check frame["playing"]["crypto"]["beliefs"].len == 3
    check frame["playing"]["marks"].len == LandmarkCount
    var kinds: seq[string]
    for event in frame["playing"]["events"]:
      kinds.add(event["k"].getStr())
    for required in BeatKinds:
      check required in kinds
    check "word" in kinds
    check "decode" in kinds
    check frame["gameover"]["over"]["cards"].len == 4
    ## ci.yml ships both files next to the bundle, or the fetches 404.
    let ci = sourceOf(".github/workflows/ci.yml")
    check "renderer_fixture.html dist/static-replay-viewer" in ci
    check "renderer_fixture_frame.json" in ci

  test "the static replay shell keeps BOTH load signals":
    let shell = sourceOf("replay-viewer/static_replay.js")
    check "data-replay-loaded" in shell
    check "data-replay-error" in shell
    ## The load attribute goes up in the 'loaded' branch, which the Worker
    ## posts only AFTER the first frame has been drawn.
    check "message.type === 'loaded'" in shell
    ## And the Worker and the module are the matched pair coworld-ctf ships.
    let worker = sourceOf("replay-viewer/static_replay_worker.js")
    check "Module.onRuntimeInitialized" in worker
    check "importScripts('./wire_constants.js', './broadcast_core.js', " &
      "'./mpe_replay.js')" in worker
    let flags = sourceOf("replay-viewer/config.nims")
    check "MODULARIZE" notin flags
    check "EXPORT_NAME" notin flags
    check "_mpe_load_replay" in flags
    check "-s ENVIRONMENT=web,worker,node" in flags
    check "--preload-file" in flags
