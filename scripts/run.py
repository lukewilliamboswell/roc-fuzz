#!/usr/bin/env python3
"""Build and run one self-contained roc-fuzz target."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from bundle_server import BundleServer
from test_local import host_target, local_env


ROOT = Path(__file__).resolve().parents[1]
PLATFORM_DECLARATION = re.compile(r'\bplatform\s+"[^"]+"')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path, help="Roc app exposing target : Target")
    parser.add_argument("--corpus", type=Path)
    parser.add_argument("--time", type=int)
    parser.add_argument("--runs", type=int)
    parser.add_argument("--max-input-size", type=int)
    parser.add_argument("--memory-limit", type=int)
    parser.add_argument("--timeout", type=int)
    parser.add_argument("--seed", type=int)
    parser.add_argument("--verbose", "-v", action="store_true")
    parser.add_argument("--libraries", choices=("release", "source"), default="release")
    args = parser.parse_args()

    app = args.app.resolve()
    if not app.is_file() or app.suffix != ".roc":
        raise SystemExit(f"Roc app does not exist: {app}")
    if args.time is not None and args.time < 0:
        raise SystemExit("--time must be non-negative")
    if args.runs is not None and args.runs < 1:
        raise SystemExit("--runs must be at least one")

    output_dir = ROOT / ".test-cache" / "run"
    output_dir.mkdir(parents=True, exist_ok=True)
    executable = output_dir / app.stem
    roc = os.environ.get("ROC", "roc")
    target = host_target()
    env = local_env()
    subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "build_platform.py"), "--target", target, "--libraries", args.libraries],
        cwd=ROOT,
        env=env,
        check=True,
    )
    with tempfile.TemporaryDirectory(prefix="roc-fuzz-run-") as temp:
        temp_root = Path(temp)
        bundle_dir = temp_root / "bundle"
        subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts" / "bundle.py"),
                "--output-dir",
                str(bundle_dir),
                "--target",
                target,
                "--roc",
                roc,
            ],
            cwd=ROOT,
            env=env,
            check=True,
        )
        bundles = list(bundle_dir.glob("*.tar.zst"))
        if len(bundles) != 1:
            raise SystemExit(f"expected one local platform bundle, found {len(bundles)}")
        server = BundleServer(bundles[0])
        with server as bundle_url:
            local_app_dir = temp_root / "app"
            shutil.copytree(app.parent, local_app_dir)
            local_app = local_app_dir / app.name
            source = local_app.read_text()
            rewritten, count = PLATFORM_DECLARATION.subn(
                f'platform "{bundle_url}"', source, count=1
            )
            if count != 1:
                raise SystemExit(f"could not find platform declaration in {app}")
            local_app.write_text(rewritten)
            subprocess.run(
                [roc, "build", "--fuzz", str(local_app), f"--output={executable}"],
                cwd=Path.cwd(),
                env=env,
                check=True,
            )
        server.assert_requested()

    command = [str(executable), "run"]
    if args.corpus is not None:
        command.append(str(args.corpus.resolve()))
    for name, value in (
        ("time", args.time),
        ("runs", args.runs),
        ("max-input-size", args.max_input_size),
        ("memory-limit", args.memory_limit),
        ("timeout", args.timeout),
        ("seed", args.seed),
    ):
        if value is not None:
            command.append(f"--{name}={value}")
    if args.verbose:
        command.append("--print-final-stats")
        print("+", " ".join(command), flush=True)
    raise SystemExit(subprocess.call(command, cwd=Path.cwd()))


if __name__ == "__main__":
    main()
