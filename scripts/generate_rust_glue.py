#!/usr/bin/env python3
from __future__ import annotations

import argparse
import filecmp
import os
import shutil
import subprocess
import tempfile
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PIN_FILE = ROOT / ".roc-version"
PLATFORM = ROOT / "platform" / "main.roc"
OUTPUT = ROOT / "src" / "roc_platform_abi.rs"


class GlueFailure(Exception):
    pass


def read_pin() -> str:
    lines = [line.strip() for line in PIN_FILE.read_text(encoding="utf-8").splitlines()]
    if len(lines) != 1 or not lines[0].startswith("nightly-"):
        raise GlueFailure(".roc-version must contain exactly one Roc nightly tag")
    return lines[0]


def matches_pin(version: str, pin: str) -> bool:
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


def compiler_version(roc: str) -> str:
    try:
        return subprocess.check_output([roc, "version"], text=True).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise GlueFailure(f"failed to run {roc!r} version: {error}") from error


def download_glue_spec(pin: str, destination: Path) -> None:
    revision = pin.rsplit("-", 1)[-1]
    url = f"https://raw.githubusercontent.com/roc-lang/roc/{revision}/src/glue/src/RustGlue.roc"
    try:
        with urllib.request.urlopen(url) as response:
            destination.write_bytes(response.read())
    except OSError as error:
        raise GlueFailure(f"failed to download pinned RustGlue.roc from {url}: {error}") from error


def main() -> None:
    parser = argparse.ArgumentParser(description="Regenerate the committed Rust platform ABI")
    parser.add_argument("--check", action="store_true", help="fail if the committed glue is stale")
    parser.add_argument("--roc", default=os.environ.get("ROC", "roc"))
    parser.add_argument(
        "--glue-spec",
        type=Path,
        default=Path(os.environ["ROC_GLUE_SPEC"]) if "ROC_GLUE_SPEC" in os.environ else None,
        help="local RustGlue.roc override for compiler development",
    )
    args = parser.parse_args()

    pin = read_pin()
    version = compiler_version(args.roc)
    if not matches_pin(version, pin) and os.environ.get("ROC_ALLOW_UNPINNED") != "1":
        raise GlueFailure(
            f".roc-version pins {pin}, but {args.roc!r} reports {version!r}; "
            "set ROC_ALLOW_UNPINNED=1 only for intentional compiler development"
        )

    # Roc removes stale `roc*` temporary directories when it starts, so this
    # directory deliberately uses a different prefix while the child runs.
    with tempfile.TemporaryDirectory(prefix="fuzz-rust-glue-") as temporary:
        temporary_dir = Path(temporary)
        if args.glue_spec is None:
            glue_spec = temporary_dir / "RustGlue.roc"
            download_glue_spec(pin, glue_spec)
            source = pin
        else:
            glue_spec = args.glue_spec.resolve()
            if not glue_spec.is_file():
                raise GlueFailure(f"Rust glue spec does not exist: {glue_spec}")
            source = str(glue_spec)

        output_dir = temporary_dir / "generated"
        command = [
            args.roc,
            "glue",
            str(glue_spec),
            str(output_dir),
            str(PLATFORM),
            "--no-cache",
        ]
        result = subprocess.run(command)
        if result.returncode != 0:
            raise GlueFailure("Roc glue generation failed")
        generated = output_dir / OUTPUT.name
        if not generated.is_file():
            raise GlueFailure(f"Roc did not generate {OUTPUT.name}")

        if args.check:
            if not OUTPUT.is_file() or not filecmp.cmp(generated, OUTPUT, shallow=False):
                raise GlueFailure("generated Rust ABI is stale; run scripts/generate_rust_glue.py")
            print(f"Rust ABI is current (glue spec: {source})")
        else:
            OUTPUT.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(generated, OUTPUT)
            print(f"Wrote {OUTPUT.relative_to(ROOT)} (glue spec: {source})")


if __name__ == "__main__":
    try:
        main()
    except GlueFailure as error:
        raise SystemExit(str(error)) from error
