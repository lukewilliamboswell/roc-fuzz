app [target] { pf: platform "../../platform/main.roc" }

import pf.Fuzz

import pf.Arbitrary

## Allocation invariant: `List.len` must not allocate.
main! : List(U8) => U8
main! = |data| {
	list = Arbitrary.new(data).arbitrary_list_u8().value
	before = Fuzz.alloc_count!()
	len = list.len()
	after = Fuzz.alloc_count!()
	if after != before {
		crash "List.len allocated ${(after - before).to_str()} times (expected 0)"
	}
	len.to_u8_wrap()
}

target = Fuzz.from_bytes!({
	name: "listLen",
	test!: main!,
})
