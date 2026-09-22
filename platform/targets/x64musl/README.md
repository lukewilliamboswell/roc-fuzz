# Vendored x64-musl platform inputs

Platform builds restore independently released libraries and build `libhost.a`
from current source. These files are not stored in Git; roc-fuzz bundles contain the inputs so
bundle users do not need Zig, musl, a C++ toolchain, or libFuzzer.

Normal development runs `scripts/build_platform.roc -- --target x64musl`; this
rehashes cached release bytes and downloads only the exact locked asset on a
miss. Use `--libraries source` only when intentionally developing the separately
dispatched linker-input producer.
The generated inputs, provenance metadata, and `SHA256SUMS` are ignored by Git.

The source and license details for the bundled runtimes are recorded in the
repository's `THIRD_PARTY_LICENSES.md`.
