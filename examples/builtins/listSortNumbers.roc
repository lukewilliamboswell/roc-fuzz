app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-12-220fd47" }

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

## `values` is uniquely owned here, so `List.sort` must sort in place using
## only its fixed scratch buffer -- the allocation count must not scale with
## the number of elements.
##
## Observed: mostly 0 allocations, occasionally up to 4 (fluxsort's scratch
## buffer, plus a degenerate small/empty-list path); the count stays flat
## across list lengths from empty up to hundreds of elements, never scaling
## with the number of elements.
test! : List(U64) => Fuzz.Outcome
test! = |values| {
	sorted = Fuzz.expect_allocs_at_most!(4, |{}| List.sort(values))

	if List.len(sorted) != List.len(values) {
		crash "List.sort changed the length of the list"
	}

	if !List.is_eq(sorted, reference_sort(values)) {
		crash "List.sort disagreed with a reference insertion sort"
	}

	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "listSortNumbers",
	generator: Fuzz.list(Fuzz.u64, 400),
	test!,
	show: |values| Str.inspect(values),
})
