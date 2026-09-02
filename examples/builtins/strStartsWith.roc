app [target] { pf: platform "../../platform/main.roc" }

import pf.Fuzz

import pf.Arbitrary

## Allocation invariant: `Str.starts_with` must not allocate.
main! : List(U8) => U8
main! = |data| {
	first = Arbitrary.new(data)
	{ value: str1, state: after_str1 } = first.arbitrary_str()
	{ value: retain1, state: after_choice1 } = after_str1.ratio(1, 2)
	{ value: str2, state: after_str2 } = after_choice1.arbitrary_str()
	{ value: retain2, .. } = after_str2.ratio(1, 2)
	tmp1 = if retain1 str1 else ""
	tmp2 = if retain2 str2 else ""
	before = Fuzz.alloc_count!()
	starts = str1.starts_with(str2)
	after = Fuzz.alloc_count!()
	if after != before {
		crash "Str.starts_with allocated ${(after - before).to_str()} times (expected 0)"
	}
	result = if starts 1 else 0
	(tmp1.count_utf8_bytes() + tmp2.count_utf8_bytes() + result).to_u8_wrap()
}

target = Fuzz.from_bytes!({
	name: "strStartsWith",
	test!: main!,
})
