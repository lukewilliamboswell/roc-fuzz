app [target] { fuzz: platform "../../../platform/main.roc" }

import fuzz.Fuzz

## Regions with known allocator counts, each reported under `measure`.
##
## Every region builds and drops its own values. A value that outlives a
## region is freed wherever the optimiser chooses, which differs between
## builds, so its drop would not be a known count. Requested bytes include the
## compiler's allocation header, so they are checked by difference: two
## regions that differ only in capacity differ by exactly that many bytes.
expect_counts! : Str, { allocs : U64, reallocs : U64, deallocs : U64 }, (() => a) => Fuzz.Stats
expect_counts! = |label, expected, body!| {
	measured = Fuzz.measure!(label, body!)
	actual = { allocs: measured.stats.allocs, reallocs: measured.stats.reallocs, deallocs: measured.stats.deallocs }
	if actual != expected {
		crash "${label}: expected ${Str.inspect(expected)}, measured ${Str.inspect(actual)}"
	}
	measured.stats
}

allocate! : U64, U8 => U64
allocate! = |capacity, value| {
	list = List.with_capacity(capacity).append(value)
	if list.capacity() != capacity {
		crash "list did not retain the requested capacity"
	}
	list.len()
}

test! : List(U8) => U8
test! = |input| {
	n = input.len().to_u8_wrap()

	# One allocation and its drop, at two capacities: the same events, and a
	# byte total that differs by the 792 extra elements alone.
	small = expect_counts!("allocate and drop 8 bytes", { allocs: 1, reallocs: 0, deallocs: 1 }, || allocate!(8, n))
	large = expect_counts!("allocate and drop 800 bytes", { allocs: 1, reallocs: 0, deallocs: 1 }, || allocate!(800, n))
	if small.requested_bytes < 8 or large.requested_bytes - small.requested_bytes != 792 {
		crash "requested bytes: measured ${small.requested_bytes.to_str()} and ${large.requested_bytes.to_str()}"
	}

	# Observe each capacity so the compiler needs to materialize both growths.
	grow! = || {
		list = List.with_capacity(1).append(n)
		initial_capacity = list.capacity()
		grown_once = list.reserve(initial_capacity)
		first_capacity = grown_once.capacity()
		grown_twice = grown_once.reserve(first_capacity)
		if first_capacity <= initial_capacity or grown_twice.capacity() <= first_capacity {
			crash "reserve did not grow the list"
		}
		grown_twice.len()
	}
	grown = expect_counts!("grow a unique list", { allocs: 1, reallocs: 2, deallocs: 1 }, grow!)
	if grown.requested_bytes == 0 {
		crash "growing a list requested no bytes"
	}
	combined_stats = Fuzz.measure!("grow again", grow!).stats
	combined = combined_stats.allocs + combined_stats.reallocs
	if combined != grown.allocs + grown.reallocs {
		crash "named measurement counted ${combined.to_str()}, but allocs + reallocs is ${(grown.allocs + grown.reallocs).to_str()}"
	}

	# Appending to a list that is still shared copies it, and leaves the
	# original as it was.
	original = List.with_capacity(4).append(n)
	_ = expect_counts!("append to a shared list", { allocs: 1, reallocs: 0, deallocs: 1 }, || original.append(n).len())
	if original != [n] {
		crash "appending to a shared list changed the original"
	}

	nothing = expect_counts!("allocate nothing", { allocs: 0, reallocs: 0, deallocs: 0 }, || n)
	if nothing.requested_bytes != 0 {
		crash "a region that allocates nothing requested ${nothing.requested_bytes.to_str()} bytes"
	}

	_ = Fuzz.measure!("label with \" and \\ and a\ttab", || {})
	0
}

target = Fuzz.from_bytes!({ examples: [], name: "allocationReport", test! })
