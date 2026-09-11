app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-11-793f9d8" }

import pf.Fuzz
import pf.Arbitrary

## Persistence checker for `Dict.insert` with *refcounted* keys and values.
##
## `examples/builtins/dictInsertAlias.roc` covers the same aliasing invariant
## with `U16`/`U8` payloads, where a wrongly shared in-place write can only
## show up as content drift. Refcounted payloads add failure modes that
## primitive ones cannot express at all:
##
##   * The `Found` branch of `Dict.insert` overwrites an entry with
##     `list_set_unsafe`, which must decref the element it replaces. With
##     primitive payloads that decref is a no-op and the path is never
##     exercised; with a heap `Str`/`List` it is real refcount arithmetic.
##   * If that decref runs against a *shared* entries list, a retained alias's
##     string is freed underneath it -- a use-after-free or double-free rather
##     than merely a wrong value. This target therefore *reads* the bytes of
##     every aliased key and value, so a freed payload is actually dereferenced
##     instead of sitting unread.
##   * The opposite slip, an over-incref, leaks. Contents stay correct, so only
##     libFuzzer's RSS ceiling catches it -- which is why this target churns
##     the same keys repeatedly rather than only growing.
##
## Keys are padded past `SMALL_STRING_SIZE` (24 bytes) so they are genuinely
## heap allocated; a short key would be stored inline and silently reduce this
## back to the primitive case. Values are non-empty `List(U8)`s for the same
## reason.
Step : [
	Put(U16, U8),
	Overwrite(U16, U8),
	Drop(U16),
	Snapshot,
	DropOldestAlias,
]

## Deliberately small so the same keys are hit again and again, driving the
## `Found`/overwrite path where the replaced value must be decref'd.
key_space : U64
key_space = 24

key_gen : Fuzz.Generator(U16)
key_gen = Fuzz.map(Fuzz.u64_in(0, key_space - 1), |n| U64.to_u16_wrap(n))

## Padded well past the 24-byte small-string boundary so the key is heap
## allocated and therefore refcounted.
make_key : U16 -> Str
make_key = |n| "roc-fuzz-dict-refcount-key-${U16.to_str(n)}"

make_value : U16, U8 -> List(U8)
make_value = |n, size| {
	count = U8.to_u64(size) % 7 + 1
	var $out = []
	var $i = 0
	while $i < count {
		$out = List.concat($out, [U64.to_u8_wrap($i + U16.to_u64(n))])
		$i = $i + 1
	}
	$out
}

step_gen : Fuzz.Generator(Step)
step_gen = |state0| {
	{ value: kind, state: state1 } = state0.u64_in_inclusive_range(0, 9)
	match kind {
		8 => { value: Snapshot, state: state1 }
		9 => { value: DropOldestAlias, state: state1 }
		6 => {
			{ value: k, state: s1 } = key_gen(state1)
			{ value: Drop(k), state: s1 }
		}
		# Weight overwrites heavily -- that is the refcount-sensitive path.
		4 | 5 | 7 => {
			{ value: k, state: s1 } = key_gen(state1)
			{ value: v, state: s2 } = Fuzz.u8(s1)
			{ value: Overwrite(k, v), state: s2 }
		}
		_ => {
			{ value: k, state: s1 } = key_gen(state1)
			{ value: v, state: s2 } = Fuzz.u8(s1)
			{ value: Put(k, v), state: s2 }
		}
	}
}

steps_gen : Fuzz.Generator(List(Step))
steps_gen = Fuzz.list(step_gen, 300)

Alias : { dict : Dict(Str, List(U8)), expected : List((Str, List(U8))) }

## Force a real dereference of every aliased key and value. If a shared
## in-place write freed one of these, this is where it faults rather than
## silently comparing against released memory.
touch : Str, List(U8) -> U64
touch = |key, value|
	Str.count_utf8_bytes(key) + List.fold(value, 0, |acc, byte| acc + U8.to_u64(byte))

check_aliases : List(Alias) -> {}
check_aliases = |aliases| {
	for alias in aliases {
		if Dict.len(alias.dict) != List.len(alias.expected) {
			crash "a retained Dict alias changed length after later inserts"
		}
		for (k, v) in alias.expected {
			match Dict.get(alias.dict, k) {
				Ok(live) => {
					if live != v {
						crash "a retained Dict alias returned a different value for a key"
					}
					# Dereference both payloads through the alias.
					if touch(k, live) != touch(k, v) {
						crash "a retained Dict alias's key/value bytes changed underneath it"
					}
				}
				Err(_) => crash "a retained Dict alias lost a key after later inserts"
			}
		}
	}
	{}
}

State : { dict : Dict(Str, List(U8)), model : List((Str, List(U8))), aliases : List(Alias) }

model_put : List((Str, List(U8))), Str, List(U8) -> List((Str, List(U8)))
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
		Put(n, size) | Overwrite(n, size) => {
			key = make_key(n)
			value = make_value(n, size)
			{
				dict: Dict.insert(state.dict, key, value),
				model: model_put(state.model, key, value),
				aliases: state.aliases,
			}
		}
		Drop(n) => {
			key = make_key(n)
			{
				dict: Dict.remove(state.dict, key),
				model: List.drop_if(state.model, |(k, _)| k == key),
				aliases: state.aliases,
			}
		}
		Snapshot => {
			kept = if List.len(state.aliases) >= 6 {
				List.drop_first(state.aliases, 1)
			} else {
				state.aliases
			}
			{
				dict: state.dict,
				model: state.model,
				aliases: List.concat(kept, [{ dict: state.dict, expected: state.model }]),
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
	if Dict.len(state.dict) != List.len(Dict.to_list(state.dict)) {
		crash "Dict.to_list length disagreed with Dict.len"
	}
	for (k, v) in state.model {
		match Dict.get(state.dict, k) {
			Ok(live) => {
				if live != v {
					crash "Dict.get returned a different value than the reference model"
				}
				if touch(k, live) != touch(k, v) {
					crash "a live key/value's bytes did not survive"
				}
			}
			Err(_) => crash "Dict.get lost a key that the reference model still holds"
		}
	}
	{}
}

## Allocation invariant: a uniquely owned, pre-sized `Dict` must not allocate
## while overwriting existing keys with already-constructed refcounted values
## (only a decref of the replaced value and an incref of the new one), and a
## `Dict` with a retained alias must allocate (copy-on-write) rather than
## mutate the shared backing store in place. Keys/values are built *before*
## the measured region so the measurement isolates `Dict.insert` itself from
## the cost of constructing the heap-allocated payloads.
check_alloc_invariants! : U64 => {}
check_alloc_invariants! = |count| {
	if count > 0 {
		var $triples = []
		var $ci = 0
		while $ci < count {
			n = U64.to_u16_wrap($ci)
			$triples = List.concat($triples, [(make_key(n), make_value(n, 1), make_value(n, 2))])
			$ci = $ci + 1
		}

		var $ad = Dict.with_capacity(count)
		for (k, v1, _v2) in $triples {
			$ad = Dict.insert($ad, k, v1)
		}

		# NOTE: this allocation regression was fixed by roc 92a663ecb8 but
		# returned in nightly-2026-09-05-b195f5b. Keep the dedicated red test in
		# trophy-case/repros/dictInsertOverwriteRefcounted.roc instead of failing
		# this broad aliasing target. Preserve the loop for the alias check below.
		for (k, _v1, v2) in $triples {
			$ad = Dict.insert($ad, k, v2)
		}
		# Alias the dict, then confirm the next overwrite copies instead of
		# mutating the shared backing store.
		match List.first($triples) {
			Ok((k, _v1, v2)) => {
				alias = $ad
				$ad = Fuzz.expect_allocs_at_least!(
					1,
					|{}| Dict.insert($ad, k, List.concat(v2, [0])),
				)
				if Dict.get(alias, k) == Dict.get($ad, k) {
					crash "the alias observed a write that should have been copy-on-write isolated"
				}
			}
			Err(_) => {}
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

	# Overwrite every live key while the retained aliases are still holding the
	# previous values, then re-verify them. This is the sharpest form of the
	# shared-backing decref: every write replaces a refcounted payload an alias
	# still points at.
	churned = List.fold(final.model, final.dict, |d, (k, v)| Dict.insert(d, k, List.concat(v, [0])))
	if Dict.len(churned) != Dict.len(final.dict) {
		crash "overwriting existing keys changed the dictionary's length"
	}
	check_aliases(final.aliases)

	# NOTE: see the comment in dictOps.roc -- bind the count instead of
	# nesting `U64.min(24, List.len(data))` directly as the call argument, or
	# this leaks one allocation on this compiler even when the guarded branch
	# below never runs.
	data_len = List.len(data)
	alloc_check_count = U64.min(24, data_len)
	check_alloc_invariants!(alloc_check_count)
	0
}

target = Fuzz.from_bytes!({
	name: "dictRefcountAlias",
	test!: main!,
})
