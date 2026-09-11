app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-11-793f9d8" }

import pf.Fuzz

Input : { values : List(U64), start : U8, len : U8 }

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

## Sort `values` and check the result, asserting on whether the sort had to
## allocate.
##
## `must_allocate: True` is for a list that still shares its backing
## allocation with something else -- copy-on-write allocation there is
## correct and expected, so this asserts allocation happened rather than
## asserting it did not. `must_allocate: False` is for a uniquely owned
## list, where the allocation count must stay flat regardless of length.
check_sorted! : List(U64), Str, Bool => {}
check_sorted! = |values, description, must_allocate| {
	sorted = if must_allocate {
		Fuzz.expect_allocs_at_least!(1, |{}| List.sort(values))
	} else {
		Fuzz.expect_allocs_at_most!(4, |{}| List.sort(values))
	}
	if List.len(sorted) != List.len(values) {
		crash "sorting ${description} changed the length of the list"
	}
	if !List.is_eq(sorted, reference_sort(values)) {
		crash "sorting ${description} disagreed with a reference insertion sort"
	}
	{}
}

test! : Input => Fuzz.Outcome
test! = |input| {
	base = input.values
	snapshot = List.map(base, |value| value)

	# `base` is read again below, so it is still shared while it is sorted.
	# A sort that wrote through to the shared allocation would show up as a
	# difference from the snapshot taken beforehand. Sorting a shared list is
	# exactly the case where copy-on-write allocation is correct, so this
	# asserts the sort DID allocate rather than that it did not.
	shared_sorted = Fuzz.expect_allocs_at_least!(1, |{}| List.sort(base))
	if !List.is_eq(base, snapshot) {
		crash "sorting a shared list modified the original list"
	}
	if !List.is_eq(shared_sorted, reference_sort(snapshot)) {
		crash "sorting a shared list disagreed with a reference insertion sort"
	}

	# A sublist is a slice into the same allocation rather than a fresh list,
	# so it too is still shared with `base` and must copy-on-write.
	slice = List.sublist(
		base,
		{
			start: U8.to_u64(input.start),
			len: U8.to_u64(input.len),
		},
	)
	check_sorted!(slice, "a sublist of a shared list", True)

	# Spare capacity puts the elements at the front of a larger allocation,
	# but `List.map` followed by `List.reserve` here produces a uniquely
	# owned list, so the sort itself should stay flat.
	check_sorted!(
		List.reserve(List.map(base, |value| value), 128),
		"a list with spare capacity",
		False,
	)

	# The degenerate lengths every sort has to special-case. `[]` and
	# `List.take_first(base, 1)` are both freshly built, uniquely owned lists.
	check_sorted!([], "an empty list", False)
	check_sorted!(List.take_first(base, 1), "a one-element list", False)

	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "listSortAliasing",
	generator: Fuzz.map2(
		Fuzz.list(Fuzz.u64, 300),
		Fuzz.map2(Fuzz.u8, Fuzz.u8, |start, len| { start, len }),
		|values, bounds| { values, start: bounds.start, len: bounds.len },
	),
	test!,
	show: |input| Str.inspect(input),
})
