app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-05-b195f5b" }

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
		|{}| {
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
	name: "string-split-round-trip",
	generator: Input.generator_for(Default),
	test!,
	show: |input| Str.inspect(input),
})
