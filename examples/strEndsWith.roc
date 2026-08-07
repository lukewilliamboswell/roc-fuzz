app [main] { pf: platform "../platform/main.roc" }

import pf.Arbitrary

main : List(U8) -> U8
main = |data| {
	first = Arbitrary.new(data)
	{ value: str1, state: after_str1 } = first.arbitrary_str()
	{ value: retain1, state: after_choice1 } = after_str1.ratio(1, 2)
	{ value: str2, state: after_str2 } = after_choice1.arbitrary_str()
	{ value: retain2, .. } = after_str2.ratio(1, 2)
	tmp1 = if retain1 str1 else ""
	tmp2 = if retain2 str2 else ""
	result = if str1.ends_with(str2) 1 else 0
	(tmp1.count_utf8_bytes() + tmp2.count_utf8_bytes() + result).to_u8_wrap()
}
