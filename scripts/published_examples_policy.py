#!/usr/bin/env python3
"""Select published compatibility checks from semantic changes to existing roots."""

import argparse
import json
import os
import re
import subprocess
from pathlib import Path

from compiler_pins import TOKEN, header_pin

ROOT = Path(__file__).resolve().parents[1]


def dependency_urls(source: str) -> list[str]:
    depth = 0
    urls = []
    for match in TOKEN.finditer(source):
        token = match.group()
        if token.startswith("#"):
            continue
        if token == "{":
            depth += 1
        elif token == "}" and depth:
            depth -= 1
            if depth == 0:
                break
        elif depth and token.startswith('"https://'):
            urls.append(token)
    return urls


def needs_validation(before: dict[str, str], after: dict[str, str]) -> bool:
    for path in before.keys() & after.keys():
        old, new = before[path], after[path]
        old_pin, new_pin = header_pin(old), header_pin(new)
        # Introducing header pins migrates an undeclared public compiler contract.
        # It is covered by source/candidate checks; subsequent pin changes are gated.
        if old_pin is not None and (new_pin is None or old_pin[2] != new_pin[2]):
            return True
        if path.startswith("examples/"):
            # Only inspect the app header, not URLs in comments or example bodies.
            old_urls = dependency_urls(old)
            # Moving previously local examples onto release URLs bootstraps the
            # public contract. The release follow-up validates its published form.
            if old_urls and old_urls != dependency_urls(new):
                return True
    return False


def sources(revision: str) -> dict[str, str]:
    paths = subprocess.check_output(
        ["git", "ls-tree", "-r", "--name-only", revision, "examples", "platform/main.roc"],
        cwd=ROOT, text=True,
    ).splitlines()
    result = {}
    for path in paths:
        if not path.endswith(".roc"):
            continue
        source = subprocess.check_output(["git", "show", f"{revision}:{path}"], cwd=ROOT, text=True)
        if path == "platform/main.roc" or re.match(r"(?:\s|#[^\n]*\n)*app\b", source):
            result[path] = source
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event", type=Path, default=os.environ.get("GITHUB_EVENT_PATH"))
    args = parser.parse_args()
    event = json.loads(args.event.read_text())
    if "pull_request" not in event:
        required = True
    else:
        pr = event["pull_request"]
        base = subprocess.check_output(
            ["git", "merge-base", pr["base"]["sha"], pr["head"]["sha"]], cwd=ROOT, text=True,
        ).strip()
        required = needs_validation(sources(base), sources(pr["head"]["sha"]))
    value = str(required).lower()
    print(f"Published example compatibility required: {value}")
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a") as destination:
            destination.write(f"required={value}\n")


if __name__ == "__main__":
    main()
