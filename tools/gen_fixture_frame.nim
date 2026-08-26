## Writes `tools/ci/renderer_fixture_frame.json`: the worst-case spectator
## frame the browser fixture feeds to the shipped viewer page. Regenerate and
## commit whenever the frame changes; `tests/test_viewer.nim` fails if the
## committed file and the server's own frame disagree.
##
##   nim r --path:src tools/gen_fixture_frame.nim
import std/[os, strformat]
import fixture_frame

when isMainModule:
  let path = currentSourcePath().parentDir() / "ci" / "renderer_fixture_frame.json"
  let text = worstCaseFramesText()
  writeFile(path, text)
  echo &"wrote {path} ({text.len} bytes)"
