app [target] { pf: platform "../../platform/main.roc" }

import pf.Fuzz

import pf.Arbitrary

## Allocation invariant: parsing a Str into a number must not allocate.
main! : List(U8) => U8
main! = |data| {
	{ value: string, state } = Arbitrary.new(data).arbitrary_str()
	{ value: retain, .. } = state.ratio(1, 2)
	tmp = if retain string else ""
	before = Fuzz.alloc_count!()
	result = U64.from_str(string)
	after = Fuzz.alloc_count!()
	if after != before {
		crash "U64.from_str allocated ${(after - before).to_str()} times (expected 0)"
	}
	bonus = match result {
		Ok(_) => 0
		Err(_) => 1
	}
	(tmp.count_utf8_bytes() + bonus).to_u8_wrap()
}

target = Fuzz.from_bytes!({
	name: "strToU64",
	test!: main!,
})
