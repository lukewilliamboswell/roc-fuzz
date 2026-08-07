"""Validate and record the prebuilt inputs shipped by the roc-fuzz platform."""

from __future__ import annotations

import hashlib
from pathlib import Path


INPUT_NAMES = (
    "crt1.o",
    "libhost.a",
    "libfuzzer.a",
    "libc++.a",
    "libc++abi.a",
    "libunwind.a",
    "libc.a",
    "libzigc.a",
    "libcompiler_rt.a",
)
MANIFEST_NAME = "SHA256SUMS"


def input_directory(root: Path) -> Path:
    return root / "platform" / "targets" / "x64musl"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_platform_manifest(root: Path) -> Path:
    directory = input_directory(root)
    missing = [name for name in INPUT_NAMES if not (directory / name).is_file()]
    if missing:
        raise RuntimeError(f"cannot write platform manifest; missing: {', '.join(missing)}")

    manifest = directory / MANIFEST_NAME
    manifest.write_text(
        "".join(f"{digest(directory / name)}  {name}\n" for name in INPUT_NAMES),
        encoding="utf-8",
    )
    return manifest


def validate_platform_inputs(root: Path) -> list[Path]:
    directory = input_directory(root)
    manifest = directory / MANIFEST_NAME
    if not manifest.is_file():
        raise RuntimeError(
            f"prebuilt platform manifest is missing: {manifest}; "
            "maintainers can regenerate it with scripts/build_platform.py"
        )

    recorded: dict[str, str] = {}
    for line_number, line in enumerate(
        manifest.read_text(encoding="utf-8").splitlines(), start=1
    ):
        parts = line.split("  ", 1)
        if len(parts) != 2 or len(parts[0]) != 64 or not parts[1]:
            raise RuntimeError(f"invalid {manifest.name} line {line_number}")
        checksum, name = parts
        if name in recorded:
            raise RuntimeError(f"duplicate {manifest.name} entry: {name}")
        recorded[name] = checksum

    expected = set(INPUT_NAMES)
    if set(recorded) != expected:
        missing = sorted(expected - set(recorded))
        extra = sorted(set(recorded) - expected)
        raise RuntimeError(
            f"platform manifest inventory mismatch; missing={missing}, extra={extra}"
        )

    inputs: list[Path] = []
    for name in INPUT_NAMES:
        path = directory / name
        if not path.is_file():
            raise RuntimeError(f"prebuilt platform input is missing: {path}")
        actual = digest(path)
        if actual != recorded[name]:
            raise RuntimeError(
                f"prebuilt platform input checksum mismatch for {name}: {actual}"
            )
        inputs.append(path)
    return inputs
