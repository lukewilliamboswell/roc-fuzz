#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
from pathlib import Path

from platform_inputs import MANIFEST_NAME, validate_platform_inputs


ROOT = Path(__file__).resolve().parents[1]
PIN_PATH = ROOT / ".roc-version"
PLATFORM_DIR = ROOT / "platform"
MAX_PLATFORM_BYTES = 100 * 1024 * 1024


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

    roc = args.roc
    if os.sep in roc or (os.altsep is not None and os.altsep in roc):
        roc = str(Path(roc).resolve())

    pin_lines = PIN_PATH.read_text(encoding="utf-8").splitlines()
    if len(pin_lines) != 1 or not pin_lines[0].startswith("nightly-"):
        raise SystemExit(".roc-version must contain exactly one Roc nightly tag")
    try:
        version = subprocess.check_output([roc, "version"], text=True).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"failed to query Roc compiler: {error}") from error
    if not compiler_matches_pin(version, pin_lines[0]) and os.environ.get("ROC_ALLOW_UNPINNED") != "1":
        raise SystemExit(
            f"compiler reports {version!r}, which does not match .roc-version; "
            "set ROC_ALLOW_UNPINNED=1 only for intentional compiler development"
        )

    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    try:
        platform_inputs = validate_platform_inputs(ROOT)
    except RuntimeError as error:
        raise SystemExit(str(error)) from error

    roc_files = sorted(PLATFORM_DIR.glob("*.roc"))
    metadata_files = [
        PLATFORM_DIR / "targets" / "x64musl" / MANIFEST_NAME,
        PLATFORM_DIR / "targets" / "x64musl" / "README.md",
    ]
    license_sources = [ROOT / "LICENSE", ROOT / "THIRD_PARTY_LICENSES.md"]
    bundle_sources = [*roc_files, *platform_inputs, *metadata_files]
    unpacked_size = sum(path.stat().st_size for path in [*bundle_sources, *license_sources])
    if unpacked_size > MAX_PLATFORM_BYTES:
        raise SystemExit(
            "platform inputs exceed Roc's default 100 MiB dependency limit: "
            f"{unpacked_size} bytes"
        )

    copied_licenses: list[Path] = []
    try:
        for source in license_sources:
            destination = PLATFORM_DIR / source.name
            if destination.exists():
                raise SystemExit(f"temporary bundle path already exists: {destination}")
            shutil.copy2(source, destination)
            copied_licenses.append(destination)

        bundle_files = [
            path.relative_to(PLATFORM_DIR).as_posix()
            for path in [*bundle_sources, *copied_licenses]
        ]
        print(
            f"Bundling {len(roc_files)} Roc modules, {len(platform_inputs)} "
            f"prebuilt target inputs, and license metadata "
            f"({unpacked_size} bytes unpacked).",
            flush=True,
        )
        subprocess.run(
            [
                roc,
                "bundle",
                *bundle_files,
                "--output-dir",
                str(output_dir),
                "--compression",
                str(args.compression),
            ],
            cwd=PLATFORM_DIR,
            check=True,
        )
    finally:
        for path in copied_licenses:
            path.unlink(missing_ok=True)

    bundles = sorted(output_dir.glob("*.tar.zst"), key=lambda path: path.stat().st_mtime_ns)
    if not bundles:
        raise SystemExit("Roc reported success but did not produce a .tar.zst bundle")
    print(f"Release bundle: {bundles[-1]}")


if __name__ == "__main__":
    main()
