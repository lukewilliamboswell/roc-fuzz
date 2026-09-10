app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-10-a670e34" }

import pf.Fuzz

## An item carrying its original position, so ties expose sort stability.
Item : { key : U64, position : U64 }

Input : { values : List(U64), modulus : U8 }

## Insert by key only, after every item whose key is not greater.
##
## Ties therefore keep the order they arrived in, which is exactly the
## stability guarantee `List.sort_by` documents.
insert_by_key : List(Item), Item -> List(Item)
insert_by_key = |sorted, value| {
	placed = List.fold(
		sorted,
		{ out: [], inserted: False },
		|acc, item| {
			if acc.inserted or item.key <= value.key {
				{ out: List.append(acc.out, item), inserted: acc.inserted }
			} else {
				{ out: List.append(List.append(acc.out, value), item), inserted: True }
			}
		},
	)
	if placed.inserted placed.out else List.append(placed.out, value)
}

reference_sort_by : List(Item) -> List(Item)
reference_sort_by = |items| List.fold(items, [], insert_by_key)

decorate : Input -> List(Item)
decorate = |input| {
	modulus = U8.to_u64(input.modulus)
	List.map_with_index(
		input.values,
		|value, index| {
			key: value % modulus,
			position: index,
		},
	)
}

## `items` is uniquely owned here, so `List.sort_by` must sort in place using
## only its fixed scratch buffer -- the allocation count must not scale with
## the number of elements.
##
## Observed: mostly 0 allocations, occasionally up to 5 (fluxsort's scratch
## buffer plus the projected-key buffer `sort_by` builds, and a degenerate
## small/empty-list path); the count stays flat across list lengths, never
## scaling with the number of elements.
test! : Input => Fuzz.Outcome
test! = |input| {
	items = decorate(input)
	sorted = Fuzz.expect_allocs_at_most!(5, |{}| List.sort_by(items, |item| item.key))

	if List.len(sorted) != List.len(items) {
		crash "List.sort_by changed the length of the list"
	}

	if !List.is_eq(sorted, reference_sort_by(items)) {
		crash "List.sort_by was not a stable sort by the projected key"
	}

	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "listSortBy",
	generator: Fuzz.map2(
		Fuzz.list(Fuzz.u64, 400),
		Fuzz.u8_in(1, 64),
		|values, modulus| { values, modulus },
	),
	test!,
	show: |input| Str.inspect(input),
})
