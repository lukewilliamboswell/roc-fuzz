# Contributing to roc-fuzz

The complete contributor guide is maintained as the
[development chapter](docs/development.adoc) of the roc-fuzz manual. It covers
the toolchain, native inputs, ABI glue, validation, documentation, packaging,
release candidates, stable releases, and design constraints.

Use issues for ordinary bugs and design discussion, and pull requests for
changes. Explain the affected behavior, the change, and its validation. Add an
automated test for bug fixes and significant new behavior, and update public
examples or interface documentation when behavior changes. Follow
[SECURITY.md](SECURITY.md) for suspected vulnerabilities.

Build the manual and generated API reference locally with:

```sh
python3 scripts/build_docs.py
```

The command requires Docker and the Roc compiler selected by `ROC` or available
as `roc` on `PATH`.
