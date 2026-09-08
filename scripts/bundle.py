#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
from pathlib import Path

from platform_inputs import MANIFEST_NAME, TARGETS_BY_NAME, TARGET_SPECS, target_directory, validate_platform_inputs
from compiler_pins import read_pin


ROOT = Path(__file__).resolve().parents[1]
PIN_PATH = ROOT / "platform" / "main.roc"
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
    parser.add_argument(
        "--target",
        action="append",
        choices=sorted(TARGETS_BY_NAME),
        help="bundle only this generated target (repeatable; defaults to all targets)",
    )
    args = parser.parse_args()

    roc = args.roc
    if os.sep in roc or (os.altsep is not None and os.altsep in roc):
        roc = str(Path(roc).resolve())

    pin = read_pin(PIN_PATH)
    try:
        version = subprocess.check_output([roc, "version"], text=True).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"failed to query Roc compiler: {error}") from error
    if not compiler_matches_pin(version, pin) and os.environ.get("ROC_ALLOW_UNPINNED") != "1":
        raise SystemExit(
            f"compiler reports {version!r}, which does not match platform/main.roc; "
            "set ROC_ALLOW_UNPINNED=1 only for intentional compiler development"
        )

    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    try:
        selected_specs = (
            [TARGETS_BY_NAME[name] for name in args.target]
            if args.target
            else list(TARGET_SPECS)
        )
        platform_inputs = validate_platform_inputs(
            ROOT, {spec.roc_name for spec in selected_specs}
        )
    except RuntimeError as error:
        raise SystemExit(str(error)) from error

    roc_files = sorted(PLATFORM_DIR.glob("*.roc"))
    metadata_files = [
        path
        for spec in selected_specs
        for path in (target_directory(ROOT, spec) / MANIFEST_NAME, target_directory(ROOT, spec) / "README.md")
    ]
    metadata_files.extend(
        target_directory(ROOT, spec) / "NATIVE_LIBRARIES.json"
        for spec in selected_specs
        if (target_directory(ROOT, spec) / "NATIVE_LIBRARIES.json").is_file()
    )
    license_sources = [ROOT / "LICENSE", ROOT / "THIRD_PARTY_LICENSES.md"]
    bundle_sources = [*roc_files, *platform_inputs, *metadata_files]
    unpacked_size = sum(path.stat().st_size for path in [*bundle_sources, *license_sources])

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
            f"generated target inputs, and license metadata "
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
    if bundles[-1].stat().st_size > MAX_PLATFORM_BYTES:
        raise SystemExit(
            "compressed platform bundle exceeds Roc's 100 MiB dependency limit: "
            f"{bundles[-1].stat().st_size} bytes"
        )
    print(f"Release bundle: {bundles[-1]}")


if __name__ == "__main__":
    main()
