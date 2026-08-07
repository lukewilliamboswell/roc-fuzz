# Contributing to the self-contained runner spike

The spike has four layers:

- `platform/Fuzz.roc` defines typed generators and statically dispatched target construction.
- `platform/Target.roc` is the type-erased closure boundary used by the platform.
- `platform/main.roc` exports `name`, `run`, and `show` and links only an x64-musl executable.
- `platform/host/main.zig` adapts generated Roc ABI calls to libFuzzer and translates the friendly CLI into native libFuzzer modes.

`platform/host/roc_platform_abi.zig` is generated from Roc's `ZigGlue.roc`.
Do not hand-edit it.

## Toolchain

Use the sibling worktree for
[roc-lang/roc#10657](https://github.com/roc-lang/roc/pull/10657). The default
paths below match this checkout:

```sh
export ROC_SOURCE="$PWD/../roc-worktrees/roc-fuzz-sancov"
export ROC="$ROC_SOURCE/zig-out/bin/roc"
python3 scripts/build_spike.py
```

`build_spike.py` intentionally has one target: `x86_64-linux-musl`. It
regenerates glue with the PR compiler, compiles `libhost.a`, compiles the
`libfuzzer-sys` 0.4.5 source pinned by `fuzz/Cargo.lock`, and copies Zig's
static musl and C++ runtime inputs. These binary target inputs are ignored by
Git in this spike; a release job would place them in the published platform
bundle.

`FuzzerInterceptors.cpp` is deliberately excluded. Its wrappers use `dlsym` to
find the underlying libc symbols and fail in a fully static musl process. Do
not re-enable it without a static-link-compatible implementation and a
mutation smoke test; the failure presents as a null call from an intercepted
libc function. Roc's compiler-provided compare and switch tracing remains
enabled without it.

## Validation

Run the typed checks and exact default-target build:

```sh
"$ROC" check spike/typed_target.roc
"$ROC" check spike/crashing_target.roc
"$ROC" build --fuzz spike/typed_target.roc
file typed_target
ldd typed_target
./typed_target --help
./typed_target run --runs=100
```

`file` should report a statically linked x86-64 ELF, and `ldd` should report
that it is not dynamic. The run summary should report one or more coverage
counter regions and save novel inputs under `.roc-fuzz/`.

Exercise rendering and minimization with:

```sh
./typed_target show .roc-version
"$ROC" build --fuzz spike/crashing_target.roc
./crashing_target replay .roc-version
./crashing_target minimize .roc-version /tmp/roc-fuzz-minimized.input
./crashing_target replay /tmp/roc-fuzz-minimized.input
./typed_target reduce-corpus .roc-fuzz/corpus /tmp/roc-fuzz-reduced
```

The last replay should reproduce the Roc crash with a smaller file.

## Design constraints

Static dispatch happens only while `Fuzz.target` is specialized for the app's
input type. `Target` then erases that type behind closures, which prevents the
native host ABI from depending on every app's record or tag-union layout.

The x64-musl restriction is expressed directly in `platform/main.roc`; there is
no glibc fallback. Keep host calls behind generated glue so changes to Roc's
natural ABI are caught by regeneration and compilation.

The root Rust host and cargo-fuzz scripts remain as the pre-spike implementation
for comparison. They are not linked into the self-contained executable. Their
`cargo test` path still requires the old separately built `ROC_FUZZ_ARCHIVE`;
use the validation commands above for this spike.
