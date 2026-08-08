#!/usr/bin/env python3
"""Build and run one self-contained roc-fuzz target."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path, help="Roc app exposing target : Target")
    parser.add_argument("--corpus", type=Path)
    parser.add_argument("--time", type=int)
    parser.add_argument("--runs", type=int)
    parser.add_argument("--max-input-size", type=int)
    parser.add_argument("--memory-limit", type=int)
    parser.add_argument("--timeout", type=int)
    parser.add_argument("--seed", type=int)
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()

    app = args.app.resolve()
    if not app.is_file() or app.suffix != ".roc":
        raise SystemExit(f"Roc app does not exist: {app}")
    if args.time is not None and args.time < 0:
        raise SystemExit("--time must be non-negative")
    if args.runs is not None and args.runs < 1:
        raise SystemExit("--runs must be at least one")

    subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "build_platform.py")],
        cwd=ROOT,
        check=True,
    )

    output_dir = ROOT / ".test-cache" / "run"
    output_dir.mkdir(parents=True, exist_ok=True)
    executable = output_dir / app.stem
    roc = os.environ.get("ROC", "roc")
    subprocess.run(
        [roc, "build", "--fuzz", str(app), f"--output={executable}"],
        cwd=Path.cwd(),
        check=True,
    )

    command = [str(executable), "run"]
    if args.corpus is not None:
        command.append(str(args.corpus.resolve()))
    for name, value in (
        ("time", args.time),
        ("runs", args.runs),
        ("max-input-size", args.max_input_size),
        ("memory-limit", args.memory_limit),
        ("timeout", args.timeout),
        ("seed", args.seed),
    ):
        if value is not None:
            command.append(f"--{name}={value}")
    if args.verbose:
        command.append("--print-final-stats")
        print("+", " ".join(command), flush=True)
    raise SystemExit(subprocess.call(command, cwd=Path.cwd()))


if __name__ == "__main__":
    main()
