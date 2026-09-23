# Vendored Apple Silicon macOS platform inputs

Platform builds restore independent native libraries and build the current host
for Roc's `arm64mac` target. They build fuzz
targets for Apple Silicon macOS with a minimum deployment target of macOS 11.0.
Published bundles let Roc users build without installing Zig, a C++ toolchain,
or libFuzzer; the generated files themselves are not stored in Git.

Regenerate them from the repository root with:

```sh
scripts/build_platform.roc -- --target arm64mac
```

The default verifies the reviewed manifest and archive hashes, including on a
cache hit, then builds the host adapter and refreshes `SHA256SUMS`. Attestations
are checked by the trusted publisher when adopting a new release, rather than by
every routine consumer. Use `--libraries source` only when explicitly developing
the dispatched producer; it compiles checksum-pinned libFuzzer (including
upstream `FuzzerInterceptors.cpp`) and Zig runtimes for
`aarch64-macos.11.0` locally.
Generated files, provenance metadata, and checksum manifests are ignored by Git.
The repository-owned host glue also supplies Roc's stack-depth coverage TLS
slot and direct libFuzzer hook bindings required without `-export_dynamic`.
The resulting executable may dynamically link Apple system libraries such as
`/usr/lib/libSystem.B.dylib`; no other dynamic dependency is permitted.
