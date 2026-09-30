app [target] { pf: platform "../../../platform/main.roc" }

import pf.Fuzz
import Prefix

## Dec prefix parsing (roc-lang/roc#11705).
##
## The reference scanner in NumText.roc computes the token and its exact
## value scaled by 10^18, so `OutOfRange` must mean the token is inexact
## (more than 18 fractional digits) or outside Dec's range, and every `Ok`
## value must equal the exact value. The split, maximality, Str/List(U8)
## agreement, zero-allocation, round-trip, and leak properties are the same
## as for integers.
generator : Fuzz.Generator(Prefix.Case)
generator = Prefix.case_generator

test! : Prefix.Case => Fuzz.Outcome
test! = |case| {
	Fuzz.expect_no_leaks!(|{}| Prefix.check_dec!(case))
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "numPrefixDec",
	generator,
	test!,
	show: Prefix.show_case,
})
