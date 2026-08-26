## Startup contract. `/bin/particle-worlds` must fail LOUDLY and CLEANLY on a
## missing or unparseable config (no traceback, non-zero exit), and the seed
## must be randomised BEFORE `config.update` when it is unpinned -- because
## every seed-derived draw (the mode schedule, the role permutation, the mark
## layout, the colour permutation, the goal and the key) is resolved during
## that call.

import std/[os, osproc, strutils, unittest]
import ../src/mpe/sim
import fixture

const LegacyFixedSeed = 0xA6019
  ## The starter's compiled-in default, which doubles as the "nobody chose a
  ## seed" sentinel.

suite "startup":

  test "a pinned seed reproduces every seed-derived draw":
    proc draw(seed: int): string =
      var config = fixtureConfig()
      config.seed = seed
      var sim = seatedSim(config)
      result = $sim.mode & "|" & $sim.goalLandmark & "|"
      for value in sim.perm:
        result.add($value & ",")
      for mark in sim.landmarks:
        result.add($mark.x & "," & $mark.y & "," & $mark.colour & ";")
    check draw(FixtureSeed) == draw(FixtureSeed)
    check draw(FixtureSeed) != draw(FixtureSeed + 1)

  test "the seed is randomised BEFORE config.update when it is unpinned":
    ## The entrypoint's own rule, asserted over its source: the randomisation
    ## has to land before the parse, or every process would draw the same
    ## episode from the same unpinned config.
    let source = sourceOf("src/particle_worlds.nim")
    let randomise = source.find("config.seed = randomSeed()")
    let update = source.find("config.update(stripUnpinnedSeed(")
    check randomise > 0
    check update > randomise
    check "seedPinned(runtimeConfig.config)" in source
    check ("LegacyFixedSeed = " & "0xA6019") in source
    check "urandom(buf)" in source

  test "the role permutation is a pure function of the config seed":
    ## Not of the live RNG stream: a later round drawing a different number of
    ## samples must not shift it.
    for seed in [0, 1, FixtureSeed, 2_147_483_647]:
      check episodePerm(seed) == episodePerm(seed)
    check episodePerm(FixtureSeed) != episodePerm(FixtureSeed + 1)

  test "the entrypoint refuses a missing config with a clean message":
    let binary = getEnv("PW_GAME_BIN")
    if binary.len == 0 or not fileExists(binary):
      ## The Nim test job does not build the image; `tools/ci/docker_smoke.sh`
      ## asserts both entrypoints exist and run inside it, and the release
      ## workflow's certify step runs the real container. This branch keeps the
      ## test meaningful where the binary IS available (a local run that sets
      ## PW_GAME_BIN) without pretending to have tested it where it is not.
      echo "PW_GAME_BIN not set; the container smoke covers this end to end"
      skip()
    else:
      putEnv("COGAME_CONFIG_URI", "file:///nope/nope.json")
      let (output, code) = execCmdEx(binary, options = {poStdErrToStdOut})
      delEnv("COGAME_CONFIG_URI")
      check code != 0
      check "Traceback" notin output
      check output.len > 0

  test "config.update rejects an unparseable config with MpeError":
    var config = fixtureConfig()
    expect MpeError:
      config.update("this is not json")
    var another = fixtureConfig()
    expect MpeError:
      another.update("""{"turnTicks": "not an integer"}""")
    var third = fixtureConfig()
    expect MpeError:
      third.update("""{"rounds": ["spread", "nonsense"]}""")
    var fourth = fixtureConfig()
    expect MpeError:
      fourth.update("""{"mapPath": "arena"}""")   ## 4 teams, 2-team map

  test "both entrypoints exist in the tree and are what the image builds":
    check fileExists(repoRoot() / "src" / "particle_worlds.nim")
    check fileExists(repoRoot() / "src" / "particle_worlds_player.nim")
    let dockerfile = sourceOf("Dockerfile")
    check "src/particle_worlds.nim" in dockerfile
    check "src/particle_worlds_player.nim" in dockerfile
    check "/bin/particle-worlds\n" in dockerfile or
      "/bin/particle-worlds " in dockerfile
    check "CMD [\"/bin/particle-worlds\"]" in dockerfile
    ## The smoke asserts them inside the image; SMOKE_SEATS cross-checks the
    ## manifest's own num_agents.
    let smoke = sourceOf("tools/ci/docker_smoke.sh")
    check "/bin/particle-worlds" in smoke
    check "SMOKE_SEATS:-4" in smoke

  test "the player registers with a legal blob and defaults to drifter":
    let source = sourceOf("src/particle_worlds_player.nim")
    check "\"type\": \"register\"" in source
    check "COWORLD_PLAYER_WS_URL" in source
    check "COGAMES_ENGINE_WS_URL" in source
    check "PLAYER_PROMPT" in source
    check "PLAYER_SCRIPTED" in source
    check "PLAYER_POLICY_LABEL" in source
    check "else: \"drifter\"" in source
    ## Bounded dialling, re-sent registration, and exit 0 on a dead socket
    ## (the raid 0.1.3 scar: whisky's receiveMessage RAISES on a close frame
    ## and the game's quit(0) can outrun the flushed frame).
    check "ConnectAttempts = 240" in source
    check "RegistrationResends = 10" in source
    check "except CatchableError" in source
    check "quit(0)" in source
