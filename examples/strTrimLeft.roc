app [main] { pf: platform "../platform/main.roc" }

import pf.Arbitrary

main : List(U8) -> U8
main = |data| {
	{ value: string, state } = Arbitrary.new(data).arbitrary_str()
	{ value: retain, .. } = state.ratio(1, 2)
	tmp = if retain string else ""
	bonus = if string.trim_start().is_empty() 1 else 0
	(tmp.count_utf8_bytes() + bonus).to_u8_wrap()
}
