app [target] { pf: platform "../../../platform/main.roc" }

import pf.Fuzz

## Allocation invariant: doing nothing must allocate nothing.
main! : List(U8) => U8
main! = |_data| {
	Fuzz.expect_allocs_at_most!(0, || {})
	0
}

target = Fuzz.target_with!({
	examples: [],
	name: "noop",
	generator: Fuzz.raw_bytes,
	test!: |input| {
		_ = main!(input)
		Fuzz.keep
	},
	show: Str.inspect,
})
