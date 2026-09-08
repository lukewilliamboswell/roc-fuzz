app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-07-14d9829" }

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
	# Use the input length directly so a reproducer's size equals the observed
	# allocation count while this nightly is red.
	n = List.len(data)

	# Pre-size outside the measured region: `with_capacity` allocates the
	# entries and bucket lists itself.
	unique_start = Dict.with_capacity(n)
	unique = Fuzz.expect_allocs_at_most!(
		0,
		|{}| {
			var $dict = unique_start
			var $i = 0
			while $i < n {
				$dict = Dict.insert($dict, $i, $i)
				$i = $i + 1
			}
			$dict
		},
	)

	# The same inserts with a second reference held across them.
	base = Dict.with_capacity(n)
	alias = base
	shared = Fuzz.expect_allocs_at_least!(
		1,
		|{}| {
			var $dict = base
			var $j = 0
			while $j < n {
				$dict = Dict.insert($dict, $j, $j)
				$j = $j + 1
			}
			$dict
		},
	)

	# Use every dict after the measured regions so none can be optimised away,
	# and so the alias is genuinely still live across the inserts above.
	if Dict.len(unique) != n or Dict.len(shared) != n {
		crash "a dict did not contain every inserted key"
	}
	if Dict.len(alias) != 0 {
		crash "the retained alias observed the inserts made through its copy"
	}

	0
}

target = Fuzz.from_bytes!({
	name: "dictInsertUniqueness",
	test!: main!,
})
