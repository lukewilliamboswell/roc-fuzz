#!/usr/bin/env python3
"""Build, serve, and test the working-tree roc-fuzz platform package."""

from __future__ import annotations

import argparse
import os
import platform
import subprocess
import sys
import tempfile
from pathlib import Path

from bundle_server import BundleServer


ROOT = Path(__file__).resolve().parents[1]


def local_env() -> dict[str, str]:
    env = os.environ.copy()
    cache_root = ROOT / ".test-cache" / "local-platform"
    env["ZIG_GLOBAL_CACHE_DIR"] = str(cache_root / "zig-global")
    env["ZIG_LOCAL_CACHE_DIR"] = str(cache_root / "zig-local")
    return env


def host_target() -> str:
    system = platform.system()
    machine = platform.machine().lower()
    if system == "Linux" and machine in {"x86_64", "amd64"}:
        return "x64musl"
    if system == "Darwin" and machine in {"arm64", "aarch64"}:
        return "arm64mac"
    raise SystemExit(f"unsupported host platform: {system}/{machine}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform-target", choices=("x64musl", "arm64mac"))
    parser.add_argument("--libraries", choices=("release", "source"), default="release")
    args, test_args = parser.parse_known_args()
    target = args.platform_target or host_target()
    roc = os.environ.get("ROC", "roc")
    env = local_env()

    subprocess.run(
        [sys.executable, str(ROOT / "scripts/build_platform.py"), "--target", target, "--libraries", args.libraries],
        cwd=ROOT,
        env=env,
        check=True,
    )
    with tempfile.TemporaryDirectory(prefix="roc-fuzz-local-bundle-") as temp:
        output_dir = Path(temp)
        subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts/bundle.py"),
                "--output-dir",
                str(output_dir),
                "--target",
                target,
                "--roc",
                roc,
            ],
            cwd=ROOT,
            env=env,
            check=True,
        )
        bundles = list(output_dir.glob("*.tar.zst"))
        if len(bundles) != 1:
            raise SystemExit(f"expected one local platform bundle, found {len(bundles)}")
        server = BundleServer(bundles[0])
        with server as bundle_url:
            subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts/test.py"),
                    "--platform-url",
                    bundle_url,
                    *test_args,
                ],
                cwd=ROOT,
                env=env,
                check=True,
            )
        server.assert_requested()


if __name__ == "__main__":
    main()
