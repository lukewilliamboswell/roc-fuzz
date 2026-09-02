app [target] { pf: platform "../../platform/main.roc" }

import pf.Fuzz

import pf.Arbitrary

## Allocation invariant: `Str.split_on` is stable -- splitting the exact
## same string/delimiter pair twice must cost the exact same number of
## allocations both times, since the shape of the work is identical.
main! : List(U8) => U8
main! = |data| {
	first = Arbitrary.new(data)
	{ value: string, state: second } = first.arbitrary_str()
	{ value: delimiter, state: choices } = second.arbitrary_str()
	{ value: retain1, state: last_choice } = choices.ratio(1, 2)
	{ value: retain2, .. } = last_choice.ratio(1, 2)
	tmp1 = if retain1 string else ""
	tmp2 = if retain2 delimiter else ""

	first_run = Fuzz.measure_allocs!(|{}| string.split_on(delimiter))
	second_run = Fuzz.measure_allocs!(|{}| string.split_on(delimiter))
	if first_run.allocations != second_run.allocations {
		crash "Str.split_on allocated a different number of times (${first_run.allocations.to_str()} vs ${second_run.allocations.to_str()}) for the same input"
	}

	parts = first_run.value
	if Str.join_with(parts, delimiter) != string {
		crash "split string did not rejoin to the original"
	}
	(tmp1.count_utf8_bytes() + tmp2.count_utf8_bytes()).to_u8_wrap()
}

target = Fuzz.from_bytes!({
	name: "strSplit",
	test!: main!,
})
