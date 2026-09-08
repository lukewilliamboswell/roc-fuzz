#!/usr/bin/env python3
"""Build and run an external target against a packaged roc-fuzz bundle."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

from bundle_server import BundleServer


ROOT = Path(__file__).resolve().parents[1]
PROXY_VARIABLES = (
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "ALL_PROXY",
    "http_proxy",
    "https_proxy",
    "all_proxy",
)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("bundle_path", type=Path)
    parser.add_argument("--roc", default=os.environ.get("ROC", "roc"))
    args = parser.parse_args()

    bundle = args.bundle_path.resolve()
    if not bundle.is_file() or not bundle.name.endswith(".tar.zst"):
        raise SystemExit(f"expected a .tar.zst platform bundle, got {bundle}")

    roc = args.roc
    if os.sep in roc or (os.altsep is not None and os.altsep in roc):
        roc = str(Path(roc).resolve())

    env = dict(os.environ)
    for name in PROXY_VARIABLES:
        env.pop(name, None)
    env["ROC"] = roc
    server = BundleServer(bundle)
    with server as bundle_url:
        subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts/test.py"),
                "--operation",
                "all",
                "--max-total-time",
                "1",
                "--platform-url",
                bundle_url,
            ],
            cwd=ROOT,
            env=env,
            check=True,
        )
    server.assert_requested()

    print(f"Bundle smoke test passed: {bundle.name}")


if __name__ == "__main__":
    main()
