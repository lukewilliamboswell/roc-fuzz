app [target] { pf: platform "../../platform/main.roc" }

import pf.Fuzz

import pf.Arbitrary

main : List(U8) -> U8
main = |data| {
	first = Arbitrary.new(data)
	{ value: string, state } = first.arbitrary_str()
	{ value: retain, .. } = state.ratio(1, 2)
	tmp = if retain string else ""
	if string.is_empty() != (string.count_utf8_bytes() == 0) {
		crash "string emptiness disagreed with its byte length"
	}
	tmp.count_utf8_bytes().to_u8_wrap()
}

target = Fuzz.from_bytes({
	name: "strIsEmpty",
	test: main,
})
