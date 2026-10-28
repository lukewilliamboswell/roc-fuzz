app [target] { fuzz: platform "../platform/main.roc" }

import fuzz.Fuzz

Input := { delimiter : Str, value : Str }.{
	parser_for : _
	encoder_for : _

	generator_for : Fuzz.FuzzEncoding -> Fuzz.Generator(Input)
	generator_for = |_| {
		{
			value: Fuzz.str,
			delimiter: Fuzz.str,
		}.Fuzz
	}
}

## `split_on` followed by `join_with` allocates at most one string per part
## plus one for the rejoined result.
##
## Observed: allocations stay within `2 * count_utf8_bytes(value) + 4`, a
## generous bound that scales with the number of parts a pathological
## delimiter (such as a single repeated byte) can produce from `value`.
test! : Input => Fuzz.Outcome
test! = |input| {
	limit = 2 * Str.count_utf8_bytes(input.value) + 4
	rejoined = Fuzz.expect_allocs_at_most!(
		limit,
		|| {
			parts = input.value.split_on(input.delimiter)
			Str.join_with(parts, input.delimiter)
		},
	)

	if rejoined == input.value {
		Fuzz.keep
	} else {
		crash "split parts did not rejoin to the original string"
	}
}

target = Fuzz.target_with!({
	examples: [
		Fuzz.example({ name: "empty-or-zero", revision: "1", make: || Input.{ delimiter: "", value: "" } }),
		Fuzz.example({ name: "representative", revision: "1", make: || Input.{ delimiter: ",", value: "one,two,,three" } }),
	],
	name: "string-split-round-trip",
	generator: Input.generator_for(Default),
	test!,
	show: |input| Str.inspect(input),
})
