#!/usr/bin/env python3
"""Validate immutable workflow references and pinned Roc release metadata."""

from __future__ import annotations

import re
import json
from pathlib import Path

from compiler_pins import discover, local_sources


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_DIR = ROOT / ".github" / "workflows"
USE_PATTERN = re.compile(r"^\s*uses:\s*([^\s#]+)(?:\s+#\s*(\S+))?\s*$")
SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")


def validate_actions() -> None:
    failures: list[str] = []
    for workflow in sorted(WORKFLOW_DIR.glob("*.yml")):
        for number, line in enumerate(workflow.read_text(encoding="utf-8").splitlines(), 1):
            match = USE_PATTERN.match(line)
            if match is None:
                continue
            reference, version = match.groups()
            if reference.startswith("./"):
                continue
            if "@" not in reference:
                failures.append(f"{workflow.relative_to(ROOT)}:{number}: missing action ref")
                continue
            action, revision = reference.rsplit("@", 1)
            if not SHA_PATTERN.fullmatch(revision):
                failures.append(
                    f"{workflow.relative_to(ROOT)}:{number}: {action} is not pinned to a full SHA"
                )
            if version is None:
                failures.append(
                    f"{workflow.relative_to(ROOT)}:{number}: pinned action lacks a version comment"
                )
    if failures:
        raise SystemExit("\n".join(failures))


def validate_roc_pin() -> None:
    config = json.loads((ROOT / ".github/roc-nightly.json").read_text())
    targets = json.loads((ROOT / "scripts/test_spec.json").read_text())["targets"]
    expected_roots = {"platform/main.roc", *(target["path"] for target in targets)}
    if set(config["compiler_roots"]) != expected_roots:
        raise SystemExit("nightly compiler roots must cover the platform and every example")
    discover(local_sources(ROOT, config["compiler_roots"]))
    if (ROOT / ".roc-version").exists():
        raise SystemExit("Remove legacy .roc-version when using header pins")


def main() -> None:
    validate_actions()
    validate_roc_pin()
    print("Supply-chain metadata is pinned and internally consistent.")


if __name__ == "__main__":
    main()
