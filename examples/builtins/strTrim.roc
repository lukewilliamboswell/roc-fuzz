app [target] { pf: platform "../../platform/main.roc" }

import pf.Fuzz

import pf.Arbitrary

main : List(U8) -> U8
main = |data| {
	{ value: string, state } = Arbitrary.new(data).arbitrary_str()
	{ value: retain, .. } = state.ratio(1, 2)
	tmp = if retain string else ""
	if string.trim() != string.trim_start().trim_end() {
		crash "trim disagreed with trim_start followed by trim_end"
	}
	tmp.count_utf8_bytes().to_u8_wrap()
}

target = Fuzz.from_bytes({
	name: "strTrim",
	test: main,
})
