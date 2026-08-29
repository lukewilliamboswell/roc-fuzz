app [target] { pf: platform "../../platform/main.roc" }

import pf.Fuzz

Order : [Before, Same, After]

Item : { key : U64, position : U64 }

Input : { values : List(U64), seed : U64 }

## A comparison that is neither antisymmetric nor transitive.
##
## The order it reports for a pair depends on a hash of both operands, so it
## contradicts itself freely. A sort given such a comparison may return any
## order it likes, but it must still return a permutation of its input, and it
## must not read or write outside the list while doing so.
inconsistent_compare : U64, Item, Item -> Order
inconsistent_compare = |seed, left, right| {
	mixed = left.key.times_wrap(31).plus_wrap(right.key.times_wrap(7)).plus_wrap(seed)
	match mixed % 3 {
		0 => Before
		1 => Same
		_ => After
	}
}

test : Input -> Fuzz.Outcome
test = |input| {
	items = List.map_with_index(input.values, |value, index| { key: value, position: index })
	length = List.len(items)
	sorted = List.sort_with(items, |left, right| inconsistent_compare(input.seed, left, right))

	if List.len(sorted) != length {
		crash "sorting with an inconsistent comparison changed the length of the list"
	}

	# Every returned element must still be an element the list started with,
	# unchanged, and each one must be returned exactly once.
	counts = List.fold(
		sorted,
		List.repeat(0, length),
		|acc, item| {
			match List.update(acc, item.position, |count| count + 1) {
				Ok(next) => next
				Err(_) => crash "sorting with an inconsistent comparison invented an element"
			}
		},
	)

	if !List.all(counts, |count| count == 1) {
		crash "sorting with an inconsistent comparison duplicated or dropped an element"
	}

	intact = List.all(
		sorted,
		|item| {
			match List.get(items, item.position) {
				Ok(original) => original.key == item.key
				Err(_) => False
			}
		},
	)
	if !intact {
		crash "sorting with an inconsistent comparison corrupted an element"
	}

	Fuzz.keep
}

target = Fuzz.target_with({
	name: "listSortInconsistentCmp",
	generator: Fuzz.map2(
		Fuzz.list(Fuzz.u64, 400),
		Fuzz.u64,
		|values, seed| { values, seed },
	),
	test,
	show: |input| Str.inspect(input),
})
