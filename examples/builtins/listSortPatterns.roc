app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.3.0/FTcKnkDxL1ZXfKsxeLmNKZ6XKnuKDd47Gv79ThxLYSfw.tar.zst" }

import pf.Fuzz

Item : { key : U64, position : U64 }

Input : { pattern : U8, length : U64, period : U64, seed : U64 }

## Cheap pseudo-random mixing, so a pattern can be built from an index alone.
mix : U64, U64 -> U64
mix = |value, seed| value.times_wrap(11400714819323198485).plus_wrap(seed).times_wrap(2654435761)

## Build the key at `index` for the chosen input shape.
##
## Sorting picks its strategy from the runs it finds in the input, so shapes
## like an already sorted list, a reversed list, or a sawtooth reach code that
## uniformly random input almost never does.
key_at : Input, U64 -> U64
key_at = |input, index| {
	period = if input.period == 0 1 else input.period
	match input.pattern % 8 {
		0 => index
		1 => input.length - index
		2 => 7
		3 => index % period
		4 => if index * 2 < input.length index else input.length - index
		5 => if mix(index, input.seed) % 64 == 0 mix(index, input.seed) else index
		6 => mix(index, input.seed) % 4
		_ => mix(index, input.seed)
	}
}

build : Input -> List(Item)
build = |input| {
	var $items = List.with_capacity(input.length)
	var $index = 0
	while $index < input.length {
		$items = List.append($items, { key: key_at(input, $index), position: $index })
		$index = $index + 1
	}
	$items
}

## Check that `sorted` is exactly the stable sort of `items`.
##
## Non-decreasing keys, increasing positions inside every run of equal keys,
## and each input element appearing exactly once together admit only one
## ordering, so this is a complete check and still linear in the length.
check_stable_sort : List(Item), List(Item) -> {}
check_stable_sort = |items, sorted| {
	length = List.len(items)
	if List.len(sorted) != length {
		crash "sorting changed the length of the list"
	}

	ordered : Bool
	ordered = List.fold_with_index(
		sorted,
		True,
		|acc, item, index| {
			if index == 0 {
				acc
			} else {
				match List.get(sorted, index - 1) {
					Ok(previous) => {
						if previous.key < item.key {
							acc
						} else if previous.key == item.key and previous.position < item.position {
							acc
						} else {
							False
						}
					}
					Err(_) => False
				}
			}
		},
	)
	if !ordered {
		crash "sorting did not return a stably ordered list"
	}

	counts = List.fold(
		sorted,
		List.repeat(0, length),
		|acc, item| {
			match List.update(acc, item.position, |count| count + 1) {
				Ok(next) => next
				Err(_) => crash "sorting invented an element"
			}
		},
	)
	if !List.all(counts, |count| count == 1) {
		crash "sorting duplicated or dropped an element"
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
		crash "sorting corrupted an element"
	}

	{}
}

## `items` is uniquely owned here, so `List.sort_by` must sort in place using
## only its fixed scratch buffer, no matter which run-length pattern its
## strategy picks up on -- the allocation count must not scale with the
## number of elements.
##
## Observed: mostly 0 allocations, occasionally up to 5 (fluxsort's scratch
## buffer plus the projected-key buffer `sort_by` builds, and a degenerate
## small/empty-list path); the count stays flat across list lengths up to
## 2000 elements and across every pattern shape, never scaling with the
## number of elements.
test! : Input => Fuzz.Outcome
test! = |input| {
	items = build(input)
	sorted = Fuzz.expect_allocs_at_most!(5, |{}| List.sort_by(items, |item| item.key))
	check_stable_sort(items, sorted)
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "listSortPatterns",
	generator: Fuzz.map2(
		Fuzz.map2(Fuzz.u8, Fuzz.u64_in(0, 2000), |pattern, length| { pattern, length }),
		Fuzz.map2(Fuzz.u64_in(0, 64), Fuzz.u64, |period, seed| { period, seed }),
		|shape, noise| {
			pattern: shape.pattern,
			length: shape.length,
			period: noise.period,
			seed: noise.seed,
		},
	),
	test!,
	show: |input| Str.inspect(input),
})
