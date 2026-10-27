# Private runtime trajectories

Set `COGAME_SAVE_TRAJECTORY_URI` to a private `file://` or signed upload destination.
The game records canonical Coworld decision events and a terminal episode summary,
separately from the spectator replay. Capture requires dispatcher-provided
`COWORLD_EPISODE_ID`, `COWORLD_GAME_VERSION`, and `COWORLD_SOURCE_REVISION`.
Missing identity pins fail visibly; they are never inferred from replay bytes.

The engine retains exact native request bodies, prompts, response bytes, response
headers, native `X-Softmax-Llm-Call-Id`, rejected attempts, and its normalized applied
action. Scripted policies and engine fallbacks retain distinct origins. A repaired
model proposal is excluded from accepted model labels. Physical seed families are
`particle-worlds-SEED` across prompt and configuration variants. A deadline is truncated,
and only normal completion qualifies as a completed episode.

File artifacts use exclusive creation and mode 0600. Use a new destination for
each episode. Upload errors propagate; capture is never silently disabled after
being configured. Private trajectories must not be included in public replay uploads.
The canonical SDK `read_trajectory_jsonl` and `complete_episodes` validate the output.
Local protocol fixtures do not establish hosted source authority or model quality.

The supported upstream writer is pinned in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
The legacy Bitworld dependency is preserved to retain stored input and simulation formats.
