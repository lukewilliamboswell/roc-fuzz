# Contributing to roc-fuzz

The complete contributor guide is maintained as the
[development chapter](docs/development.adoc) of the roc-fuzz manual. It covers
the toolchain, native inputs, ABI glue, validation, documentation, packaging,
release candidates, stable releases, and design constraints.

Build the manual and generated API reference locally with:

```sh
python3 scripts/build_docs.py
```

The command requires Docker and the Roc compiler selected by `ROC` or available
as `roc` on `PATH`.
