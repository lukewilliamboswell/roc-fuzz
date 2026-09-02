app [target] { pf: platform "../../platform/main.roc" }

import pf.Fuzz

import pf.Arbitrary

## Allocation invariant: `Str.split_on` stays within a linear budget based on
## the number of input bytes and therefore possible parts.
main! : List(U8) => U8
main! = |data| {
	first = Arbitrary.new(data)
	{ value: string, state: second } = first.arbitrary_str()
	{ value: delimiter, state: choices } = second.arbitrary_str()
	{ value: retain1, state: last_choice } = choices.ratio(1, 2)
	{ value: retain2, .. } = last_choice.ratio(1, 2)
	tmp1 = if retain1 string else ""
	tmp2 = if retain2 delimiter else ""

	limit = 2 * string.count_utf8_bytes() + 4
	parts = Fuzz.expect_allocs_at_most!(limit, |{}| string.split_on(delimiter))
	if Str.join_with(parts, delimiter) != string {
		crash "split string did not rejoin to the original"
	}
	(tmp1.count_utf8_bytes() + tmp2.count_utf8_bytes()).to_u8_wrap()
}

target = Fuzz.from_bytes!({
	name: "strSplit",
	test!: main!,
})
