app [target] { pf: platform "../../platform/main.roc" }

import pf.Fuzz

import pf.Arbitrary

## Allocation invariant: parsing a `Str` into a `Dec` must not allocate --
## the result is a plain number, not a heap value.
main! : List(U8) => U8
main! = |data| {
	{ value: string, state } = Arbitrary.new(data).arbitrary_str()
	{ value: retain, .. } = state.ratio(1, 2)
	tmp = if retain string else ""
	parsed = Fuzz.expect_allocs_at_most!(0, |{}| Dec.from_str(string))
	bonus = match parsed {
		Ok(_) => 0
		Err(_) => 1
	}
	(tmp.count_utf8_bytes() + bonus).to_u8_wrap()
}

target = Fuzz.from_bytes!({
	name: "strToDec",
	test!: main!,
})
