# Vendored x64-musl platform inputs

Release CI generates the object and archive files in this directory. They are
not stored in Git; published roc-fuzz bundles contain the generated inputs so
bundle users do not need Zig, musl, a C++ toolchain, or libFuzzer.

For source development, run `python3 scripts/build_platform.py --target
x64musl`. The generated inputs and `SHA256SUMS` are ignored by Git.

The source and license details for the bundled runtimes are recorded in the
repository's `THIRD_PARTY_LICENSES.md`.
