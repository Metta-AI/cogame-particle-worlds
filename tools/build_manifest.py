#!/usr/bin/env python3
"""Generate coworld_manifest_template.json.

`game.docs` and `game.protocols` must ship as INLINE TEXT (the garble v0.1.0 scar: they are
`{"type":"text","value":...}` objects, not bare strings, and not URIs), which means the manifest
carries a copy of README.md, docs/RULES.md, docs/PROTOCOL.md and docs/COMMANDING.md. Keeping those
copies in sync by hand is how a manifest and its docs drift, so this script is the single source:
run it whenever a doc or a constant changes and commit the regenerated manifest.

    python3 tools/build_manifest.py            # rewrite coworld_manifest_template.json
    python3 tools/build_manifest.py --check     # fail if the committed file is stale

`tests/test_manifest.nim` asserts the manifest against the sim, and ci.yml runs --check, so a
hand-edited manifest is caught in CI rather than at release time.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "coworld_manifest_template.json"

SLUG = "particle-worlds"
IMAGE_PLACEHOLDER = "{{PARTICLE_WORLDS_IMAGE}}"
SOURCE_URL = "https://github.com/Metta-AI/cogame-particle-worlds/tree/main"
SEATS = 4

# Every physics/scoring constant, at the default the sim ships. Shared by every variant so a
# variant differs ONLY in its mode sequence.
CONSTANTS = {
    "seed": 679961,
    "num_agents": SEATS,
    "minPlayers": SEATS,
    "teams": 4,
    "cogsPerTeam": 1,
    "maxTicks": 1080,
    "maxGames": 4,
    "turnTicks": 108,
    "turnBudgetMs": 10000,
    "attempt1Ms": 6000,
    "retryMs": 3000,
    "turnSpacingMs": 9000,
    "wallClockBudgetSeconds": 690,
    "lobbyJoinTimeoutTicks": 2400,
    "startWaitTicks": 120,
    "gameOverTicks": 72,
    "mapPath": "field",
    "fastMode": True,
    "showPlayerLabels": False,
    "fullyObservable": True,
    "visionConeDeg": 180,
    "visionBubble": 4096,
    "motionScale": 256,
    "accel": 250,
    "maxSpeed": 1100,
    "frictionNum": 192,
    "frictionDen": 256,
    "stopThreshold": 8,
    "playerBouncePct": 40,
    "aimTurnRate": 5,
    "pursuerAccelPct": 75,
    "pursuerSpeedPct": 77,
    "landmarkRadius": 18,
    "landmarkMargin": 140,
    "landmarkSpacingPx": 300,
    "spawnRingPx": 250,
    "closeScalePx": 500,
    "bumpPx": 14,
    "bumpPenaltyPermille": 1,
    "bumpPenaltyCap": 250,
    "tagPx": 20,
    "tagTargetTicks": 120,
    "orbitRadiusPx": 120,
    "shadowStandoffPx": 60,
    "evadeProbePx": 200,
    "symbolCount": 8,
}

MODES = ["spread", "deceive", "crypto", "tag"]

VARIANTS = [
    ("default", "Particle worlds — four scenarios",
     "The ranked variant. Four particles, four seeded landmarks and a nine-value radio play all "
     "four MPE scenarios back to back: spread, deceive, crypto, tag. Roles rotate on a seeded "
     "permutation, so every seat holds every role index exactly once per episode.",
     ["spread", "deceive", "crypto", "tag"]),
    ("coop", "Spread — cover the marks",
     "Four rounds of simple_spread. All four particles are on the same side and are scored on how "
     "well the four marks are covered, minus a small per-tick penalty for touching each other. "
     "Nobody is told which mark is whose.",
     ["spread", "spread", "spread", "spread"]),
    ("deception", "Deceive — hide the goal",
     "Four rounds of simple_adversary. One mark is the goal; three particles are told which and "
     "one is not. The three score for covering it AND for the adversary being far from it, and "
     "the radio is public — so coordinating the bait is coordinating in the clear.",
     ["deceive", "deceive", "deceive", "deceive"]),
    ("comms", "Crypto — talk past the eavesdroppers",
     "Four rounds of simple_crypto with two eavesdroppers instead of one. An anchored speaker "
     "shares a per-round key with a mobile listener; two key-less eavesdroppers hear every symbol "
     "and can only infer from behaviour. Each of the four seats is the speaker exactly once.",
     ["crypto", "crypto", "crypto", "crypto"]),
    ("chase", "Tag — one runner, three hooks",
     "Four rounds of simple_tag. One fast evader (94 px/s) against three slow pursuers (70 px/s) "
     "on a wall-bounded field; a pursuer needs five seconds of contact inside 20 px for a full "
     "score. The marks are decoration; the walls are not.",
     ["tag", "tag", "tag", "tag"]),
]


def text(value: str) -> dict:
    return {"type": "text", "value": value}


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def scalar_schema() -> dict:
    """Every scalar config property, with its default and its bounds."""
    ints = {
        "seed": (0, 2_147_483_647),
        "num_agents": (SEATS, SEATS),
        "minPlayers": (1, 32),
        "teams": (4, 4),
        "cogsPerTeam": (1, 1),
        "maxTicks": (1, 100_000),
        "maxGames": (1, 4),
        "turnTicks": (1, 10_000),
        "turnBudgetMs": (1, 120_000),
        "attempt1Ms": (1000, 120_000),
        "retryMs": (1000, 120_000),
        "turnSpacingMs": (0, 120_000),
        "wallClockBudgetSeconds": (1, 720),
        "lobbyJoinTimeoutTicks": (0, 100_000),
        "startWaitTicks": (0, 10_000),
        "gameOverTicks": (0, 10_000),
        "visionConeDeg": (0, 180),
        "visionBubble": (0, 100_000),
        "motionScale": (1, 4096),
        "accel": (1, 100_000),
        "maxSpeed": (1, 100_000),
        "frictionNum": (0, 4096),
        "frictionDen": (1, 4096),
        "stopThreshold": (0, 4096),
        "playerBouncePct": (0, 100),
        "aimTurnRate": (1, 128),
        "pursuerAccelPct": (1, 100),
        "pursuerSpeedPct": (1, 100),
        "landmarkRadius": (1, 200),
        "landmarkMargin": (1, 600),
        "landmarkSpacingPx": (120, 1200),
        "spawnRingPx": (1, 600),
        "closeScalePx": (1, 4000),
        "bumpPx": (0, 200),
        "bumpPenaltyPermille": (0, 1000),
        "bumpPenaltyCap": (0, 1000),
        "tagPx": (0, 200),
        "tagTargetTicks": (1, 100_000),
        "orbitRadiusPx": (1, 1200),
        "shadowStandoffPx": (1, 1200),
        "evadeProbePx": (1, 1200),
        "symbolCount": (4, 8),
    }
    props: dict = {}
    for name, (lo, hi) in ints.items():
        props[name] = {
            "type": "integer",
            "minimum": lo,
            "maximum": hi,
            "default": CONSTANTS[name],
        }
    for name in ("fastMode", "showPlayerLabels", "fullyObservable"):
        props[name] = {"type": "boolean", "default": CONSTANTS[name]}
    props["mapPath"] = {
        "type": "string",
        "enum": ["field"],
        "default": "field",
        "description": "The hand-authored particle-worlds board: border walls only.",
    }
    return props


def config_schema() -> dict:
    props = {
        "tokens": {
            "description": "One connection token per seat, indexed by slot.",
            "type": "array",
            "minItems": SEATS,
            "maxItems": SEATS,
            "items": {"type": "string", "minLength": 1},
        },
        "players": {
            "description": "One display-name object per seat, indexed by slot.",
            "type": "array",
            "minItems": SEATS,
            "maxItems": SEATS,
            "items": {
                "type": "object",
                "additionalProperties": False,
                "properties": {"name": {"type": "string"}},
            },
        },
        "slots": {
            "description": "One colour per seat, in seat order: red, blue, green, yellow.",
            "type": "array",
            "minItems": SEATS,
            "maxItems": SEATS,
            "items": {
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "team": {"type": "string", "enum": ["red", "blue", "green", "yellow"]}
                },
            },
        },
        "rounds": {
            "description": "The mode played by each round of the episode, in order.",
            "type": "array",
            "minItems": 1,
            "maxItems": 4,
            "items": {"type": "string", "enum": MODES},
            "default": MODES,
        },
    }
    props.update(scalar_schema())
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "additionalProperties": False,
        "required": ["tokens", "players"],
        "properties": props,
    }


def results_schema() -> dict:
    seat_array = lambda items: {  # noqa: E731
        "type": "array",
        "minItems": SEATS,
        "maxItems": SEATS,
        "items": items,
    }
    round_array = lambda items: {  # noqa: E731
        "type": "array",
        "minItems": 1,
        "maxItems": 4,
        "items": items,
    }
    inner_round = lambda items: {  # noqa: E731
        "type": "array",
        "minItems": 1,
        "maxItems": 4,
        "items": items,
    }
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "additionalProperties": False,
        "required": ["names", "scores", "win", "reason", "endRule", "roundsPlayed"],
        "properties": {
            "names": seat_array({"type": "string"}),
            "scores": seat_array({"type": "number", "minimum": 0, "maximum": 1}),
            "win": seat_array({"type": "boolean"}),
            "alias": seat_array({"type": "string"}),
            "colour": seat_array(
                {"type": "string", "enum": ["red", "blue", "green", "yellow"]}
            ),
            "roles": seat_array(inner_round({"type": "string"})),
            "roundScores": seat_array(
                inner_round({"type": "number", "minimum": 0, "maximum": 1})
            ),
            "coverPct": round_array({"type": "integer", "minimum": 0, "maximum": 100}),
            "bumps": seat_array({"type": "integer", "minimum": 0}),
            "tagTicks": round_array({"type": "integer", "minimum": 0}),
            "goalHits": round_array({"type": "integer", "minimum": 0, "maximum": SEATS}),
            "llmTurns": seat_array({"type": "integer", "minimum": 0}),
            "fallbackTurns": seat_array({"type": "integer", "minimum": 0}),
            "modes": round_array({"type": "string", "enum": MODES}),
            "roundTicks": round_array({"type": "integer", "minimum": 0}),
            "roundEndRules": round_array(
                {"type": "string", "enum": ["full_time", "wall_clock"]}
            ),
            "roundsPlayed": {"type": "integer", "minimum": 0, "maximum": 4},
            "reason": {"type": "string", "enum": ["complete", "deadline", "fault"]},
            "endRule": {
                "type": "string",
                "enum": ["full_time", "wall_clock", "sim_fault", "host_error"],
            },
            "games": {"type": "integer", "minimum": 1, "maximum": 4},
            "finalTick": {"type": "integer", "minimum": 0},
            "seed": {"type": "integer"},
        },
    }


def variant_config(rounds: list[str]) -> dict:
    config = dict(CONSTANTS)
    config["rounds"] = rounds
    config["players"] = [{"name": f"Particle{i + 1}"} for i in range(SEATS)]
    config["slots"] = [
        {"team": "red"}, {"team": "blue"}, {"team": "green"}, {"team": "yellow"}
    ]
    # No `tokens`: they are RUNNER-managed. `game.config_schema` must declare and require
    # them (the CLI injects one per seated player before validating), but an authored
    # game_config that carries them fails certification at `matriculate` with
    # `manifest_invalid: game_config must not include runner-managed tokens`
    # (coworld 0.1.42 manifest_validation.game_config_with_tokens; particle-worlds 0.1.0).
    return config


def certification() -> dict:
    # All four seats scripted, no LLM, no rate floor, 4 x 240 ticks = 960 ticks = 40 s of
    # playback at 24 fps -- deliberately LONGER than any viewer soak window (the ecos
    # 2026-08-23 scar) while fastMode plays it in a handful of wall seconds. All four modes
    # appear, so the fixture's replay exercises every readout and every beat kind.
    game_config = {
        "players": [{"name": f"P{i + 1}"} for i in range(SEATS)],
        "slots": [
            {"team": "red"}, {"team": "blue"}, {"team": "green"}, {"team": "yellow"}
        ],
        "num_agents": SEATS,
        "minPlayers": SEATS,
        "teams": 4,
        "cogsPerTeam": 1,
        "seed": 679961,
        "mapPath": "field",
        "fullyObservable": True,
        "rounds": MODES,
        "maxTicks": 240,
        "maxGames": 4,
        "turnTicks": 108,
        "turnBudgetMs": 10000,
        "attempt1Ms": 6000,
        "retryMs": 3000,
        "turnSpacingMs": 0,
        "wallClockBudgetSeconds": 180,
        "lobbyJoinTimeoutTicks": 1440,
        "startWaitTicks": 0,
        "gameOverTicks": 24,
        "fastMode": True,
        "showPlayerLabels": False,
    }
    return {
        # Every DECLARED player entry must occupy a certification slot (the raid 0.1.2
        # players_missing scar). `baseline` is the only declared player, and it is seated in
        # all four slots.
        "players": [{"player_id": "baseline"} for _ in range(SEATS)],
        "game_config": game_config,
    }


def manifest() -> dict:
    return {
        "$schema": "https://raw.githubusercontent.com/Metta-AI/metta/main/packages/coworld/"
                   "src/coworld/coworld_manifest_schema.json",
        "tags": [
            "particles",
            "mpe",
            "emergent-communication",
            "deception",
            "cooperative",
            "llm",
            "pettingzoo",
        ],
        "episode_timeout_minutes": 20,
        "game": {
            "name": SLUG,
            "replay_viewer": {"bundle": "static-replay-viewer"},
            "description": (
                "Four particles glide on a bounded field around four coloured landmarks and play "
                "four MPE scenarios back to back: cover the marks together, hide a goal from an "
                "adversary, smuggle a colour past two eavesdroppers, and run a three-on-one "
                "chase. Moving is nearly free; the only thing a seat can say to another seat is "
                "one symbol out of nine, once every 4.5 seconds, broadcast to the whole field."
            ),
            "owner": "daveey",
            "runnable": {
                "type": "game",
                "image": IMAGE_PLACEHOLDER,
                "run": ["/bin/particle-worlds"],
                "source_url": SOURCE_URL,
            },
            "config_schema": config_schema(),
            "results_schema": results_schema(),
            "protocols": {
                "player": text(read("docs/PROTOCOL.md")),
                "global": text(read("docs/PROTOCOL.md")),
            },
            "docs": {
                "readme": text(read("README.md")),
                "pages": [
                    {
                        "id": "rules",
                        "title": "Rules",
                        "content": text(read("docs/RULES.md")),
                    },
                    {
                        "id": "protocol",
                        "title": "Wire protocol",
                        "content": text(read("docs/PROTOCOL.md")),
                    },
                    {
                        "id": "commanding",
                        "title": "Writing a particle-worlds prompt",
                        "content": text(read("docs/COMMANDING.md")),
                    },
                ],
            },
        },
        "player": [
            {
                "id": "baseline",
                "type": "player",
                "name": "Drifter Baseline",
                "description": (
                    "Scripted particle: covers its assigned mark, speaks the key honestly as the "
                    "speaker, decodes it as the listener, tails the listener as an eavesdropper, "
                    "and flees or chases in tag."
                ),
                "image": IMAGE_PLACEHOLDER,
                "run": ["/bin/particle-worlds-player"],
                "env": {"PLAYER_SCRIPTED": "drifter"},
                "source_url": SOURCE_URL,
                "resources": {
                    "requests": {"cpu": "100m", "memory": "64Mi"},
                    "limits": {"cpu": "1"},
                },
            }
        ],
        "variants": [
            {
                "id": vid,
                "name": name,
                "description": description,
                "game_config": variant_config(rounds),
            }
            for vid, name, description, rounds in VARIANTS
        ],
        "certification": certification(),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    rendered = json.dumps(manifest(), indent=2, ensure_ascii=False) + "\n"
    if args.check:
        current = OUT.read_text(encoding="utf-8") if OUT.exists() else ""
        if current != rendered:
            print(
                "coworld_manifest_template.json is stale: re-run "
                "`python3 tools/build_manifest.py` and commit the result.",
                file=sys.stderr,
            )
            return 1
        print("coworld_manifest_template.json is up to date")
        return 0
    OUT.write_text(rendered, encoding="utf-8")
    print(f"wrote {OUT.relative_to(ROOT)} ({len(rendered)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
