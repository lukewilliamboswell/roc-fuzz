app [target] { fuzz: platform "../../../platform/main.roc" }

import fuzz.Fuzz

## Scalar decoding owns no allocation. Large source fixtures, maker closures,
## the target config and raw entropy must all be dropped before the callback.
## This catches capturing the complete config record in any adapter closure.
test! : U8 => Fuzz.Outcome
test! = |_value| {
	if Fuzz.live_alloc_count!() != 0 {
		crash "example preparation or decoding retained an unintended fixture"
	}
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "quality-lifetimes",
	examples: [
		Fuzz.example({ name: "typed", revision: "1", make: || 42.U8 }),
		Fuzz.saved({ name: "large-entropy", revision: "1", bytes: List.repeat(17, 4096) }),
	],
	generator: Fuzz.u8,
	test!,
	show: Str.inspect,
})
