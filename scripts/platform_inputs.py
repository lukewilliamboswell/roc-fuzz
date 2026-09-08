"""Validate and record generated native inputs for the roc-fuzz platform."""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from pathlib import Path


MANIFEST_NAME = "SHA256SUMS"


@dataclass(frozen=True)
class TargetSpec:
    """The versioned native inputs for one Roc platform target."""

    roc_name: str
    zig_target: str
    input_names: tuple[str, ...]
    include_fuzzer_interceptors: bool


TARGET_SPECS = (
    TargetSpec(
        roc_name="x64musl",
        zig_target="x86_64-linux-musl",
        input_names=(
            "crt1.o",
            "libhost.a",
            "libfuzzer.a",
            "libc++.a",
            "libc++abi.a",
            "libunwind.a",
            "libc.a",
            "libzigc.a",
            "libcompiler_rt.a",
        ),
        include_fuzzer_interceptors=False,
    ),
    TargetSpec(
        roc_name="arm64mac",
        zig_target="aarch64-macos.11.0",
        input_names=(
            "libhost.a",
            "libfuzzer.a",
            "libc++abi.a",
            "libc++.a",
            "libcompiler_rt.a",
        ),
        include_fuzzer_interceptors=True,
    ),
)
TARGETS_BY_NAME = {spec.roc_name: spec for spec in TARGET_SPECS}


def target_directory(root: Path, spec: TargetSpec) -> Path:
    return root / "platform" / "targets" / spec.roc_name


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_platform_manifest(root: Path, spec: TargetSpec) -> Path:
    directory = target_directory(root, spec)
    missing = [name for name in spec.input_names if not (directory / name).is_file()]
    if missing:
        raise RuntimeError(
            f"cannot write {spec.roc_name} platform manifest; missing: "
            f"{', '.join(missing)}"
        )

    manifest = directory / MANIFEST_NAME
    manifest.write_text(
        "".join(
            f"{digest(directory / name)}  {name}\n" for name in spec.input_names
        ),
        encoding="utf-8",
    )
    return manifest


def validate_platform_inputs(
    root: Path, target_names: set[str] | None = None
) -> list[Path]:
    """Return every verified native input, in deterministic target order."""

    inputs: list[Path] = []
    specs = (
        TARGET_SPECS
        if target_names is None
        else tuple(spec for spec in TARGET_SPECS if spec.roc_name in target_names)
    )
    if target_names is not None and {spec.roc_name for spec in specs} != target_names:
        unknown = sorted(target_names - {spec.roc_name for spec in specs})
        raise RuntimeError(f"unknown platform targets: {', '.join(unknown)}")
    for spec in specs:
        directory = target_directory(root, spec)
        manifest = directory / MANIFEST_NAME
        if not manifest.is_file():
            raise RuntimeError(
                f"generated {spec.roc_name} platform manifest is missing: {manifest}; "
                "run scripts/build_platform.py for this target"
            )

        recorded: dict[str, str] = {}
        for line_number, line in enumerate(
            manifest.read_text(encoding="utf-8").splitlines(), start=1
        ):
            parts = line.split("  ", 1)
            if len(parts) != 2 or len(parts[0]) != 64 or not parts[1]:
                raise RuntimeError(f"invalid {spec.roc_name} {manifest.name} line {line_number}")
            checksum, name = parts
            if name in recorded:
                raise RuntimeError(
                    f"duplicate {spec.roc_name} {manifest.name} entry: {name}"
                )
            recorded[name] = checksum

        expected = set(spec.input_names)
        if set(recorded) != expected:
            missing = sorted(expected - set(recorded))
            extra = sorted(set(recorded) - expected)
            raise RuntimeError(
                f"{spec.roc_name} platform manifest inventory mismatch; "
                f"missing={missing}, extra={extra}"
            )

        for name in spec.input_names:
            path = directory / name
            if not path.is_file():
                raise RuntimeError(f"generated {spec.roc_name} platform input is missing: {path}")
            actual = digest(path)
            if actual != recorded[name]:
                raise RuntimeError(
                    f"generated {spec.roc_name} platform input checksum mismatch for "
                    f"{name}: {actual}"
                )
            inputs.append(path)
    return inputs
