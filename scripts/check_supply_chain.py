#!/usr/bin/env python3
"""Validate immutable workflow references and pinned Roc release metadata."""

from __future__ import annotations

import re
from pathlib import Path

from install_roc import read_checksums, read_tag


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_DIR = ROOT / ".github" / "workflows"
USE_PATTERN = re.compile(r"^\s*uses:\s*([^\s#]+)(?:\s+#\s*(\S+))?\s*$")
SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")
REQUIRED_FRAGMENTS = {"linux_x86_64", "macos_apple_silicon"}


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
    tag = read_tag(ROOT / ".roc-version")
    checksums = read_checksums(ROOT / ".roc-nightly-sha256")
    if len(checksums) != len(REQUIRED_FRAGMENTS):
        raise SystemExit("Roc checksum manifest must contain exactly two supported archives")
    archive_version = tag.removeprefix("nightly-")
    for fragment in REQUIRED_FRAGMENTS:
        matches = [name for name in checksums if fragment in name and archive_version in name]
        if len(matches) != 1:
            raise SystemExit(f"expected one {fragment} checksum matching {tag}")


def main() -> None:
    validate_actions()
    validate_roc_pin()
    print("Supply-chain metadata is pinned and internally consistent.")


if __name__ == "__main__":
    main()
