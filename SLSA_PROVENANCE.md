# Release bundle provenance

roc-fuzz does not store native archives or objects in Git. The release workflow
builds the x64-musl inputs on a GitHub-hosted Linux runner and the Apple Silicon
inputs on a GitHub-hosted macOS runner. A Linux packaging job downloads both
sets, verifies their generated checksum manifests, and creates the platform
bundle that is tested on both supported operating systems.

After those consumer tests pass, GitHub's attestation service creates signed
SLSA build provenance and an SBOM attestation for the exact `.tar.zst` bundle.
GitHub binds the
attestation to the release workflow and source revision with its OIDC identity,
signs it through Sigstore, and records it in the repository attestations API.
No long-lived signing key is stored in the repository.

Each release also publishes `<bundle>.intoto.jsonl` for offline attestation
verification and `<bundle>.spdx.json` as an SPDX 2.3 software bill of materials.
The SBOM records the bundle digest and the libFuzzer, Zig runtime, musl, and LLVM
runtime components contained in the supported native inputs.

The build pins Zig 0.16.0 and the SHA-256 of the `libfuzzer-sys` 0.4.5 source
archive. The macOS build necessarily uses the SDK supplied by the selected
GitHub-hosted macOS runner. The final bundle, rather than intermediate native
inputs, is the published and attested subject.

## Verify a release

Download a bundle from the GitHub release, then run:

```console
gh attestation verify roc-fuzz-<version>.tar.zst \
  --repo lukewilliamboswell/roc-fuzz
```

Verification checks the bundle digest, Sigstore signature, certificate and
repository identity, and transparency information. This project does not claim
a particular SLSA level; the attestation establishes the workflow and revision
that produced the released bundle.

For offline or archived verification, download the matching
`<bundle>.intoto.jsonl` asset and pass it to GitHub CLI:

```console
gh attestation verify roc-fuzz-<version>.tar.zst \
  --bundle roc-fuzz-<version>.tar.zst.intoto.jsonl \
  --repo lukewilliamboswell/roc-fuzz
```

The adjacent `.spdx.json` file is human- and machine-readable release inventory.
Its root package checksum must equal the SHA-256 of the downloaded bundle.
