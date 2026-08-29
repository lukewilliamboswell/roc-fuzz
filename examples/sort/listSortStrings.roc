app [target] { pf: platform "../../platform/main.roc" }

import pf.Fuzz

Order : [Before, Same, After]

## A refcounted item carrying its original position.
##
## Sorting `Str` elements exercises the refcounted path through the sort
## builtin, where every element move has to keep refcounts balanced.
Item : { key : Str, position : U64 }

## Order two strings by their UTF-8 bytes, shorter prefix first.
compare_strs : Str, Str -> Order
compare_strs = |left, right| {
	left_bytes = Str.to_utf8(left)
	right_bytes = Str.to_utf8(right)
	pairs = List.map2(left_bytes, right_bytes, |l, r| (l, r))
	byte_order = List.fold_until(
		pairs,
		Same,
		|_, (l, r)| {
			if l < r {
				Break(Before)
			} else if l > r {
				Break(After)
			} else {
				Continue(Same)
			}
		},
	)
	match byte_order {
		Same => {
			if List.len(left_bytes) < List.len(right_bytes) {
				Before
			} else if List.len(left_bytes) > List.len(right_bytes) {
				After
			} else {
				Same
			}
		}
		other => other
	}
}

compare_items : Item, Item -> Order
compare_items = |left, right| compare_strs(left.key, right.key)

insert_with : List(Item), Item -> List(Item)
insert_with = |sorted, value| {
	placed = List.fold(
		sorted,
		{ out: [], inserted: False },
		|acc, item| {
			if acc.inserted or compare_items(item, value) != After {
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

test : List(Str) -> Fuzz.Outcome
test = |values| {
	items = List.map_with_index(values, |value, index| { key: value, position: index })
	sorted = List.sort_with(items, compare_items)

	if List.len(sorted) != List.len(items) {
		crash "sorting a list of strings changed its length"
	}

	if !List.is_eq(sorted, reference_sort_with(items)) {
		crash "sorting a list of strings was not a stable sort under the given comparison"
	}

	# Reading every sorted string back keeps the elements live after the sort,
	# so a refcount the sort released too early shows up here rather than at
	# some unrelated later allocation.
	total = List.fold(sorted, 0, |acc, item| acc + Str.count_utf8_bytes(item.key))
	original = List.fold(values, 0, |acc, value| acc + Str.count_utf8_bytes(value))
	if total != original {
		crash "sorting a list of strings changed the total length of its strings"
	}

	Fuzz.keep
}

target = Fuzz.target_with({
	name: "listSortStrings",
	generator: Fuzz.list(Fuzz.str, 300),
	test,
	show: |values| Str.inspect(values),
})
