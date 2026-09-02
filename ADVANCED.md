# Advanced fuzzing

This guide explains the libFuzzer details behind roc-fuzz and how to tune and
maintain targets after the basic workflow is familiar. Start with
[Fuzzing your first Roc target](GUIDE.md) if you have not yet built, run,
shown, replayed, and minimized an input.

## Understand the in-process model

The embedded libFuzzer calls a target thousands of times in the same process.
It does not start a clean executable for every generated input. This is what
makes it fast. Roc's purity means target calls cannot leak application state or
background work into later calls, and determinism makes saved inputs reliable
with the same target and generator.

A reliable target still needs all of the following properties:

- Invalid or unusual inputs return ordinary values such as `Err`, rather than
  triggering an intentional assertion or process exit.
- One input normally finishes in less than 10 milliseconds.
- Inputs and allocations have sensible upper bounds.
- Every input terminates.

The runner is a poor fit when one test takes a significant fraction of a
second, can grow without a practical memory bound, or is expected to terminate
the process for invalid input. If a crash, timeout, or memory blow-up would be
a bug, it remains a useful fuzzing failure.

A saved raw input produces the same typed value and result when the target and
generator are unchanged. Keep the executable alongside important failure
artifacts when exact historical reproduction matters.

## Understand generator dispatch

`generator_for` uses Roc's ordinary static dispatch. It is a method associated
with the target's input type, not a runtime interface, registry, or callback
table. Package APIs can require their own methods with `where` clauses, so the
method does not need to be a compiler-defined name.

The pattern deliberately mirrors `Json.parser_for`:

- `Json.parse` requires its result type to have a compatible `parser_for`
  method and asks that type for a JSON parser.
- `Fuzz.target` requires its input type to have a compatible `generator_for`
  method and asks that type for a fuzz generator.
- The checker resolves both to a specific method implementation at compile
  time. The compiled call has no dynamic-dispatch overhead.

Conceptually, `Fuzz.target` has this requirement:

```roc
target : { name : Str, test : a -> Outcome, show : a -> Str } -> Target
	where [a.generator_for : FuzzEncoding -> Generator(a)]
```

`FuzzEncoding` currently contains the `Default` policy. Passing a policy value
follows the same shape as `JsonEncoding` and leaves room for additional
generation policies without changing the method pattern.

Use `Fuzz.target` when generation is part of a reusable named input type. Use
`Fuzz.target_with` with an explicit `Generator(a)` for a local structural input
or when choosing between generators for the same type in different targets.

## Assert on allocations

A property can check what a builtin computes but not what it costs. A builtin
that stops mutating a uniquely owned value in place and starts copying it
still produces correct answers, so no content-based property will notice the
regression. `Fuzz` exposes the platform's allocation counters so a target can
assert on cost as well as correctness:

```roc
Fuzz.alloc_count! : () => U64          # cumulative allocations served this process
Fuzz.live_alloc_count! : () => U64     # allocations not yet freed
Fuzz.measure_allocs! : ({} => a) => { value : a, allocations : U64 }
Fuzz.expect_allocs_at_most! : U64, ({} => a) => a
Fuzz.expect_allocs_at_least! : U64, ({} => a) => a
Fuzz.expect_no_leaks! : ({} => a) => {}
```

`alloc_count!` and `live_alloc_count!` are process-wide and monotonic, and
libFuzzer reuses one process across millions of inputs, so never assert on a
raw value. Always read the counter before and after the region you care
about and assert on the difference; `measure_allocs!` and
`expect_allocs_at_most!` and `expect_allocs_at_least!` do this for you.

Only assert zero allocations for a value that is genuinely uniquely owned and
pre-sized. If the value is aliased anywhere, copy-on-write allocation is
correct behavior, not a regression. Measure only the region you mean to
check: a constructor call such as `Dict.with_capacity` allocates the entries
and bucket lists, so keep it outside the measured window.

```roc
# Build the dict OUTSIDE the measured region: Dict.with_capacity itself
# allocates the entries and bucket lists.
d = Dict.with_capacity(n)

filled = Fuzz.expect_allocs_at_most!(
	0,
	|{}| {
		var $result = d
		var $i = 0
		while $i < n {
			$result = Dict.insert($result, $i, $i * 2)
			$i = $i + 1
		}
		$result
	},
)
```

Allocation assertions need an effectful test, so build the target with
`Fuzz.target_with!` or `Fuzz.from_bytes!` instead of their pure counterparts.
`target_with!` takes `test! : a => Outcome`; `from_bytes!` takes
`test! : List(U8) => U8`.

These constructors exist because the runner calls a target through the
widened `run! : List(U8) => U8`, not the older pure `run : List(U8) -> U8`.
This is a backward-compatible change: a pure function body already satisfies
an effectful signature, so every existing target keeps compiling and running
unchanged. Keep targets pure unless the property itself needs one of the
allocation combinators above -- a pure target is deterministic, and
libFuzzer's crash replay and minimization rely on that determinism to
reproduce and shrink a saved failure.

## Tune a run

Give every new target a short, bounded smoke run before a long campaign:

```sh
TARGET run \
  --time=60 \
  --max-input-size=4096 \
  --timeout=5 \
  --memory-limit=2048 \
  --print-final-stats
```

The most useful limits are:

| Option | Meaning | Starting point |
| --- | --- | --- |
| `--time=N` | Stop after `N` seconds; `0` is unbounded. | Defaults to `60`. |
| `--runs=N` | Stop after `N` generated inputs. | Useful for repeatable CI checks. |
| `--max-input-size=N` | Limit raw entropy bytes supplied to the generator. | Start small and raise only when needed. |
| `--timeout=N` | Treat one input taking longer than `N` seconds as a failure. | A few seconds for a normally fast target. |
| `--memory-limit=N` | Stop when the process exceeds this many MB. | Set from the expected working set. |
| `--dictionary=FILE` | Add important byte tokens to mutations. | Useful for text or binary formats. |
| `--seed=N` | Select libFuzzer's random seed. | Useful for repeating a campaign with the same runner build and configuration. |
| `--print-final-stats` | Print final execution and resource counters. | Useful in CI and smoke tests. |

`--max-input-size` limits the generator's raw input, not necessarily every
typed list or string it produces. Put bounds in the generator as well when a
typed value could become expensive.

Do not confuse the campaign seed with a saved input. Different libFuzzer builds,
coverage layouts, or configurations may generate different mutation sequences
from `--seed`. Reproduce a failure with its saved artifact and `replay`, not
with the campaign seed alone.

libFuzzer reports compact status fields:

- `NEW`: an input reached behavior not represented by the corpus and was
  saved.
- `REDUCE`: a smaller input preserved previously found behavior.
- `cov`: covered edges or blocks.
- `corp`: number and total byte size of in-memory corpus entries.
- `exec/s`: target executions per second.
- `rss`: current process memory use.
- `DONE`: the run reached its time or iteration limit.

Coverage growth shows that the fuzzer is exploring. A plateau is a reason to
inspect the target, generator, seeds, and dictionary, not proof that the code
has no bugs. Very low `exec/s`, steadily growing `rss`, or repeated timeouts
usually calls for a narrower target or tighter bounds.

## Maintain a corpus

A corpus is a collection of small raw inputs that collectively reach useful
code. It is not a directory of every attempted input. Use a stable corpus
directory across campaigns:

```sh
TARGET run quality/corpus/my-target --time=3600 --max-input-size=4096
```

Seed a target with a few small examples that reach meaningfully different
behavior, then let the fuzzer extend them. Because roc-fuzz decodes raw entropy
into typed values, a seed file's bytes may not resemble the value printed by
`show`. Check manually created seeds with the target executable.

Reduce a large corpus into a new, initially empty directory while preserving
coverage:

```sh
TARGET reduce-corpus quality/corpus/my-target quality/corpus/my-target-small
```

Keep valuable seeds and fixed crash inputs with the target in version control.
Run them after code changes so the target does not silently stop compiling or
exercising the intended behavior.

Dictionaries are most effective when recognizable bytes flow fairly directly
into a parser. They may help less when a structural generator heavily
transforms the raw input.

Changing a generator can make old corpus and crash files decode to different
typed values. The generator is part of the target's input format. Keep it
stable when practical and use `show` to check saved inputs after a change.

## Diagnose an unstable failure

Always replay a saved failure in a fresh process. If it does not reproduce,
investigate:

- a generator or target change that altered the typed value or property;
- a different or truncated raw input file;
- an executable built from different target code; or
- a compiler or runtime defect.

Treat the failure as actionable once its conditions are understood and,
ideally, it reproduces from a clean process.

## Know what counts as a failure

Coverage feedback tells libFuzzer which inputs explore new behavior; it does
not tell the runner whether a result is correct. The property in the target is
the correctness oracle.

roc-fuzz saves explicit Roc `crash` and failed `expect` calls, per-input
timeouts, and process memory-limit failures. A wrong answer that does not break
the target's property is invisible to the fuzzer, which is why choosing a
strong property matters more than simply calling the function under test.

## Prepare a long campaign

Before committing substantial CPU time, check that:

- the target tests one named behavior with a meaningful property;
- invalid input returns normally unless invalid input crashing is the bug;
- the generator creates useful values without excessive rejection;
- input sizes and allocations are bounded;
- every generated input terminates or is caught by the timeout;
- a one-minute run gains coverage without immediate hangs or memory growth;
- a deliberate temporary `crash` is saved, shown, replayed, and minimized as
  expected; and
- the corpus and fixed failures have a clear place in the repository and CI.

## Use the libFuzzer interface

`TARGET raw [LIBFUZZER_ARG...]` passes arguments directly to the embedded
libFuzzer CLI. Run this for its complete option list:

```sh
TARGET raw -help=1
```

Prefer `run`, `show`, `replay`, `minimize`, and `reduce-corpus` for the normal
workflow. Low-level flags such as `-max_total_time` and `-max_len` belong behind
`raw`; `run` accepts the stable friendly options listed above. `raw` is an
escape hatch for libFuzzer features the friendly command layer does not yet
expose directly.

## Further reading

- [LLVM libFuzzer documentation](https://llvm.org/docs/LibFuzzer.html) covers
  the in-process execution model, options, corpus behavior, output, and FAQ.
