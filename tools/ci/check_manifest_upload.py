#!/usr/bin/env python3
"""Run the installed `coworld` CLI's own manifest gates against the template.

The repo's Nim manifest test pins what THIS game needs; this pins what the CLI
accepts. They are different sets, and the second one is only otherwise checked
at release time, inside `coworld certify`'s `matriculate` step — a round trip of
about twelve minutes and one version number per mistake. `matriculate` is
exactly `load_coworld_package`, so this runs the same three calls the CLI does:

    validate_upload_manifest        -- the pydantic upload contract
    validate_coworld_manifest_game_configs
                                    -- every variant AND the certification
                                       fixture against game.config_schema,
                                       with the runner's tokens injected (an
                                       authored `tokens` is REJECTED here:
                                       particle-worlds 0.1.0 lost a dispatch to
                                       `game_config must not include
                                       runner-managed tokens`)
    validate_certification_references
                                    -- every declared player occupies a slot

Docker is not needed: only `build`'s image resolution and the smoke episode need
it, and this substitutes the compose placeholder itself.

    python3 tools/ci/check_manifest_upload.py [--version 0.0.0]
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default="0.0.0")
    args = parser.parse_args()

    from coworld.bundle import _compose_image_placeholders, _load_template_manifest
    from coworld.certifier import load_coworld_package

    manifest_json = json.loads((ROOT / "coworld_manifest_template.json").read_text())
    # The placeholder map `coworld build` derives from `docker compose config`:
    # service `particle_worlds` -> {{PARTICLE_WORLDS_IMAGE}} -> its image.
    placeholders = _compose_image_placeholders(
        {"particle_worlds": {"image": "coworld-particle-worlds:latest"}}
    )
    manifest = _load_template_manifest(manifest_json, args.version, placeholders)

    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
        json.dump(manifest.model_dump(exclude_none=True), handle)
        hydrated = pathlib.Path(handle.name)
    load_coworld_package(hydrated, require_certification_tags=True)
    hydrated.unlink()

    print(
        f"manifest accepted by coworld: {len(manifest.variants)} variants, "
        f"{len(manifest.certification.players)} certification slots"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
