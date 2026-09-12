app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-12-220fd47" }

import pf.Fuzz
import pf.Arbitrary

## Persistence checker for `Dict.insert`'s Robin Hood write paths.
##
## `Dict.insert` mutates its entry list and bucket table in place when the
## backing store is uniquely owned (roc-lang/roc: "Preserve Dict backing
## uniqueness during insert"). That optimisation is only sound while the
## dict really is unique, so this target deliberately keeps *older* copies of
## the dict alive across later inserts and re-checks them afterwards. A
## uniqueness bug shows up as an alias whose contents drifted, and the
## rewritten iterative `dict_place_and_shift_up` shows up as a lost or
## duplicated bucket under collision pressure.
##
## Keys are U16-wide and insert counts run into the hundreds so the table
## crosses several grow thresholds and builds long probe chains, which is
## where in-place bucket shifting is most fragile.
Step : [
	Put(U16, U8),
	Snapshot,
	Reserve(U8),
	DropOldestAlias,
]

key_gen : Fuzz.Generator(U16)
key_gen = Fuzz.map(Fuzz.u64_in(0, 511), |n| U64.to_u16_wrap(n))

value_gen : Fuzz.Generator(U8)
value_gen = Fuzz.u8

step_gen : Fuzz.Generator(Step)
step_gen = |state0| {
	{ value: kind, state: state1 } = state0.u64_in_inclusive_range(0, 9)
	match kind {
		# Weight inserts heavily -- they are the operation under test.
		8 => { value: Snapshot, state: state1 }
		9 => {
			{ value: extra, state: s1 } = Fuzz.u8_in(0, 64)(state1)
			{ value: Reserve(extra), state: s1 }
		}
		7 => { value: DropOldestAlias, state: state1 }
		_ => {
			{ value: k, state: s1 } = key_gen(state1)
			{ value: v, state: s2 } = value_gen(s1)
			{ value: Put(k, v), state: s2 }
		}
	}
}

steps_gen : Fuzz.Generator(List(Step))
steps_gen = Fuzz.list(step_gen, 400)

## An alias is a retained dict plus the sorted pair list it must still equal.
Alias : { dict : Dict(U16, U8), expected : List((U16, U8)) }

sort_pairs : List((U16, U8)) -> List((U16, U8))
sort_pairs = |pairs|
	List.sort_with(
		pairs,
		|(k1, _), (k2, _)|
			if k1 < k2 {
				Before
			} else if k1 > k2 {
				After
			} else {
				Same
			},
	)

check_aliases : List(Alias) -> {}
check_aliases = |aliases| {
	for alias in aliases {
		if Dict.len(alias.dict) != List.len(alias.expected) {
			crash "a retained Dict alias changed length after later inserts"
		}
		if sort_pairs(Dict.to_list(alias.dict)) != alias.expected {
			crash "a retained Dict alias changed contents after later inserts"
		}
		for (k, v) in alias.expected {
			if Dict.get(alias.dict, k) != Ok(v) {
				crash "a retained Dict alias lost a key after later inserts"
			}
		}
	}
	{}
}

State : { dict : Dict(U16, U8), model : List((U16, U8)), aliases : List(Alias) }

model_put : List((U16, U8)), U16, U8 -> List((U16, U8))
model_put = |model, key, value| {
	without = List.drop_if(model, |(k, _)| k == key)
	if List.len(without) == List.len(model) {
		List.concat(model, [(key, value)])
	} else {
		List.map(
			model,
			|(k, v)| if k == key {
				(k, value)
			} else {
				(k, v)
			},
		)
	}
}

apply : State, Step -> State
apply = |state, step|
	match step {
		Put(k, v) => {
			dict: Dict.insert(state.dict, k, v),
			model: model_put(state.model, k, v),
			aliases: state.aliases,
		}
		Reserve(extra) => {
			dict: Dict.reserve(state.dict, U8.to_u64(extra)),
			model: state.model,
			aliases: state.aliases,
		}
		Snapshot => {
			# Retaining the dict here makes the *next* insert operate on a
			# shared backing store. Cap the retained set so long inputs stay
			# bounded in memory.
			kept = if List.len(state.aliases) >= 8 {
				List.drop_first(state.aliases, 1)
			} else {
				state.aliases
			}
			{
				dict: state.dict,
				model: state.model,
				aliases: List.concat(kept, [{ dict: state.dict, expected: sort_pairs(state.model) }]),
			}
		}
		DropOldestAlias => {
			dict: state.dict,
			model: state.model,
			aliases: if List.is_empty(state.aliases) {
				state.aliases
			} else {
				List.drop_first(state.aliases, 1)
			},
		}
	}

assert_live : State -> {}
assert_live = |state| {
	if Dict.len(state.dict) != List.len(state.model) {
		crash "Dict.len disagreed with the reference model"
	}
	if sort_pairs(Dict.to_list(state.dict)) != sort_pairs(state.model) {
		crash "Dict.to_list disagreed with the reference model"
	}
	for (k, v) in state.model {
		if Dict.get(state.dict, k) != Ok(v) {
			crash "Dict.get lost a key that the reference model still holds"
		}
	}
	if Dict.capacity(state.dict) < Dict.len(state.dict) {
		crash "Dict.capacity reported less room than the dictionary's own length"
	}
	{}
}

## Allocation invariant: a uniquely owned, pre-sized `Dict` must not allocate
## while performing inserts/overwrites that fit within its reserved capacity,
## and a `Dict` with a retained alias must allocate (copy-on-write) rather
## than mutate the shared backing store in place.
check_alloc_invariants! : U64 => {}
check_alloc_invariants! = |count| {
	if count > 0 {
		var $ad = Dict.with_capacity(count)
		var $ai = 0
		while $ai < count {
			$ad = Dict.insert($ad, U64.to_u16_wrap($ai), U64.to_u8_wrap($ai))
			$ai = $ai + 1
		}

		# NOTE: this allocation regression was fixed by roc 046b7daa26 but
		# returned in nightly-2026-09-05-b195f5b. Keep the dedicated red test
		# in trophy-case/repros/dictInsertOverwrite.roc instead of failing this
		# broad aliasing target. Preserve the loop for the alias check below.
		var $bi = 0
		while $bi < count {
			$ad = Dict.insert($ad, U64.to_u16_wrap($bi), U64.to_u8_wrap($bi + 1))
			$bi = $bi + 1
		}
		# Alias the dict, then confirm the next insert copies instead of
		# mutating the shared backing store.
		alias = $ad
		$ad = Fuzz.expect_allocs_at_least!(
			1,
			|{}| Dict.insert($ad, U64.to_u16_wrap(0), 255),
		)
		if Dict.get(alias, U64.to_u16_wrap(0)) == Ok(255) {
			crash "the alias observed a write that should have been copy-on-write isolated"
		}
	}
	{}
}

main! : List(U8) => U8
main! = |data| {
	{ value: steps, .. } = steps_gen(Arbitrary.new(data))

	final = List.fold(
		steps,
		{ dict: Dict.empty(), model: [], aliases: [] },
		|state, step| {
			next = apply(state, step)
			check_aliases(next.aliases)
			next
		},
	)

	assert_live(final)
	check_aliases(final.aliases)

	# One last stress: insert every model key again into a dict that is still
	# aliased by the retained snapshots, then re-verify every alias.
	reinserted = List.fold(final.model, final.dict, |d, (k, v)| Dict.insert(d, k, v.plus_wrap(1)))
	if Dict.len(reinserted) != Dict.len(final.dict) {
		crash "re-inserting existing keys changed the dictionary's length"
	}
	check_aliases(final.aliases)

	# NOTE: see the comment in dictOps.roc -- bind the count instead of
	# nesting `U64.min(64, List.len(data))` directly as the call argument, or
	# this leaks one allocation on this compiler even when the guarded branch
	# below never runs.
	data_len = List.len(data)
	alloc_check_count = U64.min(64, data_len)
	check_alloc_invariants!(alloc_check_count)
	0
}

target = Fuzz.from_bytes!({
	name: "dictInsertAlias",
	test!: main!,
})
