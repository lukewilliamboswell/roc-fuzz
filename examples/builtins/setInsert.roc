app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-10-a670e34" }

import pf.Fuzz

## Building a Set from bytes may grow both Dict backing lists. Keep that work
## within a linear budget while checking the resulting contents independently.
main! : List(U8) => U8
main! = |data| {
	Fuzz.expect_no_leaks!(
		|{}| {
			limit = 40 * List.len(data) + 128
			set = Fuzz.expect_allocs_at_most!(
				limit,
				|{}| List.fold(data, Set.empty(), Set.insert),
			)
			for element in data {
				if !Set.contains(set, element) {
					crash "set did not contain an inserted element"
				}
			}

			empty = List.fold(data, set, Set.remove)
			if !Set.is_empty(empty) {
				crash "set did not remove every inserted element"
			}
			{}
		},
	)
	0
}

target = Fuzz.from_bytes!({
	name: "setInsert",
	test!: main!,
})
