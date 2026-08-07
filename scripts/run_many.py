#!/usr/bin/env python3
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    parser = argparse.ArgumentParser(description="Fuzz several Roc quality targets")
    parser.add_argument("targets", nargs="*", help="default: every active target")
    parser.add_argument("--max-total-time", type=int, default=5)
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()

    command = [
        sys.executable,
        str(ROOT / "scripts" / "test.py"),
        "--operation",
        "fuzz",
        "--max-total-time",
        str(args.max_total_time),
    ]
    for target in args.targets:
        command.extend(["--target", target])
    if args.verbose:
        command.append("--verbose")
    raise SystemExit(subprocess.call(command, cwd=ROOT))


if __name__ == "__main__":
    main()
