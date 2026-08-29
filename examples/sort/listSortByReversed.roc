app [target] { pf: platform "../../platform/main.roc" }

import pf.Fuzz

## An item carrying its original position, so ties expose sort stability.
Item : { key : U64, position : U64 }

Input : { values : List(U64), modulus : U8 }

## Insert by key only, after every item whose key is not less.
##
## Ties therefore keep the order they arrived in, which is exactly the
## stability guarantee `List.sort_by_reversed` documents.
insert_by_key_descending : List(Item), Item -> List(Item)
insert_by_key_descending = |sorted, value| {
	placed = List.fold(
		sorted,
		{ out: [], inserted: False },
		|acc, item| {
			if acc.inserted or item.key >= value.key {
				{ out: List.append(acc.out, item), inserted: acc.inserted }
			} else {
				{ out: List.append(List.append(acc.out, value), item), inserted: True }
			}
		},
	)
	if placed.inserted placed.out else List.append(placed.out, value)
}

reference_sort_by_descending : List(Item) -> List(Item)
reference_sort_by_descending = |items| List.fold(items, [], insert_by_key_descending)

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

test : Input -> Fuzz.Outcome
test = |input| {
	items = decorate(input)
	sorted = List.sort_by_reversed(items, |item| item.key)

	if List.len(sorted) != List.len(items) {
		crash "List.sort_by_reversed changed the length of the list"
	}

	if !List.is_eq(sorted, reference_sort_by_descending(items)) {
		crash "List.sort_by_reversed was not a stable sort by the projected key"
	}

	Fuzz.keep
}

target = Fuzz.target_with({
	name: "listSortByReversed",
	generator: Fuzz.map2(
		Fuzz.list(Fuzz.u64, 400),
		Fuzz.u8_in(1, 64),
		|values, modulus| { values, modulus },
	),
	test,
	show: |input| Str.inspect(input),
})
