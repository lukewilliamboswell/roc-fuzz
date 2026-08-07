app [main] { pf: platform "../platform/main.roc" }

main : List(U8) -> U8
main = |data| {
	match data {
		[start, end, inclusive, ..] => {
			range = if inclusive % 2 == 0 {
				U8.range_inclusive(start, end)
			} else {
				U8.range_exclusive(start, end)
			}
			values : List(U8)
			values = Iter.collect(range)
			if List.is_empty(values) 0 else 1
		}
		_ => 2
	}
}
