app [target] { pf: platform "../../platform/main.roc" }

import pf.Fuzz

import pf.Arbitrary

main : List(U8) -> U8
main = |data| {
	first = Arbitrary.new(data)
	{ value: str1, state: second } = first.arbitrary_str()
	{ value: str2, state: choices } = second.arbitrary_str()
	{ value: retain1, state: last_choice } = choices.ratio(1, 2)
	{ value: retain2, .. } = last_choice.ratio(1, 2)
	tmp1 = if retain1 str1 else ""
	tmp2 = if retain2 str2 else ""

	out = Str.concat(str1, str2)
	if out.count_utf8_bytes() != str1.count_utf8_bytes() + str2.count_utf8_bytes() {
		crash "concatenated string has the wrong byte length"
	}

	(tmp1.count_utf8_bytes() + tmp2.count_utf8_bytes()).to_u8_wrap()
}

target = Fuzz.from_bytes({
	name: "strConcat",
	test: main,
})
