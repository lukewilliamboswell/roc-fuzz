# Contributing to roc-fuzz

The platform has four layers:

- `platform/Fuzz.roc` defines typed generators, record-builder composition,
  and statically dispatched target construction.
- `platform/Target.roc` erases the app's input type behind closures.
- `platform/main.roc` exposes the byte-oriented native boundary and declares
  only the x64-musl target.
- `src/main.zig` adapts generated Roc ABI calls to libFuzzer and
  translates the friendly runner commands.

`src/roc_platform_abi.zig` is generated from Roc's `ZigGlue.roc`.

## Toolchain

Normal documentation, Roc source validation, target builds, and packaging
require only:

- a Roc compiler containing
  [roc-lang/roc#10657](https://github.com/roc-lang/roc/pull/10657);
- Python 3.10 or newer.

The prebuilt x64-musl inputs under `platform/targets/x64musl` are versioned so
users and CI do not need a native toolchain to consume the platform. Only
maintainers intentionally regenerating those inputs additionally need Zig
0.16.0, GNU `ar`, and network access to the checksum-pinned libFuzzer source.

## Regenerate platform inputs

Regenerate the vendored inputs with:

```sh
python3 scripts/build_platform.py
```

The build has one target: `x86_64-linux-musl`. It compiles the thin Zig host,
the checksum-pinned `libfuzzer-sys` 0.4.5 source, and Zig's static musl and C++
runtime inputs. It also rewrites `platform/targets/x64musl/SHA256SUMS`.
Review and commit the archives and checksum manifest as one change.

The fully static build excludes `FuzzerInterceptors.cpp`. Its wrappers locate
libc functions through `dlsym`, which is not usable in the static musl
executable. The standard libFuzzer scheduler, mutators, corpus engine, crash
handling, minimizer, and merge engine remain unchanged. Roc's compare and
switch instrumentation still supplies value feedback.

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
python3 scripts/test.py --operation validate --verbose
python3 scripts/test.py --operation build --verbose
python3 scripts/test.py --operation seed
python3 scripts/test.py --operation fuzz --max-total-time 2
```

Validation checks the exact example inventory, Roc formatting and types.
Building creates every self-contained executable and verifies that it is a
static x86-64 ELF. Seed validation renders and replays each deterministic input.
The fuzz operation runs short campaigns and verifies that an intentional Roc
failure is saved byte-for-byte with follow-up commands.

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

The former byte-oriented builtin targets live under `examples/builtins/` and
use `Fuzz.from_bytes`. This keeps their existing properties in the regression
matrix. Top-level examples are an end-user gallery and should prefer
`Fuzz.target`, typed generators, and the `.Fuzz` record builder. A multi-file
example must live in its own directory with `main.roc` as its app root; the test
driver enforces this so editor tooling can discover the project naturally.

## Release bundle

Create a Roc platform bundle from the vendored target inputs with:

```sh
python3 scripts/bundle.py --output-dir dist
```

`bundle.py` verifies the pinned Roc version and every vendored input checksum,
then includes the prebuilt archives and license notices in `roc bundle`.
It does not regenerate native inputs. Test the resulting bundle from an
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

The platform is intentionally x64-musl only. Keep native calls behind generated
glue so compiler ABI changes are caught by regeneration and compilation.
