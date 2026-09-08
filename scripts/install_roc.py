#!/usr/bin/env python3
"""Install the checksum-pinned Roc nightly used by repository automation."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_TAG_FILE = ROOT / "platform" / "main.roc"
RELEASE_ROOT = "https://github.com/roc-lang/nightlies/releases/download"


def host_asset_fragment() -> str:
    machine = platform.machine().lower()
    if sys.platform.startswith("linux") and machine in {"x86_64", "amd64"}:
        return "linux_x86_64"
    if sys.platform == "darwin" and machine in {"arm64", "aarch64"}:
        return "macos_apple_silicon"
    raise SystemExit(f"unsupported Roc automation host: {sys.platform}/{machine}")


def read_tag(path: Path) -> str:
    if path.suffix == ".roc":
        from compiler_pins import read_pin
        return read_pin(path)
    lines = path.read_text(encoding="utf-8").splitlines()
    if len(lines) != 1 or not lines[0].startswith("nightly-"):
        raise SystemExit(f"{path} must contain exactly one nightly tag")
    return lines[0]


def read_checksums(path: Path) -> dict[str, str]:
    checksums: dict[str, str] = {}
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        parts = line.split()
        if len(parts) != 2 or len(parts[0]) != 64:
            raise SystemExit(f"invalid SHA-256 manifest line {number} in {path}")
        digest, name = parts
        if any(character not in "0123456789abcdef" for character in digest):
            raise SystemExit(f"invalid SHA-256 digest on line {number} in {path}")
        if name in checksums:
            raise SystemExit(f"duplicate nightly asset in {path}: {name}")
        checksums[name] = digest
    return checksums


def select_asset(tag: str, checksums: dict[str, str]) -> tuple[str, str]:
    fragment = host_asset_fragment()
    matches = [
        (name, digest)
        for name, digest in checksums.items()
        if fragment in name and name.endswith(".tar.gz")
    ]
    if len(matches) != 1:
        raise SystemExit(f"expected one {fragment} archive in checksum manifest")
    name, digest = matches[0]
    archive_version = tag.removeprefix("nightly-")
    if archive_version not in name:
        raise SystemExit(f"nightly asset {name} does not match pinned tag {tag}")
    return name, digest


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def install(tag: str, name: str, expected: str, destination: Path) -> Path:
    if destination.exists():
        raise SystemExit(f"installation destination already exists: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="roc-nightly-") as temporary:
        archive = Path(temporary) / name
        url = f"{RELEASE_ROOT}/{tag}/{name}"
        print(f"Downloading {url}", file=sys.stderr)
        with urllib.request.urlopen(url, timeout=120) as response, archive.open("wb") as output:
            shutil.copyfileobj(response, output)
        actual = sha256(archive)
        if actual != expected:
            raise SystemExit(
                f"Roc nightly checksum mismatch for {name}: expected {expected}, got {actual}"
            )
        destination.mkdir()
        with tarfile.open(archive, "r:gz") as package:
            package.extractall(destination, filter="data")

    executables = [
        path for path in destination.rglob("roc") if path.is_file() and os.access(path, os.X_OK)
    ]
    if len(executables) != 1:
        raise SystemExit(f"expected one Roc executable in {destination}, found {len(executables)}")
    return executables[0].parent


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag-file", type=Path, default=DEFAULT_TAG_FILE)
    parser.add_argument("--checksums-file", type=Path, help="optional independently recorded archive digests")
    parser.add_argument("--install-dir", type=Path, required=True)
    args = parser.parse_args()

    tag = read_tag(args.tag_file)
    if args.checksums_file:
        checksums = read_checksums(args.checksums_file)
    else:
        if not tag.startswith("nightly-"):
            raise SystemExit("This bootstrap installer currently supports exact nightlies only")
        release = json.loads(subprocess.check_output([
            "gh", "api", f"repos/roc-lang/nightlies/releases/tags/{tag}"
        ], text=True))
        if release.get("tag_name") != tag or release.get("draft"):
            raise SystemExit("expected a published release matching the exact compiler pin")
        checksums = {}
        for asset in release["assets"]:
            name = asset["name"]
            if host_asset_fragment() not in name or not name.endswith(".tar.gz"):
                continue
            value = asset.get("digest") or ""
            if not value.startswith("sha256:") or len(value) != 71 or any(c not in "0123456789abcdef" for c in value[7:]):
                raise SystemExit(f"Roc release has no valid SHA-256 digest for {name}")
            if name in checksums:
                raise SystemExit(f"duplicate Roc archive: {name}")
            checksums[name] = value[7:]
    name, digest = select_asset(tag, checksums)
    print(install(tag, name, digest, args.install_dir.resolve()))


if __name__ == "__main__":
    main()
