# roc-fuzz

[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/lukewilliamboswell/roc-fuzz/badge)](https://scorecard.dev/viewer/?uri=github.com/lukewilliamboswell/roc-fuzz)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/14753/badge)](https://www.bestpractices.dev/projects/14753)

`roc-fuzz` is a Roc platform for testing pure Roc code past the examples you
write:

- **Fuzz targets** check a property over typed, generated inputs with
  coverage-guided search, and save any failure so it can be shown, replayed,
  minimized and kept as a source regression.
- **Goals, trace rules and allocation measurements** check what a passing
  campaign reached and how the code behaved, with exact allocation baselines
  that change only by explicit acceptance.
- **`Model`** describes a stateful component as a state machine, searches a small
  world exhaustively under `roc test`, and fuzzes the same machine over a large
  one.
- **`Solve`** proves a claim about fixed-width integer arithmetic for every
  value, or returns the values that break it.

The platform supports Linux x86-64 with musl and Apple Silicon macOS 11 or newer.

A target builds directly into a self-contained executable:

```sh
roc build --fuzz my_target_app.roc
./my_target_app check
./my_target_app accept   # explicitly review and accept allocation observations
./my_target_app run --report-dir=.roc-fuzz/evidence
```

For example, the core of this target generates `U64` values and checks that JSON
encoding and decoding always returns the original value; the
[first-target tutorial](docs/getting-started.adoc) includes a complete app
header and runnable files:

```roc
import fuzz.Fuzz

test : U64 -> Fuzz.Outcome
test = |value| {
	encoded = Json.to_str(value)
	decoded : Try(U64, _)
	decoded = Json.parse(encoded)

	match decoded {
		Ok(round_tripped) if round_tripped == value => Fuzz.keep
		Ok(_) => crash "JSON round trip changed the value"
		Err(_) => crash "JSON output could not be parsed"
	}
}

target = Fuzz.target_with({
	examples: [Fuzz.example({ name: "zero", revision: "1", make: || 0 })],
	name: "json-u64-round-trip",
	generator: Fuzz.u64,
	test,
	show: |value| Str.inspect(value),
})
```

The [roc-fuzz manual](https://lukewilliamboswell.github.io/roc-fuzz/) starts by
[choosing a technique](docs/overview.adoc) and covers target design, models,
proofs, campaigns, CI evidence, release verification, and platform development.
The site also provides the
[generated API reference](https://lukewilliamboswell.github.io/roc-fuzz/api/)
and a downloadable PDF manual.

Examples under [`examples/`](examples/) demonstrate round trips, parser
robustness, collection invariants, structured inputs, multi-target and
multi-file applications, state-machine models and proofs. Repository examples
use relative paths to the local platform; for a published platform, download
the examples archive attached to that release, whose applications name that
release's platform URL. The focused compiler and builtin regression targets are
tests, not examples, and live under [`tests/targets/`](tests/targets/). The
[trophy case](trophy-case/README.md) records bugs found through fuzzing.

Repository development begins in [the contributor guide](CONTRIBUTING.md).
Security reports follow [the private reporting policy](SECURITY.md).
