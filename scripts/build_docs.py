#!/usr/bin/env python3
"""Build the manual with the immutable shared documentation action."""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
AUTOMATION_REPOSITORY = "https://github.com/lukewilliamboswell/roc-automation.git"
AUTOMATION_REVISION = "a0ce42bfc8cd7dd1d167c0db0a770fca1118951d"


def run(*command: str, cwd: Path = ROOT) -> None:
    subprocess.run(command, cwd=cwd, check=True)


def shared_action(override: str) -> Path:
    if override:
        root = Path(override).expanduser().resolve()
    else:
        root = ROOT / ".test-cache" / "roc-automation-docs" / AUTOMATION_REVISION
        if not root.exists():
            root.parent.mkdir(parents=True, exist_ok=True)
            run("git", "clone", "--filter=blob:none", AUTOMATION_REPOSITORY, str(root))
            run("git", "checkout", "--detach", AUTOMATION_REVISION, cwd=root)
        revision = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=root, text=True
        ).strip()
        if revision != AUTOMATION_REVISION:
            raise SystemExit(f"cached roc-automation checkout is {revision}, expected {AUTOMATION_REVISION}")
    action = root / "actions" / "build-docs" / "build_docs.py"
    if not action.is_file():
        raise SystemExit(f"shared documentation action is missing: {action}")
    return action


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--docs-version", default="trunk")
    parser.add_argument(
        "--automation-root",
        default=os.environ.get("ROC_AUTOMATION_ROOT", ""),
        help="use a local roc-automation checkout instead of the pinned remote revision",
    )
    args = parser.parse_args()
    roc = os.environ.get("ROC", "roc")
    if shutil.which(roc) is None:
        raise SystemExit(f"Roc executable was not found: {roc}")
    action = shared_action(args.automation_root)
    run(
        sys.executable,
        str(action),
        "--workspace", str(ROOT),
        "--docs-directory", "docs",
        "--entrypoint", "index.adoc",
        "--output-directory", ".docs-out",
        "--pdf-filename", "roc-fuzz.pdf",
        "--docs-version", args.docs_version,
        "--api-entrypoint", "platform/main.roc",
        "--roc-command", roc,
    )
    run(sys.executable, "scripts/check_docs.py", ".docs-out/site/api")


if __name__ == "__main__":
    main()
