app [target] { pf: platform "../../platform/main.roc" }

import pf.Fuzz

import pf.Arbitrary

## Allocation invariant: `Str.is_empty` must not allocate.
main! : List(U8) => U8
main! = |data| {
	first = Arbitrary.new(data)
	{ value: string, state } = first.arbitrary_str()
	{ value: retain, .. } = state.ratio(1, 2)
	tmp = if retain string else ""
	before = Fuzz.alloc_count!()
	is_empty = string.is_empty()
	after = Fuzz.alloc_count!()
	if after != before {
		crash "Str.is_empty allocated ${(after - before).to_str()} times (expected 0)"
	}
	if is_empty != (string.count_utf8_bytes() == 0) {
		crash "string emptiness disagreed with its byte length"
	}
	tmp.count_utf8_bytes().to_u8_wrap()
}

target = Fuzz.from_bytes!({
	name: "strIsEmpty",
	test!: main!,
})
