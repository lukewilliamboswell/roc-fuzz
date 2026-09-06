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
- Python 3.10 or newer.

Native inputs are generated in CI and published only inside release bundles.
Bundle consumers do not need a native toolchain. Source development requires
Zig 0.16.0 and network access to the checksum-pinned libFuzzer source; the
builder uses `zig ar`, not an unpinned system archiver.

Repository automation also pins the Roc nightly archives themselves. The tag
in `.roc-version` and the Linux/macOS digests in `.roc-nightly-sha256` are one
atomic dependency pin. Let the daily updater change them together; a digest
change to an already-pinned tag is treated as a supply-chain failure.

## Generate platform inputs

Generate the current host's ignored inputs with:

```sh
python3 scripts/build_platform.py
```

Pass `--target x64musl` or `--target arm64mac` explicitly in automation. The build compiles
the thin Zig host, the checksum-pinned `libfuzzer-sys` 0.4.5 source, and the
needed Zig runtime inputs and writes one local `SHA256SUMS` manifest per target.
Never commit those archives, objects, or generated manifests.

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

`test_local.py` generates the current host inputs, packages the working-tree
platform, serves it from an ephemeral localhost port, and asks `test.py` to use
temporary rewritten copies of every example. Checked-in example declarations
remain pinned to the latest published release, while local and CI runs exercise
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
release jobs generate both targets on native hosted runners before bundling.
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

The bump check is intentionally `warn` while there is no previous release.
Change it to `require` after the first release establishes a compatible bundle
baseline.

## Design constraints

Static dispatch happens while `Fuzz.target` is specialized for the app's
input type. `Target` then erases that type, preventing the native ABI from
depending on every app record or tag-union layout.

The platform supports x64-musl and Apple Silicon macOS. Keep native calls behind
generated glue so compiler ABI changes are caught by regeneration and compilation.
