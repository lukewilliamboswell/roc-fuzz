# roc-fuzz

`roc-fuzz` is a typed, coverage-guided software-quality platform for Roc.
It supports Linux x86-64 with musl and Apple Silicon macOS (macOS 11 or newer).

A target builds directly into a self-contained executable:

```sh
roc build --fuzz my_target_app.roc
./my_target_app --help
./my_target_app run
```

The executable contains the Roc target, the upstream libFuzzer engine, and the
small Roc ABI/command adapter. A normal run needs no Cargo project, external
harness, or second linking step. It is bounded to 60 seconds by default and
keeps its corpus under `.roc-fuzz/`.

This platform requires the compiler coverage implementation from
[roc-lang/roc#10657](https://github.com/roc-lang/roc/pull/10657).

## Origins and acknowledgments

The foundational and exploratory work for roc-fuzz was created by [Brendan
Hansknecht](https://github.com/bhansconnect). Brendan established the original Roc fuzzing
integration, arbitrary input machinery, quality-target suite, and the early
[trophy case](trophy-case/README.md) demonstrating the bugs this approach could
find.

The platform in this repository extends Brendan's experiment into a more
idiomatic modern Roc workflow: typed generators, statically dispatched
`generator_for` methods, record builders, and a self-contained executable
built directly with `roc build --fuzz`. This work would not exist without the
foundation he developed.

## Define a typed target

The application exposes `target : Target`. Its input type can provide a
statically dispatched `generator_for` method:

```roc
app [target] { fuzz: platform "path/to/roc-fuzz/platform/main.roc" }

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

The `.Fuzz` record builder combines any number of field generators through
`Fuzz.map2`. `Fuzz.target` resolves `Input.generator_for` at compile time,
following the same static-dispatch pattern as `Json.parser_for`. For local
structural inputs, `Fuzz.target_with` accepts an explicit generator.

Existing byte-oriented quality targets can migrate with `Fuzz.from_bytes`
without changing their property immediately. New targets should prefer typed
generators because they make the tested input domain visible in the API.

## Examples

The end-user gallery demonstrates several common target shapes:

- [`stringSplitRoundTrip.roc`](examples/stringSplitRoundTrip.roc) uses static
  generator dispatch and a record builder for a round-trip property.
- [`jsonRoundTrip.roc`](examples/jsonRoundTrip.roc) uses an explicit generator
  for a single value.
- [`parserRobustness.roc`](examples/parserRobustness.roc) treats both successful
  and failed parses as ordinary outcomes while looking for crashes and hangs.
- [`listConcatLength.roc`](examples/listConcatLength.roc) checks an invariant on
  generated collections.
- [`stack/main.roc`](examples/stack/main.roc) targets code in a separate Roc
  module and shows the required `main.roc` layout for a multi-file example.

The focused builtin regression targets are retained under
[`examples/builtins/`](examples/builtins/). They intentionally use the lower-level
`Arbitrary` API and are useful for compiler and builtin validation, but are not
the recommended starting point for application authors.

## Runner commands

```text
TARGET run [CORPUS] [OPTION...]
TARGET show INPUT
TARGET replay INPUT
TARGET minimize INPUT OUTPUT
TARGET reduce-corpus INPUT OUTPUT
TARGET raw [LIBFUZZER_ARG...]
```

Friendly run options include `--time`, `--runs`, `--max-input-size`,
`--memory-limit`, `--timeout`, `--dictionary`, and `--seed`.
Use `--time=0` for an intentionally unbounded campaign. Low-level libFuzzer
flags remain available through `raw`.

When an explicit Roc failure is saved, the runner prints ready-to-run `show`,
`replay`, and `minimize` commands.

Rejection-rate reporting remains a follow-up. `Fuzz.reject` already records the
distinction in the typed target boundary so the runner can expose that metric.

## Develop and package

Prebuilt target inputs are versioned under `platform/targets/x64musl` and
`platform/targets/arm64mac`. Users and release jobs consume them directly, so
building a fuzz target does not require Zig, a C++ toolchain, musl, or a local
libFuzzer installation. Apple Silicon outputs use the system `libSystem` and
otherwise carry their native runtime dependencies in the platform.

Maintainers regenerate those inputs only when updating the host or toolchain:

```sh
python3 scripts/build_platform.py
```

The regeneration script verifies the checksum-pinned libFuzzer source, builds
the Zig host adapter, copies the required Zig C++ and compiler runtimes, and
refreshes both `SHA256SUMS` manifests. Commit the regenerated archives and
manifests together. Release bundles verify and include those versioned inputs
without rebuilding them.

Run the repository validation matrix with:

```sh
python3 scripts/test.py --operation validate
python3 scripts/test.py --operation build
python3 scripts/test.py --operation fuzz --max-total-time 2
```

Start with the [beginner guide](GUIDE.md) for target design and the normal
workflow. [Advanced fuzzing](ADVANCED.md) covers campaign tuning, corpora, and
runtime details. The [generated API reference](https://lukewilliamboswell.github.io/roc-fuzz/)
documents every public module and keeps advanced interfaces clearly labeled.
Repository bootstrap and release work are in [CONTRIBUTING.md](CONTRIBUTING.md).
