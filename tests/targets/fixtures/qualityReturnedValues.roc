app [target] { fuzz: platform "../../../platform/main.roc" }

import fuzz.Fuzz

# A returned nominal needs no equality or codec methods to be measured.
HeapResult := { bytes : List(U8), text : Str }

assert_live_return! : Fuzz.Stats, U64 => {}
assert_live_return! = |stats, allocations| {
	if stats.allocs != allocations or stats.reallocs != 0 or stats.deallocs != 0
		or stats.exit_live_allocs != stats.entry_live_allocs + allocations
		or stats.exit_live_bytes != stats.entry_live_bytes + stats.requested_bytes
		or stats.peak_live_bytes != stats.exit_live_bytes
		{
			crash "returned heap storage was not alive at the measurement boundary: ${Str.inspect(stats)}"
		}
}

assert_parent_and_counters! : U8 => {}
assert_parent_and_counters! = |n| {
	before = {
		allocs: Fuzz.alloc_count!(),
		reallocs: Fuzz.realloc_count!(),
		deallocs: Fuzz.dealloc_count!(),
		requested_bytes: Fuzz.requested_bytes!(),
		live: Fuzz.live_alloc_count!(),
	}
	parent = Fuzz.measure!(
		"parent visibility",
		|| {
			# The user Box and list both count. Their child and parent ownership
			# wrappers are bookkeeping, including wrappers that remain live here.
			child = Fuzz.measure!("nested user box", || Box.box(List.with_capacity(8).append(n)))
			assert_live_return!(child.stats, 2)
			if Box.unbox(child.value).first() != Ok(n) {
				crash "nested measurement changed its returned user box"
			}
			child.stats.requested_bytes
		},
	)
	after = {
		allocs: Fuzz.alloc_count!(),
		reallocs: Fuzz.realloc_count!(),
		deallocs: Fuzz.dealloc_count!(),
		requested_bytes: Fuzz.requested_bytes!(),
		live: Fuzz.live_alloc_count!(),
	}
	if parent.stats.allocs != 2 or parent.stats.reallocs != 0 or parent.stats.deallocs != 2
		or parent.stats.requested_bytes != parent.value
		or parent.stats.entry_live_allocs != parent.stats.exit_live_allocs
		or parent.stats.entry_live_bytes != parent.stats.exit_live_bytes
		or parent.stats.peak_live_bytes != parent.stats.entry_live_bytes + parent.value
		{
			crash "parent measurement counted ownership bookkeeping: ${Str.inspect(parent.stats)}"
		}
	if after.allocs != before.allocs + 2 or after.reallocs != before.reallocs
		or after.deallocs != before.deallocs + 2
		or after.requested_bytes != before.requested_bytes + parent.value
		or after.live != before.live
		{
			crash "allocator counters counted ownership bookkeeping: ${Str.inspect(before)} -> ${Str.inspect(after)}"
		}
}

test! : U8 => Fuzz.Outcome
test! = |n| {
	# Projecting only Stats must not move the returned list's drop before finish.
	discarded = Fuzz.measure!("discarded list", || List.with_capacity(8).append(n)).stats
	assert_live_return!(discarded, 1)

	used = Fuzz.measure!("used list", || List.with_capacity(8).append(n))
	assert_live_return!(used.stats, 1)
	if used.value.first() != Ok(n) {
		crash "measurement changed its returned list"
	}

	text = Fuzz.measure!("discarded string", || Str.repeat("x", 40 + U8.to_u64(n) % 8)).stats
	assert_live_return!(text, 1)

	nominal = Fuzz.measure!(
		"discarded nominal",
		|| HeapResult.{
			bytes: List.with_capacity(8).append(n),
			text: Str.repeat("x", 40 + U8.to_u64(n) % 8),
		},
	).stats
	assert_live_return!(nominal, 2)

	# A user-authored Box is part of the operation, unlike the platform's
	# ownership fence. Its allocation and its contained list must both count.
	boxed = Fuzz.measure!("user box", || Box.box(List.with_capacity(8).append(n))).stats
	assert_live_return!(boxed, 2)

	function = Fuzz.measure!(
		"used function",
		|| {
			bytes = List.with_capacity(8).append(n)
			|| bytes.first()
		},
	)
	assert_live_return!(function.stats, 1)
	if (function.value)() != Ok(n) {
		crash "measurement changed its returned function"
	}

	discarded_function = Fuzz.measure!(
		"discarded function",
		|| {
			bytes = List.with_capacity(8).append(n)
			|| bytes.first()
		},
	).stats
	assert_live_return!(discarded_function, 1)

	scalar = Fuzz.measure!("scalar", || n.plus_wrap(1))
	if scalar.value != n.plus_wrap(1) or scalar.stats.allocs != 0
		or scalar.stats.reallocs != 0 or scalar.stats.deallocs != 0
		or scalar.stats.requested_bytes != 0
		or scalar.stats.entry_live_allocs != scalar.stats.exit_live_allocs
		or scalar.stats.entry_live_bytes != scalar.stats.exit_live_bytes
		{
			crash "finishing a scalar measurement introduced allocator traffic"
		}

	unit = Fuzz.measure!("unit", || {}).stats
	if unit.allocs != 0 or unit.reallocs != 0 or unit.deallocs != 0 or unit.requested_bytes != 0 {
		crash "finishing a zero-sized measurement introduced allocator traffic"
	}

	# Native report checks inspect this boundary when the entire result is unused.
	_ = Fuzz.measure!("unused observation", || List.with_capacity(8).append(n))
	assert_parent_and_counters!(n)
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "quality-returned-values",
	examples: [
		Fuzz.example({ name: "zero", revision: "1", make: || 0.U8 }),
		Fuzz.example({ name: "max", revision: "1", make: || U8.highest }),
	],
	generator: Fuzz.u8,
	test!,
	show: Str.inspect,
})
