app [target] { pf: platform "../../platform/main.roc" }

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

main : List(U8) -> U8
main = |data| {
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
	0
}

target = Fuzz.from_bytes({
	name: "dictRefcountAlias",
	test: main,
})
