"""Compare complete source games, including original-checkout canonical exports."""

import argparse
import json
import subprocess
from pathlib import Path


def episodes(path: Path):
    decisions = []
    with path.open() as stream:
        for line in stream:
            row = json.loads(line)
            if row["event_type"] == "decision":
                decisions.append(row)
            else:
                assert row["event_type"] == "episode" and row["status"] == "completed"
                yield decisions, row
                decisions = []
    assert not decisions


def compare(candidate: Path, canonical: Path) -> None:
    count = 0
    for (actual, outcome), (expected, original) in zip(
        episodes(candidate / "trajectories.jsonl"), episodes(canonical / "trajectories.jsonl"), strict=True
    ):
        assert outcome["seed_family"] == original["seed_family"]
        assert outcome["outcome"] == original["outcome"]
        assert outcome["participant_outcomes"] == original["participant_outcomes"]
        for row, reference in zip(actual, expected, strict=True):
            view, baseline_view = row["observation"], reference["observation"]
            view.pop("prompt_template")
            baseline_view.pop("prompt_template")
            assert view == baseline_view
            for key in ("executed_action", "action_status", "seat", "terminal", "decision_index"):
                assert row[key] == reference[key]
            assert row["prompt"][1:] == reference["prompt"][1:]
            system = row["prompt"][0]["content"]
            canonical_system = reference["prompt"][0]["content"]
            assert (
                system[system.index("You accelerate;") :]
                == canonical_system[canonical_system.index("You accelerate;") :]
            )
            assert row["attempts"][0]["response"] == reference["attempts"][0]["response"]
        count += 1
    assert count == 10


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--baseline-root", type=Path)
    parser.add_argument("--baseline-binary", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    args.output.mkdir(parents=True, exist_ok=False)
    binary = args.binary.resolve()
    variants = ("default", "coop", "deception", "comms", "chase")
    for variant in variants:
        canonical = args.output / (variant + "-canonical")
        subprocess.run(
            [str(binary), str(canonical.resolve()), "10", "1", variant, "canonical", "0"], cwd=root, check=True
        )
        if args.baseline_root is not None:
            assert args.baseline_binary is not None
            baseline = args.output / (variant + "-original")
            subprocess.run(
                [str(args.baseline_binary.resolve()), str(baseline.resolve()), "10", "1", variant],
                cwd=args.baseline_root,
                check=True,
            )
            originals = {}
            for split in ("train", "validation"):
                with (baseline / (split + ".jsonl")).open() as stream:
                    for line in stream:
                        row = json.loads(line)
                        originals[(row["episode_id"], row["decision_id"])] = row
            count = 0
            for decisions, outcome in episodes(canonical / "trajectories.jsonl"):
                seed = outcome["seed_family"].removeprefix("particle-worlds-")
                for decision in decisions:
                    original = originals.pop((f"particle-worlds-{variant}-{seed}", decision["decision_index"]))
                    assert decision["prompt"] == original["prompt"]
                    assert decision["attempts"][0]["response"] == original["completion"][0]["content"]
                count += 1
            assert not originals and count == 10
            assert (
                json.loads((canonical / "manifest.json").read_text())["runs"]
                == json.loads((baseline / "manifest.json").read_text())["runs"]
            )
            print(variant, "ten original canonical games PASS", flush=True)
        mixed = args.output / (variant + "-mixed")
        subprocess.run(
            [str(binary), str(mixed.resolve()), "10", "1", variant, "mixed", str(variants.index(variant))],
            cwd=root,
            check=True,
        )
        compare(mixed, canonical)
        print(variant, "ten mixed games PASS", flush=True)
    for wording in ("plain", "numbered", "questions", "reordered"):
        candidate = args.output / ("default-" + wording)
        subprocess.run(
            [str(binary), str(candidate.resolve()), "10", "1", "default", wording, "0"], cwd=root, check=True
        )
        compare(candidate, args.output / "default-canonical")
        print(wording, "ten default games PASS", flush=True)
    for wording in ("heldout-briefing", "heldout-reference"):
        destination = args.output / wording
        rejected = subprocess.run(
            [str(binary), str(destination.resolve()), "10", "1", "default", wording, "0"],
            check=False,
            cwd=root,
            capture_output=True,
            text=True,
        )
        assert rejected.returncode != 0 and "held-out wording" in rejected.stderr
        assert not destination.exists()
    print("140 source games and held-out exclusion PASS", flush=True)


if __name__ == "__main__":
    main()
