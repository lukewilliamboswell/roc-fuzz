# Vendored Apple Silicon macOS platform inputs

Release CI generates the native inputs for Roc's `arm64mac` target. They build fuzz
targets for Apple Silicon macOS with a minimum deployment target of macOS 11.0.
Published bundles let Roc users build without installing Zig, a C++ toolchain,
or libFuzzer; the generated files themselves are not stored in Git.

Regenerate them from the repository root with:

```sh
python3 scripts/build_platform.py --target arm64mac
```

The generated files and `SHA256SUMS` are ignored by Git. The script compiles the host adapter and checksum-pinned libFuzzer source for
`aarch64-macos.11.0`, includes upstream `FuzzerInterceptors.cpp`, copies Zig's
static libc++, libc++abi, and compiler-rt archives, and refreshes `SHA256SUMS`.
The repository-owned host glue also supplies Roc's stack-depth coverage TLS
slot and direct libFuzzer hook bindings required without `-export_dynamic`.
The resulting executable may dynamically link Apple system libraries such as
`/usr/lib/libSystem.B.dylib`; no other dynamic dependency is permitted.
