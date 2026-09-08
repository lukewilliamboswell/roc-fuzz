app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-07-14d9829" }

import pf.Fuzz

import pf.Arbitrary

## Allocation invariant: `Str.concat` allocates at most once (the new
## backing buffer for the joined string). Results that fit in a small
## string (< 24 bytes) are stored inline and allocate nothing.
main! : List(U8) => U8
main! = |data| {
	first = Arbitrary.new(data)
	{ value: str1, state: second } = first.arbitrary_str()
	{ value: str2, state: choices } = second.arbitrary_str()
	{ value: retain1, state: last_choice } = choices.ratio(1, 2)
	{ value: retain2, .. } = last_choice.ratio(1, 2)
	tmp1 = if retain1 str1 else ""
	tmp2 = if retain2 str2 else ""

	out = Fuzz.expect_allocs_at_most!(
		1,
		|{}| Str.concat(str1, str2),
	)
	if out.count_utf8_bytes() != str1.count_utf8_bytes() + str2.count_utf8_bytes() {
		crash "concatenated string has the wrong byte length"
	}

	(tmp1.count_utf8_bytes() + tmp2.count_utf8_bytes()).to_u8_wrap()
}

target = Fuzz.from_bytes!({
	name: "strConcat",
	test!: main!,
})
