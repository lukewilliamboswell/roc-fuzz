# roc-fuzz

This branch contains a spike for a self-contained, typed Roc fuzzing workflow:

If this is your first time using a fuzzer, start with the
[beginner guide](GUIDE.md). It explains which code is a good fit, how to write
a useful property, what the progress output means, and how to investigate a
saved failure.

```sh
roc build --fuzz my_target_app.roc
./my_target_app --help
./my_target_app run
./my_target_app show .roc-fuzz/corpus/<saved-input>
./my_target_app replay .roc-fuzz/crash-<hash>
./my_target_app minimize crash.input minimized.input
```

The platform supports only Linux x86-64 with musl. The resulting executable is
statically linked and contains the typed target, the upstream libFuzzer engine,
and the small Roc ABI/command adapter.

This spike requires the Roc compiler coverage implementation in
[roc-lang/roc#10657](https://github.com/roc-lang/roc/pull/10657).

## Define a typed target

An application provides `target : Target` instead of a byte-oriented `main`.
The input type owns a statically dispatched `generator_for` method:

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

`run` is bounded to 60 seconds by default. Friendly options include `--time`,
`--runs`, `--max-input-size`, `--memory-limit`, `--timeout`, `--dictionary`,
and `--seed`; use `--time=0` for an intentionally unbounded campaign. Native
libFuzzer flags remain available through `raw`. When an explicit Roc failure
is saved, the runner prints ready-to-run `show`, `replay`, and `minimize`
commands.

Rejection-rate reporting is not implemented in this spike yet. The typed
`Fuzz.reject` outcome makes that a straightforward follow-up driver metric.

Continue with the [beginner guide](GUIDE.md) for the normal workflow or
[advanced fuzzing](ADVANCED.md) for tuning and runtime details. Repository
bootstrap, architecture, and validation are documented in
[CONTRIBUTING.md](CONTRIBUTING.md).
