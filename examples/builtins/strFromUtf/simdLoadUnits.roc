app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-19-d025939" }

import pf.Fuzz

## Checker for the public `U16x8.load_units` / `U32x4.load_units` loads that
## the wide-UTF decoders are built on (roc-lang/roc#11700).
##
## Units come from a seamless slice of a larger parent at any unit offset, so
## loads are exercised misaligned for 16-byte vectors and right up against the
## slice's end, where a read past the slice would pick up parent units. Every
## index in `0..=len` plus one far index is checked: in-bounds loads must equal
## the slice's own units lane for lane, and the rest must be `OutOfBounds`.
## Loads borrow the list, so they must not allocate or leak.
Case : { how : U8, before : U64, units : List(U64), after : U64, far : U64 }

generator : Fuzz.Generator(Case)
generator = {
	how: Fuzz.u8_in(0, 2),
	before: Fuzz.u64_in(0, 15),
	units: Fuzz.list(Fuzz.u64, 40),
	after: Fuzz.u64_in(0, 15),
	far: Fuzz.u64,
}.Fuzz

## Take `len` units at `start` of `parent` as a slice, three ways.
slice_of : List(a), U8, U64, U64 -> List(a)
slice_of = |parent, how, start, len| match how {
	0 => parent.sublist({ start, len })
	1 => parent.drop_first(start).drop_last(parent.len() - start - len)
	_ => parent.split_at(start).others.take_first(len)
}

## Parent padding uses values that never appear in `units` below 2^15, so a
## load that reads outside the slice cannot match by accident.
pad16 : U64 -> List(U16)
pad16 = |n| List.repeat(0xFFFF, n)

pad32 : U64 -> List(U32)
pad32 = |n| List.repeat(0xFFFF_FFFF, n)

## Every index `0..=len`, then `far`.
indices : U64, U64 -> List(U64)
indices = |len, far| {
	var $out = List.with_capacity(len + 2)
	var $i = 0
	while $i <= len {
		$out = $out.append($i)
		$i = $i + 1
	}
	$out.append(far)
}

check16! : Case => {}
check16! = |case| {
	fresh = case.units.map(|n| (n % 0x8000).to_u16_wrap())
	parent = pad16(case.before).concat(fresh).concat(pad16(case.after))
	units = slice_of(parent, case.how, case.before, fresh.len())
	len = units.len()
	for index in indices(len, case.far) {
		{ value: loaded, allocations } = Fuzz.measure_allocs!(|{}| U16x8.load_units(units, index))
		if allocations != 0 {
			crash "U16x8.load_units allocated ${allocations.to_str()} times"
		}
		match loaded {
			Ok(vector) =>
				if len < 8 or index > len - 8 or vector.to_list() != fresh.sublist({ start: index, len: 8 }) {
					crash "U16x8.load_units(${Str.inspect(fresh)}, ${index.to_str()}) = ${Str.inspect(vector.to_list())}"
				}
			Err(OutOfBounds) =>
				if len >= 8 and index <= len - 8 {
					crash "U16x8.load_units rejected in-bounds index ${index.to_str()} of ${len.to_str()}"
				}
		}
	}
	Fuzz.expect_no_leaks!(|{}| U16x8.load_units(units, 0))
}

check32! : Case => {}
check32! = |case| {
	fresh = case.units.map(|n| (n % 0x8000_0000).to_u32_wrap())
	parent = pad32(case.before).concat(fresh).concat(pad32(case.after))
	units = slice_of(parent, case.how, case.before, fresh.len())
	len = units.len()
	for index in indices(len, case.far) {
		{ value: loaded, allocations } = Fuzz.measure_allocs!(|{}| U32x4.load_units(units, index))
		if allocations != 0 {
			crash "U32x4.load_units allocated ${allocations.to_str()} times"
		}
		match loaded {
			Ok(vector) =>
				if len < 4 or index > len - 4 or vector.to_list() != fresh.sublist({ start: index, len: 4 }) {
					crash "U32x4.load_units(${Str.inspect(fresh)}, ${index.to_str()}) = ${Str.inspect(vector.to_list())}"
				}
			Err(OutOfBounds) =>
				if len >= 4 and index <= len - 4 {
					crash "U32x4.load_units rejected in-bounds index ${index.to_str()} of ${len.to_str()}"
				}
		}
	}
	Fuzz.expect_no_leaks!(|{}| U32x4.load_units(units, 0))
}

test! : Case => Fuzz.Outcome
test! = |case| {
	check16!(case)
	check32!(case)
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "simdLoadUnits",
	generator,
	test!,
	show: |case| Str.inspect(case),
})
