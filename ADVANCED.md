# Advanced fuzzing

This guide explains the libFuzzer details behind roc-fuzz and how to tune and
maintain targets after the basic workflow is familiar. Start with
[Fuzzing your first Roc target](GUIDE.md) if you have not yet built, run,
shown, replayed, and minimized an input.

## Understand the in-process model

The embedded libFuzzer calls a target thousands of times in the same process.
It does not start a clean executable for every generated input. This is what
makes it fast. Ordinary Roc code already provides purity and determinism, so
most Roc targets naturally satisfy the hardest in-process requirements.

A reliable target still needs all of the following properties:

- The code under test can be called directly with an in-memory Roc value.
- Invalid or unusual inputs return ordinary values such as `Err`, rather than
  triggering an intentional assertion or process exit.
- One input normally finishes in less than 10 milliseconds.
- Running the same input with the same build and CPU architecture has the same
  result.
- Any native or platform state reached by the target is reset before the target
  returns.
- Native work started by one input, including threads, does not outlive the
  input.
- Inputs and allocations have sensible upper bounds.

Use a process-based integration test or another fuzzing setup when the code
requires a file path, subprocess, live network service, persistent thread, or
large amount of global state. The same applies when one test takes a
significant fraction of a second or when invalid input is *expected* to
terminate the process. If termination would be a bug, it remains a useful
fuzzing failure.

Purity prevents a normal Roc target from reading clocks, external randomness,
network responses, or mutable global state. These concerns return only at a
native or platform boundary. Floating-point results can also differ across CPU
architectures, so reproduce a floating-point failure with the same build and
architecture before comparing it elsewhere. Avoid logging from any native hot
path because it can reduce executions per second dramatically.

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
| `--seed=N` | Select libFuzzer's random seed. | Pair with a bounded run when reproducing campaign behavior. |
| `--print-final-stats` | Print final execution and resource counters. | Useful in CI and smoke tests. |

`--max-input-size` limits the generator's raw input, not necessarily every
typed list or string it produces. Put bounds in the generator as well when a
typed value could become expensive.

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

- a generator change that altered the typed value;
- a different executable or CPU architecture, especially for floating-point
  behavior;
- state left by native or platform code;
- a native thread that outlived its input; or
- latent native memory corruption caused by an earlier input.

Treat the failure as actionable once its conditions are understood and,
ideally, it reproduces from a clean process.

## Know what the failure detector can see

SanitizerCoverage, despite its name, supplies the coverage feedback that guides
libFuzzer. It is not AddressSanitizer, UndefinedBehaviorSanitizer, or
MemorySanitizer and does not by itself diagnose memory corruption.

The current `roc build --fuzz` spike detects explicit Roc `crash` and failed
`expect` calls, fatal process signals observed by libFuzzer, per-input
timeouts, and process memory-limit failures. It does not automatically add the
native memory-safety sanitizers recommended for conventional C and C++
libFuzzer targets. If a target reaches native or FFI code, separately test a
sanitizer-enabled build of that code where the toolchain supports it. An
undetected native memory error can corrupt the long-lived fuzzer process and
only crash on a later input.

The fully static musl executable omits libFuzzer's
`FuzzerInterceptors.cpp`, whose dynamic-loader-based libc wrappers are not
compatible with a statically linked process. The standard scheduler, mutators,
corpus management, crash handling, minimizer, and merge engine remain intact.
Roc's compare and switch instrumentation still supplies value feedback, but
libc calls such as `memcmp` do not receive the additional feedback those
interceptors normally provide. This affects search efficiency for some native
code; it does not change the typed target API.

The runner executes the target in-process, with the same environment as the
executable. Use ordinary development or CI isolation when a target reads files,
environment variables, or external services.

## Prepare a long campaign

Before committing substantial CPU time, check that:

- the target tests one named behavior with a meaningful property;
- invalid input returns normally unless invalid input crashing is the bug;
- the generator creates useful values without excessive rejection;
- input sizes and allocations are bounded;
- any native or platform code is deterministic and independent between calls;
- no native thread or other work survives the call;
- a one-minute run gains coverage without immediate hangs or memory growth;
- a deliberate temporary `crash` is saved, shown, replayed, and minimized as
  expected; and
- the corpus and fixed failures have a clear place in the repository and CI.

## Use the native interface

`TARGET raw [LIBFUZZER_ARG...]` passes arguments directly to the embedded
libFuzzer CLI. Run this for its complete option list:

```sh
TARGET raw -help=1
```

Prefer `run`, `show`, `replay`, `minimize`, and `reduce-corpus` for the normal
workflow. Native flags such as `-max_total_time` and `-max_len` belong behind
`raw`; `run` accepts the stable friendly options listed above. `raw` is an
escape hatch for libFuzzer features the friendly command layer does not yet
expose directly.

## Further reading

- [Roc's static-dispatch language reference](https://github.com/roc-lang/roc/blob/main/docs/langref/static-dispatch.md)
  explains associated methods, compile-time resolution, and package-defined
  method requirements.
- [Roc's `Json.parse` implementation](https://github.com/roc-lang/roc/blob/main/src/build/roc/Builtin.roc)
  shows the `parser_for` constraint and compile-time method selection that
  inspired `generator_for`.
- [roc-random's record-builder example](https://github.com/kili-ilo/roc-random/blob/main/examples/record-builder.roc)
  shows the same `map2`-based syntax used to assemble generated records.
- [LLVM libFuzzer documentation](https://llvm.org/docs/LibFuzzer.html) covers
  the in-process execution model, options, corpus behavior, output, and FAQ.
- [Google's introduction to fuzzing](https://github.com/google/fuzzing/blob/master/docs/intro-to-fuzzing.md)
  explains target selection and sanitizer-based failure detection.
- [OSS-Fuzz ideal integration](https://google.github.io/oss-fuzz/advanced-topics/ideal-integration/)
  gives maintenance guidance for targets, corpora, dictionaries, regression
  testing, coverage, and performance.
