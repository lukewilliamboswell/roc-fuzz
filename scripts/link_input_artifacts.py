#!/usr/bin/env python3
"""Build, lock, cache, and install roc-fuzz linker-input releases."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "native-libraries.lock.json"
KIND = "link-inputs"
TARGET_FILES = {
    "x64musl": ("crt1.o", "libfuzzer.a", "libc++.a", "libc++abi.a", "libunwind.a", "libc.a", "libzigc.a", "libcompiler_rt.a"),
    "arm64mac": ("libfuzzer.a", "libc++abi.a", "libc++.a", "libcompiler_rt.a"),
}
LICENSE_FILES = ("LICENSE", "THIRD_PARTY_LICENSES.md")
FINGERPRINT_PATHS = (
    ".github/workflows/native-libraries.yml",
    "scripts/build_platform.roc",
    "scripts/link_input_artifacts.py",
    "scripts/src",
    "scripts/workspace-deps.json",
    "src/macos_fuzzer_ext_functions.cpp",
    "LICENSE",
    "THIRD_PARTY_LICENSES.md",
)
MAX_BYTES = 512 * 1024 * 1024


def digest(path: Path) -> str:
    state = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            state.update(chunk)
    return state.hexdigest()


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode() + b"\n"


def tracked_inputs(root: Path = ROOT) -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files", "--", *FINGERPRINT_PATHS], cwd=root,
        check=True, capture_output=True, text=True,
    ).stdout.splitlines()
    return [root / name for name in sorted(result)]


def input_fingerprint(root: Path = ROOT) -> str:
    state = hashlib.sha256()
    for path in tracked_inputs(root):
        relative = path.relative_to(root).as_posix().encode()
        content = path.read_bytes()
        state.update(len(relative).to_bytes(4, "big"))
        state.update(relative)
        state.update(len(content).to_bytes(8, "big"))
        state.update(content)
    return state.hexdigest()


def archive_target(target: str, output: Path, root: Path = ROOT) -> dict[str, object]:
    files = TARGET_FILES[target]
    source = root / "platform" / "targets" / target
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"link-inputs-{target}.tar"
    metadata = canonical({
        "schema_version": 1, "kind": KIND, "target": target,
        "input_fingerprint": input_fingerprint(root),
        "files": list(files), "licenses": list(LICENSE_FILES),
    })
    with archive.open("wb") as raw, tarfile.open(fileobj=raw, mode="w", format=tarfile.PAX_FORMAT) as packed:
        contents = [("link-inputs.json", metadata)]
        contents += [(name, (source / name).read_bytes()) for name in files]
        contents += [(name, (root / name).read_bytes()) for name in LICENSE_FILES]
        for name, content in contents:
            info = tarfile.TarInfo(name)
            info.size = len(content)
            info.mode = 0o644
            info.mtime = 0
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            packed.addfile(info, io.BytesIO(content))
    return {"asset": archive.name, "sha256": digest(archive), "size": archive.stat().st_size}


def make_manifest(output: Path, repository: str, sha: str, ref: str, workflow: str) -> None:
    assets = {target: archive_target(target, output) for target in TARGET_FILES}
    manifest = {
        "schema_version": 1,
        "kind": KIND,
        "source": {
            "repository": repository, "sha": sha, "ref": ref,
            "workflow": workflow, "input_fingerprint": input_fingerprint(),
        },
        "assets": assets,
    }
    (output / "build-input-release.json").write_bytes(canonical(manifest))


def read_lock(path: Path = LOCK) -> dict:
    value = json.loads(path.read_text())
    if value.get("release") is None and value.get("targets") == {}:
        if set(value) != {"schema", "repository", "release", "source_revision", "targets"} or value.get("schema") != 1:
            raise ValueError("invalid bootstrap linker-input lock")
        return value
    required = {"schema_version", "kind", "repository", "release", "manifest", "source", "targets"}
    if set(value) != required or value["schema_version"] != 1 or value["kind"] != KIND:
        raise ValueError("unsupported linker-input lock")
    if set(value["targets"]) != set(TARGET_FILES):
        raise ValueError("linker-input lock does not cover every target")
    repository = value["repository"]
    source = value["source"]
    manifest = value["manifest"]
    if not isinstance(repository, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("invalid linker-input repository")
    if set(manifest) != {"asset", "sha256"} or manifest["asset"] != "build-input-release.json" or not re.fullmatch(r"[0-9a-f]{64}", manifest["sha256"]):
        raise ValueError("invalid linker-input manifest lock")
    if value["release"] != f"linker-inputs-sha256-{manifest['sha256']}":
        raise ValueError("linker-input release is not identified by its manifest hash")
    if set(source) != {"repository", "sha", "ref", "workflow", "input_fingerprint"}:
        raise ValueError("invalid linker-input source identity")
    if (source["repository"] != repository or not re.fullmatch(r"[0-9a-f]{40}", source["sha"])
            or not re.fullmatch(r"refs/heads/[A-Za-z0-9._/-]+", source["ref"])
            or source["workflow"] != f"{repository}/.github/workflows/native-libraries.yml"
            or not re.fullmatch(r"[0-9a-f]{64}", source["input_fingerprint"])):
        raise ValueError("invalid linker-input source identity")
    for target, item in value["targets"].items():
        if (set(item) != {"asset", "sha256", "size"}
                or item["asset"] != f"link-inputs-{target}.tar"
                or not re.fullmatch(r"[0-9a-f]{64}", item["sha256"])
                or type(item["size"]) is not int or not 0 < item["size"] <= MAX_BYTES):
            raise ValueError(f"invalid linker-input lock for {target}")
    if source["input_fingerprint"] != input_fingerprint():
        raise ValueError("linker-input lock is stale; publish a new PR-branch input release")
    return value


def cache_identity(target: str) -> str:
    lock = read_lock()
    if lock.get("release") is None:
        return "bootstrap"
    item = lock["targets"][target]
    return f"{lock['manifest']['sha256']}-{item['sha256']}-{item['size']}"


def download(url: str, destination: Path) -> None:
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as stream:
            temporary = Path(stream.name)
            with urllib.request.urlopen(url, timeout=120) as response:
                shutil.copyfileobj(response, stream)
        os.replace(temporary, destination)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def verify_manifest(lock: dict, cache: Path) -> None:
    record = lock["manifest"]
    if set(record) != {"asset", "sha256"} or record["asset"] != "build-input-release.json":
        raise ValueError("invalid linker-input manifest lock")
    path = cache / record["asset"]
    if path.exists() and digest(path) != record["sha256"]:
        path.unlink()
    if not path.exists():
        url = f"https://github.com/{lock['repository']}/releases/download/{lock['release']}/{record['asset']}"
        download(url, path)
    if digest(path) != record["sha256"]:
        path.unlink(missing_ok=True)
        raise ValueError("linker-input manifest differs from the reviewed lock")
    manifest = json.loads(path.read_text())
    expected = {"schema_version": 1, "kind": lock["kind"], "source": lock["source"], "assets": lock["targets"]}
    if manifest != expected:
        raise ValueError("linker-input manifest contents differ from the reviewed lock")


def verified_archive(target: str, cache: Path) -> tuple[Path, dict, dict]:
    lock = read_lock()
    if lock.get("release") is None:
        raise ValueError("linker inputs have not been bootstrapped")
    item = lock["targets"][target]
    if set(item) != {"asset", "sha256", "size"} or item["size"] <= 0 or item["size"] > MAX_BYTES:
        raise ValueError("invalid linker-input target lock")
    cache.mkdir(parents=True, exist_ok=True)
    verify_manifest(lock, cache)
    archive = cache / item["asset"]
    if archive.exists() and (archive.stat().st_size != item["size"] or digest(archive) != item["sha256"]):
        archive.unlink()
    if not archive.exists():
        url = f"https://github.com/{lock['repository']}/releases/download/{lock['release']}/{item['asset']}"
        with tempfile.NamedTemporaryFile(dir=cache, delete=False) as stream:
            temporary = Path(stream.name)
            with urllib.request.urlopen(url, timeout=120) as response:
                shutil.copyfileobj(response, stream)
        try:
            if temporary.stat().st_size != item["size"] or digest(temporary) != item["sha256"]:
                raise ValueError("downloaded linker-input archive differs from the reviewed lock")
            temporary.replace(archive)
        finally:
            temporary.unlink(missing_ok=True)
    if archive.stat().st_size != item["size"] or digest(archive) != item["sha256"]:
        raise ValueError("cached linker-input archive differs from the reviewed lock")
    return archive, lock, item


def extract(target: str, archive: Path, destination: Path, fingerprint: str) -> None:
    expected = {"link-inputs.json", *TARGET_FILES[target], *LICENSE_FILES}
    with tarfile.open(archive, "r:") as packed:
        members = packed.getmembers()
        names = [member.name for member in members]
        if len(names) != len(set(names)) or set(names) != expected:
            raise ValueError("linker-input archive inventory mismatch")
        if sum(member.size for member in members) > MAX_BYTES:
            raise ValueError("linker-input archive expands beyond its limit")
        for member in members:
            path = PurePosixPath(member.name)
            if not member.isfile() or path.is_absolute() or len(path.parts) != 1 or member.size > MAX_BYTES:
                raise ValueError("unsafe linker-input archive member")
        metadata = json.load(packed.extractfile("link-inputs.json"))
        if metadata != {"schema_version": 1, "kind": KIND, "target": target,
                        "input_fingerprint": fingerprint, "files": list(TARGET_FILES[target]),
                        "licenses": list(LICENSE_FILES)}:
            raise ValueError("linker-input archive metadata mismatch")
        destination.mkdir()
        for name in TARGET_FILES[target]:
            with packed.extractfile(name) as source, (destination / name).open("xb") as output:
                shutil.copyfileobj(source, output)


def install(target: str, cache: Path) -> None:
    archive, lock, item = verified_archive(target, cache)
    target_dir = ROOT / "platform" / "targets" / target
    with tempfile.TemporaryDirectory(dir=target_dir.parent) as temporary:
        staging = Path(temporary) / "inputs"
        extract(target, archive, staging, lock["source"]["input_fingerprint"])
        (target_dir / "NATIVE_LIBRARIES.json").unlink(missing_ok=True)
        for name in TARGET_FILES[target]:
            os.replace(staging / name, target_dir / name)
    provenance = {
        "target": target, "repository": lock["repository"], "release": lock["release"],
        "source_revision": lock["source"]["sha"], "archive": item["asset"], "sha256": item["sha256"],
    }
    (target_dir / "NATIVE_LIBRARIES.json").write_text(json.dumps(provenance, indent=2) + "\n")


def check_installed() -> None:
    lock = read_lock()
    if lock.get("release") is None:
        raise ValueError("published releases require a reviewed linker-input lock")
    for target, item in lock["targets"].items():
        path = ROOT / "platform" / "targets" / target / "NATIVE_LIBRARIES.json"
        actual = json.loads(path.read_text())
        expected = {
            "target": target, "repository": lock["repository"], "release": lock["release"],
            "source_revision": lock["source"]["sha"], "archive": item["asset"], "sha256": item["sha256"],
        }
        if actual != expected:
            raise ValueError(f"installed linker-input provenance mismatch for {target}")


def main() -> None:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    package = commands.add_parser("package")
    package.add_argument("--output", type=Path, required=True)
    package.add_argument("--repository", required=True)
    package.add_argument("--sha", required=True)
    package.add_argument("--ref", required=True)
    package.add_argument("--workflow", required=True)
    identity = commands.add_parser("cache-identity")
    identity.add_argument("--target", choices=TARGET_FILES, required=True)
    restore = commands.add_parser("install")
    restore.add_argument("--target", choices=TARGET_FILES, required=True)
    restore.add_argument("--cache", type=Path, default=ROOT / ".test-cache/native-libraries")
    commands.add_parser("check-installed")
    args = parser.parse_args()
    if args.command == "package":
        make_manifest(args.output, args.repository, args.sha, args.ref, args.workflow)
    elif args.command == "cache-identity":
        print(cache_identity(args.target))
    elif args.command == "install":
        install(args.target, args.cache)
    else:
        check_installed()


if __name__ == "__main__":
    main()
