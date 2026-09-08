# Vendored x64-musl platform inputs

Platform builds restore independently released libraries and build `libhost.a`
from current source. These files are not stored in Git; roc-fuzz bundles contain the inputs so
bundle users do not need Zig, musl, a C++ toolchain, or libFuzzer.

For source development, run `python3 scripts/build_platform.py --target
x64musl`. During initial bootstrap, add `--libraries source` explicitly.
The generated inputs, provenance metadata, and `SHA256SUMS` are ignored by Git.

The source and license details for the bundled runtimes are recorded in the
repository's `THIRD_PARTY_LICENSES.md`.
