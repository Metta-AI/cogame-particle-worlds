## The seeded round setup: the mark draw and its termination, the colour
## permutation, the role cycle, the crypto key, and the spawn ring. Everything
## here is re-derived by the wasm viewer rather than read out of the replay, so
## every one of these is a determinism invariant, not a nicety.

import std/[random, sets, unittest]
import ../src/mpe/sim
import fixture

suite "the field":

  test "the rejection sampler terminates and places four legal marks":
    ## 10 000 seeds. The sampler relaxes its spacing by 20 px every 400
    ## attempts and floors it at MinLandmarkSpacingPx, so it ALWAYS terminates;
    ## this is the proof, and it also measures how often the full 300 px
    ## spacing is achieved.
    var config = fixtureConfig()
    var sim = initSimServer(config)
    var wide = 0
    const trials = 10_000
    for seed in 0 ..< trials:
      sim.rng = initRand(seed * 7919 + 13)
      sim.beginRound(0)
      check sim.landmarks.len == LandmarkCount
      var far = true
      for i in 0 ..< sim.landmarks.len:
        check not sim.isWall(sim.landmarks[i].x, sim.landmarks[i].y)
        check sim.landmarks[i].x >= sim.config.landmarkMargin
        check sim.landmarks[i].y >= sim.config.landmarkMargin
        check sim.landmarks[i].x <= MapWidth - 1 - sim.config.landmarkMargin
        check sim.landmarks[i].y <= MapHeight - 1 - sim.config.landmarkMargin
        for j in i + 1 ..< sim.landmarks.len:
          let d2 = distSq(sim.landmarks[i].x, sim.landmarks[i].y,
                          sim.landmarks[j].x, sim.landmarks[j].y)
          check d2 >= MinLandmarkSpacingPx * MinLandmarkSpacingPx
          if d2 < sim.config.landmarkSpacingPx * sim.config.landmarkSpacingPx:
            far = false
      if far:
        inc wide
    echo "landmark draw: ", wide, "/", trials, " seeds kept the full ",
      sim.config.landmarkSpacingPx, " px spacing"
    check wide * 100 >= trials * 95        ## >= 95% keep the full spacing

  test "mark colours are a permutation of the four palette colours":
    var sim = initSimServer(fixtureConfig())
    for seed in 0 ..< 500:
      sim.rng = initRand(seed * 31 + 7)
      sim.beginRound(0)
      var seen: HashSet[int]
      for mark in sim.landmarks:
        check mark.colour >= 0
        check mark.colour < LandmarkCount
        seen.incl(mark.colour)
      check seen.len == LandmarkCount

  test "perm is a permutation and every seat holds every role index once":
    for seed in 0 ..< 2000:
      let perm = episodePerm(seed)
      var seen: HashSet[int]
      for value in perm:
        check value >= 0
        check value < 4
        seen.incl(value)
      check seen.len == 4
      for seat in 0 ..< 4:
        var held: HashSet[int]
        for round in 0 ..< 4:
          held.incl((perm[seat] + round) mod 4)
        check held.len == 4
      for round in 0 ..< 4:
        var holders: HashSet[int]
        for seat in 0 ..< 4:
          holders.incl((perm[seat] + round) mod 4)
        check holders.len == 4     ## one seat per role in every round

  test "keySymbols is four distinct symbols from A..H, redrawn every round":
    var config = fixtureConfig(@[modeCrypto, modeCrypto, modeCrypto, modeCrypto])
    var sim = initSimServer(config)
    var distinctKeys = 0
    var previous: array[4, int]
    for round in 0 ..< 400:
      sim.beginRound(round mod 4)
      var seen: HashSet[int]
      for colour in 0 ..< LandmarkCount:
        let symbol = sim.keySymbols[colour]
        check symbol >= 1
        check symbol <= SymbolAlphabet.len
        seen.incl(symbol)
      check seen.len == LandmarkCount
      if round > 0 and sim.keySymbols != previous:
        inc distinctKeys
      previous = sim.keySymbols
    check distinctKeys > 300      ## a fresh key nearly every round

  test "the key is empty outside crypto":
    var sim = initSimServer(fixtureConfig())
    for mode in [modeSpread, modeDeceive, modeTag]:
      sim.config.rounds = @[mode]
      sim.beginRound(0)
      for colour in 0 ..< LandmarkCount:
        check sim.keySymbols[colour] == 0

  test "the goal exists exactly in deceive and crypto":
    var sim = initSimServer(fixtureConfig())
    for mode in Mode:
      sim.config.rounds = @[mode]
      sim.beginRound(0)
      if mode in {modeDeceive, modeCrypto}:
        check sim.goalLandmark >= 0
        check sim.goalLandmark < LandmarkCount
        check sim.goalColour() >= 0
      else:
        check sim.goalLandmark == -1
        check sim.goalColour() == -1

  test "spawns are walkable, on the ring, and apart":
    var config = fixtureConfig()
    for seed in 0 ..< 200:
      config.seed = FixtureSeed + seed
      var sim = seatedSim(config)
      let (cx, cy) = centreOfField()
      for seat in 0 ..< 4:
        let (px, py) = sim.particleCentre(seat)
        check sim.isWalkable(px, py)
        let radius = sim.distanceBetween(seat, seat)
        check radius == 0                    ## the integer sqrt is exact at 0
        let d = distSq(px, py, cx, cy)
        ## nearestOpenCell may nudge a point a few pixels; the ring is 250 px.
        check d <= (sim.config.spawnRingPx + 40) *
          (sim.config.spawnRingPx + 40)
        check d >= (sim.config.spawnRingPx - 40) *
          (sim.config.spawnRingPx - 40)
      for a in 0 ..< 4:
        for b in a + 1 ..< 4:
          check sim.distanceBetween(a, b) >= 100

  test "the same seed reproduces every draw across a resetToLobby":
    var config = fixtureConfig()
    proc draws(config: GameConfig): string =
      var sim = seatedSim(config)
      for round in 0 ..< 4:
        result.add($sim.mode & "|" & $sim.goalLandmark & "|")
        for mark in sim.landmarks:
          result.add($mark.x & "," & $mark.y & "," & $mark.colour & ";")
        for colour in 0 ..< LandmarkCount:
          result.add($sim.keySymbols[colour] & ",")
        for seat in 0 ..< 4:
          result.add($sim.roleIndex[seat] & "," &
            $sim.players[seat].x & "," & $sim.players[seat].y & ";")
        sim.roundIndex = round + 1
        sim.reseat(config)
      result
    let first = draws(config)
    check first == draws(config)
    config.seed = FixtureSeed + 1
    check first != draws(config)

  test "role names are the design's, per mode and role index":
    check roleName(modeSpread, 0) == "cooperator"
    check roleName(modeSpread, 3) == "cooperator"
    check roleName(modeDeceive, 0) == "adversary"
    check roleName(modeDeceive, 1) == "good"
    check roleName(modeCrypto, 0) == "speaker"
    check roleName(modeCrypto, 1) == "listener"
    check roleName(modeCrypto, 2) == "eavesdropper"
    check roleName(modeCrypto, 3) == "eavesdropper"
    check roleName(modeTag, 0) == "evader"
    check roleName(modeTag, 2) == "pursuer"

  test "the symbol alphabet round-trips and rejects everything else":
    check symbolText(0) == SymbolSilence
    check symbolIndex(SymbolSilence) == 0
    for i in 1 .. SymbolAlphabet.len:
      check symbolIndex(symbolText(i)) == i
    check symbolIndex("Z") == 0
    check symbolIndex("") == 0
    check symbolIndex("AB") == 0
    check symbolText(99) == SymbolSilence
    check symbolText(-1) == SymbolSilence
