app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-07-14d9829" }

import pf.Fuzz

import pf.Arbitrary

## Allocation invariant: `Str.trim_start` returns a view sharing the
## original's backing buffer (or a small inline string), so it must not
## allocate.
main! : List(U8) => U8
main! = |data| {
	{ value: string, state } = Arbitrary.new(data).arbitrary_str()
	{ value: retain, .. } = state.ratio(1, 2)
	tmp = if retain string else ""
	trimmed = Fuzz.expect_allocs_at_most!(0, |{}| string.trim_start())
	bonus = if trimmed.is_empty() 1 else 0
	(tmp.count_utf8_bytes() + bonus).to_u8_wrap()
}

target = Fuzz.from_bytes!({
	name: "strTrimLeft",
	test!: main!,
})
