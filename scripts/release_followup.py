#!/usr/bin/env python3
"""Create a signed, reviewed release-URL follow-up and dispatch its validation."""

import argparse
import base64
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "lukewilliamboswell/roc-fuzz"
URL = re.compile(r'https://github\.com/lukewilliamboswell/roc-fuzz/releases/download/[^/\s"]+/[A-Za-z0-9_-]+\.tar\.zst')


def api(endpoint: str, payload: dict | None = None) -> dict:
    command = ["gh", "api", endpoint]
    if payload is not None:
        command.extend(["--input", "-"])
    return json.loads(subprocess.check_output(command, input=json.dumps(payload) if payload is not None else None, text=True))


def changes(root: Path, url: str) -> list[dict]:
    if not URL.fullmatch(url):
        raise ValueError("follow-up requires an immutable roc-fuzz platform URL")
    paths = [*sorted((root / "examples").rglob("*.roc")), root / "README.md"]
    additions = []
    for path in paths:
        source = path.read_text()
        updated = URL.sub(url, source)
        if updated != source:
            # Only URLs are changed; compiler pins and companion modules stay intact.
            additions.append({"path": path.relative_to(root).as_posix(),
                              "contents": base64.b64encode(updated.encode()).decode()})
    return additions


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--url", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-rc[0-9]+)?", args.version):
        raise SystemExit("invalid platform release version")
    if f"/download/{args.version}/" not in args.url:
        raise SystemExit("URL does not match platform release")
    repository = api(f"repos/{REPOSITORY}")
    base = repository["default_branch"]
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    if api(f"repos/{REPOSITORY}/commits/{base}")["sha"] != head:
        raise SystemExit("default branch moved: prepare and test the follow-up from its new head")
    additions = changes(ROOT, args.url)
    if not additions:
        print("Published URLs already adopted")
        return
    branch = f"release-followup/{args.version}"
    # Creating an existing ref fails; never overwrite unrelated or reviewed work.
    api(f"repos/{REPOSITORY}/git/refs", {"ref": f"refs/heads/{branch}", "sha": head})
    mutation = """mutation($input: CreateCommitOnBranchInput!) {
      createCommitOnBranch(input: $input) { commit { oid signature { isValid } } }
    }"""
    result = api("graphql", {"query": mutation, "variables": {"input": {
        "branch": {"repositoryNameWithOwner": REPOSITORY, "branchName": branch},
        "expectedHeadOid": head,
        "message": {"headline": f"Use roc-fuzz {args.version} in public examples"},
        "fileChanges": {"additions": additions},
    }}})
    if result.get("errors"):
        raise SystemExit(json.dumps(result["errors"]))
    commit = result["data"]["createCommitOnBranch"]["commit"]
    if not (commit.get("signature") or {}).get("isValid"):
        raise SystemExit("release-follow-up commit lacks a verified signature")
    pr = api(f"repos/{REPOSITORY}/pulls", {
        "title": f"Use roc-fuzz {args.version} in public examples", "head": branch, "base": base,
        "body": f"Updates public examples and README to {args.url}. Compiler header pins are preserved.\n\nValidation is dispatched on signed commit `{commit['oid']}`. Review the current-commit runs before merging; ordinary PR workflows may need approval to satisfy branch rules.",
    })
    for workflow in ("ci.yml", "published-examples.yml", "release.yml", "codeql.yml"):
        subprocess.run(["gh", "workflow", "run", workflow, "--repo", REPOSITORY,
                        "--ref", branch, "-f", "nightly_validation=true"], check=True)
    print(pr["html_url"])


if __name__ == "__main__":
    main()
