"""Validate the explicit branch-RC exception without relaxing stable releases."""

import os
import re
import subprocess


def validate(version: str, expected: str, actual: str, event: str, ref: str) -> None:
    if event != "workflow_dispatch" or not ref.startswith("refs/heads/"):
        raise ValueError("RC publication requires a manual branch dispatch")
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)-rc[1-9][0-9]*", version):
        raise ValueError("RC publication requires X.Y.Z-rcN, never a stable version")
    if not re.fullmatch(r"[0-9a-f]{40}", expected) or expected != actual:
        raise ValueError("RC source SHA differs from the explicitly requested commit")


if __name__ == "__main__":
    try:
        validate(os.environ["RELEASE_VERSION"], os.environ["EXPECTED_SHA"],
                 os.environ["GITHUB_SHA"], os.environ["GITHUB_EVENT_NAME"], os.environ["GITHUB_REF"])
        if subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip() != os.environ["EXPECTED_SHA"]:
            raise ValueError("checkout does not match the RC commit")
    except ValueError as error:
        raise SystemExit(str(error)) from error
