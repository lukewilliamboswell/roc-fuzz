# Contributing to roc-fuzz

The public workflow assumes a released Roc bundle and compiler. This document covers platform development, the repository regression matrix, and the Roc compiler coverage implementation.

## Repository layout

- `platform/main.roc` defines the platform and natural C ABI entrypoint.
- `platform/Arbitrary.roc` turns input bytes into useful Roc values and allocation shapes.
- `examples/` contains every active builtin quality target.
- `src/` is the Rust host and generated Roc ABI.
- `fuzz/` is the isolated cargo-fuzz executable used by the repository's fuzz commands.
- `scripts/` contains every command-line helper and the strict JSON spec driver.

The root `roc-fuzz` crate is a library containing the native Roc ABI host, while
cargo-fuzz requires a separate `#![no_main]` binary linked to `libfuzzer-sys`.
[`fuzz/fuzz_targets/roc-fuzz.rs`](fuzz/fuzz_targets/roc-fuzz.rs) provides that
entrypoint. [`scripts/test.py`](scripts/test.py) uses it for the opt-in `seed` and
`fuzz` operations, and [`scripts/run.py`](scripts/run.py) selects it explicitly
when fuzzing an individual app. Its corpus and failure-artifact directories are
runtime state ignored by Git. The current CI workflow does not run these opt-in
fuzz operations.

This companion crate is contributor tooling: it is neither published with the
root Rust crate nor included in the Roc platform bundle. Consumers create an
equivalent crate in their own project with `cargo fuzz init`.

## Roc version and compiler worktree

[`.roc-version`](.roc-version) is the release and CI pin. Normal checks reject a different compiler. When developing the Roc side, create a worktree from the sibling Roc repository and leave the shared checkout untouched:

```sh
git -C ../roc worktree add ../roc-worktrees/roc-fuzz-sancov -b roc-fuzz-sancov origin/main
(cd ../roc-worktrees/roc-fuzz-sancov && zig build roc)

export ROC="$PWD/../roc-worktrees/roc-fuzz-sancov/zig-out/bin/roc"
export ROC_ALLOW_UNPINNED=1
export ROC_GLUE_SPEC="$PWD/../roc-worktrees/roc-fuzz-sancov/src/glue/src/RustGlue.roc"
```

`ROC_ALLOW_UNPINNED=1` is an explicit development override; do not set it in release validation.

## Validation and spec tests

The driver follows the strict shared-spec design used by the Go platform template:

```sh
python3 scripts/test.py --operation validate
python3 scripts/test.py --operation build
python3 scripts/test.py --operation seed
python3 scripts/test.py --operation fuzz --target strFromUtf8 --max-total-time 10
```

It discovers every `examples/*.roc` file and rejects missing, extra, duplicate, or malformed spec entries. Validation checks Roc formatting, builds a fresh content-addressed bundle, serves it over loopback HTTP, rewrites temporary copies of the examples to use its URL, checks their types, runs their expects, verifies generated Rust glue, executes the Rust ABI smoke test, and runs Python units. Build, seed, and fuzz use the same served bundle path. Seed and fuzz explicitly run `roc build --fuzz` first, then give that prebuilt archive to a separate cargo-fuzz invocation. They also run an intentional Roc failure and require cargo-fuzz to save the exact triggering input as a replayable artifact. The tests therefore exercise the artifact and command boundary exactly as a consumer does, rather than resolving the platform through a repository-relative path or hiding both builds in one wrapper.

Spec tests fit this repository as an exact inventory and execution matrix, not as golden stdout files. Each Roc target contains its own invariant oracle. [`scripts/test_spec.json`](scripts/test_spec.json) supplies deterministic input bytes, libFuzzer seeds, stage controls, and explicit reasons for retired APIs.

To add a target:

1. Add `examples/<name>.roc` with `main : List(U8) -> U8`.
2. Add exactly one matching spec entry and deterministic seed.
3. Run the validate, build, and seed operations.

[`scripts/run_many.py`](scripts/run_many.py) is a convenience wrapper for fuzzing selected repository examples; with no target arguments it selects all active examples.

## Build a release bundle

This platform has no prebuilt host objects: its target emits the compiled Roc app as an archive, and the Rust crate supplies the native host. `inputs_dir` is therefore the package root, which is always present after unbundling. Build the content-addressed release artifact with:

```sh
python3 scripts/bundle.py --output-dir dist
```

Before publishing, test an external app that references the resulting `.tar.zst`. The public workflow builds it with `roc build --fuzz`, then gives the resulting archive to the Rust host through:

- `ROC_FUZZ_ARCHIVE=/absolute/path/to/libroc_fuzz.a` for the consumer workflow.

Repository automation also supports compiling a source app from the Cargo build script:

- `ROC_FUZZ_APP=/absolute/path/to/app.roc` for a bundle consumer’s app, or
- `ROC_FUZZ_TARGET=<name>` for an app in this repository’s `examples/` directory.

All three variables are mutually exclusive. `ROC_FUZZ_INSTRUMENT=0` applies only to source-app compatibility validation that intentionally does not need coverage feedback. [`scripts/run.py`](scripts/run.py) and [`scripts/run_many.py`](scripts/run_many.py) are contributor conveniences; consumers do not need this repository or Python.

## Generated Rust ABI

[`src/roc_platform_abi.rs`](src/roc_platform_abi.rs) is generated from Roc’s `RustGlue.roc`; it replaces the removed Rust-compiler `roc_std` crate and legacy out-pointer entrypoint.

```sh
python3 scripts/generate_rust_glue.py --check
python3 scripts/generate_rust_glue.py
```

Without `ROC_GLUE_SPEC`, the generator downloads the glue spec at the exact commit revision embedded in `.roc-version`. Compiler development should use the worktree override shown above.

## Roc LLVM coverage change

The compiler work is moderate and localized, not an LLVM backend redesign. Roc already had almost all of the machinery:

- `src/build/zig_llvm.cpp` already imports LLVM’s coverage pass and inserts it when `ZigLLVMEmitOptions.sancov` is enabled.
- The Zig/C++ bridge already carries LLVM’s complete coverage option structure.
- Roc combines the application and builtins into one LLVM module before object emission, so one pass covers both.

The patch adds roughly 65 lines across three CLI files:

- `src/cli/cli_args.zig` parses and documents `--fuzz`.
- `src/cli/main.zig` restricts it to LLVM, non-Wasm builds, forwards it through watch mode, and separates covered artifact names from normal cached artifacts.
- `src/cli/builder.zig` enables edge coverage, inline 8-bit counters, PC tables, compare and switch tracing, indirect-call tracing, and stack-depth feedback through the existing emit option.

The main engineering risks are complete option propagation, cache identity, coverage of linked builtins, position-independent archive output, and compatibility with the LLVM version embedded by Roc. There is no new Roc IR lowering, builtin implementation, or ABI design. Instrumenting all Roc-generated memory accesses would be a separate, much broader project; this patch is deliberately limited to coverage feedback.

Verify an emitted archive independently of the Rust wrapper:

```sh
nm -u path/to/libroc_fuzz.a | grep __sanitizer_cov_
```

The archive should import the 8-bit-counter and PC-table initialization functions plus compare and switch callbacks.
