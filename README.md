# roc-fuzz

[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/lukewilliamboswell/roc-fuzz/badge)](https://scorecard.dev/viewer/?uri=github.com/lukewilliamboswell/roc-fuzz)

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
app [target] { roc: "nightly-2026-09-05-b195f5b", fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst" }

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

A target can also assert on allocation counts rather than only on returned
values, which catches regressions such as a builtin that starts copying a
uniquely owned value instead of mutating it in place. This needs an
effectful test (`Fuzz.target_with!` or `Fuzz.from_bytes!`); existing pure
targets are unaffected. See [Assert on
allocations](ADVANCED.md#assert-on-allocations) for the API and a worked
example.

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

The [`setOps`](examples/builtins/setOps/main.roc) and
[`setCollisions`](examples/builtins/setCollisions/main.roc) targets use typed
operation sequences and a [shared list model](tests/set-model/README.md) to
check Set storage, iteration, folds, algebra, collisions, and shared heap values.

The builtin collection also holds a dedicated suite for the `List` sorting
builtins. Sorting is worth focused coverage because a sort has properties an
invariant check alone will not reach: it has to be stable, it has to return a
permutation of its input, and it changes algorithm with the length of the list
and the width of the element. The targets check each sorting API against an
independent stable insertion sort, cover refcounted and oversized elements,
aliased and sliced lists, structured input shapes such as sawtooths and pipe
organs, and comparisons that contradict themselves.

## Runner commands

```text
TARGET run [CORPUS] [OPTION...]
TARGET ci REPORT_DIR [CORPUS] [OPTION...]
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

`ci` supervises the run in a child process and writes a versioned JSON report,
Markdown summary, combined log, hashes, and failure artifacts. See
[Fuzzing evidence for downstream projects](QUALITY.md) for the report contract,
OpenSSF guidance, and a complete pull-request/daily workflow.

Rejection-rate reporting remains a follow-up. `Fuzz.reject` already records the
distinction in the typed target boundary so the runner can expose that metric.

## Develop and package

Native libraries are published independently with checksums, provenance and an
SPDX SBOM. Platform builds restore pinned libraries and build the current
`libhost.a`, then test and attest the complete platform bundle. Bundle users do
not need Zig, a C++ toolchain, musl, or a local libFuzzer installation.

A source checkout generates only its current host inputs:

```sh
python3 scripts/build_platform.py
```

The script verifies the pinned library archive and workflow attestation, builds
the Zig host adapter, and writes a local `SHA256SUMS` manifest. During initial
bootstrap, add `--libraries source` to this command and the local test commands
below until the first native-library release is adopted. See the
[native-library setup](CONTRIBUTING.md#generate-platform-inputs). Generated files are ignored by Git. See
[`SLSA_PROVENANCE.md`](SLSA_PROVENANCE.md) for release verification.

Build and serve the working-tree platform package, rewrite temporary copies of
the examples to its localhost URL, and run the repository validation matrix with:

```sh
python3 scripts/test_local.py --operation validate
python3 scripts/test_local.py --operation build
python3 scripts/test_local.py --operation fuzz --max-total-time 2
```

Start with the [beginner guide](GUIDE.md) for target design and the normal
workflow. [Advanced fuzzing](ADVANCED.md) covers campaign tuning, corpora, and
runtime details. The [generated API reference](https://lukewilliamboswell.github.io/roc-fuzz/)
documents every public module and keeps advanced interfaces clearly labeled.
Repository bootstrap and release work are in [CONTRIBUTING.md](CONTRIBUTING.md).
