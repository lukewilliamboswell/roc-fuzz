# Fuzzing evidence for downstream projects

Every executable built with roc-fuzz contains its own supervised CI runner. It
can preserve a bounded campaign's configuration, provenance, log, corpus
manifest, and reproducing failures without installing a separate helper:

```sh
my-target ci .roc-fuzz/evidence/my-target .roc-fuzz/corpus/my-target \
  --time=60 \
  --max-input-size=4096 \
  --timeout=5 \
  --memory-limit=2048 \
  --source-revision="$SOURCE_REVISION" \
  --roc-version="$ROC_VERSION" \
  --platform-release="$ROC_FUZZ_RELEASE" \
  --platform-sha256="$ROC_FUZZ_SHA256"
```

The command launches the same executable as a child. This lets the supervising
process write evidence even when a Roc `crash`, failed `expect`, detected leak,
timeout, memory limit, or native signal terminates the fuzzing child. A machine
or supervisor process kill can still prevent report generation.

The report directory must be absent or empty and must not overlap the corpus.
It receives:

- `report.json`, following
  [`roc-fuzz-ci/v1`](docs/roc-fuzz-ci-report.schema.json);
- `summary.md`, suitable for a CI job summary;
- `run.log`, containing combined stdout and stderr; and
- `failures/`, containing libFuzzer's reproducing inputs.

The JSON manifest gives every corpus and failure file a size and SHA-256 digest.
The target executable and log are also hashed. Provenance fields are optional
for local work, but supply all four when publishing CI evidence. Arbitrary
environment variables are deliberately not copied into the report.

## Keep project policy in the project

The host operates one compiled target. A downstream repository remains
responsible for:

- deciding which target source files constitute its complete target inventory;
- pinning and installing Roc and the roc-fuzz platform release;
- generating domain-specific seeds and dictionaries;
- selecting per-target input, timeout, and memory bounds; and
- turning understood findings into deterministic regression tests.

This is important for targets such as Unicode conformance fuzzers, whose seed
corpora are derived from versioned data files. A generic host cannot infer that
application policy. A checked-in script or CI matrix should enumerate targets
and invoke each resulting binary's `ci` command.

Leak checks remain enabled by default. `--no-detect-leaks` is available for a
documented exceptional campaign, and the report records that it was used.
Projects testing allocation-sensitive operations should also place
`Fuzz.expect_allocs_at_most!` or `Fuzz.expect_allocs_at_least!` around the exact
operation whose cost is an invariant.

## GitHub Actions pattern

The following complete pattern assumes one target file per `fuzz/TARGET.roc`
and optional checked-in seeds under `fuzz/corpus/TARGET/`. Repositories with
generated seeds should replace only the seed-preparation step with their own
script.

```yaml
name: Fuzz campaigns

on:
  pull_request:
  schedule:
    - cron: "17 11 * * *"
  workflow_dispatch:

permissions:
  contents: read

jobs:
  fuzz:
    runs-on: ubuntu-24.04
    strategy:
      fail-fast: false
      matrix:
        target: [parser, decoder]
    env:
      ROC_FUZZ_RELEASE: "REPLACE_WITH_THE_RELEASE_USED_BY_FUZZ_SOURCES"
      ROC_FUZZ_SHA256: "REPLACE_WITH_THE_RELEASE_BUNDLE_SHA256"
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7

      - name: Read the pinned Roc version
        run: printf 'ROC_NIGHTLY_TAG=%s\n' "$(sed -n '1p' .roc-version)" >> "$GITHUB_ENV"

      - uses: roc-lang/setup-roc@cbe782d6f165b89c87d99f50a59ac4f5f73b4427
        with:
          version: nightly-new-compiler
          nightly-tag: ${{ env.ROC_NIGHTLY_TAG }}

      - name: Restore this target's corpus
        uses: actions/cache@caa296126883cff596d87d8935842f9db880ef25 # v5
        with:
          path: .roc-fuzz/corpus/${{ matrix.target }}
          key: fuzz-${{ runner.os }}-${{ matrix.target }}-${{ env.ROC_NIGHTLY_TAG }}-${{ env.ROC_FUZZ_RELEASE }}
          restore-keys: fuzz-${{ runner.os }}-${{ matrix.target }}-

      - name: Build and seed the target
        env:
          TARGET: ${{ matrix.target }}
        run: |
          mkdir -p ".roc-fuzz/bin" ".roc-fuzz/corpus/$TARGET"
          roc build --fuzz "fuzz/$TARGET.roc" --output=".roc-fuzz/bin/$TARGET" --no-cache
          if test -d "fuzz/corpus/$TARGET"; then
            cp -R "fuzz/corpus/$TARGET/." ".roc-fuzz/corpus/$TARGET/"
          fi

      - name: Run the supervised campaign
        env:
          TARGET: ${{ matrix.target }}
          CAMPAIGN_SECONDS: ${{ github.event_name == 'schedule' && '900' || '60' }}
        run: |
          roc_version="$(roc version | tr '\n' ' ')"
          ".roc-fuzz/bin/$TARGET" ci \
            ".roc-fuzz/evidence/$TARGET" \
            ".roc-fuzz/corpus/$TARGET" \
            --time="$CAMPAIGN_SECONDS" \
            --max-input-size=4096 \
            --timeout=5 \
            --memory-limit=2048 \
            --source-revision="${{ github.sha }}" \
            --roc-version="$roc_version" \
            --platform-release="$ROC_FUZZ_RELEASE" \
            --platform-sha256="$ROC_FUZZ_SHA256"

      - name: Publish the Markdown summary
        if: always()
        env:
          TARGET: ${{ matrix.target }}
        run: |
          summary=".roc-fuzz/evidence/$TARGET/summary.md"
          if test -f "$summary"; then cat "$summary" >> "$GITHUB_STEP_SUMMARY"; fi

      - name: Upload evidence and reproducing failures
        if: always()
        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7
        with:
          name: fuzz-evidence-${{ matrix.target }}
          path: .roc-fuzz/evidence/${{ matrix.target }}
          if-no-files-found: error
```

Pull requests therefore get a one-minute bounded campaign per target, while the
scheduled workflow gives each target fifteen minutes. Keep normal unit and
regression tests on every change as well; a fuzz corpus is not a correctness
oracle by itself.

## OpenSSF evidence and coverage limits

These artifacts provide reviewable evidence that a FLOSS dynamic-analysis tool
ran with explicit bounds and assertions, and that findings were retained. They
can support a project's self-assessment for the OpenSSF Best Practices dynamic
analysis criteria. OpenSSF Scorecard recognition is a separate source-level
detection concern; roc-fuzz support must be added upstream to Scorecard.

libFuzzer's `cov` and `ft` values are search-feedback counts from LLVM
SanitizerCoverage. They have no source denominator and are not statement or
branch percentages. Do not use them to claim the Best Practices Silver 80%
statement threshold or Gold 90% statement/80% branch thresholds.

True Roc source coverage requires the Roc compiler to emit LLVM profile
instrumentation and coverage mappings, link the matching profile runtime, and
preserve stable source paths. Until that compiler work ships, the appropriate
badge response is that no FLOSS source-coverage measurement tool currently
exists for pure Roc code, with this limitation linked as the justification.
