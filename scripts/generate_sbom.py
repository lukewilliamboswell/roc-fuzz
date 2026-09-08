#!/usr/bin/env python3
"""Generate the SPDX 2.3 release SBOM for a roc-fuzz platform bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from datetime import datetime, timezone
from pathlib import Path


LIBFUZZER_VERSION = "0.4.5"
LIBFUZZER_SHA256 = "c8fff891139ee62800da71b7fd5b508d570b9ad95e614a53c6f453ca08366038"
ZIG_VERSION = "0.16.0"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def package(
    identifier: str,
    name: str,
    version: str,
    license_expression: str,
    download_location: str,
    checksum: str | None = None,
) -> dict[str, object]:
    value: dict[str, object] = {
        "SPDXID": identifier,
        "name": name,
        "versionInfo": version,
        "downloadLocation": download_location,
        "filesAnalyzed": False,
        "licenseConcluded": license_expression,
        "licenseDeclared": license_expression,
        "copyrightText": "NOASSERTION",
    }
    if checksum is not None:
        value["checksums"] = [{"algorithm": "SHA256", "checksumValue": checksum}]
    return value


def native_license(name: str) -> str:
    if name == "libhost.a":
        return "MIT"
    if name in {"crt1.o", "libc.a"}:
        return "MIT"
    if name in {"libfuzzer.a", "libc++.a", "libc++abi.a", "libunwind.a"}:
        return "Apache-2.0 WITH LLVM-exception"
    if name == "libcompiler_rt.a":
        return "(Apache-2.0 WITH LLVM-exception) AND MIT"
    if name == "libzigc.a":
        return "MIT"
    return "NOASSERTION"


def native_version(name: str, release_version: str) -> str:
    if name == "libhost.a":
        return release_version
    if name == "libfuzzer.a":
        return LIBFUZZER_VERSION
    return ZIG_VERSION


def native_packages(manifests: list[str], release_version: str) -> list[dict[str, object]]:
    packages: list[dict[str, object]] = []
    seen_targets: set[str] = set()
    for value in manifests:
        if "=" not in value:
            raise SystemExit(f"native manifest must use TARGET=PATH: {value}")
        target, path_text = value.split("=", 1)
        if not target or target in seen_targets:
            raise SystemExit(f"duplicate or empty native target: {target}")
        seen_targets.add(target)
        path = Path(path_text)
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            parts = line.split()
            if len(parts) != 2 or not re.fullmatch(r"[0-9a-f]{64}", parts[0]):
                raise SystemExit(f"invalid native manifest line {number}: {path}")
            digest, name = parts
            safe_name = re.sub(r"[^A-Za-z0-9.-]", "-", name)
            packages.append(
                package(
                    f"SPDXRef-Native-{target}-{safe_name}",
                    f"roc-fuzz native input {target}/{name}",
                    native_version(name, release_version),
                    native_license(name),
                    "NOASSERTION",
                    digest,
                )
            )
    if seen_targets != {"x64musl", "arm64mac"}:
        raise SystemExit("native manifests must cover x64musl and arm64mac")
    return packages


def generate(bundle: Path, release_version: str, manifests: list[str], library_manifests: list[Path] | None = None) -> dict[str, object]:
    bundle = bundle.resolve()
    if not bundle.is_file() or not bundle.name.endswith(".tar.zst"):
        raise SystemExit(f"expected a .tar.zst release bundle: {bundle}")
    bundle_digest = sha256(bundle)
    root_id = "SPDXRef-Package-roc-fuzz"
    packages = [
        package(
            root_id,
            "roc-fuzz",
            release_version,
            "MIT",
            f"https://github.com/lukewilliamboswell/roc-fuzz/releases/download/{release_version}/{bundle.name}",
            bundle_digest,
        ),
        package(
            "SPDXRef-Package-libFuzzer",
            "LLVM libFuzzer from libfuzzer-sys",
            LIBFUZZER_VERSION,
            "Apache-2.0 WITH LLVM-exception",
            f"https://crates.io/api/v1/crates/libfuzzer-sys/{LIBFUZZER_VERSION}/download",
            LIBFUZZER_SHA256,
        ),
        package(
            "SPDXRef-Package-Zig-runtime",
            "Zig runtime and compiler runtime",
            ZIG_VERSION,
            "MIT",
            f"https://ziglang.org/download/{ZIG_VERSION}/",
        ),
        package(
            "SPDXRef-Package-musl",
            "musl libc bundled by Zig",
            ZIG_VERSION,
            "MIT",
            f"https://github.com/ziglang/zig/tree/{ZIG_VERSION}/lib/libc/musl",
        ),
        package(
            "SPDXRef-Package-LLVM-runtime",
            "LLVM libc++, libc++abi, libunwind, and compiler-rt bundled by Zig",
            ZIG_VERSION,
            "Apache-2.0 WITH LLVM-exception",
            f"https://github.com/ziglang/zig/tree/{ZIG_VERSION}/lib",
        ),
    ]
    packages.extend(native_packages(manifests, release_version))
    for manifest in library_manifests or []:
        native = json.loads(manifest.read_text())
        packages.append(package(
            f"SPDXRef-NativeRelease-{native['target']}",
            f"roc-fuzz native-library archive {native['target']}", native["release"],
            "NOASSERTION",
            f"https://github.com/{native['repository']}/releases/download/{native['release']}/{native['archive']}",
            native["sha256"],
        ))
    relationships = [
        {
            "spdxElementId": root_id,
            "relationshipType": "DEPENDS_ON" if str(component["SPDXID"]).startswith("SPDXRef-NativeRelease-") else "CONTAINS",
            "relatedSpdxElement": component["SPDXID"],
        }
        for component in packages[1:]
    ]
    relationships.insert(
        0,
        {
            "spdxElementId": "SPDXRef-DOCUMENT",
            "relationshipType": "DESCRIBES",
            "relatedSpdxElement": root_id,
        },
    )
    return {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"{bundle.name} release SBOM",
        "documentNamespace": (
            "https://github.com/lukewilliamboswell/roc-fuzz/sbom/"
            f"{release_version}/{bundle_digest}"
        ),
        "creationInfo": {
            "created": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
            "creators": ["Tool: roc-fuzz/scripts/generate_sbom.py"],
            "licenseListVersion": "3.27.0",
        },
        "documentDescribes": [root_id],
        "packages": packages,
        "relationships": relationships,
    }


def validate(document: dict[str, object], bundle: Path, release_version: str, library_count: int = 0) -> None:
    if document.get("spdxVersion") != "SPDX-2.3":
        raise SystemExit("SBOM does not declare SPDX 2.3")
    packages = document.get("packages")
    if not isinstance(packages, list) or len(packages) != 19 + library_count:
        raise SystemExit("SBOM component inventory is incomplete")
    root = packages[0]
    if not isinstance(root, dict) or root.get("versionInfo") != release_version:
        raise SystemExit("SBOM release version does not match the requested release")
    checksums = root.get("checksums")
    if checksums != [{"algorithm": "SHA256", "checksumValue": sha256(bundle)}]:
        raise SystemExit("SBOM subject checksum does not match the release bundle")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--release-version", required=True)
    parser.add_argument(
        "--native-manifest",
        action="append",
        default=[],
        help="generated native checksum manifest as TARGET=PATH (repeat for both targets)",
    )
    parser.add_argument("--output", type=Path)
    parser.add_argument("--library-manifest", type=Path, action="append", default=[])
    args = parser.parse_args()

    document = generate(args.bundle, args.release_version, args.native_manifest, args.library_manifest)
    validate(document, args.bundle, args.release_version, len(args.library_manifest))
    output = args.output or Path(f"{args.bundle}.spdx.json")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(output)


if __name__ == "__main__":
    main()
