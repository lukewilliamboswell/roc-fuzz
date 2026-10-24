app [target] { pf: platform "../../../platform/main.roc" }

import pf.Fuzz

## Platform contract for `Fuzz.measure_memory!`: the byte counters agree with
## allocations whose sizes are known, a reallocation counts its new length and
## replaces the old one in the live total, memory freed inside the region still
## counts toward its peak, and nested measurements do not disturb each other.
##
## Sizes include Roc's refcount prefix, so a list of `n` `U64`s asks for a few
## bytes more than `8 * n`. The checks compare measurements with each other
## rather than with a fixed prefix size.
main! : List(U8) => U8
main! = |data| {
	n = 1 + List.len(data) % 300
	x = data.first() ?? 0
	element = x.to_u64()

	# Nothing allocated: every counter is zero.
	none = Fuzz.measure_memory!(|{}| element + 1)
	if none.allocations != 0 or none.requested_bytes != 0 or none.peak_live_bytes != 0 {
		crash "a region without allocations reported ${none.allocations.to_str()} allocations, ${none.requested_bytes.to_str()} requested bytes and a ${none.peak_live_bytes.to_str()} byte peak"
	}

	# One allocation of known size: it is requested once and is all still live.
	single = Fuzz.measure_memory!(|{}| List.with_capacity(n + 1).append(element))
	if single.allocations != 1 {
		crash "List.with_capacity performed ${single.allocations.to_str()} allocations (expected 1)"
	}
	if single.requested_bytes < 8 * (n + 1) or single.requested_bytes > 8 * (n + 1) + 16 {
		crash "a list of ${(n + 1).to_str()} U64s requested ${single.requested_bytes.to_str()} bytes"
	}
	if single.peak_live_bytes != single.requested_bytes {
		crash "a single live allocation of ${single.requested_bytes.to_str()} bytes reported a ${single.peak_live_bytes.to_str()} byte peak"
	}
	retained = Fuzz.live_bytes!()
	_ = single.value.len()

	# The same allocation measured by the older function counts the same.
	compatible = Fuzz.measure_allocs!(|{}| List.with_capacity(n + 1).append(element))
	if compatible.allocations != single.allocations {
		crash "measure_allocs! counted ${compatible.allocations.to_str()} allocations, measure_memory! ${single.allocations.to_str()}"
	}

	# Growth: a one-element list reserved to hold n + 1 elements. Roc grows a
	# uniquely owned list with roc_realloc, so the region requests the small
	# block and then the large one, but never holds both: the peak is the large
	# block alone.
	grown = Fuzz.measure_memory!(|{}| List.with_capacity(1).append(element).reserve(n))
	small = grown.requested_bytes - single.requested_bytes
	if grown.allocations != 2 or small < 8 or small > 24 {
		crash "growing a one-element list to ${(n + 1).to_str()} elements performed ${grown.allocations.to_str()} allocations requesting ${grown.requested_bytes.to_str()} bytes (expected 2 requesting a small block plus ${single.requested_bytes.to_str()})"
	}
	if grown.peak_live_bytes != single.requested_bytes {
		crash "a reallocation to ${single.requested_bytes.to_str()} bytes reported a ${grown.peak_live_bytes.to_str()} byte peak"
	}
	_ = grown.value.len()

	# Freed inside the region: the peak keeps the large list even though only a
	# one-element list survives.
	live_before = Fuzz.live_bytes!()
	transient = Fuzz.measure_memory!(
		|{}| {
			big = List.repeat(element, n * 4)
			[big.sum()]
		},
	)
	survivor = Fuzz.live_bytes!() - live_before
	if transient.peak_live_bytes < 8 * n * 4 {
		crash "a region that held ${(n * 4).to_str()} U64s reported a ${transient.peak_live_bytes.to_str()} byte peak"
	}
	if survivor >= transient.peak_live_bytes or transient.requested_bytes < transient.peak_live_bytes {
		crash "a region that freed its large list kept ${survivor.to_str()} bytes, peaked at ${transient.peak_live_bytes.to_str()} and requested ${transient.requested_bytes.to_str()}"
	}
	_ = transient.value.len()

	# Memory freed inside the region that was allocated before it does not make
	# the peak negative: it reads as zero.
	before_region = List.repeat(element, n)
	consumed = Fuzz.measure_memory!(|{}| before_region.sum())
	if consumed.requested_bytes != 0 or consumed.peak_live_bytes != 0 {
		crash "consuming a list built before the region requested ${consumed.requested_bytes.to_str()} bytes and peaked at ${consumed.peak_live_bytes.to_str()}"
	}

	# Nesting: an inner region measures from its own start, and its peak is
	# visible to the enclosing region.
	outer = Fuzz.measure_memory!(
		|{}| {
			inner = Fuzz.measure_memory!(
				|{}| {
					big = List.repeat(element, n * 4)
					[big.sum()]
				},
			)
			{ inner_peak: inner.peak_live_bytes, inner_len: inner.value.len() }
		},
	)
	if outer.value.inner_peak != transient.peak_live_bytes {
		crash "a nested region peaked at ${outer.value.inner_peak.to_str()} bytes, the same region alone at ${transient.peak_live_bytes.to_str()}"
	}
	if outer.peak_live_bytes < outer.value.inner_peak {
		crash "an outer region reported a ${outer.peak_live_bytes.to_str()} byte peak around a ${outer.value.inner_peak.to_str()} byte inner peak"
	}

	# Nesting: starting an inner region does not forget a peak the enclosing
	# region reached before it. The large list is summed before the inner
	# region starts, because the inner region reads the sum.
	earlier = Fuzz.measure_memory!(
		|{}| {
			big = List.repeat(element, n * 4)
			total = big.sum()
			inner = Fuzz.measure_memory!(|{}| [total])
			{ inner_peak: inner.peak_live_bytes, inner_len: inner.value.len() }
		},
	)
	if earlier.peak_live_bytes < 8 * n * 4 or earlier.value.inner_peak >= 8 * n * 4 {
		crash "a region that held ${(n * 4).to_str()} U64s before a ${earlier.value.inner_peak.to_str()} byte inner region reported a ${earlier.peak_live_bytes.to_str()} byte peak"
	}

	_ = retained
	0
}

target = Fuzz.from_bytes!({
	name: "measureMemory",
	test!: main!,
})
