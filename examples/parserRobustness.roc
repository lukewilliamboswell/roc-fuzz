app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-05-b195f5b" }

import fuzz.Fuzz

## A JSON parse, valid or not, should not allocate wildly out of proportion to
## the input it is reading.
##
## Observed: allocations stay within `4 * count_utf8_bytes(input) + 16`, a
## generous bound (parsing can allocate per token on deeply nested or
## malformed input) that still catches an unbounded blow-up.
test! : Str => Fuzz.Outcome
test! = |input| {
	limit = 4 * Str.count_utf8_bytes(input) + 16
	parsed : Try(U64, _)
	parsed = Fuzz.expect_allocs_at_most!(limit, |{}| Json.parse(input))

	# Valid and invalid JSON are both ordinary results. A crash or timeout is
	# the failure this target is looking for.
	match parsed {
		Ok(_) => Fuzz.keep
		Err(_) => Fuzz.keep
	}
}

target = Fuzz.target_with!({
	name: "parser-robustness",
	generator: Fuzz.str,
	test!,
	show: |input| Str.inspect(input),
})
