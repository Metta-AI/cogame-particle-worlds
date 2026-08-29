#!/usr/bin/env python3
"""Summarise a particle-worlds `.replay` as one strict-UTF-8 JSON object on stdout.

Python 3 standard library only: no Nim, no Docker, no emsdk. This is the JSON
view of the binary `COWLDMPE` replay the static wasm viewer parses, and it is
what phase 60's definition-of-done check reads instead of `jq .` on the raw
bytes:

    curl -sSL "$replay_url" -o /tmp/ep.replay
    python3 tools/replay_summary.py /tmp/ep.replay > /tmp/ep.json
    jq -e . /tmp/ep.json >/dev/null                  # strict UTF-8 JSON: ok
    jq -r '.protocol, .results.reason, .results.roundsPlayed' /tmp/ep.json
    jq -r '[.directives[]|select(.source=="llm")]|length, .fallbacks' /tmp/ep.json
    jq -r '[.symbols[]|select(.symbol!="-")]|length' /tmp/ep.json

The replay stays binary on purpose: a JSON replay would mean rewriting
replays.nim, replay_runtime.nim, static_replay_worker.js and
wasm_replay_smoke.cjs — the machinery this fork exists to reuse.

How it reads the file WITHOUT a decoder for the whole record stream:

* the header is SELF-DESCRIBING -- magic, u16 format version, then the game
  name, the game version and the config JSON each as a u16-length-prefixed
  string, with a u64 wall-clock stamp before the config -- so those four
  fields are read by their own lengths. (They used to be recovered by
  scanning: the first digit run for the version, the first `{` for the
  config. Both are wrong, because the u64 stamp sitting between them is
  BINARY: roughly one stamp in twenty ends in an ASCII digit and stretched
  the version to "20", and one in 256 contains a `{` and swallowed the
  config.)
* the CONTROL records — `roundcard`, `register`, `directive`, `fallback`,
  `budget_guard`, `result` — are UTF-8 JSON objects embedded verbatim in the
  chat records, so they are recovered by BRACE-MATCHING the bytes after the
  config for balanced `{"k":...}` objects (the technique the starter's
  AGENTS.md documents for prod forensics).

Nothing here needs the record framing, so it cannot drift when the framing
changes; it only needs the two things that are text.
"""

from __future__ import annotations

import json
import sys


MAGIC = b"COWLDMPE"


def brace_match(data: bytes, start: int) -> tuple[dict | None, int]:
    """Decode one balanced ``{...}`` starting at ``start``.

    Returns ``(obj, end)`` where ``end`` is the index just past the object, or
    ``(None, start + 1)`` when the bytes there are not a decodable object.
    """
    depth = 0
    in_string = False
    escaped = False
    for i in range(start, len(data)):
        ch = data[i]
        if in_string:
            if escaped:
                escaped = False
            elif ch == 0x5C:      # backslash
                escaped = True
            elif ch == 0x22:      # quote
                in_string = False
            continue
        if ch == 0x22:
            in_string = True
        elif ch == 0x7B:          # {
            depth += 1
        elif ch == 0x7D:          # }
            depth -= 1
            if depth == 0:
                chunk = data[start:i + 1]
                try:
                    return json.loads(chunk.decode("utf-8")), i + 1
                except (UnicodeDecodeError, json.JSONDecodeError):
                    return None, start + 1
        elif depth == 0:
            # A stray byte before any brace: not the start of an object.
            return None, start + 1
    return None, len(data)


def summarise(path: str) -> dict:
    data = open(path, "rb").read()
    protocol = "particle-worlds/v1"
    game_version = ""
    # The header is self-describing, so READ it rather than guess at it: the
    # magic, a u16 format version, then the game name and the game version as
    # u16-length-prefixed strings (bitworld's `writeReplayString`, little
    # endian). The eight bytes that follow the version are a u64 wall-clock
    # stamp, so the old "first digit run after the game name" scan appended a
    # stamp byte whenever the low byte happened to be ASCII '0'-'9' -- or one
    # of latin-1's superscript digits, which `str.isdigit()` also accepts --
    # and reported a version like "20". That is ~13 of 256 stamps, and it made
    # tests/test_replay.nim fail about one run in twenty.
    config: dict = {}
    cursor = 0
    if data.startswith(MAGIC):
        pos = len(MAGIC) + 2                        # past the u16 format version
        pos += 2 + int.from_bytes(data[pos:pos + 2], "little")   # past gameName
        version_len = int.from_bytes(data[pos:pos + 2], "little")
        game_version = data[pos + 2:pos + 2 + version_len].decode("utf-8")
        pos += 2 + version_len + 8                  # past the version + u64 stamp
        config_len = int.from_bytes(data[pos:pos + 2], "little")
        cursor = pos + 2 + config_len
        config = json.loads(data[pos + 2:cursor].decode("utf-8"))

    directives: list[dict] = []
    fallbacks = 0
    registers: list[dict] = []
    roundcards: list[dict] = []
    budget_guards = 0
    results: dict = {}
    i = cursor
    while True:
        i = data.find(b'{"k":', i)
        if i < 0:
            break
        obj, nxt = brace_match(data, i)
        i = nxt
        if not isinstance(obj, dict):
            continue
        kind = obj.get("k")
        if kind == "directive":
            directives.append(obj)
        elif kind == "fallback":
            fallbacks += 1
        elif kind == "register":
            registers.append(obj)
        elif kind == "roundcard":
            roundcards.append(obj)
        elif kind == "budget_guard":
            budget_guards += 1
        elif kind == "result":
            results = obj.get("results", obj)

    names = [p.get("name", "") for p in (config.get("players") or [])]
    # One particle per seat, dealt red / blue / green / yellow, so the aliases
    # are a pure function of the seat count.
    aliases = [
        f"{colour}-alpha"
        for colour in ("RED", "BLUE", "GREEN", "YELLOW")
    ][: int(config.get("num_agents") or config.get("numAgents") or 4)]

    # Every symbol anybody broadcast, in order, straight out of the directive
    # records: a coworld about talking whose replay contains no words is broken
    # even if it is green, so this is the thing phase 60 counts.
    symbols: list[dict] = []
    for record in directives:
        for cog in record.get("cogs") or []:
            symbols.append({
                "round": record.get("round"),
                "turn": record.get("turn"),
                "seat": record.get("seat"),
                "alias": cog.get("id"),
                "symbol": cog.get("symbol", "-"),
            })

    rounds = [
        {
            "round": card.get("round"),
            "mode": card.get("mode"),
            "roles": card.get("roles") or [],
            "goal": card.get("goal"),
            "goal_colour": card.get("goal_colour"),
            "key": card.get("key"),
            "marks": card.get("marks") or [],
        }
        for card in roundcards
    ]

    return {
        "protocol": protocol,
        "gameVersion": game_version,
        "seed": config.get("seed"),
        "names": names,
        "aliases": aliases,
        "policyKinds": [r.get("kind", "") for r in registers],
        "rounds": rounds,
        "modes": config.get("rounds") or [],
        "tickCount": len(data),
        "symbols": symbols,
        "directives": directives,
        "fallbacks": fallbacks,
        "budgetGuards": budget_guards,
        "results": results,
    }


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: replay_summary.py <path.replay>", file=sys.stderr)
        return 2
    out = summarise(argv[1])
    # ensure_ascii=False keeps a non-ASCII policy label or note as real UTF-8,
    # which is exactly what the strict-parse check downstream is testing.
    sys.stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
