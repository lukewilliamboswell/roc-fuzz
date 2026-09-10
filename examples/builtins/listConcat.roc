app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-09-7dadc35" }

import pf.Fuzz

import pf.Arbitrary

## Allocation invariant: `List.concat` allocates at most once (a single
## backing buffer sized for the combined length).
main! : List(U8) => U8
main! = |data| {
	first = Arbitrary.new(data)
	{ value: bytes1, state: second } = first.arbitrary_list_u8()
	{ value: bytes2, state: choices } = second.arbitrary_list_u8()
	{ value: retain1, state: last_choice } = choices.ratio(1, 2)
	{ value: retain2, .. } = last_choice.ratio(1, 2)
	tmp1 = if retain1 bytes1 else []
	tmp2 = if retain2 bytes2 else []

	out = Fuzz.expect_allocs_at_most!(
		1,
		|{}| List.concat(bytes1, bytes2),
	)
	if List.len(out) != List.len(bytes1) + List.len(bytes2) {
		crash "concatenated list has the wrong length"
	}

	x = match List.first(tmp1) {
		Ok(value) => value
		Err(_) => 0
	}
	y = match List.first(tmp2) {
		Ok(value) => value
		Err(_) => 0
	}
	x.plus_wrap(y)
}

target = Fuzz.from_bytes!({
	name: "listConcat",
	test!: main!,
})
