app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-11-793f9d8" }

import pf.Fuzz

import pf.Arbitrary

## Allocation invariant: parsing a `Str` into an `F32` must not allocate --
## the result is a plain number, not a heap value.
main! : List(U8) => U8
main! = |data| {
	{ value: string, state } = Arbitrary.new(data).arbitrary_str()
	{ value: retain, .. } = state.ratio(1, 2)
	tmp = if retain string else ""
	parsed = Fuzz.expect_allocs_at_most!(0, |{}| F32.from_str(string))
	bonus = match parsed {
		Ok(_) => 0
		Err(_) => 1
	}
	(tmp.count_utf8_bytes() + bonus).to_u8_wrap()
}

target = Fuzz.from_bytes!({
	name: "strToF32",
	test!: main!,
})
