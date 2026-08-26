#!/usr/bin/env bash
# Records one full particle-worlds episode as a .bitreplay fixture, natively.
#
#   tools/record_fixture.sh <out.bitreplay> [seed] [maxTicks] [extraConfigJson]
#
# The containerised twin of this is tools/ci/docker_smoke.sh, which is what CI
# runs; this is the local forensics path, so it uses whatever binaries are on
# hand rather than building an image:
#
#   nim c -d:release --out:particle-worlds src/particle_worlds.nim
#   nim c -d:release --out:particle-worlds-player src/particle_worlds_player.nim
#   tools/record_fixture.sh /tmp/ep.bitreplay 679961 1080
#   python3 tools/replay_summary.py /tmp/ep.bitreplay | jq .
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:?usage: record_fixture.sh <out.bitreplay> [seed] [maxTicks] [extraJson]}"
SEED="${2:-679961}"
MAXTICKS="${3:-1080}"
EXTRA="${4:-{\}}"
PORT="${PORT:-21000}"
GAME_BIN="${GAME_BIN:-./particle-worlds}"
PLAYER_BIN="${PLAYER_BIN:-./particle-worlds-player}"
SCRIPTED="${SCRIPTED:-drifter}"

for binary in "${GAME_BIN}" "${PLAYER_BIN}"; do
  [ -x "${binary}" ] || {
    echo "missing ${binary} -- build it first (see the header)" >&2
    exit 1
  }
done

work="$(mktemp -d /tmp/pw-fixture-XXXXXX)"
trap 'rm -rf "${work}"; kill 0 2>/dev/null || true' EXIT

python3 - "${work}/config.json" "${SEED}" "${MAXTICKS}" "${EXTRA}" <<'PY'
import json, sys
config = json.load(open("config.json"))
config["seed"] = int(sys.argv[2])
config["maxTicks"] = int(sys.argv[3])
config["turnSpacingMs"] = 0
config.update(json.loads(sys.argv[4]))
json.dump(config, open(sys.argv[1], "w"), indent=1)
PY

COGAME_HOST=127.0.0.1 COGAME_PORT="${PORT}" \
COGAME_CONFIG_URI="file://${work}/config.json" \
COGAME_RESULTS_URI="file://${work}/results.json" \
COGAME_SAVE_REPLAY_URI="file://${PWD}/${OUT}" \
COGAME_EVENTS_URI="file://${work}/events.jsonl" \
"${GAME_BIN}" > "${work}/game.log" 2>&1 &
game_pid=$!

# Wait for the port to LISTEN before starting the seats: the game bakes its
# board render caches before it opens the listener, and a seat that dials too
# early just retries -- but a game that died on its config should fail here
# rather than strand four players in a lobby that will never fill.
for _ in $(seq 1 120); do
  if ! kill -0 "${game_pid}" 2>/dev/null; then
    echo "the game exited before listening:" >&2
    tail -20 "${work}/game.log" >&2
    exit 1
  fi
  if (exec 3<>/dev/tcp/127.0.0.1/"${PORT}") 2>/dev/null; then break; fi
  sleep 0.5
done

tokens=$(python3 -c '
import json, sys
print(" ".join(json.load(open(sys.argv[1]))["tokens"]))' "${work}/config.json")
slot=0
for token in ${tokens}; do
  COWORLD_PLAYER_WS_URL="ws://127.0.0.1:${PORT}/player?slot=${slot}&token=${token}" \
  PLAYER_SCRIPTED="${SCRIPTED}" \
  PLAYER_POLICY_LABEL="${SCRIPTED}-${slot}" \
  "${PLAYER_BIN}" > "${work}/player-${slot}.log" 2>&1 &
  slot=$((slot + 1))
done

wait "${game_pid}"
status=$?
echo "game exited ${status}"
tail -6 "${work}/game.log"
if [ -f "${work}/results.json" ]; then
  python3 -c '
import json, sys
r = json.load(open(sys.argv[1]))
print("reason", r["reason"], r["endRule"], "roundsPlayed", r["roundsPlayed"])
print("modes", r["modes"])
print("scores", r["scores"])' "${work}/results.json"
fi
ls -l "${OUT}"
exit "${status}"
