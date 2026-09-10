app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-09-7dadc35" }

import pf.Fuzz

## Allocation invariant: materializing a `U8` range into a `List` allocates
## at most once (a single backing buffer sized for the range).
main! : List(U8) => U8
main! = |data| {
	match data {
		[start, end, inclusive, ..] => {
			range = if inclusive % 2 == 0 {
				U8.range_inclusive_to(start, end)
			} else {
				U8.range_exclusive_to(start, end)
			}
			values : List(U8)
			values = Fuzz.expect_allocs_at_most!(
				1,
				|{}| List.from_iter(range.iter()),
			)
			if List.is_empty(values) 0 else 1
		}
		_ => 2
	}
}

target = Fuzz.from_bytes!({
	name: "listRange",
	test!: main!,
})
