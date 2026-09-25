app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-19-d025939" }

import pf.Fuzz
import Utf

## Seamless-slice checker for the wide-UTF decoders (roc-lang/roc#11700).
##
## The decoders load SIMD lanes by unit index from the list they borrow. A
## slice shares its parent's allocation from an offset, so a slice at any
## unit offset (including ones misaligned for 16-byte loads) must decode
## exactly like a fresh list of the same units, and nothing outside the slice
## may influence the result. Padding around the slice is drawn from the same
## surrogate-heavy chunks, and a trailing low surrogate / invalid unit is
## sometimes placed right after the slice so an out-of-bounds read would pair
## with it or change the problem reported. The parent must be unchanged
## afterwards, results must match the Utf.roc oracle, allocations must match
## the fresh-list contract, and nothing leaks.
Case : { utf32 : Bool, how : U8, before : List(U64), body : List(U64), after : List(U64), trap : Bool }

chunk : Fuzz.Generator(U64)
chunk = Fuzz.map2(Fuzz.u8_in(0, 9), Fuzz.u64, |class, n| (n // 16) * 16 + class.to_u64())

generator : Fuzz.Generator(Case)
generator = {
	utf32: Fuzz.map(Fuzz.u8_in(0, 1), |n| n == 1),
	how: Fuzz.u8_in(0, 2),
	before: Fuzz.list(chunk, 24),
	body: Fuzz.list(chunk, 96),
	after: Fuzz.list(chunk, 24),
	trap: Fuzz.map(Fuzz.u8_in(0, 1), |n| n == 1),
}.Fuzz

units16 : List(U64) -> List(U16)
units16 = |chunks| List.join(chunks.map(|c| Utf.utf16_chunk((c % 16).to_u8_wrap(), c // 16)))

units32 : List(U64) -> List(U32)
units32 = |chunks| List.join(chunks.map(|c| Utf.utf32_chunk((c % 16).to_u8_wrap(), c // 16)))

## Take `len` units at `start` of `parent` as a slice, three ways.
slice_of : List(a), U8, U64, U64 -> List(a)
slice_of = |parent, how, start, len| match how {
	0 => parent.sublist({ start, len })
	1 => parent.drop_first(start).drop_last(parent.len() - start - len)
	_ => parent.split_at(start).others.take_first(len)
}

check_bound! = |label, allocations, bound|
	if allocations > bound {
		crash "${label} on a slice allocated ${allocations.to_str()} times (expected <= ${bound.to_str()})"
	}

check_utf16! : Case => {}
check_utf16! = |case| {
	fresh = units16(case.body)
	trap : List(U16)
	trap = if case.trap [0xDC00, 0xD800] else []
	parent = units16(case.before).concat(fresh).concat(trap).concat(units16(case.after))
	start = units16(case.before).len()
	slice = slice_of(parent, case.how, start, fresh.len())
	if slice != fresh {
		crash "slice construction did not reproduce the body units"
	}
	expected = Utf.decode_utf16(fresh)
	{ value: strict, allocations: strict_allocs } = Fuzz.measure_allocs!(|{}| Str.from_utf16(slice))
	{ value: lossy, allocations: lossy_allocs } = Fuzz.measure_allocs!(|{}| Str.from_utf16_lossy(slice))
	check_bound!("Str.from_utf16", strict_allocs, Utf.strict_alloc_bound(expected))
	check_bound!("Str.from_utf16_lossy", lossy_allocs, Utf.alloc_bound(expected.bytes))
	if strict != Str.from_utf16(fresh) or lossy != Str.from_utf16_lossy(fresh) {
		crash "UTF-16 slice decoded differently from a fresh list of the same units"
	}
	if lossy.to_utf8() != expected.bytes {
		crash "UTF-16 slice lossy output differs from oracle"
	}
	agrees = match strict {
		Ok(s) => expected.problem == NoProblem and s == lossy
		Err(BadUtf16({ index, problem })) => match problem {
			UnpairedHighSurrogate => expected.problem == UnpairedHigh(index)
			UnpairedLowSurrogate => expected.problem == UnpairedLow(index)
		}
	}
	if !agrees {
		crash "UTF-16 slice strict result ${Str.inspect(strict)} disagrees with oracle ${Str.inspect(expected.problem)}"
	}
	if parent.sublist({ start, len: fresh.len() }) != fresh {
		crash "decoding a UTF-16 slice changed its parent list"
	}
	Fuzz.expect_no_leaks!(|{}| (Str.from_utf16(slice), Str.from_utf16_lossy(slice)))
}

check_utf32! : Case => {}
check_utf32! = |case| {
	fresh = units32(case.body)
	trap : List(U32)
	trap = if case.trap [0xDC00, 0x110000] else []
	parent = units32(case.before).concat(fresh).concat(trap).concat(units32(case.after))
	start = units32(case.before).len()
	slice = slice_of(parent, case.how, start, fresh.len())
	if slice != fresh {
		crash "slice construction did not reproduce the body units"
	}
	expected = Utf.decode_utf32(fresh)
	{ value: strict, allocations: strict_allocs } = Fuzz.measure_allocs!(|{}| Str.from_utf32(slice))
	{ value: lossy, allocations: lossy_allocs } = Fuzz.measure_allocs!(|{}| Str.from_utf32_lossy(slice))
	check_bound!("Str.from_utf32", strict_allocs, Utf.strict_alloc_bound(expected))
	check_bound!("Str.from_utf32_lossy", lossy_allocs, Utf.alloc_bound(expected.bytes))
	if strict != Str.from_utf32(fresh) or lossy != Str.from_utf32_lossy(fresh) {
		crash "UTF-32 slice decoded differently from a fresh list of the same units"
	}
	if lossy.to_utf8() != expected.bytes {
		crash "UTF-32 slice lossy output differs from oracle"
	}
	agrees = match strict {
		Ok(s) => expected.problem == NoProblem and s == lossy
		Err(BadUtf32({ index, problem })) => match problem {
			CodePointTooLarge => expected.problem == TooLarge(index)
			SurrogateCodePoint => expected.problem == Surrogate(index)
		}
	}
	if !agrees {
		crash "UTF-32 slice strict result ${Str.inspect(strict)} disagrees with oracle ${Str.inspect(expected.problem)}"
	}
	if parent.sublist({ start, len: fresh.len() }) != fresh {
		crash "decoding a UTF-32 slice changed its parent list"
	}
	Fuzz.expect_no_leaks!(|{}| (Str.from_utf32(slice), Str.from_utf32_lossy(slice)))
}

test! : Case => Fuzz.Outcome
test! = |case| {
	if case.utf32 check_utf32!(case) else check_utf16!(case)
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "strFromUtfSlices",
	generator,
	test!,
	show: |case| Str.inspect(case),
})
