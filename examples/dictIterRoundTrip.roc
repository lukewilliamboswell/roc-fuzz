app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-12-220fd47" }

import fuzz.Fuzz

## Targets the `Iter` protocol paths that `Dict.iter`/`Dict.from_iter`
## (roc-lang/roc#10735) branch on. Entries carry a `255` sentinel key that
## gets filtered out with `Iter.keep_if`, which is how a real iterator
## legitimately yields `Skip` (unlike `Iter.custom`, which never does). This
## naturally covers leading/interleaved skips and the all-skipped/empty case.
key_gen : Fuzz.Generator(U8)
key_gen = Fuzz.u8_in(0, 7)

value_gen : Fuzz.Generator(U8)
value_gen = Fuzz.u8

junk_key : U8
junk_key = 255

entry_gen : Fuzz.Generator((U8, U8))
entry_gen = |state0| {
	{ value: is_junk, state: state1 } = state0.ratio(1, 4)
	if is_junk {
		{ value: v, state: state2 } = value_gen(state1)
		{ value: (junk_key, v), state: state2 }
	} else {
		{ value: k, state: state2 } = key_gen(state1)
		{ value: v, state: state3 } = value_gen(state2)
		{ value: (k, v), state: state3 }
	}
}

entries_gen : Fuzz.Generator(List((U8, U8)))
entries_gen = Fuzz.list(entry_gen, 20)

## `key_gen` only produces keys in `0..7`, so a round trip through at most 20
## entries can never touch more than 8 distinct keys -- generous headroom
## above what growth/rehashing could plausibly cost here.
round_trip_alloc_budget : U64
round_trip_alloc_budget = 64

test! : List((U8, U8)) => Fuzz.Outcome
test! = |entries| {
	Fuzz.expect_no_leaks!(
		|{}| {
			real_pairs = List.drop_if(entries, |(k, _)| k == junk_key)

			filtered_iter = List.iter(entries).keep_if(|(k, _)| k != junk_key)
			from_skip_iter = Dict.from_iter(filtered_iter)
			expected = Dict.from_list(real_pairs)
			if !Dict.is_eq(from_skip_iter, expected) {
				crash "Dict.from_iter over a Skip-containing iterator disagreed with Dict.from_list over the filtered pairs"
			}

			dict = Dict.from_list(real_pairs)
			dict_iter = Dict.iter(dict)

			if List.from_iter(dict_iter) != Dict.to_list(dict) {
				crash "Dict.iter's yielded pairs did not match Dict.to_list order"
			}

			round_tripped = Fuzz.expect_allocs_at_most!(
				round_trip_alloc_budget,
				|{}| Dict.from_iter(Dict.iter(dict)),
			)
			if !Dict.is_eq(round_tripped, dict) {
				crash "Dict.from_iter(Dict.iter(d)) round trip changed the dict"
			}
			{}
		},
	)

	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "dict-iter-round-trip",
	generator: entries_gen,
	test!,
	show: |entries| Str.inspect(entries),
})
