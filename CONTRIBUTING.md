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
Do not hand-edit it.

## Toolchain

Development currently requires:

- a Roc compiler containing
  [roc-lang/roc#10657](https://github.com/roc-lang/roc/pull/10657);
- Zig 0.16.0;
- Python 3.10 or newer; and
- GNU `ar`.

Build the platform inputs with:

```sh
python3 scripts/build_platform.py
```

The build has one target: `x86_64-linux-musl`. It compiles the thin Zig host,
the checksum-pinned `libfuzzer-sys` 0.4.5 source, and Zig's static musl and C++
runtime inputs. Generated archives under `platform/targets/x64musl` are
ignored by Git and included in release bundles.

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

Build the target inputs and create a Roc platform bundle with:

```sh
python3 scripts/bundle.py --output-dir dist
```

`bundle.py` verifies the pinned Roc version, runs `build_platform.py`, and
then calls `roc bundle`. Test the resulting bundle from an external target
before publishing it.

## Design constraints

Static dispatch happens while `Fuzz.target` is specialized for the app's
input type. `Target` then erases that type, preventing the native ABI from
depending on every app record or tag-union layout.

The platform is intentionally x64-musl only. Keep native calls behind generated
glue so compiler ABI changes are caught by regeneration and compilation.
