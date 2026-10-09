app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-19-d025939" }

import pf.Fuzz
import Utf

## Boundary checker for the wide-UTF decoders (roc-lang/roc#11700).
##
## Both decoder passes check ASCII 16 units at a time with Roc SIMD, output of
## at most 23 bytes takes a scalar inline path, and longer output is encoded
## into one exact-capacity list. Each input is an ASCII prefix of chosen
## length, one probe (a 1-4 byte scalar or an invalid unit) placed right at
## that offset, and a suffix of ASCII or dense multi-byte scalars, so the probe
## lands on every SIMD chunk edge and both sides of the inline limit. Strict
## and lossy results are compared with the oracle, allocations match
## `Utf.strict_alloc_bound` and `Utf.alloc_bound`, and nothing leaks.
Case : { utf32 : Bool, prefix : U64, probe : U64, suffix_dense : Bool, suffix : U64, seed : U64 }

generator : Fuzz.Generator(Case)
generator = {
	utf32: Fuzz.map(Fuzz.u8_in(0, 1), |n| n == 1),
	prefix: Fuzz.u64_in(0, 200),
	probe: Fuzz.u64_in(0, 15),
	suffix_dense: Fuzz.map(Fuzz.u8_in(0, 1), |n| n == 1),
	suffix: Fuzz.u64_in(0, 300),
	seed: Fuzz.u64,
}.Fuzz

## Probes 0-10 are valid scalars of every UTF-8 width; the rest are invalid.
probe_units : Bool, U64 -> List(U32)
probe_units = |utf32, probe|
	if probe <= 10 {
		[Utf.width_scalar(probe)]
	} else {
		invalid : List(U32)
		invalid = if utf32 [0xD800, 0xDFFF, 0x110000, 0xFFFFFFFF, 0xDC00] else [0xD800, 0xDBFF, 0xDC00, 0xDFFF, 0xD83D]
		[invalid.get(probe - 11) ?? 0xD800]
	}

scalars : Case -> List(U32)
scalars = |case| {
	suffix = if case.suffix_dense List.repeat(Utf.width_scalar(case.seed // 0x80), case.suffix) else Utf.ascii_seq(case.seed, case.suffix)
	Utf.ascii_seq(case.seed, case.prefix).concat(probe_units(case.utf32, case.probe)).concat(suffix)
}

check_bound! = |label, allocations, bound|
	if allocations > bound {
		crash "${label} allocated ${allocations.to_str()} times (expected <= ${bound.to_str()})"
	}

check_utf16! : List(U16) => {}
check_utf16! = |units| {
	expected = Utf.decode_utf16(units)
	{ value: strict, allocations: strict_allocs } = Fuzz.measure_allocs!(|{}| Str.from_utf16(units))
	{ value: lossy, allocations: lossy_allocs } = Fuzz.measure_allocs!(|{}| Str.from_utf16_lossy(units))
	check_bound!("Str.from_utf16", strict_allocs, Utf.strict_alloc_bound(expected))
	check_bound!("Str.from_utf16_lossy", lossy_allocs, Utf.alloc_bound(expected.bytes))
	if lossy.to_utf8() != expected.bytes {
		crash "UTF-16 lossy output differs from oracle"
	}
	agrees = match strict {
		Ok(s) => expected.problem == NoProblem and s == lossy
		Err(BadUtf16({ index, problem })) => match problem {
			UnpairedHighSurrogate => expected.problem == UnpairedHigh(index)
			UnpairedLowSurrogate => expected.problem == UnpairedLow(index)
		}
	}
	if !agrees {
		crash "UTF-16 strict result ${Str.inspect(strict)} disagrees with oracle ${Str.inspect(expected.problem)}"
	}
	Fuzz.expect_no_leaks!(|{}| (Str.from_utf16(units), Str.from_utf16_lossy(units)))
}

check_utf32! : List(U32) => {}
check_utf32! = |units| {
	expected = Utf.decode_utf32(units)
	{ value: strict, allocations: strict_allocs } = Fuzz.measure_allocs!(|{}| Str.from_utf32(units))
	{ value: lossy, allocations: lossy_allocs } = Fuzz.measure_allocs!(|{}| Str.from_utf32_lossy(units))
	check_bound!("Str.from_utf32", strict_allocs, Utf.strict_alloc_bound(expected))
	check_bound!("Str.from_utf32_lossy", lossy_allocs, Utf.alloc_bound(expected.bytes))
	if lossy.to_utf8() != expected.bytes {
		crash "UTF-32 lossy output differs from oracle"
	}
	agrees = match strict {
		Ok(s) => expected.problem == NoProblem and s == lossy
		Err(BadUtf32({ index, problem })) => match problem {
			CodePointTooLarge => expected.problem == TooLarge(index)
			SurrogateCodePoint => expected.problem == Surrogate(index)
		}
	}
	if !agrees {
		crash "UTF-32 strict result ${Str.inspect(strict)} disagrees with oracle ${Str.inspect(expected.problem)}"
	}
	Fuzz.expect_no_leaks!(|{}| (Str.from_utf32(units), Str.from_utf32_lossy(units)))
}

test! : Case => Fuzz.Outcome
test! = |case| {
	cps = scalars(case)
	if case.utf32 {
		check_utf32!(cps)
	} else {
		check_utf16!(List.join(cps.map(|cp| if cp > 0xFFFF Utf.scalar_utf16(cp) else [cp.to_u16_wrap()])))
	}
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "strFromUtfBoundaries",
	generator,
	test!,
	show: |case| Str.inspect(case),
})
