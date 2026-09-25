app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-19-d025939" }

import pf.Fuzz
import Prefix

## Float prefix parsing (roc-lang/roc#11705) for F32 and F64.
##
## The token length comes from the reference scanner in NumText.roc (decimal
## and hex mantissas, exponents, `inf`/`infinity`/`nan` in any case). Values
## are compared bit for bit with `T.from_str` of the token; `OutOfRange` is
## allowed only for a token whose magnitude can overflow the type, and only
## the special words may parse to a non-finite value. The split, maximality,
## Str/List(U8) agreement, zero-allocation, round-trip, and leak properties
## are the same as for integers.
generator : Fuzz.Generator(Prefix.Case)
generator = Prefix.case_generator

## Floats are compared by their bits, so NaN payloads and signed zeros count.
f32_bits : F32 -> Str
f32_bits = |v| v.to_bits().to_str()

f64_bits : F64 -> Str
f64_bits = |v| v.to_bits().to_str()

check! : Prefix.Case => {}
check! = |case| {
	Prefix.check_float!(case, "F32", 38, 127, Prefix.int_ops(F32.from_str, F32.from_str_prefix, F32.from_utf8_prefix, f32_bits), F32.is_finite)
	Prefix.check_float!(case, "F64", 308, 1023, Prefix.int_ops(F64.from_str, F64.from_str_prefix, F64.from_utf8_prefix, f64_bits), F64.is_finite)
}

test! : Prefix.Case => Fuzz.Outcome
test! = |case| {
	Fuzz.expect_no_leaks!(|{}| check!(case))
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "numPrefixFloat",
	generator,
	test!,
	show: Prefix.show_case,
})
