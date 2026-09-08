app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-08-39a3f89" }

import pf.Fuzz

Order : [Before, Same, After]

## An element of exactly 96 bytes, the largest the sort builtin copies through
## its fixed element buffer.
Narrow : {
	key : U64,
	position : U64,
	p1 : U64,
	p2 : U64,
	p3 : U64,
	p4 : U64,
	p5 : U64,
	p6 : U64,
	p7 : U64,
	p8 : U64,
	p9 : U64,
	p10 : U64,
}

## An element of 104 bytes, one field past that buffer, which makes the sort
## builtin order pointers and gather the elements afterwards.
Wide : {
	key : U64,
	position : U64,
	p1 : U64,
	p2 : U64,
	p3 : U64,
	p4 : U64,
	p5 : U64,
	p6 : U64,
	p7 : U64,
	p8 : U64,
	p9 : U64,
	p10 : U64,
	p11 : U64,
}

Input : { values : List(U64), modulus : U8, wide : Bool }

## Insert before the first item the comparison orders after `value`, which
## makes folding this over a list a stable insertion sort.
insert_with : List(a), a, (a, a -> Order) -> List(a)
insert_with = |sorted, value, compare| {
	placed = List.fold(
		sorted,
		{ out: [], inserted: False },
		|acc, item| {
			if acc.inserted or compare(item, value) != After {
				{ out: List.append(acc.out, item), inserted: acc.inserted }
			} else {
				{ out: List.append(List.append(acc.out, value), item), inserted: True }
			}
		},
	)
	if placed.inserted placed.out else List.append(placed.out, value)
}

reference_sort_with : List(a), (a, a -> Order) -> List(a)
reference_sort_with = |items, compare|
	List.fold(items, [], |sorted, item| insert_with(sorted, item, compare))

compare_u64 : U64, U64 -> Order
compare_u64 = |left, right| {
	if left < right {
		Before
	} else if left > right {
		After
	} else {
		Same
	}
}

keys : Input -> List(U64)
keys = |input| {
	modulus = U8.to_u64(input.modulus)
	List.map(input.values, |value| value % modulus)
}

test_narrow! : Input => Fuzz.Outcome
test_narrow! = |input| {
	items : List(Narrow)
	items = List.map_with_index(
		keys(input),
		|key, index| {
			key,
			position: index,
			p1: key,
			p2: index,
			p3: key,
			p4: index,
			p5: key,
			p6: index,
			p7: key,
			p8: index,
			p9: key,
			p10: index,
		},
	)
	sorted = Fuzz.expect_allocs_at_most!(
		4,
		|{}| List.sort_with(items, |left, right| compare_u64(left.key, right.key)),
	)
	expected = reference_sort_with(items, |left, right| compare_u64(left.key, right.key))
	if !List.is_eq(sorted, expected) {
		crash "sorting 96-byte elements was not a stable sort under the given comparison"
	}
	Fuzz.keep
}

test_wide! : Input => Fuzz.Outcome
test_wide! = |input| {
	items : List(Wide)
	items = List.map_with_index(
		keys(input),
		|key, index| {
			key,
			position: index,
			p1: key,
			p2: index,
			p3: key,
			p4: index,
			p5: key,
			p6: index,
			p7: key,
			p8: index,
			p9: key,
			p10: index,
			p11: key,
		},
	)
	sorted = Fuzz.expect_allocs_at_most!(
		8,
		|{}| List.sort_with(items, |left, right| compare_u64(left.key, right.key)),
	)
	expected = reference_sort_with(items, |left, right| compare_u64(left.key, right.key))
	if !List.is_eq(sorted, expected) {
		crash "sorting 104-byte elements was not a stable sort under the given comparison"
	}
	Fuzz.keep
}

## Both element shapes sort with allocation counts that stay flat as the
## number of elements grows -- the count does not scale with length,
## whether the sort moves fixed-size elements in place (narrow, <=96 bytes)
## or has to allocate to order pointers and gather afterward (wide, >96
## bytes, which is why it gets a looser bound than narrow).
test! : Input => Fuzz.Outcome
test! = |input| if input.wide test_wide!(input) else test_narrow!(input)

target = Fuzz.target_with!({
	name: "listSortWideElements",
	generator: Fuzz.map2(
		Fuzz.map2(
			Fuzz.list(Fuzz.u64, 300),
			Fuzz.u8_in(1, 64),
			|values, modulus| { values, modulus },
		),
		Fuzz.u8_in(0, 1),
		|partial, wide| {
			values: partial.values,
			modulus: partial.modulus,
			wide: wide == 1,
		},
	),
	test!,
	show: |input| Str.inspect(input),
})
