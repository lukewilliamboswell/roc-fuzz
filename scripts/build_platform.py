#!/usr/bin/env python3
"""Build x64-musl host assets bundled by the roc-fuzz platform."""

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

from platform_inputs import write_platform_manifest


ROOT = Path(__file__).resolve().parents[1]
LIBFUZZER_VERSION = "0.4.5"
LIBFUZZER_SHA256 = "c8fff891139ee62800da71b7fd5b508d570b9ad95e614a53c6f453ca08366038"
LIBFUZZER_URL = f"https://crates.io/api/v1/crates/libfuzzer-sys/{LIBFUZZER_VERSION}/download"


def run(command: list[str]) -> None:
    print("+", " ".join(command))
    subprocess.run(command, cwd=ROOT, check=True)


def capture(command: list[str], *, env: dict[str, str] | None = None) -> str:
    print("+", " ".join(command))
    completed = subprocess.run(
        command,
        cwd=ROOT,
        check=True,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    return completed.stdout


def validate_libfuzzer_source(source: Path) -> Path:
    source = source.resolve()
    if not (source / "FuzzerMain.cpp").is_file():
        raise SystemExit(f"libFuzzer source directory is incomplete: {source}")
    return source


def cached_libfuzzer_archive() -> Path | None:
    cargo_home = Path(os.environ.get("CARGO_HOME", Path.home() / ".cargo"))
    matches = sorted(
        (cargo_home / "registry" / "cache").glob(
            f"*/libfuzzer-sys-{LIBFUZZER_VERSION}.crate"
        )
    )
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
        with urllib.request.urlopen(LIBFUZZER_URL, timeout=60) as response, archive.open(
            "wb"
        ) as output:
            shutil.copyfileobj(response, output)

    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != LIBFUZZER_SHA256:
        raise SystemExit(
            f"libfuzzer-sys {LIBFUZZER_VERSION} checksum mismatch: {digest}"
        )

    extract_root.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "r:gz") as package:
        package.extractall(extract_root)
    return validate_libfuzzer_source(source)


def build_libfuzzer(zig: str, ar: str, source: Path, output: Path, work: Path) -> None:
    objects: list[str] = []
    object_dir = work / "libfuzzer-objects"
    object_dir.mkdir()
    for cpp in sorted(source.glob("*.cpp")):
        # This translation unit locates the underlying libc functions through
        # dlsym. That cannot work in a fully static musl executable. Roc's
        # trace-cmp instrumentation still supplies comparison feedback.
        if cpp.name == "FuzzerInterceptors.cpp":
            continue
        obj = object_dir / f"{cpp.stem}.o"
        run(
            [
                zig,
                "c++",
                "-target",
                "x86_64-linux-musl",
                "-std=c++17",
                "-O2",
                "-fno-omit-frame-pointer",
                "-fPIC",
                "-w",
                "-c",
                str(cpp),
                "-o",
                str(obj),
            ]
        )
        objects.append(str(obj))
    output.unlink(missing_ok=True)
    run([ar, "rcs", str(output), *objects])


def copy_zig_runtime(zig: str, target_dir: Path, work: Path) -> None:
    probe = work / "runtime_probe.cpp"
    probe.write_text("int main() { return 0; }\n", encoding="utf-8")
    probe_exe = work / "runtime_probe"
    env = dict(os.environ)
    env["ZIG_VERBOSE_LINK"] = "1"
    output = capture(
        [
            zig,
            "c++",
            "-target",
            "x86_64-linux-musl",
            "-O2",
            "-static",
            str(probe),
            "-o",
            str(probe_exe),
        ],
        env=env,
    )

    wanted = {
        "crt1.o",
        "libc++.a",
        "libc++abi.a",
        "libunwind.a",
        "libzigc.a",
        "libcompiler_rt.a",
        "libc.a",
    }
    found: dict[str, Path] = {}
    for line in output.splitlines():
        if "ld.lld" not in line:
            continue
        for token in shlex.split(line):
            candidate = Path(token)
            if candidate.name in wanted and candidate.is_file():
                found[candidate.name] = candidate

    missing = wanted - found.keys()
    if missing:
        raise SystemExit(
            "could not locate Zig's x64-musl runtime artifacts: "
            + ", ".join(sorted(missing))
        )
    for name, source in found.items():
        shutil.copy2(source, target_dir / name)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--roc-source",
        type=Path,
        default=Path(os.environ["ROC_SOURCE"]) if "ROC_SOURCE" in os.environ else None,
        help="Roc source checkout used only with --regenerate-glue",
    )
    parser.add_argument("--regenerate-glue", action="store_true")
    parser.add_argument(
        "--libfuzzer-source",
        type=Path,
        help="override the pinned libFuzzer source directory",
    )
    parser.add_argument("--zig", default=os.environ.get("ZIG", "zig"))
    parser.add_argument("--ar", default=os.environ.get("AR", "ar"))
    args = parser.parse_args()

    target_dir = ROOT / "platform" / "targets" / "x64musl"
    target_dir.mkdir(parents=True, exist_ok=True)

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
        run(
            [
                str(roc),
                "glue",
                str(glue),
                str(ROOT / "src"),
                str(ROOT / "platform" / "main.roc"),
            ]
        )
        run([args.zig, "fmt", str(generated_glue)])
    elif not generated_glue.is_file():
        raise SystemExit("generated Zig ABI glue is missing; use --regenerate-glue")

    with tempfile.TemporaryDirectory(prefix="roc-fuzz-build-") as temp:
        work = Path(temp)
        libfuzzer_source = resolve_libfuzzer_source(args.libfuzzer_source, work)
        run(
            [
                args.zig,
                "build-lib",
                str(ROOT / "src" / "main.zig"),
                "-target",
                "x86_64-linux-musl",
                "-O",
                "ReleaseFast",
                f"-femit-bin={target_dir / 'libhost.a'}",
                "-fcompiler-rt",
                "-lc",
            ]
        )
        build_libfuzzer(
            args.zig,
            args.ar,
            libfuzzer_source,
            target_dir / "libfuzzer.a",
            work,
        )
        copy_zig_runtime(args.zig, target_dir, work)
    manifest = write_platform_manifest(ROOT)
    print(f"x64-musl platform host ready in {target_dir}")
    print(f"Updated platform input checksums in {manifest}")


if __name__ == "__main__":
    main()
