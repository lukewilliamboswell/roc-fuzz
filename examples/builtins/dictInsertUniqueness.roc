app [target] { pf: platform "../../platform/main.roc" }

import pf.Fuzz

## Asserts both directions of `Dict.insert`'s uniqueness contract, using the
## platform's allocation counters rather than the dictionary's contents.
##
## `Dict.insert` mutates its entries and Robin Hood bucket tables in place when
## it owns them uniquely, and must copy them when it does not. Both halves of
## that contract are invisible to a content property, because a copying insert
## still computes the right answer -- the regression is in cost, not in the
## result. The two halves fail in opposite directions:
##
##   * Losing uniqueness makes every insert reallocate. Correct, but a large
##     performance regression.
##   * Wrongly keeping it makes an insert write through a shared backing store
##     and corrupt an alias. See `dictInsertAlias` for the content side of that.
##
## So this target measures a uniquely owned, pre-sized dict (which must not
## allocate at all) against the same inserts performed while an alias is held
## (which must allocate, or copy-on-write did not happen).
main! : List(U8) => U8
main! = |data| {
	n = 100 + List.len(data)

	# Pre-size outside the measured region: `with_capacity` allocates the
	# entries and bucket lists itself.
	var $unique = Dict.with_capacity(n)
	unique_before = Fuzz.alloc_count!()
	var $i = 0
	while $i < n {
		$unique = Dict.insert($unique, $i, $i)
		$i = $i + 1
	}
	unique_allocs = Fuzz.alloc_count!() - unique_before

	# The same inserts with a second reference held across them.
	base = Dict.with_capacity(n)
	alias = base
	shared_before = Fuzz.alloc_count!()
	var $shared = base
	var $j = 0
	while $j < n {
		$shared = Dict.insert($shared, $j, $j)
		$j = $j + 1
	}
	shared_allocs = Fuzz.alloc_count!() - shared_before

	# Use every dict after the measured regions so none can be optimised away,
	# and so the alias is genuinely still live across the inserts above.
	if Dict.len($unique) != n or Dict.len($shared) != n {
		crash "a dict did not contain every inserted key"
	}
	if Dict.len(alias) != 0 {
		crash "the retained alias observed the inserts made through its copy"
	}

	if unique_allocs != 0 {
		crash "inserts into a uniquely owned pre-sized Dict allocated ${unique_allocs.to_str()} times (expected 0)"
	}
	if shared_allocs == 0 {
		crash "inserts into an aliased Dict allocated nothing, so copy-on-write did not happen"
	}
	0
}

target = Fuzz.from_bytes!({
	name: "dictInsertUniqueness",
	test!: main!,
})
