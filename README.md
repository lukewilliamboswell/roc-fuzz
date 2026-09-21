# roc-fuzz

[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/lukewilliamboswell/roc-fuzz/badge)](https://scorecard.dev/viewer/?uri=github.com/lukewilliamboswell/roc-fuzz)

`roc-fuzz` helps Roc application authors find inputs they did not think to test.
You write a small fuzz target that generates ordinary Roc values, calls one
part of your application, and checks a rule that must always hold. roc-fuzz
then explores variations, saves any failure, and lets you inspect, reproduce,
and minimize it.

Unit tests remain the right tool for named examples and known regressions.
Fuzzing complements them when the input space is too large to enumerate: it
uses feedback from the compiled program to retain inputs that reach new behavior
and explore nearby cases. This is especially useful for parsers, codecs,
normalizers, collections, state transitions, and other fast in-memory code with
a clear property.

The platform supports Linux x86-64 with musl and Apple Silicon macOS 11 or newer.

A target builds directly into a self-contained executable:

```sh
roc build --fuzz my_target_app.roc
./my_target_app run
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
	name: "json-u64-round-trip",
	generator: Fuzz.u64,
	test,
	show: |value| Str.inspect(value),
})
```

The [roc-fuzz manual](https://lukewilliamboswell.github.io/roc-fuzz/) covers
target design, failure investigation, campaign tuning, corpora, CI evidence,
release verification, and platform development. The site also provides the
[generated API reference](https://lukewilliamboswell.github.io/roc-fuzz/api/)
and a downloadable PDF manual.

Examples under [`examples/`](examples/) demonstrate round trips, parser
robustness, collection invariants, structured inputs, and multi-file targets.
The focused compiler and builtin regressions remain under
[`examples/builtins/`](examples/builtins/), and the
[trophy case](trophy-case/README.md) records bugs found through fuzzing.

Native libraries and platform bundles are published independently with
checksums, provenance, and SPDX SBOMs. See the
[releases](https://github.com/lukewilliamboswell/roc-fuzz/releases) for immutable
bundles and versioned PDF/HTML documentation archives.

Repository development begins in [the contributor guide](CONTRIBUTING.md).
Security reports follow [the private reporting policy](SECURITY.md).
