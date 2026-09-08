app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-07-14d9829" }

import pf.Fuzz

import pf.Arbitrary

## Allocation invariant: `Str.repeat` allocates at most once (a single
## backing buffer sized for the whole repeated string), and repeating zero
## times must allocate nothing at all.
main! : List(U8) => U8
main! = |data| {
	first = Arbitrary.new(data)
	{ value: string, state: choice } = first.arbitrary_str()
	{ value: retain, state: count_input } = choice.ratio(1, 2)
	{ value: count, .. } = count_input.u64_in_inclusive_range(0, 512)
	tmp = if retain string else ""

	out = if count == 0 {
		before = Fuzz.alloc_count!()
		zero_out = string.repeat(count)
		after = Fuzz.alloc_count!()
		if after != before {
			crash "Str.repeat(_, 0) allocated ${(after - before).to_str()} times (expected 0)"
		}
		zero_out
	} else {
		Fuzz.expect_allocs_at_most!(
			1,
			|{}| string.repeat(count),
		)
	}

	if count == 0 and out != "" {
		crash "repeating a string zero times was not empty"
	}
	tmp.count_utf8_bytes().to_u8_wrap()
}

target = Fuzz.from_bytes!({
	name: "strRepeat",
	test!: main!,
})
