app [target] { pf: platform "../../platform/main.roc" }

import pf.Fuzz

## Allocation invariant: doing nothing must allocate nothing.
main! : List(U8) => U8
main! = |_data| {
	Fuzz.expect_allocs_at_most!(0, |{}| {})
	0
}

target = Fuzz.from_bytes!({
	name: "noop",
	test!: main!,
})
