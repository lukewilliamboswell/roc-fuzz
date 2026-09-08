#!/usr/bin/env python3
"""Package and restore independently released native libraries (never libhost.a)."""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

from platform_inputs import TARGETS_BY_NAME, TargetSpec, digest, target_directory
from generate_sbom import native_license, native_version, package

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "lukewilliamboswell/roc-fuzz"
WORKFLOW = "native-libraries.yml"
LOCK = ROOT / "native-libraries.lock.json"
VERSION_PATTERN = re.compile(r"native-libs-v[0-9]+\.[0-9]+\.[0-9]+")
METADATA = {"SHA256SUMS", "build.json", "LICENSE", "THIRD_PARTY_LICENSES.md"}


def library_names(spec: TargetSpec) -> set[str]:
    return set(spec.input_names) - {"libhost.a"}


def read_lock(path: Path = LOCK) -> dict:
    lock = json.loads(path.read_text())
    if lock.get("schema") != 1 or lock.get("repository") != REPOSITORY:
        raise ValueError("unsupported native-library lock schema or repository")
    if not isinstance(lock.get("release"), str) or not VERSION_PATTERN.fullmatch(lock["release"]):
        raise ValueError("native libraries are not bootstrapped: publish native-libs-v1.0.0 and review its generated lock file; use --libraries source for explicit local builds")
    if not re.fullmatch(r"[0-9a-f]{40}", lock.get("source_revision", "")):
        raise ValueError("native-library source revision must be a full Git SHA")
    if set(lock.get("targets", {})) != set(TARGETS_BY_NAME):
        raise ValueError("native-library lock must cover both supported targets")
    for target, entry in lock["targets"].items():
        if entry.get("archive") != f"{lock['release']}-{target}.tar.gz" or not re.fullmatch(r"[0-9a-f]{64}", entry.get("sha256", "")):
            raise ValueError(f"invalid native-library asset pin for {target}")
    return lock


def extract(archive: Path, destination: Path, spec: TargetSpec) -> dict:
    """Accept an exact, flat inventory of regular files before writing anything."""
    expected = library_names(spec) | METADATA
    with tarfile.open(archive, "r:gz") as package_file:
        members = package_file.getmembers()
        if len(members) != len(expected) or {m.name for m in members} != expected:
            raise ValueError("native-library archive inventory mismatch")
        if any(not m.isfile() or m.size > 128 * 1024 * 1024 for m in members):
            raise ValueError("native-library archive contains an invalid file")
        package_file.extractall(destination, filter="data")
    checksums = {}
    for line in (destination / "SHA256SUMS").read_text().splitlines():
        parts = line.split("  ")
        if len(parts) != 2 or not re.fullmatch(r"[0-9a-f]{64}", parts[0]) or parts[1] in checksums:
            raise ValueError("invalid native-library manifest")
        checksums[parts[1]] = parts[0]
    if set(checksums) != library_names(spec):
        raise ValueError("native-library manifest inventory mismatch")
    for name, expected_digest in checksums.items():
        if digest(destination / name) != expected_digest:
            raise ValueError(f"native-library checksum mismatch: {name}")
    metadata = json.loads((destination / "build.json").read_text())
    if metadata.get("target") != spec.roc_name or metadata.get("zig_target") != spec.zig_target:
        raise ValueError("native-library target mismatch")
    return metadata


def restore(spec: TargetSpec) -> None:
    lock = read_lock()
    entry = lock["targets"][spec.roc_name]
    cache = ROOT / ".test-cache" / "native-libraries" / entry["sha256"]
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / entry["archive"]
    if not archive.exists():
        url = f"https://github.com/{REPOSITORY}/releases/download/{lock['release']}/{entry['archive']}"
        with tempfile.TemporaryDirectory(dir=cache) as work:
            downloaded = Path(work) / entry["archive"]
            with urllib.request.urlopen(url, timeout=120) as response, downloaded.open("wb") as output:
                shutil.copyfileobj(response, output)
            if digest(downloaded) != entry["sha256"]:
                raise ValueError("downloaded native-library archive checksum mismatch")
            downloaded.replace(archive)
    if digest(archive) != entry["sha256"]:
        raise ValueError("cached native-library archive checksum mismatch")
    # Verify cached archives too; a cache entry is never a source of trust.
    subprocess.run([
        "gh", "attestation", "verify", str(archive), "--repo", REPOSITORY,
        "--signer-workflow", f"{REPOSITORY}/.github/workflows/{WORKFLOW}",
        "--source-digest", lock["source_revision"],
        "--deny-self-hosted-runners",
    ], check=True)
    with tempfile.TemporaryDirectory(prefix="roc-fuzz-native-") as temporary:
        staging = Path(temporary)
        metadata = extract(archive, staging, spec)
        if metadata.get("source_revision") != lock["source_revision"] or metadata.get("release") != lock["release"]:
            raise ValueError("native-library release identity mismatch")
        directory = target_directory(ROOT, spec)
        directory.mkdir(parents=True, exist_ok=True)
        for name in library_names(spec):
            shutil.copy2(staging / name, directory / name)
        (directory / "NATIVE_LIBRARIES.json").write_text(json.dumps({
            "target": spec.roc_name, "repository": REPOSITORY,
            "release": lock["release"], "source_revision": lock["source_revision"],
            **entry,
        }, indent=2) + "\n")


def require_release_inputs() -> None:
    """Refuse publication while a target still uses the source-build bootstrap."""
    lock = read_lock()
    for spec in TARGETS_BY_NAME.values():
        path = target_directory(ROOT, spec) / "NATIVE_LIBRARIES.json"
        if not path.is_file():
            raise ValueError(f"{spec.roc_name} lacks released-library provenance; remove the CI bootstrap source-build flag after adopting the lock")
        recorded = json.loads(path.read_text())
        expected = {"target": spec.roc_name, "repository": REPOSITORY,
                    "release": lock["release"], "source_revision": lock["source_revision"],
                    **lock["targets"][spec.roc_name]}
        if recorded != expected:
            raise ValueError(f"{spec.roc_name} library provenance does not match the reviewed lock")


def pack(spec: TargetSpec, release: str, output: Path) -> Path:
    if not VERSION_PATTERN.fullmatch(release):
        raise ValueError("expected native-libs-vX.Y.Z")
    from build_platform import LIBFUZZER_SHA256, LIBFUZZER_VERSION
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    zig_version = subprocess.check_output(["zig", "version"], text=True).strip()
    if zig_version != "0.16.0":
        raise ValueError(f"native-library recipe requires Zig 0.16.0, got {zig_version}")
    metadata = {"schema": 1, "release": release, "source_revision": revision,
                "target": spec.roc_name, "zig_target": spec.zig_target,
                "zig_version": zig_version, "libfuzzer_version": LIBFUZZER_VERSION,
                "libfuzzer_sha256": LIBFUZZER_SHA256}
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"{release}-{spec.roc_name}.tar.gz"
    with tempfile.TemporaryDirectory(prefix="roc-fuzz-native-pack-") as temporary:
        staging = Path(temporary)
        for name in library_names(spec):
            shutil.copy2(target_directory(ROOT, spec) / name, staging / name)
        for name in ("LICENSE", "THIRD_PARTY_LICENSES.md"):
            shutil.copy2(ROOT / name, staging / name)
        (staging / "build.json").write_text(json.dumps(metadata, indent=2) + "\n")
        (staging / "SHA256SUMS").write_text("".join(f"{digest(staging / name)}  {name}\n" for name in sorted(library_names(spec))))
        with tarfile.open(archive, "w:gz") as package_file:
            for name in sorted(library_names(spec) | METADATA):
                package_file.add(staging / name, arcname=name)
        root_id = "SPDXRef-NativeLibraries"
        packages = [package(root_id, f"roc-fuzz native libraries {spec.roc_name}", release,
                            "NOASSERTION", f"https://github.com/{REPOSITORY}/releases/download/{release}/{archive.name}", digest(archive))]
        for index, name in enumerate(sorted(library_names(spec))):
            packages.append(package(f"SPDXRef-Library-{index}", name, native_version(name, release),
                                    native_license(name), "NOASSERTION", digest(staging / name)))
        sbom = {"spdxVersion": "SPDX-2.3", "dataLicense": "CC0-1.0", "SPDXID": "SPDXRef-DOCUMENT",
                "name": archive.name, "documentNamespace": f"https://github.com/{REPOSITORY}/sbom/{digest(archive)}",
                "creationInfo": {"created": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "creators": ["Tool: roc-fuzz/native_libraries.py"]},
                "packages": packages, "documentDescribes": [root_id],
                "relationships": [{"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES", "relatedSpdxElement": root_id}]
                + [{"spdxElementId": root_id, "relationshipType": "CONTAINS", "relatedSpdxElement": p["SPDXID"]} for p in packages[1:]]}
        archive.with_name(archive.name + ".spdx.json").write_text(json.dumps(sbom, indent=2) + "\n")
    archive.with_name(archive.name + ".sha256").write_text(f"{digest(archive)}  {archive.name}\n")
    return archive


def make_lock(directory: Path, release: str) -> dict:
    targets = {}
    revisions = set()
    for spec in TARGETS_BY_NAME.values():
        archive = directory / f"{release}-{spec.roc_name}.tar.gz"
        with tempfile.TemporaryDirectory() as temporary:
            metadata = extract(archive, Path(temporary), spec)
        if metadata.get("release") != release:
            raise ValueError("archive release mismatch")
        revisions.add(metadata["source_revision"])
        targets[spec.roc_name] = {"archive": archive.name, "sha256": digest(archive)}
    if len(revisions) != 1:
        raise ValueError("native-library targets were built from different commits")
    return {"schema": 1, "repository": REPOSITORY, "release": release,
            "source_revision": revisions.pop(), "targets": targets}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("pack", "restore", "lock", "extract", "check"))
    parser.add_argument("--target", choices=tuple(TARGETS_BY_NAME))
    parser.add_argument("--release", default="native-libs-v1.0.0")
    parser.add_argument("--directory", type=Path, default=ROOT / "dist" / "native")
    parser.add_argument("--archive", type=Path)
    args = parser.parse_args()
    if args.operation == "check":
        require_release_inputs()
        return
    if args.operation == "lock":
        print(json.dumps(make_lock(args.directory, args.release), indent=2))
        return
    if args.target is None:
        parser.error("--target is required")
    spec = TARGETS_BY_NAME[args.target]
    if args.operation == "restore":
        restore(spec)
    elif args.operation == "pack":
        print(pack(spec, args.release, args.directory))
    else:
        if args.archive is None:
            parser.error("--archive is required")
        args.directory.mkdir(parents=True, exist_ok=True)
        extract(args.archive, args.directory, spec)


if __name__ == "__main__":
    try:
        main()
    except ValueError as error:
        raise SystemExit(str(error)) from error
