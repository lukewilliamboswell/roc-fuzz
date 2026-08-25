app [target] { pf: platform "../../platform/main.roc" }

import pf.Fuzz

main : List(U8) -> U8
main = |data| {
	match data {
		[start, end, inclusive, ..] => {
			range = if inclusive % 2 == 0 {
				U8.range_inclusive_to(start, end)
			} else {
				U8.range_exclusive_to(start, end)
			}
			values : List(U8)
			values = List.from_iter(range.iter())
			if List.is_empty(values) 0 else 1
		}
		_ => 2
	}
}

target = Fuzz.from_bytes({
	name: "listRange",
	test: main,
})
