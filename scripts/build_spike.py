#!/usr/bin/env python3
"""Build the x64-musl host assets used by the self-contained runner spike."""

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ROC_SOURCE = ROOT.parent / "roc-worktrees" / "roc-fuzz-sancov"


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


def find_libfuzzer_source() -> Path:
    metadata = json.loads(
        capture(
            [
                "cargo",
                "metadata",
                "--manifest-path",
                str(ROOT / "fuzz" / "Cargo.toml"),
                "--format-version",
                "1",
                "--locked",
            ]
        )
    )
    matches = [
        package
        for package in metadata["packages"]
        if package["name"] == "libfuzzer-sys" and package["version"] == "0.4.5"
    ]
    if len(matches) != 1:
        raise SystemExit("fuzz/Cargo.lock must resolve exactly libfuzzer-sys 0.4.5")
    source = Path(matches[0]["manifest_path"]).parent / "libfuzzer"
    if not (source / "FuzzerMain.cpp").is_file():
        raise SystemExit(f"libFuzzer source directory is incomplete: {source}")
    return source


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
        default=Path(os.environ.get("ROC_SOURCE", DEFAULT_ROC_SOURCE)),
        help="Roc source worktree containing PR 10657 and ZigGlue.roc",
    )
    parser.add_argument("--zig", default=os.environ.get("ZIG", "zig"))
    parser.add_argument("--ar", default=os.environ.get("AR", "ar"))
    args = parser.parse_args()

    roc_source = args.roc_source.resolve()
    roc = Path(os.environ.get("ROC", roc_source / "zig-out" / "bin" / "roc"))
    glue = roc_source / "src" / "glue" / "src" / "ZigGlue.roc"
    target_dir = ROOT / "platform" / "targets" / "x64musl"
    target_dir.mkdir(parents=True, exist_ok=True)

    for required in [roc, glue]:
        if not required.is_file():
            raise SystemExit(f"missing required PR-worktree asset: {required}")

    run(
        [
            str(roc),
            "glue",
            str(glue),
            str(ROOT / "platform" / "host"),
            str(ROOT / "platform" / "main.roc"),
        ]
    )
    run([args.zig, "fmt", str(ROOT / "platform" / "host" / "roc_platform_abi.zig")])
    libfuzzer_source = find_libfuzzer_source()
    with tempfile.TemporaryDirectory(prefix="roc-fuzz-build-") as temp:
        work = Path(temp)
        run(
            [
                args.zig,
                "build-lib",
                str(ROOT / "platform" / "host" / "main.zig"),
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
    print(f"x64-musl spike host ready in {target_dir}")


if __name__ == "__main__":
    main()
