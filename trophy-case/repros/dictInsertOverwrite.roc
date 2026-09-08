app [target] { pf: platform "../../platform/main.roc" }

import pf.Fuzz

## RED TEST -- currently fails, see `trophy-case/README.md`.
##
## Overwriting an existing key in a uniquely owned, pre-sized `Dict` allocates
## once per call. Inserting a *new* key into the same dictionary allocates
## nothing, so the cost is specific to `Dict.insert`'s `Found` branch rather
## than to growth, hashing or the dictionary being shared.
##
## Narrowed as far as the builtin surface allows:
##
##   * `Dict.get` over the same keys allocates nothing, so the lookup half of
##     `insert` (`dict_find`) is not responsible.
##   * `List.set` on a uniquely owned list -- including a list of tuples, which
##     is what `Dict` stores -- allocates nothing, so the write itself is fine
##     when the list is genuinely unique.
##
## That leaves the entry list being shared at the point the `Found` branch
## writes to it. This is a cost regression, not a wrong answer: a copying
## insert still returns the correct dictionary, which is why no content
## property has ever caught it.
main! : List(U8) => U8
main! = |data| {
	n = 50 + List.len(data) % 20

	var $d = Dict.with_capacity(n)
	missing_before = Fuzz.alloc_count!()
	var $i = 0
	while $i < n {
		$d = Dict.insert($d, $i, $i)
		$i = $i + 1
	}
	missing_allocs = Fuzz.alloc_count!() - missing_before

	# Every key already exists and the capacity is untouched, so this loop
	# should mutate in place exactly like the loop above.
	found_before = Fuzz.alloc_count!()
	var $j = 0
	while $j < n {
		$d = Dict.insert($d, $j, $j + 1)
		$j = $j + 1
	}
	found_allocs = Fuzz.alloc_count!() - found_before

	if Dict.len($d) != n {
		crash "overwriting existing keys changed the dictionary's length"
	}
	if missing_allocs != 0 {
		crash "inserting new keys into a pre-sized Dict allocated ${missing_allocs.to_str()} times (expected 0)"
	}
	if found_allocs != 0 {
		crash "overwriting ${n.to_str()} existing keys in a uniquely owned, pre-sized Dict allocated ${found_allocs.to_str()} times (expected 0)"
	}
	0
}

target = Fuzz.from_bytes!({
	name: "dictInsertOverwrite",
	test!: main!,
})
