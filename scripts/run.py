#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    parser = argparse.ArgumentParser(description="Fuzz an app that uses the released roc-fuzz bundle")
    parser.add_argument("app", type=Path, help="Roc app with main : List(U8) -> U8")
    parser.add_argument(
        "--corpus",
        type=Path,
        help="persistent corpus directory (default: .roc-fuzz-corpus/<app name>)",
    )
    parser.add_argument("--max-total-time", type=int, help="stop after this many seconds")
    parser.add_argument("--runs", type=int, help="stop after this many executions")
    parser.add_argument("--libfuzzer-seed", type=int, help="deterministic libFuzzer random seed")
    args = parser.parse_args()

    app = args.app.resolve()
    if not app.is_file() or app.suffix != ".roc":
        raise SystemExit(f"Roc app does not exist: {app}")
    if args.max_total_time is not None and args.max_total_time < 1:
        raise SystemExit("--max-total-time must be at least one second")
    if args.runs is not None and args.runs < 1:
        raise SystemExit("--runs must be at least one")
    if args.max_total_time is not None and args.runs is not None:
        raise SystemExit("choose --max-total-time or --runs, not both")
    if shutil.which("cargo-fuzz") is None and "fuzz" not in subprocess.check_output(
        ["cargo", "--list"], text=True
    ):
        raise SystemExit("cargo-fuzz is not installed; run `cargo install cargo-fuzz`")

    corpus = (
        args.corpus.resolve()
        if args.corpus is not None
        else Path.cwd() / ".roc-fuzz-corpus" / app.stem
    )
    corpus.mkdir(parents=True, exist_ok=True)

    archive_dir = ROOT / "target" / "roc-fuzz" / app.stem
    archive_dir.mkdir(parents=True, exist_ok=True)
    archive = archive_dir / "libroc_fuzz.a"
    roc = os.environ.get("ROC", "roc")
    build = subprocess.run(
        [
            roc,
            "build",
            str(app),
            "--fuzz",
            "--target=x64glibc",
            "--opt=speed",
            f"--output={archive}",
        ],
        cwd=Path.cwd(),
    )
    if build.returncode != 0:
        raise SystemExit(build.returncode)

    environment = os.environ.copy()
    environment["ROC_FUZZ_ARCHIVE"] = str(archive.resolve())
    environment.pop("ROC_FUZZ_APP", None)
    environment.pop("ROC_FUZZ_TARGET", None)
    environment.pop("ROC_FUZZ_INSTRUMENT", None)

    command = [
        "cargo",
        "fuzz",
        "run",
        f"--fuzz-dir={ROOT / 'fuzz'}",
        "--sanitizer=none",
        "roc-fuzz",
        str(corpus),
    ]
    libfuzzer_args: list[str] = []
    if args.max_total_time is not None:
        libfuzzer_args.append(f"-max_total_time={args.max_total_time}")
    if args.runs is not None:
        libfuzzer_args.append(f"-runs={args.runs}")
    if args.libfuzzer_seed is not None:
        libfuzzer_args.append(f"-seed={args.libfuzzer_seed}")
    if libfuzzer_args:
        command.extend(["--", *libfuzzer_args])

    raise SystemExit(subprocess.call(command, cwd=Path.cwd(), env=environment))


if __name__ == "__main__":
    main()
