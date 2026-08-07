# Fuzzing your first Roc target

Fuzzing runs one small test many times with automatically varied inputs. Unlike
a unit test, you do not choose every example. You describe the values to try
and the rule that must always hold; roc-fuzz searches for a value that breaks
that rule.

`roc build --fuzz` packages the target and fuzzing engine into one executable.
You use that executable to run the search and inspect any failures it finds.

This page covers the normal workflow. See [Advanced fuzzing](ADVANCED.md) when
you need to tune libFuzzer, manage a long-lived corpus, fuzz native code, or
understand the in-process execution model.

## The target API

A fuzz target has four parts:

| Part | Purpose |
| --- | --- |
| `Input.generator_for` | Tells roc-fuzz how to generate the target's typed input. |
| `test` | Calls the code under test and checks a property. |
| `show` | Renders a saved typed input for a person to read. |
| `name` | Identifies the target in command output. |

This follows the same pattern as `Json.parser_for`. `Json.parse` asks its result
type for the parser that understands that type; `Fuzz.target` asks its input
type for the generator that creates that type. Roc chooses the specific method
at compile time.

The test returns one of these outcomes:

- `Fuzz.keep` means the input was useful and completed normally.
- `Fuzz.reject` means the input was outside the useful domain of this target.
- `crash` or a failed `expect` means the fuzzer found a failure.

roc-fuzz is best suited to small, fast library operations that accept in-memory
values: parsers, encoders and decoders, string and collection operations,
compression, and pure protocol transformations are good examples. A
target that needs a file, subprocess, live service, or long-running task
usually needs a different testing setup. The [advanced fit guide](ADVANCED.md#understand-the-in-process-model)
explains why.

Ordinary Roc code is pure and deterministic, so the same generated value has
the same result within a build. That makes Roc functions especially natural
fuzz targets. Native code and replay across CPU architectures need a little
more care, as explained in the advanced guide.

## Write a small target

Start with one operation and one clear property. This target checks that
splitting and rejoining a string does not change it:

```roc
app [target] { fuzz: platform "path/to/roc-fuzz/platform/main.roc" }

import fuzz.Fuzz

Input := { delimiter : Str, value : Str }.{
	generator_for : Fuzz.FuzzEncoding -> Fuzz.Generator(Input)
	generator_for = |_| {
		{
			value: Fuzz.str,
			delimiter: Fuzz.str,
		}.Fuzz
	}
}

test : Input -> Fuzz.Outcome
test = |input| {
	parts = input.value.split_on(input.delimiter)
	rejoined = Str.join_with(parts, input.delimiter)

	if rejoined == input.value {
		Fuzz.keep
	} else {
		crash "split parts did not rejoin to the original string"
	}
}

target = Fuzz.target({
	name: "split-round-trip",
	test,
	show: |input| Str.inspect(input),
})
```

`generator_for` is an ordinary method associated with `Input`. This lets the
input type keep its generation rules alongside its definition and makes them
reusable across targets. There is no dynamic lookup at runtime.

For a one-off structural input that should not define a named type,
`Fuzz.target_with` accepts an explicit generator. The [advanced dispatch
guide](ADVANCED.md#understand-generator-dispatch) explains both forms.

### Build record generators

Roc's record-builder syntax makes generators for records read like the records
they produce:

```roc
{
	value: Fuzz.str,
	delimiter: Fuzz.str,
	max_parts: Fuzz.u8_in(1, 20),
}.Fuzz
```

Each field contains a generator rather than a finished value. The `.Fuzz`
suffix combines them using `Fuzz.map2` and returns one generator for the whole
record. With two fields, the first example is equivalent to:

```roc
Fuzz.map2(
	Fuzz.str,
	Fuzz.str,
	|value, delimiter| { value, delimiter },
)
```

For larger records, the builder chains `map2` automatically. Record builders
are ordinary Roc syntax, not a fuzzing special case; any nominal type with a
compatible `map2` method can use the same pattern.

### Choose a useful property

The fuzzer can find only failures your test knows how to recognize. Strong
properties include:

- **Round trip:** decoding an encoded value returns the original value.
- **Inverse:** an operation followed by its inverse returns the starting value.
- **Idempotence:** normalizing twice gives the same result as normalizing once.
- **Invariant:** an operation preserves ordering, length, membership, or
  another rule of the data structure.
- **Differential:** two independent implementations produce the same result.
- **Robustness:** arbitrary input may return success or an ordinary error, but
  must not crash or hang.

Keep unrelated properties or formats in separate targets. A narrow target is
usually faster and its failures are easier to understand.

### Handle invalid input deliberately

Malformed input is not automatically a bug. For a parser robustness target,
both `Ok` and `Err` may be normal and should usually return `Fuzz.keep`; a crash
or hang is the failure.

Use `Fuzz.reject` only when a value is outside the property you are testing.
Do not use `crash` or `expect` to validate generated input because the runner
correctly treats them as failures.

Prefer generating useful values directly instead of rejecting most inputs.
Range generators such as `Fuzz.u8_in`, bounded lists, and generators composed
with `Fuzz.map`, `Fuzz.map2`, or a record builder keep the search focused.

## Build and run

Build the target as a self-contained executable:

```sh
roc build --fuzz split_round_trip.roc
```

The first run needs no tuning:

```sh
./split_round_trip run
```

`run` uses `.roc-fuzz/corpus` by default and saves failures under
`.roc-fuzz/`. It stops after 60 seconds by default, so a first invocation does
not unexpectedly run forever. Use `--runs=10000` for an iteration bound,
`--time=300` for a longer campaign, or `--time=0` for an intentionally
unbounded run. Discoveries already written to the corpus remain available for
the next run.

While it runs, `NEW` means the fuzzer found an input that explores new
behavior. `cov` reports coverage growth and `exec/s` reports how many inputs
run each second. See [Tuning a run](ADVANCED.md#tune-a-run) for limits and a
complete explanation of the status fields.

## Investigate a failure

A failure normally leaves a raw input such as `.roc-fuzz/crash-<hash>`,
`.roc-fuzz/timeout-<hash>`, or `.roc-fuzz/oom-<hash>`.

For a Roc `crash` or failed `expect`, the runner prints the exact `show`,
`replay`, and `minimize` commands immediately after saving the artifact.

Render its typed value:

```sh
./split_round_trip show .roc-fuzz/crash-<hash>
```

Reproduce it in a fresh process:

```sh
./split_round_trip replay .roc-fuzz/crash-<hash>
```

Then minimize it and inspect the smaller result:

```sh
./split_round_trip minimize \
  .roc-fuzz/crash-<hash> .roc-fuzz/minimized-crash
./split_round_trip replay .roc-fuzz/minimized-crash
./split_round_trip show .roc-fuzz/minimized-crash
```

Keep the raw minimized file as a regression case after fixing the bug.
`replay` and `show` consume the raw fuzzer file, not the text printed by
`show`.

If a failure does not reproduce, continue with [Diagnosing an unstable
failure](ADVANCED.md#diagnose-an-unstable-failure).

## Everyday command reference

Run `TARGET --help` to see the commands for a built target.

| Command | Use it to |
| --- | --- |
| `TARGET run [CORPUS] [OPTION...]` | Search for failures, optionally using a specific corpus. |
| `TARGET show INPUT` | Render the typed value represented by a raw input file. |
| `TARGET replay INPUT` | Run one saved input in a fresh process. |
| `TARGET minimize INPUT OUTPUT` | Make a reproducing failure smaller. |
| `TARGET reduce-corpus INPUT OUTPUT` | Copy a coverage-preserving subset into a new corpus. |

The [`raw` command and native libFuzzer options](ADVANCED.md#use-the-native-interface)
are intended for advanced use.
