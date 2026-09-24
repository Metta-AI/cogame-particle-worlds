# Training Particle Worlds

The persistent numeric bridge covers all five certified variants: `default`,
`coop`, `deception`, `comms`, and `chase`. It uses each seat's exact hosted
`seatViewJson`, exposes a fixed 178-feature encoding, and passes seven action
heads through the production directive parser and controller. All four views
and scripted teacher actions are frozen before a turn's orders and radio
symbols are applied. A complete episode includes four rounds.

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/particle-worlds-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py /tmp/particle-worlds-train-bridge
```

For Metta RL, call `recipes.external.coworld_metta_rl.train`. For native
PufferLib, call `recipes.external.coworld.train`. Pass a command of the form
`[/tmp/particle-worlds-train-bridge, /path/to/coworld_manifest_template.json,
default]`, choose one of the five variants, and set `players=4`. Always set a
finite timestep limit. The bridge also provides the full seat view as a
semantic observation for Observatory consumers.

# Metta post-training data

The native simulator and published `drifter` policy can export supervised
examples for all five certified variants: `default`, `coop`, `deception`,
`comms`, and `chase`.

```sh
nimby sync nimby.lock
nim r -d:release --path:src tools/export_posttrain.nim \
  /tmp/particle-worlds-default 10 1 default
```

Replace the output path and final argument for another variant. The exporter
reads that variant's manifest config and plays complete seeded four-seat,
four-round games. Every row records the hosted system prompt, the acting
seat's visible observation, and a parsed scripted directive. Decisions for
one seed stay in the same train or validation split. The manifest records
source revision, variant, scores, wins, and row counts. Existing output
directories are never overwritten.

Train with the shared Metta post-training pipeline:

```sh
nix develop -c uv run --package metta-posttrain --extra train \
  python -m metta_posttrain.train --dataset /tmp/particle-worlds-default \
  --output /tmp/particle-worlds-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

Each local 10-game variant exported 1,280 train and 320 validation examples.
All 8,000 examples fit a 4,096-token smoke model. One CPU optimizer update
reduced validation loss for every variant: default 1.7600 to 1.7535, coop
1.7600 to 1.7536, deception 1.7621 to 1.7556, comms 1.7646 to 1.7583,
and chase 1.7562 to 1.7498. The scripted teacher won 28/40, 40/40,
39/40, 8/40, and 0/40 seat games respectively. These data distill a
scripted policy; the update does not establish stronger league play.
