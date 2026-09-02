app [target] { pf: platform "../../platform/main.roc" }

import pf.Fuzz

## Allocation invariant: doing nothing must allocate nothing.
main! : List(U8) => U8
main! = |_data| {
	before = Fuzz.alloc_count!()
	after = Fuzz.alloc_count!()
	if after != before {
		crash "noop allocated ${(after - before).to_str()} times (expected 0)"
	}
	0
}

target = Fuzz.from_bytes!({
	name: "noop",
	test!: main!,
})
