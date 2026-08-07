app [main] { pf: platform "../platform/main.roc" }

import pf.Arbitrary

main : List(U8) -> U8
main = |data| {
	first = Arbitrary.new(data)
	{ value: string, state: choice } = first.arbitrary_str()
	{ value: retain, state: count_input } = choice.ratio(1, 2)
	{ value: count, .. } = count_input.u64_in_inclusive_range(0, 512)
	tmp = if retain string else ""
	out = string.repeat(count)
	if count == 0 and out != "" {
		crash "repeating a string zero times was not empty"
	}
	tmp.count_utf8_bytes().to_u8_wrap()
}
