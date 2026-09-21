# roc-fuzz

[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/lukewilliamboswell/roc-fuzz/badge)](https://scorecard.dev/viewer/?uri=github.com/lukewilliamboswell/roc-fuzz)

`roc-fuzz` is a typed, coverage-guided software-quality platform for Roc. It
supports Linux x86-64 with musl and Apple Silicon macOS 11 or newer.

A target builds directly into a self-contained executable containing the Roc
application, libFuzzer, and the command adapter:

```sh
roc build --fuzz my_target_app.roc
./my_target_app run
```

Targets describe typed input generation and the property that every generated
value must satisfy:

```roc
import fuzz.Fuzz

Input := { bytes : List(U8), radix : U8 }.{
	generator_for : Fuzz.FuzzEncoding -> Fuzz.Generator(Input)
	generator_for = |_| {
		{
			bytes: Fuzz.bytes,
			radix: Fuzz.u8_in(2, 36),
		}.Fuzz
	}
}

test : Input -> Fuzz.Outcome
test = |input| {
	if List.is_empty(input.bytes) Fuzz.reject else Fuzz.keep
}

target = Fuzz.target({
	name: "typed-target",
	test,
	show: |input| Str.inspect(input),
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
