#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PIN_PATH = ROOT / ".roc-version"


def compiler_matches_pin(version: str, pin: str) -> bool:
    reported = version.split()[-1] if version.split() else version
    if reported == pin:
        return True
    revision = pin.rsplit("-", 1)[-1]
    reported_revision = reported.rsplit("-", 1)[-1]
    return (
        len(revision) >= 7
        and reported_revision.startswith(revision)
        and all(character in "0123456789abcdefABCDEF" for character in reported_revision)
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Create the releasable roc-fuzz platform bundle")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "dist")
    parser.add_argument("--roc", default=os.environ.get("ROC", "roc"))
    parser.add_argument("--compression", type=int, choices=range(1, 23), default=19)
    args = parser.parse_args()

    pin_lines = PIN_PATH.read_text(encoding="utf-8").splitlines()
    if len(pin_lines) != 1 or not pin_lines[0].startswith("nightly-"):
        raise SystemExit(".roc-version must contain exactly one Roc nightly tag")
    try:
        version = subprocess.check_output([args.roc, "version"], text=True).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"failed to query Roc compiler: {error}") from error
    if not compiler_matches_pin(version, pin_lines[0]) and os.environ.get("ROC_ALLOW_UNPINNED") != "1":
        raise SystemExit(
            f"compiler reports {version!r}, which does not match .roc-version; "
            "set ROC_ALLOW_UNPINNED=1 only for intentional compiler development"
        )

    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "build_platform.py")],
        cwd=ROOT,
        check=True,
    )
    result = subprocess.run(
        [
            args.roc,
            "bundle",
            "main.roc",
            "--output-dir",
            str(output_dir),
            "--compression",
            str(args.compression),
        ],
        cwd=ROOT / "platform",
    )
    if result.returncode != 0:
        raise SystemExit(result.returncode)

    bundles = sorted(output_dir.glob("*.tar.zst"), key=lambda path: path.stat().st_mtime_ns)
    if not bundles:
        raise SystemExit("Roc reported success but did not produce a .tar.zst bundle")
    print(f"Release bundle: {bundles[-1]}")


if __name__ == "__main__":
    main()
