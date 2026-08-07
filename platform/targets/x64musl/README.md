# Vendored x64-musl platform inputs

These object and archive files are versioned parts of the roc-fuzz platform.
They let Roc users build self-contained fuzz targets without installing Zig, a
C++ toolchain, musl, or libFuzzer.

Normal builds and releases consume these files directly. Maintainers should
run `python3 scripts/build_platform.py` only when intentionally updating the
host adapter, libFuzzer, Zig, or the generated Roc ABI glue. That script
rebuilds every input and refreshes `SHA256SUMS`; commit the binaries and
manifest together.

The source and license details for the bundled runtimes are recorded in the
repository's `THIRD_PARTY_LICENSES.md`.
