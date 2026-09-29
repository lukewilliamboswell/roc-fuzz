app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.1/FfSwkD2HdA63fcar5Z4EQpTBSGy4LcvEGenqzgiy9Mix.tar.zst", roc: "nightly-2026-09-29-7f11a82" }

import fuzz.Fuzz

## `input` is aliased (passed as both arguments), so `List.concat` must
## allocate a fresh backing buffer rather than reusing either argument's.
##
## Observed: exactly 1 allocation, regardless of `input`'s length.
test! : List(U8) => Fuzz.Outcome
test! = |input| {
	combined = Fuzz.expect_allocs_at_most!(1, |{}| List.concat(input, input))
	if List.len(combined) == List.len(input) * 2 {
		Fuzz.keep
	} else {
		crash "concatenating a list did not double its length"
	}
}

target = Fuzz.target_with!({
	name: "list-concat-length",
	generator: Fuzz.bytes,
	test!,
	show: |input| Str.inspect(input),
})
