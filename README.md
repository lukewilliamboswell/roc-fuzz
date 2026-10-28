# roc-fuzz

[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/lukewilliamboswell/roc-fuzz/badge)](https://scorecard.dev/viewer/?uri=github.com/lukewilliamboswell/roc-fuzz)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/14753/badge)](https://www.bestpractices.dev/projects/14753)

`roc-fuzz` checks pure Roc code through one self-contained executable. Declare
known examples, assert on results and allocation costs, validate logical traces,
and explore nearby inputs with coverage feedback. Saved failures can be rendered,
replayed, retained as source regressions, and minimized.

Each declared example runs once in a fresh process. Exact allocation baselines
require explicit acceptance; ordinary checks never update them.

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

The default baseline is `<declared-target-name>_baseline.json` in the working
directory. Use `--baseline=PATH` and `--profile=NAME` when needed. Default runs
check examples and the baseline, then explore for 60 seconds with a 10-second
invocation deadline and leak checks. See the provider-free
[consumer template](templates/quality/README.adoc) for Blueprint tasks and CI.

The [roc-fuzz manual](https://lukewilliamboswell.github.io/roc-fuzz/) covers
target design, failure investigation, campaign tuning, corpora, CI evidence,
release verification, and platform development. The site also provides the
[generated API reference](https://lukewilliamboswell.github.io/roc-fuzz/api/)
and a downloadable PDF manual.

Repository examples use relative paths to the local platform. For applications
using a published platform, download the examples archive attached to that
release. Each released application names that release's platform URL. Neither
the platform nor its examples pin a compiler.

Examples under [`examples/`](examples/) demonstrate round trips, parser
robustness, collection invariants, structured inputs, and multi-file targets.
The focused compiler and builtin regression targets are tests, not examples,
and live under [`tests/targets/`](tests/targets/). The
[trophy case](trophy-case/README.md) records bugs found through fuzzing.

Content-addressed linker inputs, `libhost.a`, and platform bundles have distinct
invalidation boundaries. Linker-input releases are admitted from exact PR
producer commits with hashes and attestations, while routine builds reuse their
verified caches instead of rebuilding or repeatedly downloading them. See the
[releases](https://github.com/lukewilliamboswell/roc-fuzz/releases) for immutable
bundles and versioned PDF/HTML documentation archives.

Repository development begins in [the contributor guide](CONTRIBUTING.md).
Security reports follow [the private reporting policy](SECURITY.md).
