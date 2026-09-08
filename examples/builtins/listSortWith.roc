app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.3.0/FTcKnkDxL1ZXfKsxeLmNKZ6XKnuKDd47Gv79ThxLYSfw.tar.zst", roc: "nightly-2026-09-05-b195f5b" }

import pf.Fuzz

Order : [Before, Same, After]

## An item carrying its original position, so ties expose sort stability.
Item : { key : U64, position : U64 }

Input : { values : List(U64), modulus : U8 }

## Compare on the key alone, which leaves every equal key a visible tie.
compare_keys : Item, Item -> Order
compare_keys = |left, right| {
	if left.key < right.key {
		Before
	} else if left.key > right.key {
		After
	} else {
		Same
	}
}

## Insert before the first item the comparison orders after `value`.
##
## Folding this over the input is a stable insertion sort under the same
## comparison, which is the oracle for `List.sort_with`.
insert_with : List(Item), Item -> List(Item)
insert_with = |sorted, value| {
	placed = List.fold(
		sorted,
		{ out: [], inserted: False },
		|acc, item| {
			if acc.inserted or compare_keys(item, value) != After {
				{ out: List.append(acc.out, item), inserted: acc.inserted }
			} else {
				{ out: List.append(List.append(acc.out, value), item), inserted: True }
			}
		},
	)
	if placed.inserted placed.out else List.append(placed.out, value)
}

reference_sort_with : List(Item) -> List(Item)
reference_sort_with = |items| List.fold(items, [], insert_with)

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

## `items` is uniquely owned here, so `List.sort_with` must sort in place
## using only its fixed scratch buffer -- the allocation count must not scale
## with the number of elements.
##
## Observed: mostly 0 allocations, occasionally up to 4 (fluxsort's scratch
## buffer, plus a degenerate small/empty-list path); the count stays flat
## across list lengths, never scaling with the number of elements.
test! : Input => Fuzz.Outcome
test! = |input| {
	items = decorate(input)
	sorted = Fuzz.expect_allocs_at_most!(4, |{}| List.sort_with(items, compare_keys))

	if List.len(sorted) != List.len(items) {
		crash "List.sort_with changed the length of the list"
	}

	if !List.is_eq(sorted, reference_sort_with(items)) {
		crash "List.sort_with was not a stable sort under the given comparison"
	}

	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "listSortWith",
	generator: Fuzz.map2(
		Fuzz.list(Fuzz.u64, 400),
		Fuzz.u8_in(1, 64),
		|values, modulus| { values, modulus },
	),
	test!,
	show: |input| Str.inspect(input),
})
