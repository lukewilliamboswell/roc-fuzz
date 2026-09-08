# Release migration status

The default branch remains `trunk`. Releases currently support exact Roc nightlies;
the compiler release guard's nightly-bootstrap exception is explicit. No stable
compiler line or support branch is claimed.

## Bootstrap sequence

An explicit branch RC can unblock public examples before stable bootstrap:
dispatch `Release` on the source branch with `release_candidate=true`, a new
`X.Y.Z-rcN` version and `expected_sha` equal to its full commit. The workflow
checks source identity, tests the exact bundle on both targets and attests it,
then publishes a prerelease with `--latest=false`. This RC alone may contain
source-built libraries. It does not deploy Pages or open a default-branch
follow-up. Adopt and test its URL on the originating PR after publication.
Stable publication retains the released-library provenance requirement below.

1. Land and validate the `Native libraries` workflow on the default branch.
   Its default manual run is validation-only. Explicit publication of
   `native-libs-v1.0.0` builds and tests both targets, attests the archives and
   publishes them without changing the latest platform release.
2. Download its `native-libraries.lock.json` asset. Review the source revision,
   archive digests and workflow attestations. Replace the empty bootstrap lock
   and remove `--libraries source` from the CI and platform-release workflows in
   the same PR. Normal builds then restore verified archives and only build hosts.
   Keep source compilation explicit in the dedicated native workflow.
3. Run both platform targets and the exact candidate bundle tests. Publish a new
   platform version from the final tested commit. Its version is independent of
   the native-library tag.
4. The release follow-up verifies actual published downloads on both operating
   systems, opens a signed URL-update PR, and dispatches validation on that head.
   Review and merge after current-commit required checks pass.

Platform-source changes and new examples are tested against the working-tree
platform and exact candidate bundle. Their committed URLs are updated after
publication by the reviewed release follow-up; pointing at the prior release
during development does not block this source PR.

Published compatibility runs for changes to existing compiler header pins or
existing example dependency URLs, and for every manual/nightly dispatch.
Introducing header pins is a migration, not an update to a previously declared
compiler requirement. Likewise, moving local examples onto initial release URLs
is bootstrapped through source tests and the release follow-up. Subsequent pin
and published URL changes are gated. Required aggregate
checks always run; classification failures and unexpected skips fail closed.

The examples now use the published `0.4.0-rc1` bootstrap candidate, which includes
the new platform APIs absent from `0.3.0`. The candidate was built from commit
`1fa2b5f09d77f1e91a2df3b0a11adf8454dd2831` in
[Release run 34202782369](https://github.com/lukewilliamboswell/roc-fuzz/actions/runs/34202782369).
Both target consumer tests and SLSA/SPDX attestations passed. The published bundle
is byte-identical to the tested artifact (SHA-256
`e045382e6dcb9e04c29b14c6e63949fcb879917f328ab5c7120c5351653ba9b0`).
The RC did not change latest stable (`0.3.0`) or deploy Pages.
The full Linux suite also passed against the adopted public RC URLs without
platform rewriting, retaining only the existing documented upstream skips.

## Validation and live acceptance

Stable platform publication refuses an empty native lock or target provenance
that does not match it. Source-build bootstrap is available to validation and
explicitly requested release candidates.

Local verification completed during implementation: Linux native archive creation
and extraction, full platform-bundle checks/builds/replays/fuzz campaigns (retaining
the existing documented Dict uniqueness and F64 parsing skips), tooling unit tests,
workflow lint, header-based compiler installation and supply-chain consistency.
The RC also passed Linux/macOS archive tests and attested publication in CI.
Independent native-library publication, signed follow-up and protected-branch
acceptance still require live validation.

- `Published examples required`: committed URLs with the declared compiler, on
  fresh runners without restoring dependency caches when the published contract
  changes or validation is explicitly dispatched; otherwise an explicit skip.
- `CI required`: current source bundled and served to temporary example copies.
- `Release required`: exact archives proposed for publication, including both
  supported targets, documentation and SBOM generation.
- `nightly_validation: true` never publishes, creates follow-ups or deploys Pages.
- Configure the reviewed shared workflow SHA and nested actions in the allowlist;
  verify PR creation settings and strict branch rules using a real bot PR.
- Automatic merging remains disabled. A dispatched green run does not necessarily
  satisfy required PR checks; approve ordinary workflow startup if needed and
  verify a real protected merge. No bypass or bot self-approval is provided.
- Record successful Linux/macOS native publication, signed follow-up validation,
  nightly success, no-op and failed-candidate run links in the rollout PR.

## Recovery

Existing release tags and assets must never be overwritten. If publication is
partial, preserve the run's exact tested artifacts and inspect the tag SHA and
uploaded digests before a reviewed recovery. Do not blindly rerun a publishing
job. Retained workflow artifacts last 30 days for native builds.

The `Release follow-up` workflow can be dispatched separately with an existing
platform version after a publication/follow-up interruption. It resolves and
tests against the current default-branch head. It refuses to replace an existing
`release-followup/<version>` branch; inspect that branch and its PR before manual
recovery. Compiler pins and generated documentation are excluded from URL changes.
