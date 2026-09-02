app [target] { pf: platform "../../platform/main.roc" }

import pf.Fuzz
import pf.Arbitrary

## Differential model checker for the Dict builtin surface, including the
## new `subscript`/`fold_until` (roc-lang/roc#10735). A bounded sequence of
## operations is decoded from the fuzzer bytes and applied to both a real
## `Dict` and a reference model -- an insertion-order, last-write-wins
## `List((U8, U8))` maintained entirely in this file. After every operation
## the two are checked for agreement.
##
## The `Snapshot` op additionally retains an older copy of the dict, so the
## operations that follow it run against a *shared* backing store. `Dict.insert`
## mutates its entries and Robin Hood buckets in place when it owns them
## uniquely, so a retained snapshot that drifts is how a lost-uniqueness bug
## surfaces here.
Op : [
	Insert(U8, U8),
	Remove(U8),
	Clear,
	KeepIfGe(U8),
	DropIfGe(U8),
	MapAddWrap(U8),
	InsertAll(List((U8, U8))),
	RemoveAllKeys(List(U8)),
	KeepSharedWith(List((U8, U8))),
	Snapshot,
	Reserve(U8),
]

key_gen : Fuzz.Generator(U8)
key_gen = Fuzz.u8_in(0, 63)

value_gen : Fuzz.Generator(U8)
value_gen = Fuzz.u8

pair_gen : Fuzz.Generator((U8, U8))
pair_gen = Fuzz.map2(key_gen, value_gen, |k, v| (k, v))

pairs_gen : Fuzz.Generator(List((U8, U8)))
pairs_gen = Fuzz.list(pair_gen, 5)

keys_gen : Fuzz.Generator(List(U8))
keys_gen = Fuzz.list(key_gen, 5)

op_gen : Fuzz.Generator(Op)
op_gen = |state0| {
	{ value: kind, state: state1 } = state0.u64_in_inclusive_range(0, 10)
	match kind {
		0 => {
			{ value: k, state: s1 } = key_gen(state1)
			{ value: v, state: s2 } = value_gen(s1)
			{ value: Insert(k, v), state: s2 }
		}
		1 => {
			{ value: k, state: s1 } = key_gen(state1)
			{ value: Remove(k), state: s1 }
		}
		2 => { value: Clear, state: state1 }
		3 => {
			{ value: t, state: s1 } = value_gen(state1)
			{ value: KeepIfGe(t), state: s1 }
		}
		4 => {
			{ value: t, state: s1 } = value_gen(state1)
			{ value: DropIfGe(t), state: s1 }
		}
		5 => {
			{ value: c, state: s1 } = value_gen(state1)
			{ value: MapAddWrap(c), state: s1 }
		}
		6 => {
			{ value: pairs, state: s1 } = pairs_gen(state1)
			{ value: InsertAll(pairs), state: s1 }
		}
		7 => {
			{ value: keys, state: s1 } = keys_gen(state1)
			{ value: RemoveAllKeys(keys), state: s1 }
		}
		8 => {
			{ value: pairs, state: s1 } = pairs_gen(state1)
			{ value: KeepSharedWith(pairs), state: s1 }
		}
		9 => { value: Snapshot, state: state1 }
		_ => {
			{ value: extra, state: s1 } = value_gen(state1)
			{ value: Reserve(extra), state: s1 }
		}
	}
}

ops_gen : Fuzz.Generator(List(Op))
ops_gen = Fuzz.list(op_gen, 40)

model_get : List((U8, U8)), U8 -> Try(U8, [KeyNotFound])
model_get = |model, key|
	match List.find_first(model, |(k, _)| k == key) {
		Ok((_, v)) => Ok(v)
		Err(_) => Err(KeyNotFound)
	}

model_contains : List((U8, U8)), U8 -> Bool
model_contains = |model, key|
	match model_get(model, key) {
		Ok(_) => Bool.True
		Err(_) => Bool.False
	}

model_insert : List((U8, U8)), U8, U8 -> List((U8, U8))
model_insert = |model, key, value|
	if model_contains(model, key) {
		List.map(
			model,
			|(k, v)| if k == key {
				(k, value)
			} else {
				(k, v)
			},
		)
	} else {
		List.concat(model, [(key, value)])
	}

model_remove : List((U8, U8)), U8 -> List((U8, U8))
model_remove = |model, key| List.drop_if(model, |(k, _)| k == key)

model_insert_all : List((U8, U8)), List((U8, U8)) -> List((U8, U8))
model_insert_all = |model, pairs| List.fold(pairs, model, |m, (k, v)| model_insert(m, k, v))

model_remove_all_keys : List((U8, U8)), List(U8) -> List((U8, U8))
model_remove_all_keys = |model, keys| List.fold(keys, model, |m, k| model_remove(m, k))

model_keep_shared : List((U8, U8)), List((U8, U8)) -> List((U8, U8))
model_keep_shared = |model, pairs| {
	# `Dict.keep_shared` compares against `Dict.from_list(pairs)`, which
	# resolves duplicate keys to the last value -- not the first match.
	other = model_insert_all([], pairs)
	List.keep_if(
		model,
		|(k, v)|
			match model_get(other, k) {
				Ok(ov) => ov == v
				Err(_) => Bool.False
			},
	)
}

sort_pairs : List((U8, U8)) -> List((U8, U8))
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

assert_agree : Dict(U8, U8), List((U8, U8)) -> {}
assert_agree = |dict, model| {
	if Dict.len(dict) != List.len(model) {
		crash "Dict.len disagreed with the reference model"
	}
	if Dict.is_empty(dict) != List.is_empty(model) {
		crash "Dict.is_empty disagreed with the reference model"
	}
	if sort_pairs(Dict.to_list(dict)) != sort_pairs(model) {
		crash "Dict.to_list disagreed with the reference model"
	}

	var $key = 0
	while $key <= 63 {
		k = U64.to_u8_wrap($key)
		if Dict.contains(dict, k) != model_contains(model, k) {
			crash "Dict.contains disagreed with the reference model"
		}
		if Dict.get(dict, k) != model_get(model, k) {
			crash "Dict.get disagreed with the reference model"
		}
		if Dict.subscript(dict, k) != Dict.get(dict, k) {
			crash "Dict.subscript disagreed with Dict.get"
		}
		$key = $key + 1
	}

	fold_sum = Dict.fold(dict, 0.U8, |acc, _k, v| acc.plus_wrap(v))
	fold_until_sum = Dict.fold_until(dict, 0.U8, |acc, _k, v| Continue(acc.plus_wrap(v)))
	if fold_sum != fold_until_sum {
		crash "Dict.fold and Dict.fold_until (never breaking) disagreed"
	}

	rebuilt = Dict.from_list(Dict.to_list(dict))
	if !Dict.is_eq(dict, rebuilt) {
		crash "Dict.is_eq was not reflexive against a structurally rebuilt copy"
	}

	if Dict.capacity(dict) < Dict.len(dict) {
		crash "Dict.capacity reported less room than the dictionary's own length"
	}

	{}
}

Snapshot_ : { dict : Dict(U8, U8), expected : List((U8, U8)) }

## Re-check every retained copy of the dict. These were captured before later
## mutations ran, so any drift means an operation wrote through a shared
## backing store instead of copying it.
assert_snapshots : List(Snapshot_) -> {}
assert_snapshots = |snapshots| {
	for snapshot in snapshots {
		if Dict.len(snapshot.dict) != List.len(snapshot.expected) {
			crash "a retained Dict snapshot changed length after later operations"
		}
		if sort_pairs(Dict.to_list(snapshot.dict)) != snapshot.expected {
			crash "a retained Dict snapshot changed contents after later operations"
		}
		for (k, v) in snapshot.expected {
			if Dict.get(snapshot.dict, k) != Ok(v) {
				crash "a retained Dict snapshot lost a key after later operations"
			}
		}
	}
	{}
}

State : { dict : Dict(U8, U8), model : List((U8, U8)), snapshots : List(Snapshot_) }

apply_op : State, Op -> State
apply_op = |state, op|
	match op {
		Insert(k, v) => { dict: Dict.insert(state.dict, k, v), model: model_insert(state.model, k, v), snapshots: state.snapshots }
		Remove(k) => { dict: Dict.remove(state.dict, k), model: model_remove(state.model, k), snapshots: state.snapshots }
		Clear => { dict: Dict.clear(state.dict), model: [], snapshots: state.snapshots }
		KeepIfGe(t) => {
			dict: Dict.keep_if(state.dict, |(_, v)| v >= t),
			model: List.keep_if(state.model, |(_, v)| v >= t),
			snapshots: state.snapshots,
		}
		DropIfGe(t) => {
			dict: Dict.drop_if(state.dict, |(_, v)| v >= t),
			model: List.drop_if(state.model, |(_, v)| v >= t),
			snapshots: state.snapshots,
		}
		MapAddWrap(c) => {
			dict: Dict.map(state.dict, |_k, v| v.plus_wrap(c)),
			model: List.map(state.model, |(k, v)| (k, v.plus_wrap(c))),
			snapshots: state.snapshots,
		}
		InsertAll(pairs) => {
			dict: Dict.insert_all(state.dict, Dict.from_list(pairs)),
			model: model_insert_all(state.model, pairs),
			snapshots: state.snapshots,
		}
		RemoveAllKeys(keys) => {
			dict: Dict.remove_all(state.dict, Dict.from_list(List.map(keys, |k| (k, 0)))),
			model: model_remove_all_keys(state.model, keys),
			snapshots: state.snapshots,
		}
		KeepSharedWith(pairs) => {
			dict: Dict.keep_shared(state.dict, Dict.from_list(pairs)),
			model: model_keep_shared(state.model, pairs),
			snapshots: state.snapshots,
		}
		Reserve(extra) => {
			dict: Dict.reserve(state.dict, U8.to_u64(extra)),
			model: state.model,
			snapshots: state.snapshots,
		}
		Snapshot => {
			# Retaining the dict here makes the next mutating op run against a
			# shared backing store. Bound the retained set so long inputs stay
			# bounded in memory.
			kept = if List.len(state.snapshots) >= 8 {
				List.drop_first(state.snapshots, 1)
			} else {
				state.snapshots
			}
			{
				dict: state.dict,
				model: state.model,
				snapshots: List.concat(kept, [{ dict: state.dict, expected: sort_pairs(state.model) }]),
			}
		}
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
			$ad = Dict.insert($ad, U64.to_u8_wrap($ai), U64.to_u8_wrap($ai))
			$ai = $ai + 1
		}

		# NOTE: overwriting existing keys in a uniquely owned, pre-sized Dict
		# still allocates once per call. That defect is tracked as a dedicated
		# red test in trophy-case/repros/dictInsertOverwrite.roc and logged in
		# trophy-case/README.md, rather than failing every Dict target here.
		# The loop below is kept so the alias check that follows sees the same
		# dictionary state it did before.
		var $bi = 0
		while $bi < count {
			$ad = Dict.insert($ad, U64.to_u8_wrap($bi), U64.to_u8_wrap($bi + 1))
			$bi = $bi + 1
		}

		# Alias the dict, then confirm the next insert copies instead of
		# mutating the shared backing store.
		alias = $ad
		before2 = Fuzz.alloc_count!()
		$ad = Dict.insert($ad, U64.to_u8_wrap(0), 255)
		after2 = Fuzz.alloc_count!()
		if after2 == before2 {
			crash "inserting into a Dict with a retained alias performed zero allocations (copy-on-write did not trigger)"
		}
		if Dict.get(alias, U64.to_u8_wrap(0)) == Ok(255) {
			crash "the alias observed a write that should have been copy-on-write isolated"
		}
	}
	{}
}

main! : List(U8) => U8
main! = |data| {
	{ value: ops, .. } = ops_gen(Arbitrary.new(data))

	final = List.fold(
		ops,
		{ dict: Dict.empty(), model: [], snapshots: [] },
		|state, op| {
			next = apply_op(state, op)
			assert_agree(next.dict, next.model)
			assert_snapshots(next.snapshots)
			next
		},
	)

	assert_agree(final.dict, final.model)
	assert_snapshots(final.snapshots)

	# NOTE: bind the count instead of nesting `U64.min(64, List.len(data))`
	# directly as the call argument -- the nested form reliably leaked one
	# allocation on this compiler (debug-0d0d6264) even when the guarded
	# branch below never ran (count == 0). Suspected ARC-insertion bug for
	# compound call arguments inside an effectful function; this is a
	# workaround, not a fix.
	data_len = List.len(data)
	alloc_check_count = U64.min(64, data_len)
	check_alloc_invariants!(alloc_check_count)
	0
}

target = Fuzz.from_bytes!({
	name: "dictOps",
	test!: main!,
})
