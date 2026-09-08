# Contributing to roc-fuzz

The platform has four layers:

- `platform/Fuzz.roc` defines typed generators, record-builder composition,
  and statically dispatched target construction.
- `platform/Target.roc` erases the app's input type behind closures.
- `platform/main.roc` exposes the byte-oriented native boundary and declares
  the x64-musl and Apple Silicon macOS targets.
- `src/main.zig` adapts generated Roc ABI calls to libFuzzer and
  translates the friendly runner commands.

`src/roc_platform_abi.zig` is generated from Roc's `ZigGlue.roc`.

## Toolchain

Normal documentation, Roc source validation, target builds, and packaging
require only:

- a Roc compiler containing
  [roc-lang/roc#10657](https://github.com/roc-lang/roc/pull/10657);
- Python 3.12 or newer.

Native libraries have an independent release cycle; `libhost.a` is built with
each platform update. Source development requires Zig 0.16.0 and GitHub CLI for
library attestation verification. The builder uses `zig ar`.

Exact compiler versions live in the platform and application header `roc`
fields. The shared updater changes only those pins, preserving published URLs.
The installer verifies archives against SHA-256 digests returned by GitHub for
the exact upstream release. These digests are no longer committed beside a
duplicate `.roc-version`; independently recorded digests can be supplied using
`install_roc.py --checksums-file`.

## Generate platform inputs

Generate the current host's ignored inputs with:

```sh
python3 scripts/build_platform.py
```

Pass `--target x64musl` or `--target arm64mac` explicitly in automation. The default
restores the archive in `native-libraries.lock.json`, verifies its digest and
producing workflow's attestation, builds the current host, and writes local
`SHA256SUMS`. Never commit generated archives, objects, or manifests.

During initial bootstrap, the lock intentionally has no published release.
Use `--libraries source` explicitly with `build_platform.py`, `test_local.py`, or
`run.py` until adopting the first release. This compiles pinned libFuzzer and Zig
runtimes locally. CI's temporary source-build flags must be removed in the same
reviewed change that adopts the published lock.

The `Native libraries` workflow packages each target without `libhost.a`, tests
the archive with a fresh host, and signs provenance and an SPDX SBOM when
explicitly publishing from the default branch. Tags use `native-libs-vX.Y.Z`
and never become GitHub's latest platform release. Release new libraries for
changes to library sources, runtimes/toolchains, flags, targets, security fixes,
or the macOS adapter compiled into `libfuzzer.a`. The workflow emits the archive
pins and source identity as a lock-file release asset for review. The macOS
coverage shim stays with `libhost.a`.

Before adopting a native-library release, review its `native-libraries.lock.json`
asset, source revision, archive digests, and workflow attestations. The workflow's
default manual run is validation-only; publication must be explicitly requested.

The fully static build excludes `FuzzerInterceptors.cpp`. Its wrappers locate
libc functions through `dlsym`, which is not usable in the static musl
executable. The standard libFuzzer scheduler, mutators, corpus engine, crash
handling, minimizer, and merge engine remain unchanged. Roc's compare and
switch instrumentation still supplies value feedback.

The macOS target includes `FuzzerInterceptors.cpp`: its `dlsym` lookups work
with macOS's dynamic `libSystem`. Its deployment target is macOS 11.0, and its
only allowed dynamic dependencies are system libraries.

`src/macos_sancov.c` supplies the public TLS slot required by Roc's macOS
stack-depth coverage instrumentation. `src/macos_fuzzer_ext_functions.cpp`
binds the standalone runner hooks directly because upstream libFuzzer's Darwin
`dlsym` lookup requires `-export_dynamic`, which Roc does not pass. Both files
are repository-owned platform glue covered by the project license; the native
build, `show`/replay, fuzz, failure-artifact, and packaged-bundle smoke tests
exercise them on Apple Silicon.

## Regenerate ABI glue

Regenerate glue only when the Roc natural ABI changes:

```sh
export ROC_SOURCE="$PWD/../roc-worktrees/roc-fuzz-sancov"
export ROC="$ROC_SOURCE/zig-out/bin/roc"
python3 scripts/build_platform.py --regenerate-glue
```

Review the generated Zig diff and rebuild every example after regeneration.

## Validation

Use the compiler under development through `ROC`:

```sh
export ROC=/path/to/roc
python3 scripts/test_local.py --operation validate --verbose
python3 scripts/test_local.py --operation build --verbose
python3 scripts/test_local.py --operation seed
python3 scripts/test_local.py --operation fuzz --max-total-time 2
```

`test_local.py` prepares the current host inputs, packages the working-tree
platform, serves it from an ephemeral localhost port, and asks `test.py` to use
temporary rewritten copies of every example. Checked-in example declarations
remain pinned to a published release, while local and CI runs exercise
unreleased platform changes. Validation checks the exact example inventory, Roc formatting and types.
After generating the current host inputs, building creates every self-contained executable and verifies a static x86-64
ELF on Linux or an arm64 Mach-O with system-only dynamic dependencies on macOS.
Seed validation renders and replays each deterministic input. The fuzz
operation runs short campaigns and verifies that an intentional Roc failure is
saved byte-for-byte with follow-up commands.

Generate and audit the public API documentation with:

```sh
ROC_DOCS_URL_ROOT=/roc-fuzz/main roc docs \
  --output=.test-cache/docs platform/main.roc
python3 scripts/check_docs.py .test-cache/docs
```

The audit fails if an exposed module or public entry has no rendered
documentation. CI and the release workflow run the same check.

Every example runs the `check`, `test`, `build`, `seed`, and `fuzz` stages by
default. A temporary exception must use a `skip` entry in `test_spec.json` with
both a concrete reason and a full GitHub issue URL. The driver rejects
unexplained skips; skipping a prerequisite also requires skipping its dependent
stages.

Published-example compatibility checks run when existing compiler header pins or
published dependency URLs change, and on every manual/nightly dispatch. Source
and candidate-bundle checks cover platform development and initial migration
from local paths. `nightly_validation: true` never publishes or deploys.

Every target asserts on allocation behaviour as well as on results. A property
can check what an operation computes but not what it costs, so a builtin that
stops mutating a uniquely owned value in place and starts copying it still
returns the right answer and no content property notices. Pin the cost with
`Fuzz.expect_allocs_at_most!` or `Fuzz.expect_allocs_at_least!`, and build the target with `Fuzz.target_with!` or
`Fuzz.from_bytes!` so the property may perform effects. The `check` stage
requires one of those assertion helpers; raw counter reads, measurements, and
leak-only checks do not satisfy the policy. A target that genuinely cannot
assert on cost belongs in
`ALLOCATION_ASSERTION_EXEMPT` in `scripts/test.py` with a concrete reason.

Assert on a difference between two counter reads, never on a raw value: the
counter is process-wide and libFuzzer reuses one process across millions of
inputs. Only assert zero for a value that is uniquely owned and pre-sized,
because copy-on-write allocation is correct when a value is aliased.

Separately, the runner checks after every input that the target freed
everything it allocated, and fails the input otherwise. Pass
`--no-detect-leaks` to a run to turn that off.

The former byte-oriented builtin targets live under `examples/builtins/` and
use `Fuzz.from_bytes`. This keeps their existing properties in the regression
matrix. Top-level examples are an end-user gallery and should prefer
`Fuzz.target`, typed generators, and the `.Fuzz` record builder. A multi-file
example must live in its own directory with `main.roc` as its app root; the test
driver enforces this so editor tooling can discover the project naturally.

## Release bundle

Create a Roc platform bundle after generating both target input sets with:

```sh
python3 scripts/bundle.py --output-dir dist
```

`bundle.py` verifies the pinned Roc version and every generated input checksum,
then includes the archives and license notices in `roc bundle`. Production
release jobs build both hosts on native hosted runners before bundling.
Test the resulting bundle from an
external target with:

```sh
python3 scripts/test_bundle.py dist/<bundle>.tar.zst
```

Production releases use the `Release` workflow. From the repository's
**Actions** tab, run it on the default branch with an `X.Y.Z` version (or an
`X.Y.Z-rcN` release candidate). Pull requests run the same workflow in dry-run
mode. A real release:

1. validates all sources, tests, and short fuzz campaigns;
2. builds the platform bundle and tests that packaged bundle as an external
   consumer;
3. generates and validates versioned API docs;
4. publishes the bundle and docs archive in a GitHub release; and
5. deploys the versioned docs to Pages and updates the root redirect.

The bump check requires a version increment from the previous platform release.
The release policy explicitly permits exact-nightly bootstrap on `trunk`; no
stable compiler compatibility or maintenance branch is implied.

To unblock a source PR before stable bootstrap, dispatch `Release` on that branch
with `release_candidate=true`, a new `X.Y.Z-rcN` version, and the full source SHA
in `expected_sha`. Both target bundles must pass before the workflow attests and
publishes the RC. Only this explicit RC path permits source-built libraries.
It preserves the latest stable release and Pages, and does not create a
default-branch URL follow-up. Verify the published archive and adopt its URL in
the originating PR. Stable releases still require the independent library lock.

After publication, `Release follow-up` verifies the published archive, tests
proposed URLs on Linux and macOS, creates a verified signed URL-update PR, and
dispatches its validation. Compiler pins are preserved. Required PR workflows
may still need approval to start; dispatch success alone does not establish
that branch protection accepts the PR. If an old platform lacks newly used APIs,
publish a compatible platform and adopt its URL through the follow-up.
Inspect partial publication before recovery; never replace existing tags or
assets or rebuild an already-published release from a moving branch.
Preserve the run's exact tested artifacts and inspect the tag SHA and uploaded
digests before recovery; do not blindly rerun a publishing job.

After an interrupted follow-up, dispatch `Release follow-up` with the existing
platform version. It tests against the current default-branch head and refuses
to replace an existing `release-followup/<version>` branch. Inspect that branch
and its PR before manual recovery. URL updates exclude compiler pins and
generated documentation.

## Design constraints

Static dispatch happens while `Fuzz.target` is specialized for the app's
input type. `Target` then erases that type, preventing the native ABI from
depending on every app record or tag-union layout.

The platform supports x64-musl and Apple Silicon macOS. Keep native calls behind
generated glue so compiler ABI changes are caught by regeneration and compilation.
