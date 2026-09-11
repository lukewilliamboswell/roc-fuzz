app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-11-793f9d8" }

import pf.Fuzz

## Insert into an already descending list, after every item that is not less.
##
## Folding this over the input is a stable descending insertion sort, which is
## the independent oracle this target checks `List.sort_reversed` against.
insert_descending : List(U64), U64 -> List(U64)
insert_descending = |sorted, value| {
	placed = List.fold(
		sorted,
		{ out: [], inserted: False },
		|acc, item| {
			if acc.inserted or item >= value {
				{ out: List.append(acc.out, item), inserted: acc.inserted }
			} else {
				{ out: List.append(List.append(acc.out, value), item), inserted: True }
			}
		},
	)
	if placed.inserted placed.out else List.append(placed.out, value)
}

reference_sort_reversed : List(U64) -> List(U64)
reference_sort_reversed = |values| List.fold(values, [], insert_descending)

## `values` is uniquely owned here, so `List.sort_reversed` must sort in place
## using only its fixed scratch buffer -- the allocation count must not scale
## with the number of elements.
##
## Observed: mostly 0 allocations, occasionally up to 4 (fluxsort's scratch
## buffer, plus a degenerate small/empty-list path); the count stays flat
## across list lengths, never scaling with the number of elements.
test! : List(U64) => Fuzz.Outcome
test! = |values| {
	sorted = Fuzz.expect_allocs_at_most!(4, |{}| List.sort_reversed(values))

	if List.len(sorted) != List.len(values) {
		crash "List.sort_reversed changed the length of the list"
	}

	if !List.is_eq(sorted, reference_sort_reversed(values)) {
		crash "List.sort_reversed disagreed with a reference descending insertion sort"
	}

	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "listSortReversed",
	generator: Fuzz.list(Fuzz.u64, 400),
	test!,
	show: |values| Str.inspect(values),
})
