app [target] { fuzz: platform "../platform/main.roc" }

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
	name: "string-split-round-trip",
	test,
	show: |input| Str.inspect(input),
})
