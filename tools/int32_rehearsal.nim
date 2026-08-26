## A 32-BIT REHEARSAL of the wasm32 replay-runtime path, runnable without emsdk.
##
##   nim c --cpu:i386 --passC:-m32 --passL:-m32 -d:release --path:src \
##     -o:/tmp/int32_rehearsal tools/int32_rehearsal.nim
##   /tmp/int32_rehearsal dist/smoke/replay.json
##
## Why: the shipped replay viewer is built `--cpu:wasm32`, where Nim's `int` is
## 32 BITS, and a release build keeps overflow checks (only `-d:danger` drops
## them). Every 64-bit native test can pass while the browser bundle dies on
## `initialize replay runtime: over- or underflow` before it draws a frame --
## which is exactly what a `low(int32)` tick sentinel and a `seed * 2 + 1`
## derivation each did once. `--cpu:i386` gives the same 32-bit `int` on a
## machine that has no emsdk, so the trap happens here in seconds instead of in
## a CI job twelve minutes later.
##
## It runs the WHOLE timeline: the runtime init, the full precompute scan, a
## packet build at five points across the episode (which crosses every round
## switch), and three thousand presentation frames -- and it fails on a hash
## mismatch as well as on an overflow.
##
## `ci.yml`'s `wasm-viewer` job is still the authority: it opens the real
## emitted module in a real browser. This is the cheap rehearsal, not a
## replacement.
import std/[json, os]
import ../src/mpe/[replays, replay_runtime, broadcast, global]
let data = parseReplayBytes(readFile(paramStr(1)))
echo "int bits: ", sizeof(int) * 8
var init = initReplayRuntime(data, mismatchQuit = false,
                             gameEventLoggingEnabled = false)
var
  game = move(init.sim)
  player = move(init.player)
  tracker = move(init.tracker)
  viewer = initGlobalViewerState()
  frames = 0
player.advanceReplayScan(1_000_000)
echo "scan complete=", player.scanComplete(), " beats=", player.beatEvents.len,
  " lead=", player.leadSeries.len, " lulls=", player.lullSpans.len
let maxTick = player.replayMaxTick()
for fraction in [0, 25, 50, 75, 99]:
  let target = maxTick * fraction div 100
  discard player.advanceReplayFrame(game, tracker, @[target], @[])
  var seekViewer: GlobalViewerState
  let seekPacket = game.buildReplayViewerPacket(
    player, viewer, seekViewer, newJArray())
  doAssert seekPacket.len > 0
  viewer = seekViewer
  echo "seek ", fraction, "% -> tick ", game.tickCount, " round ",
    game.roundIndex, " ", game.mode
while frames < 3000:
  let events = player.advanceReplayFrame(game, tracker, @[], @[])
  var nextViewer: GlobalViewerState
  let packet = game.buildReplayViewerPacket(player, viewer, nextViewer, events)
  doAssert packet.len > 0
  viewer = nextViewer
  inc frames
  if player.hashMismatchTick >= 0:
    quit("MISMATCH at tick " & $player.hashMismatchTick, 1)
echo "ok frames=", frames, " tick=", game.tickCount,
  " mismatch=", player.hashMismatchTick
