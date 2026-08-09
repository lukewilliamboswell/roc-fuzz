#!/usr/bin/env python3
"""Build the native assets bundled by the roc-fuzz platform."""

from __future__ import annotations

import argparse
import hashlib
import os
import shlex
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
from pathlib import Path

from platform_inputs import TARGETS_BY_NAME, TARGET_SPECS, TargetSpec, target_directory, write_platform_manifest


ROOT = Path(__file__).resolve().parents[1]
LIBFUZZER_VERSION = "0.4.5"
LIBFUZZER_SHA256 = "c8fff891139ee62800da71b7fd5b508d570b9ad95e614a53c6f453ca08366038"
LIBFUZZER_URL = f"https://crates.io/api/v1/crates/libfuzzer-sys/{LIBFUZZER_VERSION}/download"


def run(command: list[str]) -> None:
    print("+", " ".join(command))
    subprocess.run(command, cwd=ROOT, check=True)


def capture(command: list[str], *, env: dict[str, str] | None = None) -> str:
    print("+", " ".join(command))
    return subprocess.run(
        command,
        cwd=ROOT,
        check=True,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    ).stdout


def macos_sdk(spec: TargetSpec) -> str | None:
    """Return the SDK required to compile the macOS target."""

    if spec.roc_name != "arm64mac":
        return None
    try:
        sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(
            "building arm64mac inputs requires an installed macOS SDK (xcrun)"
        ) from error
    if not sdk:
        raise SystemExit("xcrun did not report a macOS SDK path")
    return sdk


def cxx_target_args(spec: TargetSpec) -> list[str]:
    sdk = macos_sdk(spec)
    return ["-isysroot", sdk, "-isystem", f"{sdk}/usr/include"] if sdk is not None else []


def zig_target_args(spec: TargetSpec) -> list[str]:
    sdk = macos_sdk(spec)
    return ["--sysroot", sdk] if sdk is not None else []


def validate_libfuzzer_source(source: Path) -> Path:
    source = source.resolve()
    if not (source / "FuzzerMain.cpp").is_file():
        raise SystemExit(f"libFuzzer source directory is incomplete: {source}")
    return source


def cached_libfuzzer_archive() -> Path | None:
    cargo_home = Path(os.environ.get("CARGO_HOME", Path.home() / ".cargo"))
    matches = sorted((cargo_home / "registry" / "cache").glob(f"*/libfuzzer-sys-{LIBFUZZER_VERSION}.crate"))
    return matches[0] if matches else None


def resolve_libfuzzer_source(explicit: Path | None, work: Path) -> Path:
    if explicit is not None:
        return validate_libfuzzer_source(explicit)

    extract_root = ROOT / ".test-cache" / "libfuzzer-source"
    source = extract_root / f"libfuzzer-sys-{LIBFUZZER_VERSION}" / "libfuzzer"
    if (source / "FuzzerMain.cpp").is_file():
        return validate_libfuzzer_source(source)

    archive = cached_libfuzzer_archive()
    if archive is None:
        archive = work / f"libfuzzer-sys-{LIBFUZZER_VERSION}.crate"
        print(f"+ download {LIBFUZZER_URL}", flush=True)
        with urllib.request.urlopen(LIBFUZZER_URL, timeout=60) as response, archive.open("wb") as output:
            shutil.copyfileobj(response, output)

    archive_digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if archive_digest != LIBFUZZER_SHA256:
        raise SystemExit(f"libfuzzer-sys {LIBFUZZER_VERSION} checksum mismatch: {archive_digest}")

    extract_root.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "r:gz") as package:
        package.extractall(extract_root)
    return validate_libfuzzer_source(source)


def build_libfuzzer(zig: str, ar: str, source: Path, output: Path, work: Path, spec: TargetSpec) -> None:
    objects: list[str] = []
    object_dir = work / f"{spec.roc_name}-libfuzzer-objects"
    object_dir.mkdir()
    for cpp in sorted(source.glob("*.cpp")):
        # FuzzerInterceptors resolves libc via dlsym, which cannot work in a fully
        # static musl executable. The macOS target uses libSystem dynamically, so
        # it keeps the upstream interceptors.
        if cpp.name == "FuzzerInterceptors.cpp" and not spec.include_fuzzer_interceptors:
            continue
        if cpp.name == "FuzzerExtFunctionsDlsym.cpp" and spec.roc_name == "arm64mac":
            continue
        obj = object_dir / f"{cpp.stem}.o"
        run([
            zig, "c++", "-target", spec.zig_target, *cxx_target_args(spec), "-std=c++17", "-O2",
            "-fno-omit-frame-pointer", "-fPIC", "-w", "-c", str(cpp), "-o", str(obj),
        ])
        objects.append(str(obj))
    if spec.roc_name == "arm64mac":
        cpp = ROOT / "src" / "macos_fuzzer_ext_functions.cpp"
        obj = object_dir / f"{cpp.stem}.o"
        run([
            zig, "c++", "-target", spec.zig_target, *cxx_target_args(spec),
            "-I", str(source), "-std=c++17", "-O2", "-fno-omit-frame-pointer",
            "-fPIC", "-w", "-c", str(cpp), "-o", str(obj),
        ])
        objects.append(str(obj))
    output.unlink(missing_ok=True)
    run([ar, "rcs", str(output), *objects])


def copy_zig_runtime(zig: str, target_dir: Path, work: Path, spec: TargetSpec) -> None:
    probe = work / f"{spec.roc_name}-runtime_probe.cpp"
    probe.write_text("int main() { return 0; }\n", encoding="utf-8")
    probe_exe = work / f"{spec.roc_name}-runtime_probe"
    env = dict(os.environ)
    env["ZIG_VERBOSE_LINK"] = "1"
    command = [
        zig, "c++", "-target", spec.zig_target, *cxx_target_args(spec), "-O2", "-v",
        str(probe), "-o", str(probe_exe),
    ]
    if spec.roc_name == "x64musl":
        command.insert(-2, "-static")
    output = capture(command, env=env)

    wanted = set(spec.input_names) - {"libhost.a", "libfuzzer.a"}
    found: dict[str, Path] = {}
    for line in output.splitlines():
        if "ld.lld" not in line and "zig ld " not in line:
            continue
        for token in shlex.split(line):
            candidate = Path(token)
            if candidate.name in wanted and candidate.is_file():
                found[candidate.name] = candidate

    missing = wanted - found.keys()
    if missing:
        raise SystemExit(
            f"could not locate Zig's {spec.roc_name} runtime artifacts: "
            + ", ".join(sorted(missing))
        )
    for name, source in found.items():
        shutil.copy2(source, target_dir / name)


def build_target(zig: str, ar: str, source: Path, work: Path, spec: TargetSpec) -> None:
    directory = target_directory(ROOT, spec)
    directory.mkdir(parents=True, exist_ok=True)
    run([
        zig, "build-lib", str(ROOT / "src" / "main.zig"), "-target", spec.zig_target, *zig_target_args(spec),
        "-O", "ReleaseFast", f"-femit-bin={directory / 'libhost.a'}", "-fcompiler-rt", "-lc",
    ])
    if spec.roc_name == "arm64mac":
        stack_depth = work / "macos_sancov.o"
        run([
            zig, "cc", "-target", spec.zig_target, *cxx_target_args(spec), "-O2", "-fPIC",
            "-c", str(ROOT / "src" / "macos_sancov.c"), "-o", str(stack_depth),
        ])
        run([ar, "rcs", str(directory / "libhost.a"), str(stack_depth)])
    build_libfuzzer(zig, ar, source, directory / "libfuzzer.a", work, spec)
    copy_zig_runtime(zig, directory, work, spec)
    manifest = write_platform_manifest(ROOT, spec)
    print(f"{spec.roc_name} platform host ready in {directory}")
    print(f"Updated platform input checksums in {manifest}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--roc-source", type=Path, default=Path(os.environ["ROC_SOURCE"]) if "ROC_SOURCE" in os.environ else None, help="Roc source checkout used only with --regenerate-glue")
    parser.add_argument("--regenerate-glue", action="store_true")
    parser.add_argument("--libfuzzer-source", type=Path, help="override the pinned libFuzzer source directory")
    parser.add_argument("--target", choices=tuple(TARGETS_BY_NAME), action="append", help="target to regenerate (default: all)")
    parser.add_argument("--zig", default=os.environ.get("ZIG", "zig"))
    parser.add_argument("--ar", default=os.environ.get("AR", "ar"))
    args = parser.parse_args()

    generated_glue = ROOT / "src" / "roc_platform_abi.zig"
    if args.regenerate_glue:
        if args.roc_source is None:
            raise SystemExit("--regenerate-glue requires --roc-source or ROC_SOURCE")
        roc_source = args.roc_source.resolve()
        roc = Path(os.environ.get("ROC", roc_source / "zig-out" / "bin" / "roc"))
        glue = roc_source / "src" / "glue" / "src" / "ZigGlue.roc"
        for required in [roc, glue]:
            if not required.is_file():
                raise SystemExit(f"missing glue-generation input: {required}")
        run([str(roc), "glue", str(glue), str(ROOT / "src"), str(ROOT / "platform" / "main.roc")])
        run([args.zig, "fmt", str(generated_glue)])
    elif not generated_glue.is_file():
        raise SystemExit("generated Zig ABI glue is missing; use --regenerate-glue")

    selected = set(args.target or TARGETS_BY_NAME)
    with tempfile.TemporaryDirectory(prefix="roc-fuzz-build-") as temp:
        work = Path(temp)
        source = resolve_libfuzzer_source(args.libfuzzer_source, work)
        for spec in TARGET_SPECS:
            if spec.roc_name in selected:
                build_target(args.zig, args.ar, source, work, spec)


if __name__ == "__main__":
    main()
