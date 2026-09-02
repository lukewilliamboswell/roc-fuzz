app [target] { pf: platform "../../platform/main.roc" }

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

## The comparison `List.sort_with_reversed` is specified to sort under.
##
## Reversing the comparison must not also reverse the tie order: equal keys
## still keep their input order.
compare_reversed : Item, Item -> Order
compare_reversed = |left, right| {
	match compare_keys(left, right) {
		Before => After
		Same => Same
		After => Before
	}
}

## Insert before the first item the reversed comparison orders after `value`.
insert_reversed : List(Item), Item -> List(Item)
insert_reversed = |sorted, value| {
	placed = List.fold(
		sorted,
		{ out: [], inserted: False },
		|acc, item| {
			if acc.inserted or compare_reversed(item, value) != After {
				{ out: List.append(acc.out, item), inserted: acc.inserted }
			} else {
				{ out: List.append(List.append(acc.out, value), item), inserted: True }
			}
		},
	)
	if placed.inserted placed.out else List.append(placed.out, value)
}

reference_sort_with_reversed : List(Item) -> List(Item)
reference_sort_with_reversed = |items| List.fold(items, [], insert_reversed)

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

## `items` is uniquely owned here, so `List.sort_with_reversed` must sort in
## place using only its fixed scratch buffer -- the allocation count must not
## scale with the number of elements.
##
## Observed: mostly 0 allocations, occasionally up to 4 (fluxsort's scratch
## buffer, plus a degenerate small/empty-list path); the count stays flat
## across list lengths, never scaling with the number of elements.
test! : Input => Fuzz.Outcome
test! = |input| {
	items = decorate(input)
	sorted = Fuzz.expect_allocs_at_most!(4, |{}| List.sort_with_reversed(items, compare_keys))

	if List.len(sorted) != List.len(items) {
		crash "List.sort_with_reversed changed the length of the list"
	}

	if !List.is_eq(sorted, reference_sort_with_reversed(items)) {
		crash "List.sort_with_reversed was not a stable sort under the reversed comparison"
	}

	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "listSortWithReversed",
	generator: Fuzz.map2(
		Fuzz.list(Fuzz.u64, 400),
		Fuzz.u8_in(1, 64),
		|values, modulus| { values, modulus },
	),
	test!,
	show: |input| Str.inspect(input),
})
