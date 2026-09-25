app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-19-d025939" }

import pf.Fuzz
import NumText
import Prefix

## Integer prefix parsing (roc-lang/roc#11705) for all ten integer types.
##
## Every input is checked against every integer type, so range independence
## of the token is part of the property. For each type:
## * the result equals the reference scanner and exact-value oracle in
##   NumText.roc: `NotANumber` iff no token, `OutOfRange` iff the token
##   denotes no value of the type, otherwise the value and the exact rest;
## * `T.from_str(token)` agrees (split property), and no longer prefix is
##   accepted by `T.from_str` (maximality);
## * `from_str_prefix` on the input as a `Str` and `from_utf8_prefix` on its
##   bytes agree, and neither allocates or leaks;
## * a `from_str`-accepted body followed by a terminator and any tail parses
##   as the whole body.
generator : Fuzz.Generator(Prefix.Case)
generator = Prefix.case_generator

check! : Prefix.Case => {}
check! = |case| {
	Prefix.check_int!(case, "U8", U8.highest.to_u128(), 0, Prefix.int_ops(U8.from_str, U8.from_str_prefix, U8.from_utf8_prefix, U8.to_str))
	Prefix.check_int!(case, "I8", 127, 128, Prefix.int_ops(I8.from_str, I8.from_str_prefix, I8.from_utf8_prefix, I8.to_str))
	Prefix.check_int!(case, "U16", U16.highest.to_u128(), 0, Prefix.int_ops(U16.from_str, U16.from_str_prefix, U16.from_utf8_prefix, U16.to_str))
	Prefix.check_int!(case, "I16", 32767, 32768, Prefix.int_ops(I16.from_str, I16.from_str_prefix, I16.from_utf8_prefix, I16.to_str))
	Prefix.check_int!(case, "U32", U32.highest.to_u128(), 0, Prefix.int_ops(U32.from_str, U32.from_str_prefix, U32.from_utf8_prefix, U32.to_str))
	Prefix.check_int!(case, "I32", 2147483647, 2147483648, Prefix.int_ops(I32.from_str, I32.from_str_prefix, I32.from_utf8_prefix, I32.to_str))
	Prefix.check_int!(case, "U64", U64.highest.to_u128(), 0, Prefix.int_ops(U64.from_str, U64.from_str_prefix, U64.from_utf8_prefix, U64.to_str))
	Prefix.check_int!(case, "I64", 9223372036854775807, 9223372036854775808, Prefix.int_ops(I64.from_str, I64.from_str_prefix, I64.from_utf8_prefix, I64.to_str))
	Prefix.check_int!(case, "U128", U128.highest, 0, Prefix.int_ops(U128.from_str, U128.from_str_prefix, U128.from_utf8_prefix, U128.to_str))
	Prefix.check_int!(case, "I128", 170141183460469231731687303715884105727, 170141183460469231731687303715884105728, Prefix.int_ops(I128.from_str, I128.from_str_prefix, I128.from_utf8_prefix, I128.to_str))
}

test! : Prefix.Case => Fuzz.Outcome
test! = |case| {
	Fuzz.expect_no_leaks!(|{}| check!(case))
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "numPrefixInt",
	generator,
	test!,
	show: Prefix.show_case,
})
