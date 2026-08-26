## Shared test scaffolding: the ONE place a test builds a particle-worlds sim,
## so every test in this suite plays the same game the manifest declares rather
## than a hand-tuned variant of it.
##
## `fixtureConfig` mirrors `certification.game_config` in
## coworld_manifest_template.json; `variantConfig` mirrors the shipped variants.
## `tests/test_manifest.nim` asserts both against the manifest, so a config that
## drifts from the manifest fails there instead of quietly making every other
## test measure a different game.

import std/[json, os, strutils]
import ../src/mpe/sim

const
  FixtureSeed* = 679961
  FixtureSeats* = 4

proc repoRoot*(): string =
  currentSourcePath().parentDir().parentDir()

proc manifestJson*(): JsonNode =
  parseJson(readFile(repoRoot() / "coworld_manifest_template.json"))

proc baseConfig*(): GameConfig =
  ## The shipped defaults plus the four seats, which is what every variant and
  ## the certification fixture have in common.
  result = defaultGameConfig()
  result.seed = FixtureSeed
  result.numAgents = FixtureSeats
  result.minPlayers = FixtureSeats
  result.teams = 4
  result.cogsPerTeam = 1
  result.mapPath = "field"
  result.fullyObservable = true
  result.visionConeDeg = 180
  result.visionBubble = 4096
  result.accel = DefaultParticleAccel
  result.maxSpeed = DefaultParticleMaxSpeed
  result.frictionNum = DefaultParticleFrictionNum
  result.turnTicks = 108
  result.turnBudgetMs = 10_000
  result.attempt1Ms = 6000
  result.retryMs = 3000
  result.turnSpacingMs = 0
  result.showPlayerLabels = false
  result.fastMode = true
  result.slots = @[
    PlayerSlotConfig(hasTeam: true, team: Red, name: "P1", token: "t0"),
    PlayerSlotConfig(hasTeam: true, team: Blue, name: "P2", token: "t1"),
    PlayerSlotConfig(hasTeam: true, team: Green, name: "P3", token: "t2"),
    PlayerSlotConfig(hasTeam: true, team: Yellow, name: "P4", token: "t3")]

proc fixtureConfig*(rounds: seq[Mode] = @[
    modeSpread, modeDeceive, modeCrypto, modeTag]): GameConfig =
  ## The CERTIFICATION fixture: four scripted seats, 4 x 240 ticks, no LLM and
  ## no rate floor.
  result = baseConfig()
  result.rounds = rounds
  result.maxTicks = 240
  result.maxGames = 4
  result.wallClockBudgetSeconds = 180
  result.lobbyJoinTimeoutTicks = 1440
  result.startWaitTicks = 0
  result.gameOverTicks = 24

proc variantConfig*(rounds: seq[Mode]): GameConfig =
  ## A shipped VARIANT: 4 x 1080 ticks, the 9 s rate floor and the 690 s stop.
  result = baseConfig()
  result.rounds = rounds
  result.maxTicks = 1080
  result.maxGames = 4
  result.turnSpacingMs = DefaultParticleTurnSpacingMs
  result.wallClockBudgetSeconds = 690
  result.lobbyJoinTimeoutTicks = 2400
  result.startWaitTicks = 120
  result.gameOverTicks = 72

proc seatedSim*(config: GameConfig): SimServer =
  ## A sim with all four seats joined and the first round drawn.
  result = initSimServer(config)
  for i in 0 ..< min(FixtureSeats, config.slots.len):
    discard result.addPlayer(
      config.slots[i].name, i, config.slots[i].token)
  result.startGame()

proc reseat*(sim: var SimServer, config: GameConfig) =
  ## Re-seat the roster for the next round, exactly as the server's round switch
  ## does: resetToLobby empties the roster, the seats rejoin, startGame draws
  ## the round.
  sim.resetToLobby()
  for i in 0 ..< min(FixtureSeats, config.slots.len):
    discard sim.addPlayer(config.slots[i].name, i, config.slots[i].token)
  sim.startGame()

proc sourceOf*(rel: string): string =
  readFile(repoRoot() / rel)

proc containsAll*(text: string, needles: openArray[string]): bool =
  for needle in needles:
    if needle notin text:
      echo "MISSING: ", needle
      return false
  true
