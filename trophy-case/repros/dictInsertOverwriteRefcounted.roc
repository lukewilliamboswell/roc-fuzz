app [target] { pf: platform "../../platform/main.roc" }

import pf.Fuzz

## RED TEST -- currently fails. Follow-up to the primitive-key overwrite defect
## fixed by "Preserve Dict uniqueness across projected field takes"
## (roc 046b7daa26), which made `Dict(U64, U64)` overwrites free.
##
## With *refcounted* keys and values -- `Dict(Str, List(U8))`, where the keys
## are padded past the 24-byte inline threshold so they are genuinely heap
## allocated -- overwriting an existing key in a uniquely owned, pre-sized
## dictionary still allocates once per call, scaling linearly with the number
## of overwrites.
##
## Every key and replacement value is built before the measured region, so the
## loop only performs the overwrites. `control_cost` performs the identical
## `List.get` traffic without the `Dict.insert` and allocates nothing, which
## attributes the cost to the overwrite itself rather than to reading the
## pre-built inputs.
make_key : U64 -> Str
make_key = |n| "roc-fuzz-dict-refcount-key-${U64.to_str(n)}"

overwrite_cost! : U64 => U64
overwrite_cost! = |n| {
	var $d = Dict.with_capacity(n)
	var $keys = List.with_capacity(n)
	var $vals = List.with_capacity(n)
	var $i = 0
	while $i < n {
		$d = Dict.insert($d, make_key($i), [U64.to_u8_wrap($i)])
		$keys = List.append($keys, make_key($i))
		$vals = List.append($vals, [U64.to_u8_wrap($i), 9])
		$i = $i + 1
	}

	before = Fuzz.alloc_count!()
	var $j = 0
	while $j < n {
		$d = Dict.insert($d, List.get($keys, $j) ?? "", List.get($vals, $j) ?? [])
		$j = $j + 1
	}
	after = Fuzz.alloc_count!()
	if Dict.len($d) != n {
		crash "overwriting existing keys changed the dictionary's length"
	}
	after - before
}

## Same reads, no overwrite. Establishes that the pre-built inputs are free.
control_cost! : U64 => U64
control_cost! = |n| {
	var $keys = List.with_capacity(n)
	var $vals = List.with_capacity(n)
	var $i = 0
	while $i < n {
		$keys = List.append($keys, make_key($i))
		$vals = List.append($vals, [U64.to_u8_wrap($i), 9])
		$i = $i + 1
	}
	before = Fuzz.alloc_count!()
	var $sink = 0
	var $j = 0
	while $j < n {
		k = List.get($keys, $j) ?? ""
		v = List.get($vals, $j) ?? []
		$sink = $sink + Str.count_utf8_bytes(k) + List.len(v)
		$j = $j + 1
	}
	after = Fuzz.alloc_count!()
	if $sink == 0 {
		crash "control loop did no work"
	}
	after - before
}

main! : List(U8) => U8
main! = |data| {
	n = 40 + List.len(data) % 40

	control = control_cost!(n)
	if control != 0 {
		crash "reading the pre-built keys and values allocated ${control.to_str()} times, so the measurement below is not attributable to Dict.insert"
	}

	overwrites = overwrite_cost!(n)
	if overwrites != 0 {
		crash "overwriting ${n.to_str()} existing keys with pre-built refcounted keys and values in a uniquely owned, pre-sized Dict allocated ${overwrites.to_str()} times (expected 0)"
	}
	0
}

target = Fuzz.from_bytes!({
	name: "dictInsertOverwriteRefcounted",
	test!: main!,
})
