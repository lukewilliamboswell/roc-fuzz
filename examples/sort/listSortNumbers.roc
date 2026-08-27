app [target] { pf: platform "../../platform/main.roc" }

import pf.Fuzz

## Insert into an already sorted list, after every item that is not greater.
##
## Folding this over the input is a stable insertion sort, which is the
## independent oracle this target checks `List.sort` against.
insert_sorted : List(U64), U64 -> List(U64)
insert_sorted = |sorted, value| {
	placed = List.fold(
		sorted,
		{ out: [], inserted: False },
		|acc, item| {
			if acc.inserted or item <= value {
				{ out: List.append(acc.out, item), inserted: acc.inserted }
			} else {
				{ out: List.append(List.append(acc.out, value), item), inserted: True }
			}
		},
	)
	if placed.inserted placed.out else List.append(placed.out, value)
}

reference_sort : List(U64) -> List(U64)
reference_sort = |values| List.fold(values, [], insert_sorted)

test : List(U64) -> Fuzz.Outcome
test = |values| {
	sorted = List.sort(values)

	if List.len(sorted) != List.len(values) {
		crash "List.sort changed the length of the list"
	}

	if !List.is_eq(sorted, reference_sort(values)) {
		crash "List.sort disagreed with a reference insertion sort"
	}

	Fuzz.keep
}

target = Fuzz.target_with({
	name: "listSortNumbers",
	generator: Fuzz.list(Fuzz.u64, 400),
	test,
	show: |values| Str.inspect(values),
})
