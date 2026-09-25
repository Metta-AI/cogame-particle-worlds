## The sim's shared vocabulary: the core constants (including GameVersion
## and its changelog), the gameplay/wire types, the process-wide map
## dimension globals, and the pure helpers both sides of every seam need —
## split out of sim.nim (docs/plans/2026-08-01-sim-split.md) so the leaf
## modules (rig_art, arena, map_art, sim_config, sim_state, roster) share
## them without importing gameplay. Leaf modules may declare their own
## section-local consts/types; anything two modules need lives here.
##
## MOVED VERBATIM from sim.nim: SimServer and friends are flatty-serialized
## POSITIONALLY into replay keyframes, so declaration/field order here is
## wire format — reorder nothing without a GameVersion bump.

import
  std/[math, random],
  bitworld/pixelfonts,
  bitworld/server,
  pixie

const
  GameName* = "particle-worlds"
  GameVersion* = "2"   ## GV2: the wall-clock `deadline` stop is RECORDED.
    ## The engine's 690 s stop banks the round in progress and finishes the
    ## game from outside `step`, and the same loop iteration records that
    ## state's `gameHash` — so the tick could not be re-derived, and every
    ## `deadline` replay mismatched on its last hash and stayed `Playing` in
    ## the viewer forever. The stop is now written as a `stop` control record
    ## and applied at playback through the same `applyWallClockStop` the server
    ## calls (docs/PROTOCOL.md §Chat records). The number changes because a
    ## GV1 viewer would LOAD a GV2 recording and re-simulate it wrong at the
    ## stop tick, which is exactly what a version is for; nothing in
    ## `gameHash`, the integer motion model or the seeded draw order moved.
    ##
    ## GV1 (particle worlds): the FIRST version of this game.
    ## Forked from `Metta-AI/coworld-ctf` at its GV44 and renumbered from 1,
    ## because nothing in the starter's GameVersion history describes a
    ## particle-worlds episode: no ctf replay re-simulates here and none should
    ## be expected to. What the fork inherits, byte for byte, is the 24 Hz tick
    ## loop, the Sprite v1 button-mask input, the fixed-point integer motion
    ## model (`motionScale` 256, the `carryX`/`carryY` sub-pixel accumulators,
    ## `applyMomentumAxis`'s wall slide and `bouncePlayers`' restitution), the
    ## per-pixel wall mask, the `mapSpec` round trip, the replay codec with its
    ## per-tick `gameHash` chain and its keyframe/lull machinery, the seat/cog
    ## split and the two name spaces, the server-side decision layer and the
    ## `COGAME_*` runtime contract.
    ##
    ## What is NEW at GV1: the four-scenario round schedule and its seeded
    ## role permutation; four seeded landmarks with a seeded colour
    ## permutation; the nine-value symbol radio (recorded and rendered, and
    ## deliberately EXCLUDED from `gameHash` — nothing a commander says may
    ## move the hash chain); damp-both-axes-then-drive motion at
    ## `frictionNum` 192 (MPE's `damping = 0.25`); the four per-tick scoring
    ## terms and the round bank; the public belief state
    ## (`nearestMark`/`settledTicks`) and its `onpoint`/`decode` detectors; and
    ## `checkFieldInvariants`, the sim guard the tick loop turns into
    ## `fault`/`sim_fault`.
    ##
    ## What is GONE at GV1, deleted rather than disabled: every weapon and its
    ## art, every pickup, the heart objective, floor paint, King of the Hill,
    ## hit points, lives, respawns and kills. Nothing in particle worlds can be
    ## destroyed.
  ReplayFps* = 24
  DefaultMapPath* = "arena"
  DarkBgPath* = "data/darkbg.aseprite"
  SpriteSheetAsepritePath* = "data/spritesheet.aseprite"
  SpriteSize* = 12
  CrewSpriteSize* = 16
  CrewSpriteVariants* = 8
  ## HD top-down soldier: the real Cogs-vs-Clips cog, one tinted master per team
  ## (soldier_red/blue.png, facing SOUTH, smile visor visible) plus the shared
  ## particle-worlds gun master (paintgun.png, muzzle east). Body and gun are mounted
  ## as ONE rigid unit — the gun held in FRONT of the face, both pointing the
  ## same way — and pre-rotated together through SoldierRotations aim steps:
  ## the cog looks where it aims. The canvas is larger than the body only so
  ## the extended gun never clips as the unit rotates. Emitted through the
  ## existing player sprite id pool (16 ids per color) — this replaces the
  ## flat 8-variant + h-flip crew.
  SoldierRotations* = 16      ## pre-rendered aim steps (16 brads apart).
  SoldierCanvas* = 72         ## px square sprite canvas (fits the swinging gun).
  SoldierBodyPx* = 34         ## cog body target size on the map (full-body unit).
  GunLengthPx* = 34           ## top-down gun master length on the map (stock-tip to
                              ## muzzle, along the aim ray).
  GunGripPx* = -13            ## gun stock-tip offset from the body center, along
                              ## aim (negative = stock sits behind the hub so the
                              ## barrel reaches out front, marker straddling the cog).
  GunRightPx* = 10            ## the marker is held at the cog's RIGHT: barrel
                              ## centerline offset this far off the aim ray, toward
                              ## the head's right (screen +y when facing +x/east).
                              ## Enough to clear the head silhouette and read as a
                              ## distinct held object, without floating far off.
  GunGlowRadius* = 0.6        ## px blur (master-frame): tiny, so the rim is CRISP —
                              ## an outline stroke, not a soft glow.
  GunGlowSpread* = 1.0        ## px the silhouette expands before blurring — this is
                              ## the outline WIDTH that sticks out past the gun edge.
  GunGlowAlpha* = 95'u8       ## faint warm outline (0..255), reads as a subtle stroke.
  SprayHeldLengthPx* = 22     ## the held spray can's length on the map, along the
                              ## aim ray. Shorter than the marker (GunLengthPx):
                              ## a can is a fistful, and the silhouette difference
                              ## is what tells a viewer WHICH weapon a cog holds.
  SprayHeldGripPx* = -6       ## can tail offset from the body center along aim.
                              ## Less negative than GunGripPx so the short can
                              ## sits IN the fist rather than straddling the hub.
  CollisionW* = 1
  CollisionH* = 1
  PlayerHalf* = 6             ## half-extent of the solid player footprint, in px.
  ## Draw offset for the soldier: place the canvas so its center lands on
  ## the player position (canvas center = the body pivot).
  SoldierDrawOff* = SoldierCanvas div 2
  MotionScale* = 256
  Accel* = 76
  FrictionNum* = 144
  FrictionDen* = 256
  MaxSpeed* = 704
  StopThreshold* = 8
  MovementSlideMaxScan* = 3
  PlayerSolidSpan* = 2 * PlayerHalf  ## centers this close (Chebyshev) means
                                     ## two player footprints overlap.
  PlayerBouncePct* = 40       ## restitution of player-player collisions, in
                              ## percent: 0 = a dead-stop shove, 100 = a
                              ## perfectly elastic billiard bounce.
  TargetFps* = 24
  PlaybackSpeeds* = [1, 2, 3, 4, 8, 16]
    ## Replay/live playback speed steps (as multiples of real time). Lives in
    ## sim (not replays) so every layer that must agree with the top speed —
    ## the transport keymap, global.nim's cog-drive smoothing window, the JS
    ## clients' wire constants — derives from ONE table.
  SpaceColor* = 0'u8
  TintColor* = 3'u8
  ShadeTintColor* = 9'u8
  OutlineColor* = 0'u8

  # MPE tuning defaults (RULES.md). Second-based values convert at 24 ticks/sec.
  Lives* = 3
  HitPoints* = 3              ## hits to kill: each shot removes one hit point.
  RespawnTicks* = 72          ## ~3s before respawning at home.
  GunRange* = 1050            ## px, the SMALL generated map's field width
                              ## (round(1235 * 0.85)) — the ONE fixed gun
                              ## range every map def ships (GV34): map-wide
                              ## only on the smallest field, so on larger
                              ## maps paint falls short and closing distance
                              ## matters. A league config can still override
                              ## it per game (config gunRange).
  AimJitterCentralZ* = 1.2815516  ## Phi^-1(0.90): 80% of a Gaussian lies
                              ## within +-z*sigma. The released-shot jitter's
                              ## sigma is asin((PlayerHalf + BulletHalfWidth)
                              ## / gunRange) / this, which is exactly "a
                              ## fully visible body at max range is hit 80%
                              ## of the time" — the +-14px acceptance window
                              ## the corridor gives a centered silhouette,
                              ## spanned by 1.28 sigma of angular error at
                              ## gunRange px out (GV34). Derived from the
                              ## LIVE config.gunRange so a range override
                              ## keeps the calibration; at the stock 1050 px,
                              ## sigma is ~0.6 degrees, and a fully visible
                              ## body is hit ~99% at half range, ~100% inside
                              ## a third.
  ExposureSampleStep* = 3     ## px between silhouette line-of-sight samples
                              ## across a target's body (±PlayerHalf): only
                              ## the exposed part of a body can be hit.
  BulletHalfWidth* = 8.0      ## the bullet corridor half-width: a shot travels
                              ## along the facing ray and hits the FIRST player
                              ## whose footprint crosses it.
  FireCooldownTicks* = 12     ## ~0.5s between shots.
  FireWindupTicks* = 5        ## ~0.2s from trigger pull to the shot; aim locks
                              ## at the pull, so a peeking target can duck back.
  ShotFxTicks* = 12           ## ~0.5s a shot tracer stays visible (cosmetic only).
  HitFlashTicks* = 8          ## ~0.33s the struck-target flash rings a victim
                              ## in the spectator view (cosmetic only).
  SplatterFxTicks* = 120      ## ~5s a death splatter stays visible (cosmetic only).
  HitFxTicks* = 34            ## ~1.4s a non-fatal hit's paint splat stays visible.
  StainChancePct* = 100       ## % of paint landing on TERRAIN that dries into a
                              ## permanent stain. 100 = every miss marks the wall
                              ## it hit, so the lanes players actually run get
                              ## visibly repainted over a match; lower it to thin
                              ## the buildup. Cosmetic only, never in gameHash.
  StainSeatDepth* = 6         ## px a wall stain is pushed past the wall's
                              ## leading edge so the masked blot lands on the
                              ## face rather than half-overhanging the floor.
  StainMaxCount* = 1200       ## most dried stains kept for a match. A 5000-tick
                              ## game with 16 cogs firing every FireCooldownTicks
                              ## tops out near 6600 shots, so this caps unbounded
                              ## growth (and the wire) while still reading as
                              ## "this corridor is covered in paint". Oldest wins:
                              ## once full, new paint stops sticking rather than
                              ## evicting the history the viewer already saw.
  DamageFxTicks* = 26         ## ~1.1s a floating "-1" damage pop rises and fades
                              ## after a hit (cosmetic only, never in gameHash).
  KillFxTicks* = 44           ## ~1.8s a floating "KO" kill marker rises and fades
                              ## after a death (cosmetic only, never in gameHash).
  CarrierSpeedPct* = 70       ## carrier moves at 70% speed.
  AimBradsTurn* = 256         ## aim angle units per full turn (binary radians).
  AimTurnRate* = 5            ## brads/tick a held rotate button turns the aim
                              ## (~7 deg/tick; a full turn takes ~2.1s).
  VisionConeDeg* = 60         ## vision cone half-angle around the aim angle.
  VisionBubble* = 90          ## omnidirectional vision radius in px.

  FovCellSize* = 8            ## fog-of-war visibility grid cell size in px.

  StartWaitTicks* = 5 * TargetFps
  GameOverTicks* = 360
  MaxTicks* = 7_200  ## a 5:00 game at 24 ticks/sec; 0 = no limit.
  BarrageStartSec* = 30       ## grenade-barrage default: the barrage latches
                              ## on with this many clock seconds remaining
                              ## (config barrageStartSec; the mode itself
                              ## arms via barrageMaxPerSec > 0). On the
                              ## default 5:00 clock that is 4:30 elapsed.
  BarrageSaturateSec* = 30    ## grenade-barrage default: seconds from the
                              ## latch to full saturation (whole board at
                              ## barrageMaxPerSec). Start 30 + saturate 30
                              ## = fully saturated exactly at 5:00 on the
                              ## default clock.
  BarrageStartPerSec* = 4     ## grenade-barrage default: launch rate at the
                              ## latch, grenades/second along the map edges.
  BarrageAbsMaxPerSec* = 50   ## config ceiling on barrageMaxPerSec: keeps
                              ## the concurrent airborne count (rate x the
                              ## ~10-tick flight) inside the drawn-orb pool.
  BarrageEdgeBandPx* = 40     ## the strip of map inside every edge the
                              ## barrage targets at latch; the band deepens
                              ## linearly to full coverage as the ramp
                              ## completes.
  MaxGames* = 0  ## 0 = no limit.
  MaxPlayers* = 32
  MinPlayers* = 16

  WinReward* = 1              ## each winner scores +1 on capture or wipe.
  LossReward* = -1            ## each loser scores -1 on capture or wipe.
  ClassicScoring* = "classic" ## winner +1 per losing team, each loser -1.
  PotScoring* = "pot"         ## every team antes one point; the winning team
                              ## takes the whole pot and the losing teams
                              ## split the forfeit (see potScoring below).
  TimeoutReward* = -1         ## EVERY player scores -1 on a time-limit draw
                              ## (GameVersion 21): stalling out the clock is
                              ## never better than losing, for either side.

  # Achievement ids exported per slot in results.json (the platform's
  # achievement catalog in the coworld manifest uses the same ids). All are
  # WIN-GATED: only slots on a game's winning team can earn them, so an idle
  # policy cannot farm pacifist/spotless. Analysis-only: evaluation reads the
  # analysis counters and writes RewardAccount.earnedAchievements, none of
  # which enters gameHash — replays and gameplay are untouched.
  AchievementPacifist* = "pacifist"    ## won without a single attack (gun,
                                       ## grenade, or spray) by ANY cog of the
                                       ## winning team.
  AchievementSpotless* = "spotless"    ## won without any cog of the team
                                       ## taking damage — shield-absorbed hits
                                       ## still count as damage taken.
  AchievementAlmost* = "almost"        ## whole winning team finished with
                                       ## fewer than AlmostTeamHp hp of life
                                       ## budget (living hp + respawns owed).
  AchievementGrenadier* = "grenadier"  ## won with at least GrenadierPct of
                                       ## the team's damage dealt (summed over its
                                       ## cogs) coming from grenades,
                                       ## and more than zero dealt.
  GrenadierPct* = 80          ## `grenadier` threshold, percent of damage dealt.
  AchievementRambo* = "rambo"          ## one cog killed >= RamboKills cogs in a
                                       ## single life (between spawns).
  AchievementMedic* = "medic"          ## one cog took >= MedicHeals med kits in
                                       ## a single life.
  AchievementSniper* = "sniper"        ## every point of the team's damage
                                       ## came from the inherited gun.
  AchievementBanksy* = "banksy"        ## >= BanksyPct of the team's damage
                                       ## came from spray paint.
  AchievementPack* = "pack"            ## EVERY cog of the team spent
                                       ## >= PackPct of its alive ticks with
                                       ## >= PackMates teammates inside a circle
                                       ## of PackAreaPct of the map's area.
  AchievementPitMaster* = "pit-master" ## >= PitMasterPct of the team's
                                       ## damage was dealt while standing in a
                                       ## trench/pit.
  AchievementHeist* = "heist"          ## the win came from carrying the
                                       ## enemy heart home and the team
                                       ## killed nobody.
  AchievementSilent* = "silent"        ## no cog of the team shouted all game.
  AchievementAssassin* = "assassin"    ## one cog made >= AssassinKills kill
                                       ## shots (gun or grenade, never spray)
                                       ## on cogs it had not damaged before
                                       ## in that victim's life.
  AchievementLucky* = "lucky"          ## one cog was caught in >= LuckyBlasts
                                       ## grenade blasts this game and walked
                                       ## away from every one of them.
  AssassinKills* = 10         ## `assassin`: first-touch kill shots in a game.
  LuckyBlasts* = 5            ## `lucky`: grenade blasts survived in a game.
  RamboKills* = 9             ## `rambo`: kills in one life, "more than 8".
  MedicHeals* = 4             ## `medic`: med kits in one life.
  BanksyPct* = 90             ## `banksy` threshold, percent of damage dealt.
  PitMasterPct* = 90          ## `pit-master` threshold, percent of damage dealt.
  PackPct* = 90               ## `pack`: percent of a cog's alive ticks.
  PackMates* = 2              ## `pack`: teammates that must be within range.
  PackAreaPct* = 5            ## `pack`: the circle's area as a percent of the
                              ## map's area; radius² = area / π, integer math.
  AlmostTeamHp* = 2           ## `almost` threshold: the winning team's life
                              ## budget — living cogs' hp plus a full hp bar
                              ## per respawn still owed — is strictly below
                              ## this when the game ends: one cog, one hit
                              ## from losing, and nobody coming back.

  FlagPickupRange* = 34       ## touch radius to steal the enemy flag: STAND ON
                              ## THE PEDESTAL AND THE HEART IS YOURS (GV42).
                              ## The grab radius is deliberately keyed to the
                              ## art a player aims at, not to a bare point.
                              ## The planted heart is drawn 60px across
                              ## (PlantedFlagW) on a 96px pedestal disc
                              ## (PedestalCoverSize), so 30px is the drawn
                              ## heart's own half-extent: anywhere a player
                              ## can see heart pixels under their feet now
                              ## grabs. The old 12px was a quarter of the
                              ## pedestal and a fifth of the heart — it asked
                              ## for the exact pinpoint center of a big
                              ## target, so humans and policies alike stood
                              ## visibly ON the heart and did not pick it up
                              ## (the 2026-08-08 sprite-center fix removed a
                              ## 28px OFFSET; this removes the remaining
                              ## precision demand). The +4 past the heart's
                              ## half-extent covers the body half-extent
                              ## (PlayerHalf = 6) partway, so a footprint
                              ## overlapping the art counts as a touch. The
                              ## radius stays well inside the pedestal's own
                              ## protected spawn pocket on EVERY size class —
                              ## the tightest is "small", whose 0.85 factor
                              ## puts the pocket half-width at 60px (70 on
                              ## standard) — so a grab never reaches through
                              ## a wall, and an attacker still has to enter
                              ## the pocket to steal. Unlike the field, the
                              ## heart and pedestal art never scale, so the
                              ## art-derived radius must not either.
  CaptureZoneWidth* = 40      ## width of each home-edge capture zone.
  PedestalCoverSize* = 96     ## px footprint the flag-home pedestal art covers.

  ClassicHomeDepth* = 700     ## the historical home-anchor depth permille:
                              ## the base 30% of the way in from its edge.
  HomeDepthMin* = 400         ## depth bounds. Below the floor the bases
  HomeDepthMax* = 800         ## crowd the center; above it they clip the
                              ## border.
  EndzoneRadiusMin* = 90      ## compact-endzone radius bounds. The floor
  EndzoneRadiusMax* = 220     ## keeps the pedestal art and its endzone pits
                              ## inside the zone; the ceiling keeps the two
                              ## zones clear of the center ring ON THE
                              ## STANDARD 1235-WIDE FIELD — wider boards get
                              ## a proportionally larger ceiling, see
                              ## maxEndzoneRadius.
  EndzoneWallMargin* = 6      ## px of protected floor past the scoring ring,
                              ## the compact echo of the classic column's
                              ## 210-clear vs 206-threshold gap.

  GrenadeSpawnInset* = 40     ## corner grenade spawn inset from the border.
  GrenadePickupRange* = 12    ## touch radius to pick a grenade up.
  GrenadeRespawnTicks* = 5 * ReplayFps  ## a taken corner refills after 5s.
  GrenadeMinRange* = 30       ## a tap's distance: inside the blast radius,
                              ## so a panicked drop can hurt the thrower.
  GrenadeChargeTicks* = 24    ## hold this long for a full-strength throw.
  GrenadeFlightMultiple* = 2  ## release-to-burst = this many shot windups,
                              ## REGARDLESS of distance: a grenade is a snap
                              ## weapon, not a mortar shell you can stroll
                              ## away from. (Was 6 px/tick of flight — a
                              ## full-range lob hung airborne ~41 ticks.)
  GrenadeBlastRadius* = 52    ## everyone whose SOLID BODY BOX (±PlayerHalf)
                              ## touches this circle takes damage — a body
                              ## test, not a position-point test (GV31), so
                              ## on-axis reach is 52 + PlayerHalf = 58 px.
                              ## (GameVersion 17: 40 -> 52, +30%.)
  GrenadeDamage* = 2          ## hit points removed by one blast, for a
                              ## victim standing outside any trench.
  GrenadeTrenchDamage* = 6    ## a blast that lands in the SAME trench as its
                              ## victim: the pit traps the blast, amplifying it.
  GrenadeTrenchSplashDamage* = 1  ## a victim in a trench, hit by a blast that
                              ## landed elsewhere (open field or another
                              ## trench): the pit mostly shields them.
  BlastFxTicks* = 12          ## cosmetic blast flash duration in ticks.

  MedKitPickupRange* = 12     ## touch radius to pick a med kit up.
  MedKitRespawnTicks* = 30 * ReplayFps  ## a taken kit refills after 30s.
  SprayPaintSpawnInset* = GrenadeSpawnInset
  SprayPaintPickupRange* = 12  ## touch radius to pick a spray can up.
  SprayPaintRespawnTicks* = 30 * ReplayFps
  SprayPaintSquare* = SoldierBodyPx  ## one "square": a cog body length.
  SprayPaintFxReach* = 4 * SprayPaintSquare
                              ## how far the DRAWN plume spans, and the span
                              ## its puffs are sized against. This is art
                              ## geometry, not damage: the mist is a chain of
                              ## round puffs drawn oversize so they merge
                              ## (SprayPuffOverlap), so its outermost pixel
                              ## lands well past this. The damage reach below
                              ## is set to cover that overhang — see
                              ## test_spraypaint's containment check, which is
                              ## what keeps the two in step if either moves.
  SprayPaintFxMaxWidth* = 2 * SprayPaintSquare
                              ## the drawn plume's width at SprayPaintFxReach.
  SprayPaintReach* = 5 * SprayPaintSquare  ## forward cone reach: 5 squares
                              ## (GameVersion 30, was 4). The 5th square is
                              ## not extra range for its own sake — it is
                              ## exactly what it takes for the damage cone to
                              ## cover the tip of the plume the game draws, so
                              ## a cog the paint engulfs cannot walk away
                              ## clean.
  SprayPaintMaxWidth* = 5 * SprayPaintSquare div 2  ## cone width AT max reach:
                              ## 2.5 squares, which holds the half-angle at
                              ## atan(1/4) ~ 14.0 degrees everywhere along the
                              ## reach as the reach grew. The cone widens
                              ## linearly from the muzzle.
  SprayPaintBodyRadius* = SoldierBodyPx div 2
                              ## the sprayed cog's own half-width, added to the
                              ## cone on every side (GameVersion 30). Reach and
                              ## width above describe the cone's CENTERLINE
                              ## geometry, and a victim used to be tested as a
                              ## bare point (CollisionW is 1px) — so paint could
                              ## visibly engulf a 34px body that took no damage,
                              ## worst of all point-blank, where the centerline
                              ## cone is narrower than the cog it covers (10px
                              ## to each side at 40px out). Spraying a body now
                              ## hits it: the test is the cog's DISC against the
                              ## cone, not its center point.
  SprayPaintDamage* = 3        ## hit points removed by one cone touch:
                              ## instantly lethal to a bare cog (3 hp), but a
                              ## shield carrier (6 hp) survives the first one.
  SprayPaintActiveTicks* = 5   ## a fired cone stays on this many ticks,
                              ## tracking the attacker's position and aim.
  SprayPaintResetTicks* = 20   ## recharge time after the cone shuts off; the
                              ## refire cadence is ActiveTicks + ResetTicks.
  SprayPaintFxTicks* = 4       ## each per-tick cone snapshot fades this long
                              ## (cosmetic only).

  ShieldPickupRange* = 12     ## touch radius to pick a shield up.
  ShieldRespawnTicks* = 30 * ReplayFps  ## a taken endzone shield refills after 30s.
  ShieldLayerHp* = 3          ## hp in a full shield layer. Damage depletes
                              ## the layer before base hp; a pickup refills it
                              ## and never heals base damage.
  ShieldFireSlowdown* = 3     ## a shield carrier's fire cooldown is this many
                              ## times longer (3x slower fire rate).
  CarrierFireSlowdown* = 3    ## a HEART carrier's fire cooldown multiplier
                              ## (GV26): carriers can shoot, at a third the
                              ## rate. Shield+heart do not stack (max, not
                              ## product).

  BarrierPickupRange* = 12    ## touch radius to pick a cardboard barrier up.
  BarrierRespawnTicks* = 30 * ReplayFps  ## a taken barrier pickup refills after 30s.
  BarrierHp* = 10             ## particle-worlds hits a placed barrier soaks before
                              ## it is gone. Only the gun chips it; the spray
                              ## cone is merely blocked, and grenades fly
                              ## over it like every other obstacle.
  BarrierRadius* = 24         ## half-hex circumradius in px: the distance
                              ## from the placement center (the placer's own
                              ## center) to each of the four vertices. The
                              ## flat middle side sits at the apothem
                              ## (~0.87R = 21px) straight down the placer's
                              ## aim, so the cardboard wraps their front.
  BarrierHalfThick* = 2       ## half-thickness of the cardboard band: a map
                              ## pixel within this distance of one of the
                              ## three sides is covered (band ~5px wide, so
                              ## a 1px-stepped paint ray can never lace
                              ## through it diagonally).
  MaxBarriersPlaced* = 16     ## most placed barriers standing at once
                              ## (sizes the render pools); placing past the
                              ## cap flattens the OLDEST standing barrier.
  MaxBarrierPickupsPerTeam* = 2  ## cap on the barrierPickups config knob.

  TrenchSize* = 56            ## side length of the walkable trench square
                              ## open flag ring (corner reach ~40px < the
                              ## 70px ring), so it never touches a wall.
  TrenchSpeedDivisor* = 5     ## CLIMBING OUT is 1/5 speed: while the center
                              ## is inside a pit, any axis motion pointing
                              ## AWAY from the pit's center has its cap and
                              ## accel divided by this, and outward momentum
                              ## sheds to the cap. Dropping in, crossing,
                              ## and moving around the pit are full speed.
  TrenchFireSlowdown* = 3     ## an occupant's gun fire cooldown multiplier
                              ## (1/3 fire rate). Max-composed with the
                              ## shield/carrier slowdown, never the product —
                              ## same rule as shield+heart (GV26).
  TrenchMissPct* = 70         ## percent of gun shots that would hit a trench
                              ## occupant that fly straight over instead
                              ## (deterministic sim RNG); the bullet carries
                              ## on down the ray. Shots fired from inside the
                              ## same trench never miss this way.

  PuddleSize* = 64            ## nominal diameter of a paint-puddle splat
                              ## (the core disc; lobes reach a little
                              ## further — see arena.nim's PuddleMaxRadiusPx).
                              ## Like obstacles and trenches, puddles never
                              ## scale with the map's size class.
  PuddleRollTicks* = TargetFps  ## one damage roll per full SECOND of
                              ## continuous puddle occupancy (24 ticks).
  DefaultPuddleDamagePct* = 20  ## default percent chance the per-second
                              ## occupancy roll deals 1 damage.
                              ## (GameVersion 43: 10 -> 20, 2x.)
  MaxPuddles* = 64            ## hard cap on mapPuddles requests, matching
                              ## the trench cap (and sizing the stated-marker
                              ## sprite/object pool).

  BubbleImpactTicks* = 8      ## ~0.33s the bubble's blink/dent impact FX
                              ## lasts (cosmetic only, like HitFlashTicks).

  ShoutMaxChars* = 10         ## a shout is at most this many characters.
  ShoutTicks* = 3 * ReplayFps ## a shout stays observable this long.
  ShoutCooldownTicks* = ReplayFps  ## at most one shout per second.

  # --- Particle worlds King of the Hill (docs/plans/2026-08-25-particle-worlds-design.md) ---
  # Every value below is a DEFAULT for the matching GameConfig field; a
  # variant may override it. All particle-worlds arithmetic is integer-only so the
  # native server and the wasm viewer re-derive the identical tick.
  PaintTile* = 34               ## px side of one floor-paint tile: one cog body.
  MaxPaintTiles* = 768          ## render-pool ceiling on the paint grid; the
                                ## 1235x659 arena needs 37 x 20 = 740.
  DefaultHillRadiusTiles* = 2   ## hill = the (2r+1)^2 tile block at map centre.
  DefaultHillOwnPermille* = 800 ## >= 80% of the hill's FLOOR tiles owns it.
                                ## Above 500, so at most one team can qualify.
  DefaultHillDecisiveTicks* = 720  ## hill-tick margin worth a full 1.0 game score.
  DefaultPaintSpeedOwnPct* = 125   ## own colour underfoot: x125% speed/accel.
  DefaultPaintSpeedEnemyPct* = 85  ## enemy colour underfoot: x85% speed/accel.
  DefaultPaintHealTicks* = 48   ## consecutive ticks on own paint per +1 hp.
  HillFlipThrottleTicks* = 12   ## min ticks between two `hillflip` beats, so a
                                ## contested rim cannot flood the feed.
  DefaultCogsPerTeam* = 4       ## cogs one seat commands (RED-alpha..delta).
  DefaultSprayDamage* = 1       ## hp per cone touch under the particle loadout
                                ## (the starter's SprayPaintDamage is 3): three
                                ## touches tag a 3 hp cog out, which is what
                                ## makes the heal half of the buff matter.
  DefaultTurnTicks* = 108       ## 4.5 s of sim time per decision turn.
  ## v1.1 timing amendment (2026-08-25). The 0.1.2 deadlines were 4500/2000 ms
  ## inside a 7000 ms cap, and curly's timeout is CURLOPT_TIMEOUT — whole
  ## seconds — so attempt 1 really ran with 4 s. Particle worlds's own sidecar
  ## measured a 4618 ms median over 85 hosted calls (56 of them past 4 s) and
  ## every successful LLM directive reported a 3999–4001 ms latency: the
  ## deadline, not the model, was answering. All three values are now whole
  ## seconds so the configured number IS the effective one, and attempt 1
  ## clears that median by ~1.4 s.
  DefaultTurnBudgetMs* = 10_000 ## hard monotonic cap around one whole turn.
  DefaultAttempt1Ms* = 6000     ## first parallel batch deadline (6 s exactly).
  DefaultRetryMs* = 3000        ## single retry batch deadline (6 + 3 <= 10).
  DefaultWallClockBudgetSeconds* = 690
                                ## engine hard stop, 57.5% of the assumed 1200 s
                                ## episodeTimeoutSeconds (the 60% pin).
  DefaultMaxOutputTokens* = 900 ## 400 truncates Haiku mid-object.
  LoadoutMpe* = "mpe"           ## the starter's loadout: pickups, gun, hearts.
  LoadoutParticles* = "particle-worlds"  ## spray can always held, no pickups, no gun.
  RegimeResidentText* = "resident"
  RegimeVisitorText* = "visitor"
  MaxNoteRunes* = 160           ## directive note cap, in RUNES (never bytes).
  MaxSayRunes* = ShoutMaxChars  ## a cog's shout cap, in RUNES.
  MaxPolicyLabelRunes* = 48     ## `register.policy` cap, in RUNES.
  MaxFallbackDetailRunes* = 200 ## `fallback.detail` cap, in RUNES.
  MaxDirectiveRunes* = 900      ## whole serialized `directive` record cap.
  MaxPromptRunes* = 4000        ## PLAYER_PROMPT transport cap (truncate, never
                                ## reject); never written to the replay.
  MaxCogIdRunes* = 12           ## `cogs[].id` cap, in RUNES.
  AimUnitScale* = 1024
    ## Fixed-point scale of the integer aim table below. The paint grid's cone
    ## test is the one piece of NEW hashed arithmetic in this fork, and Nim's
    ## `int` is 32-bit under `--cpu:wasm32`, so it is integer-only end to end:
    ## a compile-time cos/sin would be evaluated by whichever libm the build
    ## container ships and could differ by an ulp between the amd64 game image
    ## and the emscripten viewer image. These literals cannot.
  AimUnitX*: array[256, int] = [
     1024,  1024,  1023,  1021,  1019,  1016,  1013,  1009,
     1004,   999,   993,   987,   980,   972,   964,   955,
      946,   936,   926,   915,   903,   891,   878,   865,
      851,   837,   822,   807,   792,   775,   759,   742,
      724,   706,   688,   669,   650,   630,   610,   590,
      569,   548,   526,   505,   483,   460,   438,   415,
      392,   369,   345,   321,   297,   273,   249,   224,
      200,   175,   150,   125,   100,    75,    50,    25,
        0,   -25,   -50,   -75,  -100,  -125,  -150,  -175,
     -200,  -224,  -249,  -273,  -297,  -321,  -345,  -369,
     -392,  -415,  -438,  -460,  -483,  -505,  -526,  -548,
     -569,  -590,  -610,  -630,  -650,  -669,  -688,  -706,
     -724,  -742,  -759,  -775,  -792,  -807,  -822,  -837,
     -851,  -865,  -878,  -891,  -903,  -915,  -926,  -936,
     -946,  -955,  -964,  -972,  -980,  -987,  -993,  -999,
    -1004, -1009, -1013, -1016, -1019, -1021, -1023, -1024,
    -1024, -1024, -1023, -1021, -1019, -1016, -1013, -1009,
    -1004,  -999,  -993,  -987,  -980,  -972,  -964,  -955,
     -946,  -936,  -926,  -915,  -903,  -891,  -878,  -865,
     -851,  -837,  -822,  -807,  -792,  -775,  -759,  -742,
     -724,  -706,  -688,  -669,  -650,  -630,  -610,  -590,
     -569,  -548,  -526,  -505,  -483,  -460,  -438,  -415,
     -392,  -369,  -345,  -321,  -297,  -273,  -249,  -224,
     -200,  -175,  -150,  -125,  -100,   -75,   -50,   -25,
        0,    25,    50,    75,   100,   125,   150,   175,
      200,   224,   249,   273,   297,   321,   345,   369,
      392,   415,   438,   460,   483,   505,   526,   548,
      569,   590,   610,   630,   650,   669,   688,   706,
      724,   742,   759,   775,   792,   807,   822,   837,
      851,   865,   878,   891,   903,   915,   926,   936,
      946,   955,   964,   972,   980,   987,   993,   999,
     1004,  1009,  1013,  1016,  1019,  1021,  1023,  1024
  ]
  AimUnitY*: array[256, int] = [
        0,   -25,   -50,   -75,  -100,  -125,  -150,  -175,
     -200,  -224,  -249,  -273,  -297,  -321,  -345,  -369,
     -392,  -415,  -438,  -460,  -483,  -505,  -526,  -548,
     -569,  -590,  -610,  -630,  -650,  -669,  -688,  -706,
     -724,  -742,  -759,  -775,  -792,  -807,  -822,  -837,
     -851,  -865,  -878,  -891,  -903,  -915,  -926,  -936,
     -946,  -955,  -964,  -972,  -980,  -987,  -993,  -999,
    -1004, -1009, -1013, -1016, -1019, -1021, -1023, -1024,
    -1024, -1024, -1023, -1021, -1019, -1016, -1013, -1009,
    -1004,  -999,  -993,  -987,  -980,  -972,  -964,  -955,
     -946,  -936,  -926,  -915,  -903,  -891,  -878,  -865,
     -851,  -837,  -822,  -807,  -792,  -775,  -759,  -742,
     -724,  -706,  -688,  -669,  -650,  -630,  -610,  -590,
     -569,  -548,  -526,  -505,  -483,  -460,  -438,  -415,
     -392,  -369,  -345,  -321,  -297,  -273,  -249,  -224,
     -200,  -175,  -150,  -125,  -100,   -75,   -50,   -25,
        0,    25,    50,    75,   100,   125,   150,   175,
      200,   224,   249,   273,   297,   321,   345,   369,
      392,   415,   438,   460,   483,   505,   526,   548,
      569,   590,   610,   630,   650,   669,   688,   706,
      724,   742,   759,   775,   792,   807,   822,   837,
      851,   865,   878,   891,   903,   915,   926,   936,
      946,   955,   964,   972,   980,   987,   993,   999,
     1004,  1009,  1013,  1016,  1019,  1021,  1023,  1024,
     1024,  1024,  1023,  1021,  1019,  1016,  1013,  1009,
     1004,   999,   993,   987,   980,   972,   964,   955,
      946,   936,   926,   915,   903,   891,   878,   865,
      851,   837,   822,   807,   792,   775,   759,   742,
      724,   706,   688,   669,   650,   630,   610,   590,
      569,   548,   526,   505,   483,   460,   438,   415,
      392,   369,   345,   321,   297,   273,   249,   224,
      200,   175,   150,   125,   100,    75,    50,    25
  ]
  # --- particle worlds (docs/plans/2026-08-26-particle-worlds-design.md) ---
  # Every value below is the DEFAULT of the matching GameConfig field; a
  # variant may override it. ALL particle-worlds arithmetic is integer-only,
  # so the native server and the wasm viewer re-derive the identical tick
  # (Nim's `int` is 32-bit under --cpu:wasm32).
  DefaultParticleAccel* = 250     ## motion units/tick^2. Cruise = accel/(1-0.75)
                                  ## = 1000 units = 3.91 px/tick = 94 px/s.
  DefaultParticleMaxSpeed* = 1100 ## per-axis speed clamp, motion units/tick.
  DefaultParticleFrictionNum* = 192  ## 192/256 = 0.75 retention per tick, i.e.
                                     ## MPE's damping = 0.25, exactly.
  DefaultPursuerAccelPct* = 75    ## MPE simple_tag: adversary accel 3.0 vs
                                  ## good 4.0.
  DefaultPursuerSpeedPct* = 77    ## MPE simple_tag: adversary max_speed 1.0 vs
                                  ## good 1.3.
  LandmarkCount* = 4              ## four particles, four marks. Never ranged.
  DefaultLandmarkRadius* = 18     ## px. Marks are never solid: a particle
                                  ## glides over them in every mode.
  DefaultLandmarkMargin* = 140    ## px kept clear of every board edge.
  DefaultLandmarkSpacingPx* = 300 ## px minimum centre-to-centre separation the
                                  ## rejection sampler aims for.
  MinLandmarkSpacingPx* = 120     ## the sampler's floor, and the sim guard's
                                  ## invariant.
  DefaultSpawnRingPx* = 250       ## spawn circle radius about the field centre.
  DefaultCloseScalePx* = 500      ## `closeness` reaches 0 at this distance.
  DefaultBumpPx* = 14             ## centres this close counts as a bump tick.
  DefaultBumpPenaltyPermille* = 1 ## permille debited per bump tick in `spread`.
  DefaultBumpPenaltyCap* = 250    ## the debit never exceeds this.
  DefaultTagPx* = 20              ## pursuer contact radius in `tag`.
  DefaultTagTargetTicks* = 120    ## contact ticks worth a full pursuer score.
  DefaultOrbitRadiusPx* = 120     ## `orbit` stand-off from its target.
  DefaultShadowStandoffPx* = 60   ## `shadow` stand-off from its target particle.
  DefaultEvadeProbePx* = 200      ## `evade` probe radius (16 fixed brads).
  DefaultSymbolCount* = 8         ## A..H, plus "-" for silence = 9 values.
  DefaultParticleTurnSpacingMs* = 9000
                                  ## wall-clock floor between batch STARTS, and
                                  ## the ONE in-code default (sim_config.nim)
                                  ## as well as the value every shipped variant
                                  ## and the config schema carry. FOUR seats per
                                  ## turn at 9 s = 26.7 req/min, under the
                                  ## sidecar's 30/min per-episode cap (raid,
                                  ## 2026-08-23). The 5000 that used to sit in
                                  ## the base config was a two-seat number no
                                  ## shipped config could pick up, and four
                                  ## seats at 5 s would be 48 req/min.
  NeverTick* = -1_000_000         ## "this has not happened yet" for a tick
                                  ## throttle. NOT low(int): Nim's `int` is
                                  ## 32-bit under --cpu:wasm32 and every
                                  ## throttle is `tick - lastTick`, so a
                                  ## low(int32) sentinel OVERFLOWS on the very
                                  ## first comparison and the wasm viewer dies
                                  ## with "over- or underflow" before it draws
                                  ## a frame (release builds keep overflow
                                  ## checks; only -d:danger drops them). A
                                  ## million ticks is 11 hours of play, four
                                  ## orders of magnitude past any episode.
  BumpEventThrottleTicks* = 12    ## min ticks between two `bump` events for one
                                  ## pair, so a jostle cannot flood the feed.
  TagEventThrottleTicks* = 12     ## quiet ticks a contact must follow to emit a
                                  ## `tag` event.
  TagBeatThrottleTicks* = 48      ## min ticks between two `tag` scrubber beats.
  SettleTicks* = 48               ## consecutive ticks on one nearest mark that
                                  ## count as "settled" (a `decode`).
  SettleSlackPx* = 60             ## a particle counts as settled on its nearest
                                  ## mark inside landmarkRadius + this.
  OnPointSlackPx* = 12            ## "on the goal" = inside landmarkRadius + this.
  SymbolAlphabet* = "ABCDEFGH"    ## the eight speakable symbols.
  SymbolSilence* = "-"            ## the ninth value: saying nothing.
  MarkColourNames*: array[LandmarkCount, string] =
    ["amber", "teal", "violet", "bone"]
    ## Deliberately DISJOINT from the four particle colours, so a spectator
    ## never confuses a particle with a mark.
  MarkColours*: array[LandmarkCount, ColorRGBA] = [
    rgba(232, 163, 61, 255),    # amber
    rgba(64, 176, 168, 255),    # teal
    rgba(150, 108, 214, 255),   # violet
    rgba(226, 219, 198, 255)    # bone
  ]
  SymbolHues*: array[8, ColorRGBA] = [
    rgba(232, 96, 74, 255),     # A
    rgba(232, 163, 61, 255),    # B
    rgba(214, 210, 90, 255),    # C
    rgba(120, 200, 104, 255),   # D
    rgba(72, 190, 182, 255),    # E
    rgba(90, 152, 226, 255),    # F
    rgba(158, 116, 220, 255),   # G
    rgba(226, 130, 190, 255)    # H
  ]
    ## One fixed hue per symbol, so "F" reads the same colour every time it is
    ## said, by anybody, in any round.

  ReasonComplete* = "complete"
  ReasonDeadline* = "deadline"
  ReasonFault* = "fault"
  EndRuleFullTime* = "full_time"
  EndRuleMercy* = "mercy"
  EndRuleWipe* = "wipe"
  EndRuleWallClock* = "wall_clock"
  EndRuleSimFault* = "sim_fault"
  EndRuleHostError* = "host_error"

  TextLineHeight* = 7
  MapSpriteId* = 1
  MapObjectId* = 1
  MapLayerId* = 0
  MapLayerType* = 0
  ScoreboardLayerId* = 1       ## left roster panel (red; +green on 4-team maps).
  ScoreboardLayerType* = 1     ## top-left anchor.
  BottomRightLayerId* = 3
  BottomRightLayerType* = 3
  ZoomableLayerFlag* = 1
  UiLayerFlag* = 2
  PlayerSpriteBase* = 100
  FlagSpriteBase* = 700       ## team flag sprites: 700..703 by team.
  SelectedPlayerSpriteBase* = 6000  ## outlined selected-soldier pool:
                              ## 4 teams x 16 rotations per skin — default
                              ## 6000..6063, crown 6064..6127. Moved from
                              ## 800: that pool swallowed the hp pips
                              ## (820..823) and the sound/impact rings
                              ## (830/831) — same collision class as the
                              ## 2026-07-22 unit-tag/fire-icon incident.
  PlayerObjectBase* = 1000
  SelectedTextObjectId* = 4000
  PlayerColors* = [
    3'u8,
    7,
    8,
    14,
    4,
    11,
    13,
    15,
    1,
    2,
    5,
    6,
    9,
    10,
    12,
    0
  ]
  PlayerColorNames* = [
    "red",
    "orange",
    "yellow",
    "light blue",
    "pink",
    "lime",
    "blue",
    "pale blue",
    "gray",
    "white",
    "dark brown",
    "brown",
    "dark teal",
    "green",
    "dark navy",
    "black"
  ]
  ## Team colors: Red team = palette red (3), Blue team = palette blue (13),
  ## Green team = palette green (10), Yellow team = palette yellow (8).
  RedTeamColor* = 3'u8
  BlueTeamColor* = 13'u8
  GreenTeamColor* = 10'u8
  YellowTeamColor* = 8'u8
  ShadowMap* = [
    0'u8,  #  0 black       -> black
    12,    #  1 gray         -> dark navy
    9,     #  2 white        -> dark teal
    5,     #  3 red          -> dark brown
    5,     #  4 pink         -> dark brown
    0,     #  5 dark brown   -> black
    5,     #  6 brown        -> dark brown
    5,     #  7 orange       -> dark brown
    5,     #  8 yellow       -> dark brown
    12,    #  9 dark teal    -> dark navy
    9,     # 10 green        -> dark teal
    9,     # 11 lime         -> dark teal
    0,     # 12 dark navy    -> black
    12,    # 13 blue         -> dark navy
    12,    # 14 light blue   -> dark navy
    9,     # 15 pale blue    -> dark teal
  ]
  WebSocketPath* = "/player"
  GlobalWebSocketPath* = "/global"
  ReplayWebSocketPath* = "/replay"
  RewardWebSocketPath* = "/reward"

## Runtime map state. The game supports multiple arenas ("arena" is the
## default, "arena-large" the 30%-larger variant); one is selected per
## process by loadMpeMap (driven by config.mapPath) BEFORE any sim, mask,
## or render work happens, and never changes afterward — the render bakes
## in global.nim rely on that per-process invariant. The values below are
## initialized to the default arena so tools that never call loadMpeMap
## keep working unchanged.
var
  MapWidth* = 1235
  MapHeight* = 659
  FovGridW* = (MapWidth + FovCellSize - 1) div FovCellSize
  FovGridH* = (MapHeight + FovCellSize - 1) div FovCellSize
  FovCellCount* = FovGridW * FovGridH
  GrenadeMaxRange* = MapWidth div 5  ## max throw distance (full charge).
  ShoutRange* = MapWidth div 5  ## audible within 20% of the screen width.

type
  Team* = enum
    ## The first two members are the classic pair; a game's ACTIVE teams are
    ## always a prefix of this enum (`Red .. Team(teamCount - 1)`), so every
    ## 2-team code path sees exactly the members it always did.
    Red
    Blue
    Green
    Yellow

  TeamLayout* = enum
    ## Where the teams live on the map. `layoutSides` is the classic 2-team
    ## left/right arena; the two 4-team layouts put a team in each corner or
    ## at the end of each arm of a plus.
    layoutSides
    layoutCorners
    layoutPlus

  Skin* = enum
    DefaultSkin
    CrownSkin

  Perk* = enum
    ## Named, icon-badged team buffs (docs/plans/2026-08-07-team-perks-design.md).
    ## Assignment and magnitudes are config (`GameConfig.perks` / the perkMods
    ## knobs); a default config carries none and plays byte-identical to an
    ## engine without perks.
    PerkArmor     ## +perkMods.armorHp max hit points per bot.
    PerkScope     ## gun aim-jitter sigma reduced by perkMods.scopeAim.
    PerkGrenade   ## grenade max throw range +perkMods.grenadeRange.
    PerkThruster  ## max speed +perkMods.thrusterSpeed.
    PerkLuck      ## perkMods.luckChance of landed gun shots deal luckDamage.

  PerkSet* = set[Perk]

  PerkGroup* = object
    ## One perk group of a team: the set one policy seat carries, optionally
    ## PINNED to a policy by name. `pol == ""` = unnamed, dealt to the team's
    ## distinct policies in join order; a named group goes to exactly the
    ## policy whose policyName matches. A team's groups are all-named (object
    ## config form) or all-unnamed (array form) — the parser enforces it.
    pol*: string
    perks*: PerkSet

  PerkMods* = object
    ## The perk magnitudes ("mods"), config-tunable as one block. Fractions
    ## are integer permille (the handicaps rule) so every in-sim derivation
    ## is integer or perk-gated; counts are plain hit points. Only read when
    ## a seat actually carries the perk, so the values never touch a
    ## perk-free game. Compared as ONE value against DefaultPerkMods for the
    ## config echo, so adding a knob here cannot be silently dropped from
    ## replay configs.
    armorHp*: int        ## armor: extra max hit points.
    scopeAim*: int       ## scope: fraction of aim-jitter sigma removed, permille.
    grenadeRange*: int   ## grenade: extra max throw range, permille.
    thrusterSpeed*: int  ## thruster: extra max speed, permille.
    luckChance*: int     ## luck: chance a landed gun shot is lucky, permille.
    luckDamage*: int     ## luck: hit points a lucky shot removes.

  PaintUnder* = enum
    ## What a cog's BODY CENTRE is standing on this tick, sampled once per
    ## tick by updatePaintBuff and consumed by the next tick's applyInput.
    puNone                     ## unpainted floor.
    puOwn                      ## this cog's own team colour.
    puEnemy                    ## the other team's colour.

  Regime* = enum
    ## Which cogs of a team its seat drives for one GAME of the episode.
    ## `resident` = all four; `visitor` = alpha only, the other three run the
    ## published `holdline` baseline. Ordinals are wire format.
    regimeResident
    regimeVisitor

  Mode* = enum
    ## The four MPE scenarios one episode plays back to back. A closed enum;
    ## ordinals are wire format (the mode code is hashed).
    modeSpread = "spread"
    modeDeceive = "deceive"
    modeCrypto = "crypto"
    modeTag = "tag"

  Landmark* = object
    ## One coloured mark. Never solid; a particle glides over it. HASHED.
    x*, y*: int
    colour*: int               ## index into MarkColourNames / MarkColours.

  RoundLogEntry* = object
    ## One banked round. HASHED (every field), so the wasm viewer re-derives
    ## the same episode score the server wrote.
    mode*: Mode
    roles*: array[4, int]      ## role INDEX per seat for that round.
    ticks*: int                ## ticks the round actually ran.
    endRule*: string           ## EndRuleFullTime | EndRuleWallClock.
    permille*: array[4, int]   ## the banked round score per seat, 0..1000.
    goal*: int                 ## the round's goal landmark, -1 in spread/tag.
    coverPct*: int             ## mean coverage percent (spread only, else 0).
    tagTicks*: int             ## total contact ticks (tag only, else 0).
    goalHits*: int             ## mobile agents on the goal at the final tick.

  MpeError* = object of ValueError

  SimGuardError* = object of CatchableError
    ## A sim INVARIANT tripped: a paint index out of range, a cog outside the
    ## map, hill counts that cannot be true. The design note's end-condition
    ## table row 5 says what happens next — the episode ends `fault` /
    ## `sim_fault`, both seats score 0.500, and the partial replay is written
    ## — and the server's tick loop is the only place that catches it.

  GamePhase* = enum
    Lobby
    Playing
    GameOver

  Room* = object
    name*: string
    x*, y*, w*, h*: int

  MapRect* = object
    x*, y*, w*, h*: int

  PuddleSpot* = object
    ## One disc of a paint puddle's splat cluster.
    cx*, cy*, r*: int

  Puddle* = object
    ## A paint puddle: the UNION of a handful of overlapping paint discs —
    ## the classic splat silhouette. Discs (not polygons) because disc
    ## membership is pure integer math that transforms BIT-EXACTLY under the
    ## map symmetries (mirror/rot180 move a center, never change a
    ## distance), so a puddle pair — and the stitched center puddle — is
    ## exactly team-fair; the polygon scanline rule would drop whole pixel
    ## rows at pass-through vertices (see pointInPolygon's strict-straddle
    ## doc).
    spots*: seq[PuddleSpot]

  ArenaShapeKind* = enum
    shapeRect
    shapeDisc
    shapeDiamond
    shapeDiagonal
    shapePolygon

  ArenaShape* = object
    ## One arena obstacle. Discs and diamonds are center + radius (L2 and L1
    ## norms); diagonals are a 45-degree wall segment of given perpendicular
    ## thickness between two endpoints. A `window` shape is glass: it blocks
    ## movement, bullets, and spray-cone line-of-sight exactly like stone, but
    ## fog-of-war shadowcasting sees straight through it.
    window*: bool
    case kind*: ArenaShapeKind
    of shapeRect:
      rect*: MapRect
    of shapeDisc, shapeDiamond:
      cx*, cy*, radius*: int
    of shapeDiagonal:
      x0*, y0*, x1*, y1*, thickness*: int
    of shapePolygon:
      ## A closed ring of INTEGER vertices. Curves (Beziers, metaballs,
      ## superellipses) are flattened to one of these by the authoring tools
      ## BEFORE they reach the sim, so the runtime never evaluates a curve —
      ## only integer even-odd point-in-polygon (`inShape`). Integer vertices
      ## keep symmetry transforms bit-exact, so a polygon and its mirror image
      ## rasterize to exactly mirror-symmetric wall masks (team fairness).
      points*: seq[MapPoint]

  MapPoint* = object
    x*, y*: int

  TeamPickupPoints* = object
    ## EXPLICIT per-team pickup points for a full-board (symNone) map, in team
    ## order (Red, Blue, [Green, Yellow]). Empty on symmetric maps (the orbit
    ## supplies them). Each seq, when non-empty, has one point per active team.
    ## Barriers carry `perTeam` points each, flattened team-major (team 0's
    ## points, then team 1's, ...), matching barrierSpawnPoints' orbit order.
    shields*: seq[MapPoint]
    cans*: seq[MapPoint]        ## spray-can (spraypaint-arc) points
    barriers*: seq[MapPoint]    ## cardboard points, team-major (perTeam each)

  EndzoneShape* = enum
    ## The shape of a team's home capture region on a SIDES map. The classic
    ## column runs the full map height along the home border; the two COMPACT
    ## shapes wrap the base itself, which lets the base sit well off the edge
    ## with playable wilderness all around it — behind included.
    ezColumn
    ezDisc
    ezSquare

  CaptureZone* = object
    ## One team's home capture region. Sides maps use the classic
    ## full-height columns; plus arms are boxes bounded on both axes; corner
    ## teams get a DIAGONAL zone — everything within an L1 radius of their
    ## map corner, whose threshold edge is a 45-degree line cut across the
    ## corner. A COMPACT endzone is the anchor-centered box (a square zone
    ## needs nothing more; `disc` rounds it off). The box fields always hold
    ## the zone's bounding box (the strip and diff-box machinery scan it);
    ## `diag` / `disc` refine membership.
    xLo*, xHi*, yLo*, yHi*: int
    diag*: bool                ## L1 corner zone instead of the full box.
    cornerX*, cornerY*: int    ## the map corner the diagonal zone hugs.
    diagLimit*: int            ## inclusive L1 radius from that corner.
    disc*: bool                ## L2 zone around the anchor instead of the box.
    anchorX*, anchorY*: int    ## the base the compact zone is centered on.
    radius*: int               ## inclusive L2 radius from that anchor.

  MapSymmetry* = enum
    ## How a map's full obstacle set derives from its authored/generated
    ## seed set. Mirror and rot180 complete a LEFT-half set across the
    ## vertical center line (2-team maps); rot90 completes a QUADRANT set by
    ## rotating it 90/180/270 degrees about the center (4-team maps, square
    ## only); quadMirror completes a TOP-LEFT quadrant set by reflecting it
    ## across both center axes (mirrorX, mirrorY, rot180 — 4-team maps, any
    ## rectangle). All are exactly team-fair; rot180 keeps diagonal lanes
    ## diagonal instead of folding them into chevrons.
    ##
    ## Ordinals are wire format (flatty stores them positionally in replay
    ## keyframes): APPEND new members, never insert.
    symMirror
    symRot180
    symRot90
    symQuadMirror
    symNone
      ## FULL-BOARD authoring (coworld-particle-worlds#280): the authored obstacle set IS
      ## the whole board — no fundamental domain, no lift. Used for organic,
      ## irregular, theme-based maps that no group-completion can express (the
      ## corpus's asymmetric tier). There is no symmetry group, so there is no
      ## `teamImagePoint` orbit: a symNone spec MUST carry EXPLICIT per-team
      ## pickup/shield/can points, validated for walkability + connectivity
      ## like spawns. Team-FAIRNESS is NOT guaranteed by construction here —
      ## it is a MEASURED property the caller gates on (mapgen program, law 5);
      ## the engine only validates the spec is well-formed, it does not judge
      ## balance. Appended last: older viewers cannot parse symNone specs, the
      ## same wire caveat GV39's quadmirror (#237) shipped with.

  MpeMap* = object
    name*: string
    path*: string
    width*, height*: int
    mapLayer*, walkLayer*, wallLayer*: int
    center*: MapPoint
    rooms*: seq[Room]
    ## Arena layout: the open-space clearances, the map's default gun range,
    ## and the LEFT-half obstacle set (mirrored across the vertical center
    ## line on selection).
    flagRing*: int             ## clear radius of the open center ring.
    captureClear*: int         ## x-columns kept traversable for carriers.
    spawnClearW*: int          ## half-width of the open spawn pockets.
    spawnClearH*: int          ## half-height of the open spawn pockets.
    gunRange*: int             ## default gun range on this map (px).
    endzone*: EndzoneShape     ## home capture-region shape (sides maps).
    endzoneRadius*: int        ## COMPACT endzones: the scoring radius (disc)
                               ## or half-extent (square) around the anchor,
                               ## in px. 0 on `ezColumn` maps.
    homeDepth*: int            ## home anchor position as a permille of the
                               ## half-field, measured from the center: 700
                               ## (the classic) puts the base 30% of the way
                               ## in from its edge, and SMALLER values push it
                               ## further from the edge.
    symmetry*: MapSymmetry
    layout*: TeamLayout        ## sides (2 teams) / corners / plus (4 teams).
    genSeed*: int              ## generator seed; 0 for hand-authored maps.
    medKitSpawns*: seq[MapPoint]     ## the two ACTIVE med-kit points.
    medKitCandidates*: seq[MapPoint] ## the drawn candidate set (4 on
                                     ## generated maps; equals the active
                                     ## pair on hand-authored maps).
    leftObstacles*: seq[ArenaShape]
    trenches*: seq[ArenaShape]  ## walkable dug pits (config-gated): standing
                               ## inside slows movement and fire, and most
                               ## incoming gun shots fly straight over. FULL-map
                               ## (both halves, already symmetrized). The
                               ## generator emits `rect` pits; authored maps may
                               ## use any shape, including `polygon` (curved
                               ## pits). Membership is `inShape`, so the mechanic
                               ## is shape-agnostic; only the organic-edge ART is
                               ## rect-specific (other kinds fill flat for now).
    puddles*: seq[Puddle]      ## paint-puddle hazards (config-gated): every
                               ## full second a cog's center spends
                               ## continuously inside one rolls a
                               ## puddleDamagePct chance of 1 damage. Pure
                               ## floor hazard — no movement, fire, or vision
                               ## effect. FULL-map (both halves, already
                               ## symmetrized), pinned into replay specs like
                               ## trenches.
    teamPickups*: TeamPickupPoints
                               ## EXPLICIT per-team pickup points (coworld-particle-worlds
                               ## #280). Symmetric maps leave this empty and
                               ## derive every team's shield/can/barrier point
                               ## from RED's via the symmetry orbit
                               ## (`teamImagePoint`). A symNone (full-board) map
                               ## has NO orbit, so it MUST author each team's
                               ## points here. The loader validates they are
                               ## PRESENT (one per team; barriers a multiple of
                               ## the team count) and NOT WALL — each point must
                               ## be in-bounds and clear of every obstacle
                               ## (wall-overlap test, no silent default). It does
                               ## NOT do a full flood-CONNECTIVITY check at load
                               ## (too heavy); reachability/fairness is the
                               ## caller's measured gate. Ignored on symmetric maps.
    homeRotation*: int         ## GV44: per-episode rotation of TEAM -> HOME
                               ## OWNERSHIP, in quarter-turns around the home
                               ## orbit (0..3; 0 = the historical fixed
                               ## assignment). The pads themselves never move —
                               ## the board carves the same four congruent
                               ## homes either way — only which team owns which
                               ## one changes, so that a 4-team season deals
                               ## every seat every slot instead of pinning it
                               ## to one. Derived from the GAME seed by
                               ## `homeRotationFor` and applied in
                               ## `resolveMpeMapMetadata`, so it is a pure
                               ## function of the config a replay already
                               ## carries and never needs pinning into
                               ## `mapSpec`. ALWAYS 0 for teamCount <= 2:
                               ## Red-left / Blue-right is a game contract.
                               ## Read it ONLY through `homeSlot` — that remap
                               ## is the single choke point the whole home
                               ## bundle rotates through.

  CrewSprite* = ref object
    width*, height*: int
    rgba*: seq[uint8]

  RewardAccount* = object
    address*: string
    slotIndex*: int
    team*: Team
    hasTeam*: bool
    won*: bool
    abandoned*: bool
    reward*: int
    wins*: array[Team, int]    ## lifetime wins while seated on each team.
    games*: array[Team, int]   ## lifetime games seated on each team.
    kills*: int
    deaths*: int
    captures*: int
    earnedAchievements*: seq[string]
      ## Achievement ids this address earned across the episode's games,
      ## deduplicated (see recordAchievement). Account-level so it survives
      ## per-game Player counter resets under maxGames > 1 and a mid-episode
      ## disconnect; exported per slot in results.json.

  PlayerSlotConfig* = object
    name*: string
    token*: string
    team*: Team
    color*: uint8
    skin*: Skin
    hasTeam*: bool
    hasColor*: bool

  MapGenOverrides* = object
    ## Per-parameter locks for the terrain generator. Zero-value ("" / 0,
    ## windows -1) = unlocked, drawn from the map seed. Locking a parameter
    ## replaces its draw without shifting the other draws.
    size*: string          ## "small" | "standard" | "large"
    symmetry*: string      ## "mirror" | "rot180"
    columns*: int          ## obstacle column count per half, 3..8
    windows*: int          ## glass-window count per half, 0..6; -1 = draw
    centerFeature*: string ## "bracket" | "ring" | "walls"
    layout*: string        ## 4-team maps: "corners" | "plus"; "" = draw.
    pits*: int             ## requested TOTAL trench count, 0..64; -1 =
                           ## density draw. Best-effort: when the candidate
                           ## spots can't host the full request, the map
                           ## places as many as fit. Even counts place
                           ## symmetric pairs; an odd count anchors its
                           ## extra pit dead center (self-symmetric under
                           ## mirror AND rot180), so both parities stay
                           ## exactly team-fair.
    pitDensity*: int       ## percent multiplier on the default per-class
                           ## pit chances (100 = default feel, 0 = none,
                           ## 200 = twice as digging-happy); -1 = default.
                           ## Ignored when `pits` locks an exact count.
    puddles*: int          ## requested TOTAL paint-puddle count, 0..64.
                           ## <= 0 = none (the default — puddles have no
                           ## density draw, so the zero object default and
                           ## an explicit 0 mean the same thing).
                           ## Best-effort like pits: places as many as fit.
                           ## Even counts place symmetric pairs; an odd
                           ## count anchors its extra puddle dead center.
    endzone*: string       ## "column" | "disc" | "square"; "" = draw. The
                           ## two COMPACT shapes wrap the base and open the
                           ## home border strip up as wilderness.
    endzoneRadius*: int    ## compact endzone scoring radius in px,
                           ## EndzoneRadiusMin..EndzoneRadiusMax; 0 = draw.
                           ## Ignored on `ezColumn` maps.
    baseDepth*: int        ## home anchor depth permille (see MpeMap.
                           ## homeDepth), HomeDepthMin..HomeDepthMax;
                           ## 0 = draw (700 on column maps).

  GameConfig* = object
    motionScale*: int
    accel*: int
    frictionNum*: int
    frictionDen*: int
    maxSpeed*: int
    stopThreshold*: int
    playerBouncePct*: int
    seed*: int
    speed*: int
    lives*: int
    hitPoints*: int
    respawnTicks*: int
    gunRange*: int
    fireCooldownTicks*: int
    fireWindupTicks*: int
    carrierSpeedPct*: int
    aimTurnRate*: int          ## brads/tick a held rotate button turns the aim.
    visionConeDeg*: int
    visionBubble*: int
    minPlayers*: int
    startWaitTicks*: int
    lobbyJoinTimeoutTicks*: int  ## finite matches only: abort the lobby when
                                 ## the roster is still short after this many
                                 ## lobby ticks (0 = wait forever, the
                                 ## pre-existing behavior). The clock runs on
                                 ## lobby ticks, so board bake/setup before
                                 ## the loop starts never eats the budget.
    gameOverTicks*: int
    maxTicks*: int
    maxGames*: int
    showPlayerLabels*: bool
    fastMode*: bool           ## advance frames early when every player has
                              ## sent the Sprite v1 ready packet; pacing only,
                              ## never in gameHash.
    teams*: int               ## active team count: 2 (classic sides) or 4
                              ## (corner / plus free-for-all maps). Every
                              ## team fights for itself; "2v2" is two
                              ## policies splitting one classic team's
                              ## seats, not a game mode.
    scoring*: string          ## end-of-game reward rule: ClassicScoring
                              ## (default, unchanged) or PotScoring.
    mapPath*: string
    mapSeed*: int             ## terrain seed for "gen"/"pool"; -1 = derive
                              ## from the game seed.
    mapPoolIndex*: int        ## explicit pool pick; -1 = mapSeed mod pool.
    mapGen*: MapGenOverrides
    mapSpec*: string          ## expanded map geometry JSON. Filled once at
                              ## config parse for generated maps and written
                              ## into replays, so playback reuses the EXACT
                              ## geometry and never re-runs the generator.
    closedRoster*: bool
    slots*: seq[PlayerSlotConfig]
    barrageMaxPerSec*: int    ## grenade-barrage endgame: the launch rate the
                              ## barrage ramps UP to, in grenades/second.
                              ## 0 = the mode is off — the default,
                              ## byte-identical to the pre-barrage game.
                              ## Requires maxTicks > 0 when set; capped at
                              ## BarrageAbsMaxPerSec.
    barrageStartPerSec*: int  ## grenade-barrage endgame: the launch rate at
                              ## the moment the barrage latches (default
                              ## BarrageStartPerSec); ramps linearly to
                              ## barrageMaxPerSec over barrageSaturateSec.
    barrageStartSec*: int     ## grenade-barrage endgame: the barrage latches
                              ## on when the game clock has this many seconds
                              ## remaining (default BarrageStartSec — 4:30
                              ## elapsed on the default 5:00 clock). Once
                              ## latched it only ever escalates.
    barrageSaturateSec*: int  ## grenade-barrage endgame: seconds from the
                              ## latch until the ramp completes — whole
                              ## board targeted at barrageMaxPerSec
                              ## (default BarrageSaturateSec, landing full
                              ## saturation exactly at the scheduled end).
    handicaps*: array[Team, int]  ## per-team handicap in PERMILLE (0..1000),
                                  ## authored as a 0.0..1.0 float. 0 = normal
                                  ## (the default, byte-identical to no
                                  ## handicap); 1000 = fully handicapped: 50%
                                  ## of shots miss, 1 life, 1 hit point, half
                                  ## max speed. Intermediate values interpolate
                                  ## linearly (see hitPointsFor/livesFor/
                                  ## maxSpeedFor/missPermilleFor). Integer
                                  ## permille keeps every in-sim derivation
                                  ## integer-only, so native and wasm agree.
    perks*: array[Team, seq[PerkGroup]]
      ## Per-team perk GROUPS. Empty (the default) = no perks, byte-identical
      ## to an engine without the field. One unnamed group = the whole team
      ## shares it; several unnamed = MPE-Doubles: the Nth distinct POLICY to
      ## seat on the team (join order, policyName collapse) gets group N,
      ## clamped to the last. NAMED groups (object config form) pin a group
      ## to its policy exactly; an unmatched policy gets nothing. See
      ## docs/plans/2026-08-07-team-perks-design.md.
    perkMods*: PerkMods        ## the perk magnitudes; DefaultPerkMods unless
                               ## the config's perkMods block overrides.
    puddleDamagePct*: int         ## percent chance (0..100) that one full
                                  ## second of continuous paint-puddle
                                  ## occupancy deals 1 damage. Default 20
                                  ## (GV43; was 10). Inert on maps without
                                  ## puddles (the roll — and its RNG draw —
                                  ## only happens while a cog stands in one,
                                  ## so the puddle-free path stays
                                  ## byte-identical across builds).
    barrierPickups*: int          ## cardboard barrier pickups PER TEAM
                                  ## (0..MaxBarrierPickupsPerTeam), staged on
                                  ## the line from each team's anchor toward
                                  ## map center. 0 = the mode is off — the
                                  ## default, byte-identical to the
                                  ## pre-barrier game (no spawns, no carries,
                                  ## no placements, no new RNG draws).
    # --- particle-worlds gates (all OFF by default: a gate-off config plays the
    # starter's rules unchanged, which is what keeps the inherited engine
    # meaningful) ---
    numAgents*: int               ## seats (websocket connections). 2 here; a
                                  ## seat commands one four-cog squad.
    cogsPerTeam*: int             ## cogs a team fields (4).
    loadout*: string              ## LoadoutMpe (default) or LoadoutParticles.
    floorPaint*: bool             ## the paint grid exists and cones repaint it.
    paintBuff*: bool              ## own/enemy paint changes speed and heals.
    hill*: bool                   ## KotH replaces the capture win condition.
    paintTile*: int               ## px side of one paint tile.
    hillRadiusTiles*: int         ## hill is the (2r+1)^2 tile block at centre.
    hillOwnPermille*: int         ## coverage permille that OWNS the hill.
    hillDecisiveTicks*: int       ## hill-tick margin worth a 1.0 game score.
    paintSpeedOwnPct*: int        ## speed/accel percent on own colour.
    paintSpeedEnemyPct*: int      ## speed/accel percent on enemy colour.
    paintHealTicks*: int          ## consecutive own-paint ticks per +1 hp.
    sprayDamage*: int             ## hp removed by one cone touch.
    regimes*: seq[Regime]         ## regime per game index (resident/visitor).
    turnTicks*: int               ## sim ticks per decision turn.
    turnBudgetMs*: int            ## monotonic cap on one whole turn.
    attempt1Ms*: int              ## first batch deadline.
    retryMs*: int                 ## retry batch deadline.
    turnSpacingMs*: int           ## wall-clock floor between batch starts.
    wallClockBudgetSeconds*: int  ## engine hard stop -> reason "deadline".
    # --- particle worlds (appended; the config object is not wire format, but
    # keeping additions together keeps the schema readable) ---
    rounds*: seq[Mode]            ## the mode played by each round, in order.
    fullyObservable*: bool        ## every seat frame uses an all-visible mask.
                                  ## MPE is a fully observable environment.
    pursuerAccelPct*: int         ## a `tag` pursuer's accel, percent of base.
    pursuerSpeedPct*: int         ## a `tag` pursuer's max speed, percent.
    landmarkRadius*: int          ## px radius of one mark's disc.
    landmarkMargin*: int          ## px kept clear of every board edge.
    landmarkSpacingPx*: int       ## px the sampler aims to keep marks apart.
    spawnRingPx*: int             ## px radius of the spawn circle.
    closeScalePx*: int            ## px at which `closeness` reaches 0.
    bumpPx*: int                  ## px centre distance that counts as a bump.
    bumpPenaltyPermille*: int     ## permille debited per bump tick in spread.
    bumpPenaltyCap*: int          ## ceiling on that debit.
    tagPx*: int                   ## px pursuer contact radius.
    tagTargetTicks*: int          ## contact ticks worth a full pursuer score.
    orbitRadiusPx*: int           ## px `orbit` stand-off.
    shadowStandoffPx*: int        ## px `shadow` stand-off.
    evadeProbePx*: int            ## px `evade` probe radius.
    symbolCount*: int             ## speakable symbols (8 = A..H) plus silence.

  Player* = object
    x*, y*: int
    homeX*, homeY*: int
    velX*, velY*: int
    carryX*, carryY*: int
    flipH*: bool
    aimBrads*: int             ## aim angle in brads, 0..255: 0 = east (+x),
                               ## counter-clockwise on screen (64 = north).
    team*: Team
    alive*: bool
    lives*: int
    hp*: int                   ## remaining hit points this life.
    respawnTimer*: int
    fireCooldown*: int
    fireWindup*: int           ## ticks until a pulled trigger releases its shot.
    windupBrads*: int          ## aim angle locked at the trigger pull, -1 = none.
    carryingFlag*: bool
    hasGrenade*: bool          ## each player carries at most one grenade.
    hasShield*: bool           ## carrying an endzone shield: 3x slower fire.
    shieldHp*: int             ## remaining shield-layer hp (0..ShieldLayerHp);
                               ## damage depletes it before base hp.
    hasSprayPaint*: bool        ## each player carries at most one spray can.
    arcTicksLeft*: int         ## remaining active ticks of a fired spray
                               ## cone (0 = the cone is off).
    arcAimBrads*: int          ## aim direction locked at the spray's fire
                               ## instant, -1 = no active cone. The cone points
                               ## this way for its whole active window: turning
                               ## the cog mid-spray no longer sweeps it. (The
                               ## cone's ORIGIN still rides the owner.)
    arcHitMask*: uint32        ## players already damaged by the current
                               ## activation: one hit per victim per firing.
    throwCharge*: int          ## ticks the throw button has been held.
    puddleTicks*: int          ## consecutive ticks this cog's center has
                               ## stood inside a paint puddle; at
                               ## PuddleRollTicks the damage roll fires and
                               ## the counter restarts. Resets on exit and
                               ## on death. Deterministic gameplay state,
                               ## but NOT mixed into gameHash: hashing a new
                               ## always-zero field would shift every
                               ## pre-puddle replay's hash chain (keyframe
                               ## scrub still restores it exactly via the
                               ## flatty sim snapshot).
    lastShoutTick*: int        ## tick of this player's latest shout, -1 = never.
    paintHitTick*: int         ## tick of the latest PAINT hit taken. Every
                               ## weapon throws paint — gun, grenade, and the
                               ## spray can — so all three stamp it. Cosmetic:
                               ## drives the EYES-PiP visor paint splat; -1 =
                               ## never, never enters gameHash.
    joinOrder*: int
    address*: string
    color*: uint8
    skin*: Skin               ## cosmetic only; excluded from gameHash.
    reward*: int
    kills*: int
    deaths*: int
    captures*: int
    shotsFired*: int           ## shots this player released; analysis-only,
                               ## excluded from gameHash (see gameHash).
    shotsHit*: int             ## released shots that connected with an enemy;
                               ## analysis-only, excluded from gameHash.
    multiKills2*: int          ## grenade blasts / spray bursts that
                               ## killed exactly 2; analysis-only, excluded
                               ## from gameHash.
    multiKills3*: int          ## grenade blasts / spray bursts that
                               ## killed 3 or more; analysis-only, excluded
                               ## from gameHash.
    teamKills*: int            ## teammates this player killed (backstabs);
                               ## analysis-only, excluded from gameHash.
    arcKillsThisFire*: int     ## kills scored by the current spray
                               ## activation; transient multi-kill
                               ## bookkeeping, excluded from gameHash.
    perks*: PerkSet            ## this seat's perks, resolved ONCE at join
                               ## from config.perks + the policy's rank among
                               ## the team's distinct policies (roster.nim).
                               ## Pure function of config + the replayed join
                               ## stream, so excluded from gameHash.
    hasBarrier*: bool          ## carrying one folded cardboard barrier
                               ## (config-gated). Mutually exclusive with
                               ## hasGrenade — both place/throw on button C,
                               ## so a cog holds one or the other, never
                               ## both. Deterministic gameplay state, but NOT
                               ## mixed into gameHash: hashing a new
                               ## always-false field would shift every
                               ## pre-barrier replay's hash chain (keyframe
                               ## scrub still restores it exactly via the
                               ## flatty sim snapshot — the puddleTicks rule).
    attacksMade*: int          ## attack initiations of any kind — gun shots
                               ## released, grenades thrown, spray cans
                               ## fired; analysis-only (the `pacifist`
                               ## achievement), excluded from gameHash.
    damageTaken*: int          ## total damage absorbed this game, shield
                               ## layer included; analysis-only (the
                               ## `spotless` achievement), excluded from
                               ## gameHash.
    damageDealt*: int          ## total damage this cog dealt to OTHER cogs
                               ## (teammates included, self excluded);
                               ## analysis-only (the `grenadier`
                               ## achievement), excluded from gameHash.
    grenadeDamageDealt*: int   ## the grenade-blast share of damageDealt;
                               ## analysis-only, excluded from gameHash.
    gunDamageDealt*: int       ## the inherited-gun share of damageDealt
                               ## (`sniper`); analysis-only.
    sprayDamageDealt*: int     ## the spraypaint-spray share of damageDealt
                               ## (`banksy`); analysis-only.
    pitDamageDealt*: int       ## damageDealt while this cog stood in a
                               ## trench/pit (`pit-master`); analysis-only.
    killsThisLife*: int        ## kills since this cog last spawned; reset on
                               ## death (`rambo`); analysis-only.
    bestKillsInLife*: int      ## max killsThisLife over the game.
    healsThisLife*: int        ## med kits taken since spawn; reset on death
                               ## (`medic`); analysis-only.
    bestHealsInLife*: int      ## max healsThisLife over the game.
    aliveTicks*: int           ## ticks spent alive this game (`pack`).
    packTicks*: int            ## alive ticks with >= PackMates teammates
                               ## inside the pack radius (`pack`).
    hurtByMask*: uint32        ## bit i set = player i damaged this cog in
                               ## its CURRENT life; reset on death
                               ## (`assassin`); analysis-only, excluded from
                               ## gameHash (index >= 32 never tracked).
    assassinKills*: int        ## kill shots (gun/grenade) whose hit was this
                               ## cog's first damage on that victim in the
                               ## victim's life (`assassin`); analysis-only.
    blastsSurvived*: int       ## grenade blasts this cog took and outlived
                               ## this game (`lucky`); analysis-only.
    seat*: int                 ## which SEAT (websocket) owns this cog's squad:
                               ## 0 = RED command, 1 = BLUE command. Set at
                               ## squad construction from the cog's team, so a
                               ## broadcast event keyed by slot keeps working.
                               ## Derived from config, so excluded from gameHash.
    paintUnder*: PaintUnder    ## what this cog's centre stood on at the END of
                               ## the previous tick; consumed by applyInput.
                               ## HASHED (it changes movement).
    ownPaintTicks*: int        ## consecutive ticks on own colour; at
                               ## paintHealTicks it heals 1 hp and resets.
                               ## Reset by stepping off, by damage, by death
                               ## and at the start of each game. HASHED.

  PlayerFov* = object
    ## One player's cached fog-of-war visibility grid (FovGridW x FovGridH
    ## cells). The expensive shadowcast pass depends only on the viewer's
    ## CELL, so it is cached separately (cellVisible) from the final
    ## cone-filtered grid (visible): a viewer who only turns — bots rotate
    ## aim nearly every tick — reuses the cached shadowcast and pays just
    ## the cone filter.
    valid*: bool
    originCx*, originCy*: int
    aimBrads*: int
    visible*: seq[bool]
    cellValid*: bool
    cellCx*, cellCy*: int
    cellVisible*: seq[bool]

  DiamondPatch* = object
    ## Diamond-free wall pixels for one live geometry window. Fields exported
    ## for sim.nim's restamp machinery (stage-1 split); not public API.
    x0*, y0*, w*, h*: int
    frame*: int
    dirty*: bool    ## frame advanced this tick, mask not restamped yet.
    baseWall*: seq[bool]
    neighbours*: seq[int]
      ## Every diamond whose own window overlaps this one, INCLUDING itself.
      ## A restamp ORs all of them, so a shared pixel gets the same answer
      ## whichever window wrote it last. Usually just self; dense generated
      ## maps can pack diamonds closer than the arena does.

  AchievementFocus* = object
    ## One earned achievement paired with its focus cog (see
    ## SimServer.achievementFocus). Analysis-only, never in gameHash.
    id*: string                ## achievement id (AchievementPacifist, ...).
    playerIndex*: int          ## live player index of the focus cog.

  ShotFx* = object
    ## A cosmetic shot tracer segment; never enters gameHash (replay-safe).
    x0*, y0*, x1*, y1*: int
    firedTick*: int
    color*: uint8
    hit*: bool                 ## the shot connected with a player: its tracer
                               ## draws full-bright, a miss draws pre-faded.

  HitFlashFx* = object
    ## A cosmetic "target was struck" flash; never enters gameHash
    ## (replay-safe). The spectator view draws a brief bright ring over the
    ## victim (tracked by index, so the flash follows them) the instant a
    ## bullet connects — making hits legible at a glance where the tracer
    ## alone is ambiguous.
    playerIndex*: int          ## the struck player; players are only appended.
    tick*: int                 ## when the bullet connected.

  BubbleImpactFx* = object
    ## A cosmetic shield-bubble impact; never enters gameHash (replay-safe).
    ## When a bullet lands on a carrier whose bubble is still up, the bubble
    ## itself blinks and dents toward the shooter — replacing the struck-target
    ## ring and body paint spark, so the hit reads as absorbed by the shield.
    playerIndex*: int          ## the struck carrier; players are only appended.
    tick*: int                 ## when the bullet connected.
    angleBrads*: int           ## impact site: direction from the carrier's
                               ## center toward the shooter, in aim brads.

  SplatterFx* = object
    ## A cosmetic death splatter mark; never enters gameHash (replay-safe). A
    ## `hit` mark is the smaller, shorter-lived paint spark left by a non-fatal
    ## hit; a death mark (hit == false) is the larger, long-dwelling splatter.
    x*, y*: int
    tick*: int
    color*: uint8
    hit*: bool

  PaintStain* = object
    ## A DRIED paint stain on the terrain: cosmetic, permanent for the rest of
    ## the match, and never in gameHash (replay-safe). Where SplatterFx marks
    ## where a cog was HIT and fades over a few seconds, a stain is the paint
    ## that missed and hit the map — so the lanes players fight over slowly
    ## accumulate their colors. Emitted once per stain and then left on the
    ## client forever (see addPaintStains), so this is nearly free per frame.
    x*, y*: int
    color*: uint8              ## the SHOOTER's paint, so a lane's color says
                               ## which team keeps running it.
    onWall*: bool              ## true when the paint struck WALL geometry. The
                               ## renderer masks the blot to pixels of this same
                               ## surface, so a splat on a wall stays on the wall
                               ## instead of spilling onto the floor beside it.
    seed*: uint32              ## picks the blot shape/rotation variant, derived
                               ## from the impact site so a replay re-derives
                               ## the identical mark.

  DiamondStain* = object
    ## Paint that landed on a ROTATING center diamond. Stored in the diamond's
    ## OWN un-rotated frame (lx, ly) rather than in map pixels, so the mark
    ## turns with the stone it stuck to instead of hanging in the air where the
    ## shot happened to hit. Cosmetic; never enters gameHash.
    diamond*: uint8            ## index into AnimatedDiamonds.
    lx*, ly*: float32          ## offset from the diamond center, un-rotated.
    color*: uint8
    seed*: uint32

  BlastFx* = object
    ## A cosmetic grenade blast flash; never enters gameHash (replay-safe).
    ## Landing is audible: views also derive their landing sound rings here.
    x*, y*: int
    tick*: int
    color*: uint8              ## the thrower's paint color, so the landing
                               ## splat reads as that team's paint-bomb.
    trenchLanding*: bool       ## true when the blast landed inside a trench:
                               ## the flash renders truncated to the pit's
                               ## footprint instead of the open-field size.

  SprayPaintFx* = object
    ## A cosmetic spray-cone paint flash; never enters gameHash (replay-safe).
    x*, y*: int
    aimBrads*: int
    tick*: int
    color*: uint8
    attacker*: int
      ## Which player fired this snapshot. One burst emits a snapshot per active
      ## tick, each with the owner's LIVE pose; the renderer groups snapshots by
      ## attacker and draws them all along the newest one's pose, so a burst that
      ## swings its aim reads as one plume, not a divergent trail. See
      ## sprayPaintRenderPose.

  DamageFx* = object
    ## A cosmetic floating "-N" damage number that rises and fades above a
    ## player the instant they lose hit points; never enters gameHash
    ## (replay-safe). Makes each of the 3 health bars visibly tick down.
    x*, y*: int                ## where the hit landed (player center at hit).
    tick*: int                 ## when the hit landed.
    amount*: int               ## hit points lost (1 for a shot; a grenade
                               ## varies by trench, see explodeGrenade).
    color*: uint8              ## the victim's team color, so it reads as their loss.
    kill*: bool                ## a fatal hit: drawn as a "KO" kill marker that
                               ## lives KillFxTicks instead of the "-N" number.

  SimEventKind* = enum
    ## Tier-2 analysis event channel (the Logs substrate). Every kind is
    ## emitted at the exact in-sim site where the fact is known first-hand
    ## (weapon, positions, attacker), so downstream never has to guess by
    ## counter-diffing. Analysis-only: never enters gameHash.
    Shot        ## a gun shot released (source = shooter).
    Hit         ## a released shot connected with an enemy on its ray.
    Damage      ## hit points removed (gun/spray/grenade), amount = hp lost.
    Kill        ## a CREDITED kill (mirrors recordKill; self-kills by own
                ## grenade are a Death without a Kill).
    Death       ## a player died (source = victim, target = killer).
    FlagSteal   ## a flag left its pedestal on an enemy's back.
    FlagReturn  ## a flag went home for any reason other than capture.
    Capture     ## a carrier scored the enemy flag.
    Respawn     ## a dead player came back at home.
    Heal        ## hit points restored (med kit or shield pickup).
    PhaseChange ## the game phase moved (lobby / playing / gameover):
                ## weapon = the new phase name, amount = its ordinal.
    GunTrigger  ## a player pulled the gun trigger and locked their aim.
    ShotImpact  ## a released shot ended at a player, wall, or range limit.
    GrenadeThrow
    GrenadeImpact
    SprayUse    ## one active spray-cone tick and the damage it dealt.
    Pickup      ## a player picked up an item; item names the pickup.
    ShoutEvent  ## a player shouted; content is the sanitized text.
    PaintTiles  ## NEW: one cone repainted `amount` floor tiles this tick,
                ## `hp` of which were hill tiles.
    HillFlip    ## NEW: hill ownership changed; weapon = the new owner's team
                ## name or "none", amount = its coverage percent.
    HillHold    ## NEW: one more banked SECOND of hill time; weapon = team,
                ## amount = seconds held.
    Directive   ## NEW: a seat's directive for a turn; weapon = the source
                ## ("llm" | "scripted" | "fallback"), amount = the turn index,
                ## content = the note.
    # --- particle worlds. These six and the two above (PhaseChange,
    # Directive) are the ONLY kinds a particle-worlds episode emits: the
    # weapon, pickup, heart, paint and hill stages never run.
    Symbol      ## a seat's broadcast symbol changed; item = the symbol text,
                ## amount = the turn index.
    Bump        ## two particles' centres came within bumpPx (source, target).
    Tag         ## a pursuer touched the evader after a quiet spell;
                ## amount = its contact ticks so far.
    OnPoint     ## a mobile agent reached the round's goal mark for the first
                ## time this round; amount = the mark index.
    Decode      ## an agent has visibly settled on one mark for SettleTicks;
                ## amount = the mark, item = "right" | "wrong".
    RoundOver   ## a round boundary; weapon = the mode, amount = the round.

  EventDamage* = object
    ## One victim damaged by a primary impact/use event.
    slot*: int
    amount*: int
    hp*: int
    blocked*: int

  SimEvent* = object
    ## One tier-2 analysis event; never enters gameHash (replay-safe).
    ## Collected only while collectEvents is on, so live servers pay nothing.
    tick*: int
    kind*: SimEventKind
    source*: int               ## acting player's stable join slot, -1 = n/a.
    target*: int               ## affected player's stable join slot, -1 = n/a.
    weapon*: string            ## "gun" / "spray" / "grenade", the new phase
                               ## name for PhaseChange, "" = n/a.
    amount*: int               ## hp delta for Damage/Kill/Heal, the new
                               ## phase ordinal for PhaseChange, else 0.
    hp*: int                   ## the affected player's remaining hit points
                               ## AFTER the event, floored at 0 (a fatal
                               ## overkill still reads 0): the victim on
                               ## Damage, the healed player on Heal.
                               ## -1 on every other kind (n/a).
    blocked*: int              ## on a Damage event, how many of `amount`'s hit
                               ## points the victim's SHIELD absorbed — i.e.
                               ## damage prevented from touching the base cog.
                               ## A shield carrier holds bonus hp above the base
                               ## HitPoints ceiling (only a shield pickup lifts a
                               ## cog there), so any of this hit that lands while
                               ## the victim is above base is shield-soaked. 0
                               ## when the victim held no shield hp, and on every
                               ## non-Damage kind (n/a).
    x*, y*: float              ## map position where the event happened.
    actionId*: int64           ## ties stages of one weapon action together.
    headingBrads*: int         ## native aim heading (0..255), -1 = n/a.
    distance*: float           ## throw/shot distance in map pixels.
    item*: string              ## pickup item name, "" = n/a.
    content*: string           ## sanitized shout content, "" = n/a.
    damages*: seq[EventDamage] ## victims damaged by this impact/use.

  Shout* = object
    ## One short player message, audible within ShoutRange of where it was
    ## made. Bots observe shouts, so they are gameplay state (in gameHash)
    ## and replays re-apply the recorded chat records that produced them.
    address*: string           ## the shouter, by player address.
    team*: Team
    text*: string              ## sanitized, at most ShoutMaxChars.
    tick*: int                 ## when it was shouted.
    x*, y*: int                ## shouter center at shout time.

  PickupSpawn* = object
    ## One fixed pickup point: corner grenades and center med kits.
    x*, y*: int
    present*: bool
    respawnAt*: int            ## tick the pickup refills (when not present).

  PlacedBarrier* = object
    ## One standing cardboard barrier: three sides of a hexagon (a half-hex)
    ## whose flat middle side faces where the placer was aiming. It blocks
    ## every PAINT path (gun corridor and spray cone) but never sight, never
    ## movement, and never grenades. The four vertices are snapped to map
    ## pixels at placement, so every later coverage test is integer-only and
    ## native/wasm agree.
    x*, y*: int                ## placement center (the placer's center).
    facingBrads*: int          ## the placer's aim at placement (render/label).
    verts*: array[4, tuple[x, y: int]]  ## half-hex vertices at aim -90,
                               ## -30, +30, +90 degrees; the three sides are
                               ## the consecutive pairs, the middle one flat
                               ## across the aim.
    minX*, minY*, maxX*, maxY*: int  ## coverage bounding box (band included)
                               ## for cheap point rejection.
    hp*: int                   ## particle-worlds hits left (starts at BarrierHp).
    team*: Team                ## the placer's team (tints the tape stripe).
    placedTick*: int

  AirborneGrenade* = object
    ## One thrown grenade in flight: it flies OVER walls in a straight line
    ## from the throw point to the target and explodes on landing.
    sx*, sy*: int
    tx*, ty*: int
    launchTick*: int
    flightTicks*: int
    thrower*: int              ## live index retained for replay-hash compatibility.
    throwerSlot*: int          ## immutable analysis identity; never hashed.
    throwerAccount*: int       ## stable results account; never hashed.

  FlagState* = object
    ## One team's flag: provably sitting on its home pedestal (carrier == -1),
    ## carried by an enemy player (never loose), or retired and out of play
    ## (captured, carrier == -1, frozen where it left play).
    x*, y*: int
    carrier*: int              ## player index carrying this flag, -1 when home.
    captured*: bool            ## the heart is out of play for the rest of the
                               ## game: captured (GV32), or retired because its
                               ## team has been completely killed (GV33). A
                               ## retired heart is never drawn and cannot be
                               ## stolen.

  SimServer* = object
    config*: GameConfig
    players*: seq[Player]
    rewardAccounts*: seq[RewardAccount]
    crewSprites*: seq[CrewSprite]
    flagSprite*: Sprite
    gameMap*: MpeMap
    rooms*: seq[Room]
    flags*: array[Team, FlagState]  ## per-team flags on the home pedestals.
    mapPixels*: seq[uint8]
    mapRgba*: seq[uint8]
    darkBgPixels*: seq[uint8]
    walkMask*: seq[bool]
    wallMask*: seq[bool]
    windowMask*: seq[bool]     ## STATIC glass pixels; wall, but never opaque to vision.
    fovBlocked*: seq[bool]     ## FovGridW x FovGridH; a cell is opaque when mostly wall.
    fovCaches*: seq[PlayerFov]           ## exported for sim.nim (stage-1 split).
    diamondPatches*: seq[DiamondPatch]   ## exported for sim.nim (stage-1 split).
    rng*: Rand
    nextJoinOrder*: int
    tickCount*: int
    recentShots*: seq[ShotFx]  ## cosmetic shot tracers; excluded from gameHash.
    hitFlashes*: seq[HitFlashFx]  ## cosmetic struck-target flashes; excluded from gameHash.
    bubbleImpacts*: seq[BubbleImpactFx]  ## cosmetic shield-bubble impact blinks; excluded from gameHash.
    splatters*: seq[SplatterFx]  ## cosmetic death splatters; excluded from gameHash.
    diamondStains*: seq[DiamondStain]  ## permanent paint riding the spinning
                               ## center diamonds; excluded from gameHash.
    paintStains*: seq[PaintStain]  ## permanent dried terrain paint; excluded from
                               ## gameHash. Append-only within a match and reset
                               ## on startGame/resetToLobby, so a replay rebuilds
                               ## the exact same buildup as it re-simulates and a
                               ## keyframe scrub restores the paint of that tick.
    recentBlasts*: seq[BlastFx]  ## cosmetic grenade blasts; excluded from gameHash.
    damagePops*: seq[DamageFx]  ## cosmetic floating "-N" damage numbers; excluded from gameHash.
    recentShouts*: seq[Shout]  ## live shouts; observable state, in gameHash.
    grenadeSpawns*: array[4, PickupSpawn]
    medKitSpawns*: seq[PickupSpawn]       ## the map's active med kits (2 on
                                          ## sides maps, 4 on 4-team maps).
    shieldSpawns*: seq[PickupSpawn]       ## one shield per team endzone.
    sprayPaintSpawns*: seq[PickupSpawn]    ## one spray can per team endzone.
    airborneGrenades*: seq[AirborneGrenade]
    sprayPaintFlashes*: seq[SprayPaintFx]
    gameStartTick*: int
    startWaitTimer*: int
    lobbyWaitTimer*: int  ## lobby ticks spent short of minPlayers (live-server
                          ## lobby lifecycle only: not hashed, not in replays).
    phase*: GamePhase
    asciiSprites*: PixelFont
    shoutFont*: PixelFont  ## chunky 9px grid font used only for shout bubbles.
    winner*: Team
    lastCaptureTeam*: Team     ## team whose carrier scored the most recent
                               ## heart capture (`heist`); analysis-only.
    lastCaptureTick*: int      ## tick of that capture, -1 = none this game.
    lastCaptureIndex*: int     ## player index of that capture's carrier, -1 =
                               ## none this game; analysis-only (the `heist`
                               ## badge's focus cog), excluded from gameHash.
    achievementFocus*: seq[AchievementFocus]
                               ## per earned achievement, the cog the badge is
                               ## ABOUT (the rambo streaker, the lucky
                               ## survivor, the heist capturer; the team's
                               ## top contributor for team-wide badges).
                               ## Filled by finishGame, analysis-only,
                               ## excluded from gameHash. The replay viewer
                               ## ships it so a badge's watch link can select
                               ## the receiving cog.
    gameOverTimer*: int
    timeLimitReached*: bool
    barrageStartTick*: int     ## tickCount at which the grenade barrage
                               ## latched on; -1 before. Deterministic
                               ## (derived from the clock), so replays
                               ## re-derive it; mixed into gameHash only once
                               ## latched, keeping barrage-off games
                               ## hash-identical.
    barrageAccum*: int         ## fractional-launch accumulator in permille-
                               ## grenade-seconds: each Playing tick adds the
                               ## current rate (permille grenades/second) and
                               ## every TargetFps*1000 drained launches one
                               ## shell. Hashed alongside barrageStartTick.
    isDraw*: bool
    needsReregister*: bool
    gameEventLoggingEnabled*: bool
    collectEvents*: bool       ## tier-2 event sink switch; default off so
                               ## live servers pay nothing (see SimEvent).
    events*: seq[SimEvent]     ## collected tier-2 events; the extractor
                               ## drains this every tick. Never in gameHash.
    lastLobbyPlayersLogged*: int
    lastLobbyNeededLogged*: int
    lastLobbySecondsLogged*: int
    barrierSpawns*: seq[PickupSpawn]  ## config-gated cardboard barrier
                               ## pickups (barrierPickups per team); empty on
                               ## default configs. Appended at the END of the
                               ## type: keyframes are flatty-positional, and
                               ## they are derived in-process (never read
                               ## from a replay file), so appending is safe
                               ## without a GameVersion bump.
    placedBarriers*: seq[PlacedBarrier]  ## standing cardboard barriers,
                               ## oldest first (the placement cap flattens
                               ## index 0). Deterministic gameplay state,
                               ## kept OUT of gameHash like puddleTicks so
                               ## barrier-free games hash identically to
                               ## pre-barrier builds.
    # --- particle-worlds state (appended at the END of the type: keyframes are
    # flatty-POSITIONAL, so new fields may only be appended) ---
    paintOwner*: seq[uint8]    ## gw*gh tiles: 0 unpainted, 1 RED, 2 BLUE.
                               ## HASHED, eight bytes at a time.
    paintFloor*: seq[bool]     ## whether a tile is PAINTABLE — its centre
                               ## pixel is not wall at spin frame 0. Computed
                               ## ONCE at map install, so the native server
                               ## and the wasm viewer agree exactly.
    paintGridW*, paintGridH*: int
    paintCount*: array[Team, int]   ## painted tiles per team (incremental).
    hillTiles*: seq[int]       ## flat tile indices inside the hill square.
    hillFloorTiles*: int       ## how many of those are PAINTABLE (the
                               ## denominator of the 80% test).
    hillPaint*: array[Team, int]    ## hill tiles owned per team (incremental).
    hillTicks*: array[Team, int]    ## banked hill points THIS game. HASHED.
    hillOwner*: Team           ## meaningful only while hillOwned is true.
    hillOwned*: bool
    lastHillFlipTick*: int     ## throttle for the `hillflip` beat.
    regime*: Regime            ## the regime THIS game is played under.
    gameIndex*: int            ## 0-based index of the game inside the episode.
    gameHill*: seq[array[Team, int]]  ## archived hillTicks per finished game.
    gameRegimes*: seq[Regime]  ## the regime each finished game was played under.
    endReason*: string         ## ReasonComplete / ReasonDeadline / ReasonFault.
    endRule*: string           ## EndRuleFullTime / Mercy / Wipe / WallClock / ...
    llmTurns*: array[4, int]   ## per seat: turns whose directive came from an LLM.
    fallbackTurns*: array[4, int]  ## per seat: turns that fell back to scripted.
    seatNames*: array[4, string]   ## real policy names, SPECTATOR SIDE ONLY.
    seatPolicyKind*: array[4, string]  ## "llm" | "scripted".
    feedDirectives*: seq[string]   ## the last few `directive` chat records, as
                               ## JSON text, so the broadcast feed can show the
                               ## commander lines LIVE and in replay from one
                               ## source. Non-hashed presentation state (the
                               ## puddleTicks rule); a keyframe scrub restores
                               ## it exactly through the flatty snapshot.
    # --- particle-worlds state, APPENDED at the END of the type: replay
    # keyframes are flatty-POSITIONAL, so new fields may only be appended.
    # Everything here except commSymbol/commTurn is HASHED (§Determinism):
    # nothing a commander SAYS may move the hash chain.
    roundIndex*: int           ## 0-based index of the round inside the episode.
    mode*: Mode                ## the mode THIS round is played under.
    perm*: array[4, int]       ## the episode's seeded role permutation.
    roleIndex*: array[4, int]  ## role index per SEAT for this round.
    landmarks*: seq[Landmark]  ## always LandmarkCount entries once a round runs.
    goalLandmark*: int         ## the round's goal mark, -1 in spread/tag.
    keySymbols*: array[4, int] ## crypto: symbol index (1..8) per mark COLOUR.
    spawnOffsetBrads*: int     ## this round's spawn-ring rotation, 0..63.
    roundAccum*: array[4, int64]   ## per seat: summed per-tick score term.
    coverAccum*: int64         ## spread: summed per-tick coverage permille.
    bumps*: array[4, int]      ## per seat: bump ticks this round.
    tagCredit*: array[4, int]  ## per seat: contact ticks this round.
    tagTicks*: int             ## ticks with at least one contact this round.
    tagContact*: array[4, bool]    ## per seat: in contact right now.
    lastTagTick*: array[4, int]    ## per seat: tick of its latest `tag` event.
    lastBumpTick*: array[16, int]  ## per unordered pair: `bump` event throttle.
    nearestMark*: array[4, int]    ## per seat: index of the nearest mark, -1.
    settledTicks*: array[4, int]   ## per seat: consecutive settled ticks.
    decodedMark*: array[4, int]    ## per seat: the mark it has settled on, -1.
    onPointDone*: array[4, bool]   ## per seat: `onpoint` already emitted.
    holdX*, holdY*: array[4, int]  ## per seat: the position `hold` returns to.
    commSymbol*: array[4, int]     ## per seat: current symbol, 0 = silence.
                               ## NOT HASHED (the starter's activeDirective
                               ## rule): nothing a commander says may move the
                               ## hash chain, and nothing about the radio
                               ## touches physics.
    commPrev*: array[4, int]       ## per seat: the symbol it held last turn.
    commTurn*: array[4, int]       ## per seat: the turn its symbol was set.
    roundLog*: seq[RoundLogEntry]  ## every round banked so far. HASHED.
    roundsPlayed*: int             ## how many rounds counted toward the mean.


# Team endzone display colors (shared by the map bake and the paint FX).
const
  RedEndzoneColor* = rgba(224, 82, 58, 255)    ## team vermillion (§4).
  BlueEndzoneColor* = rgba(63, 124, 196, 255)  ## team cerulean (§4).
  GreenEndzoneColor* = rgba(69, 168, 94, 255)  ## matches the viewer --green.
  YellowEndzoneColor* = rgba(221, 197, 49, 255)  ## matches the viewer --yellow.
    ## Exported as THE team display colors. The 16-entry `Palette` a sprite's
    ## `color: uint8` indexes is the retro engine palette, and its blue slot
    ## (BlueTeamColor = 13) is a muted lavender (131,118,156) that reads nothing
    ## like the vivid cerulean the soldier art (116,168,255) and the endzone
    ## floor actually show. Any NEW team-colored art should tint from these four
    ## so it matches what a viewer sees on the board.

# Pure aim-angle math (needed on both sides of the art/gameplay split).
proc distSq*(ax, ay, bx, by: int): int =
  let
    dx = ax - bx
    dy = ay - by
  dx * dx + dy * dy

proc aimVector*(brads: int): tuple[x, y: float] =
  ## Returns the unit vector for one aim angle in brads (256 per turn):
  ## 0 points east (+x) and the angle increases counter-clockwise on screen,
  ## so 64 is north (-y in map coordinates), 128 west, and 192 south.
  let angle = float(brads) * PI / float(AimBradsTurn div 2)
  (cos(angle), -sin(angle))

proc bradsOfVector*(dx, dy: int): int =
  ## Returns the aim-brads angle of a map-space vector — the inverse of
  ## `aimVector` (screen y points down, so north is -y).
  if dx == 0 and dy == 0:
    return 0
  let brads = int(round(
    arctan2(-float(dy), float(dx)) * float(AimBradsTurn div 2) / PI))
  ((brads mod AimBradsTurn) + AimBradsTurn) mod AimBradsTurn


# Team helpers (pure functions over the types/consts above).
proc teamCount*(layout: TeamLayout): int =
  ## Returns how many teams a layout seats.
  case layout
  of layoutSides:
    2
  of layoutCorners, layoutPlus:
    4

proc teamCount*(gameMap: MpeMap): int =
  ## Returns how many teams play on one map.
  gameMap.layout.teamCount()

proc activeTeams*(count: int): Slice[Team] =
  ## Returns the active-team slice for one team count. Active teams are
  ## always a prefix of the enum, so 2-team games iterate exactly Red..Blue
  ## — every historical loop, hash, and wire frame is unchanged.
  doAssert count in [2, 4], "team count must be 2 or 4"
  Red .. Team(count - 1)

proc teams*(gameMap: MpeMap): Slice[Team] =
  ## Returns the active teams on one map.
  activeTeams(gameMap.teamCount())

proc teams*(sim: SimServer): Slice[Team] =
  ## Returns the active teams in one game.
  sim.gameMap.teams()


proc teamText*(team: Team): string =
  ## Returns the readable team name.
  case team
  of Red:
    "red"
  of Blue:
    "blue"
  of Green:
    "green"
  of Yellow:
    "yellow"

proc teamColor*(team: Team): uint8 =
  ## Returns the palette color for one team.
  case team
  of Red:
    RedTeamColor
  of Blue:
    BlueTeamColor
  of Green:
    GreenTeamColor
  of Yellow:
    YellowTeamColor

# Per-team handicap accessors. The handicap is stored as a permille (0..1000);
# every derivation below is pure integer math and returns the EXACT base config
# value at permille 0, so an unhandicapped game (the default) is byte-identical
# to one with no handicap field at all — no drift, no extra RNG. See
# docs/plans/2026-08-05-per-team-handicaps-design.md.

proc hitPointsFor*(config: GameConfig, team: Team): int =
  ## Hit points for `team`: interpolates from config.hitPoints down to 1 as the
  ## team's handicap rises from 0 to full.
  let p = config.handicaps[team]
  if p <= 0: config.hitPoints
  else: max(1, config.hitPoints - (config.hitPoints - 1) * p div 1000)

proc livesFor*(config: GameConfig, team: Team): int =
  ## Lives for `team`: interpolates from config.lives down to 1.
  let p = config.handicaps[team]
  if p <= 0: config.lives
  else: max(1, config.lives - (config.lives - 1) * p div 1000)

proc maxSpeedFor*(config: GameConfig, team: Team): int =
  ## Max speed for `team`: interpolates from config.maxSpeed down to half.
  let p = config.handicaps[team]
  if p <= 0: config.maxSpeed
  else: config.maxSpeed * (2000 - p) div 2000

proc missPermilleFor*(config: GameConfig, team: Team): int =
  ## Fraction of a would-be gun hit dropped, in permille (0..500): 0 at no
  ## handicap, 500 (50%) at full. The caller draws RNG only when this is > 0.
  config.handicaps[team] div 2

# Perk accessors. Like the handicap accessors above, every derivation returns
# the EXACT base value when the perk is absent (no arithmetic, no drift, no
# extra RNG), so a perk-free game — the default — is byte-identical to an
# engine without perks. See docs/plans/2026-08-07-team-perks-design.md.

const PerkNames*: array[Perk, string] = [
  "armor", "scope", "grenade", "thruster", "luck"]
  ## The authored/wire name of each perk (config JSON, broadcast roster `pk`,
  ## marker labels, scorebug icon keys).

const DefaultPerkMods* = PerkMods(
  armorHp: 1,         # armor: +1 max hit point.
  scopeAim: 500,      # scope: 50% less aim deviation.
  grenadeRange: 250,  # grenade: +25% throw range.
  thrusterSpeed: 100, # thruster: +10% max speed.
  luckChance: 100,    # luck: 10% of landed shots are lucky.
  luckDamage: 2       # luck: a lucky shot deals 2 hp.
)

proc perkText*(perk: Perk): string =
  ## Returns one perk's authored/wire name.
  PerkNames[perk]

proc parsePerk*(text: string): Perk =
  ## Parses one authored perk name; raises MpeError on an unknown name.
  for perk in Perk:
    if PerkNames[perk] == text:
      return perk
  raise newException(MpeError, "Unknown perk name: " & text)

proc maxHpFor*(config: GameConfig, team: Team, perks: PerkSet): int =
  ## One seat's max hit points: the team's (handicap-interpolated) hit points
  ## plus the armor bonus when the seat carries the perk.
  result = config.hitPointsFor(team)
  if PerkArmor in perks:
    result += config.perkMods.armorHp

proc maxSpeedFor*(config: GameConfig, team: Team, perks: PerkSet): int =
  ## One seat's max speed: the team's (handicap-interpolated) max speed,
  ## boosted by the thruster perk when carried. Integer permille, so native
  ## and wasm agree.
  result = config.maxSpeedFor(team)
  if PerkThruster in perks:
    result = result * (1000 + config.perkMods.thrusterSpeed) div 1000

proc grenadeRangeFor*(config: GameConfig, maxRange: int, perks: PerkSet): int =
  ## One seat's max grenade throw distance, given the map's base
  ## GrenadeMaxRange: boosted by the grenade perk when carried.
  result = maxRange
  if PerkGrenade in perks:
    result = result * (1000 + config.perkMods.grenadeRange) div 1000

proc perkGroupTexts*(config: GameConfig, team: Team): seq[string] =
  ## Each of one team's perk groups as comma-joined perk names in Perk enum
  ## order ("" for an empty group); the empty seq when the team has none.
  ## The shared source for the marker label (labelPerks) and the broadcast
  ## scorebug, so the two streams can never disagree.
  for group in config.perks[team]:
    var names = ""
    for perk in Perk:
      if perk in group.perks:
        if names.len > 0:
          names.add ","
        names.add perkText(perk)
    result.add names

proc policyName*(address: string): string =
  ## The policy identity behind one seat's connection name: the hosted runtime
  ## appends a per-connection " (N)" suffix to the SAME policy's multiple seats
  ## ("softmaxwell (2)", "softmaxwell (7)"…), so stripping it collapses every
  ## seat of one policy to a single shared name. The join path converts spaces
  ## to underscores (server.nim cleanPlayerName), so by the time the name is a
  ## player address the separator reads "_(N)" — accept either. Names without
  ## the suffix (local self-play "Player1"…) pass through unchanged.
  result = address
  if result.len >= 4 and result[^1] == ')':
    var i = result.len - 2
    while i >= 0 and result[i] in {'0' .. '9'}:
      dec i
    if i >= 1 and i < result.len - 2 and result[i] == '(' and
        result[i - 1] in {' ', '_'}:
      result = result[0 ..< i - 1]
      while result.len > 0 and result[^1] in {' ', '_'}:
        result.setLen(result.len - 1)
