app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.3.0/FTcKnkDxL1ZXfKsxeLmNKZ6XKnuKDd47Gv79ThxLYSfw.tar.zst" }

import pf.Fuzz

import pf.Arbitrary

## Allocation invariant: `Str.is_empty` must not allocate.
main! : List(U8) => U8
main! = |data| {
	first = Arbitrary.new(data)
	{ value: string, state } = first.arbitrary_str()
	{ value: retain, .. } = state.ratio(1, 2)
	tmp = if retain string else ""
	is_empty = Fuzz.expect_allocs_at_most!(0, |{}| string.is_empty())
	if is_empty != (string.count_utf8_bytes() == 0) {
		crash "string emptiness disagreed with its byte length"
	}
	tmp.count_utf8_bytes().to_u8_wrap()
}

target = Fuzz.from_bytes!({
	name: "strIsEmpty",
	test!: main!,
})
