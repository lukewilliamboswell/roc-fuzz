app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-19-d025939" }

import pf.Fuzz
import NumText
import Prefix

## Random values of all thirteen numeric types, rendered by `to_str` and by
## `Str.inspect`, then followed by a terminator from `", ]\n"` and an arbitrary
## tail (possibly non-UTF-8 for `List(U8)`). The prefix parsers must return
## the original value (floats bit for bit, NaN as NaN) with exactly the
## terminator and tail as `rest`, and the `Str` and `List(U8)` forms must
## agree.
Case : { a : U64, b : U64, terminator : U8, tail : List(U8) }

generator : Fuzz.Generator(Case)
generator = {
	a: Fuzz.u64,
	b: Fuzz.u64,
	terminator: Fuzz.u8_in(0, 3),
	tail: Prefix.pieces(4),
}.Fuzz

## Parse `text ++ terminator ++ tail` and require the original value back.
round_trip! : Str, Str, Case, List(U8), Prefix.Ops(a), (a, a -> Bool) => {}
round_trip! = |label, text, case, tail, ops, same| {
	terminator = NumText.terminators.get(case.terminator.to_u64()) ?? ','
	after = [terminator].concat(tail)
	joined = text.to_utf8().concat(after)
	expected = match (ops.from_str)(text) {
		Ok(v) => v
		Err(_) => crash "${label}.from_str rejected its own rendering ${Str.inspect(text)}"
	}
	match (ops.utf8_prefix)(joined) {
		Ok({ value, rest }) => {
			if !same(value, expected) {
				crash "${label}: ${Str.inspect(text)} parsed back as ${(ops.render)(value)}"
			}
			if rest != after {
				crash "${label}: ${Str.inspect(text)} left rest ${Str.inspect(rest)}, expected ${Str.inspect(after)}"
			}
		}
		Err(e) => crash "${label}: prefix parse of ${NumText.show_bytes(joined)} failed with ${Str.inspect(e)}"
	}
	match Str.from_utf8(joined) {
		Ok(s) => {
			str_obs = Prefix.observe_str((ops.str_prefix)(s), ops.render)
			list_obs = Prefix.observe_list((ops.utf8_prefix)(joined), ops.render)
			if str_obs != list_obs {
				crash "${label}: Str and List(U8) prefix parsers disagree on ${Str.inspect(s)}"
			}
		}
		Err(_) => {}
	}
}

eq : a, a -> Bool where [a.is_eq : a, a -> Bool]
eq = |x, y| x == y

same_f32 : F32, F32 -> Bool
same_f32 = |x, y| if x.is_nan() y.is_nan() else x.to_bits() == y.to_bits()

same_f64 : F64, F64 -> Bool
same_f64 = |x, y| if x.is_nan() y.is_nan() else x.to_bits() == y.to_bits()

f32_bits : F32 -> Str
f32_bits = |v| v.to_bits().to_str()

f64_bits : F64 -> Str
f64_bits = |v| v.to_bits().to_str()

both! : Str, a, Case, List(U8), Prefix.Ops(a), (a, a -> Bool) => {}
both! = |label, value, case, tail, ops, same| {
	round_trip!(label, (ops.render)(value), case, tail, ops, same)
}

check! : Case => {}
check! = |case| {
	a = case.a
	b = case.b
	wide = a.to_u128() * 18446744073709551616 + b.to_u128()
	tail = case.tail
	both!("U8", a.to_u8_wrap(), case, tail, Prefix.int_ops(U8.from_str, U8.from_str_prefix, U8.from_utf8_prefix, U8.to_str), eq)
	both!("I8", a.to_i8_wrap(), case, tail, Prefix.int_ops(I8.from_str, I8.from_str_prefix, I8.from_utf8_prefix, I8.to_str), eq)
	both!("U16", a.to_u16_wrap(), case, tail, Prefix.int_ops(U16.from_str, U16.from_str_prefix, U16.from_utf8_prefix, U16.to_str), eq)
	both!("I16", a.to_i16_wrap(), case, tail, Prefix.int_ops(I16.from_str, I16.from_str_prefix, I16.from_utf8_prefix, I16.to_str), eq)
	both!("U32", a.to_u32_wrap(), case, tail, Prefix.int_ops(U32.from_str, U32.from_str_prefix, U32.from_utf8_prefix, U32.to_str), eq)
	both!("I32", a.to_i32_wrap(), case, tail, Prefix.int_ops(I32.from_str, I32.from_str_prefix, I32.from_utf8_prefix, I32.to_str), eq)
	both!("U64", a, case, tail, Prefix.int_ops(U64.from_str, U64.from_str_prefix, U64.from_utf8_prefix, U64.to_str), eq)
	both!("I64", a.to_i64_wrap(), case, tail, Prefix.int_ops(I64.from_str, I64.from_str_prefix, I64.from_utf8_prefix, I64.to_str), eq)
	both!("U128", wide, case, tail, Prefix.int_ops(U128.from_str, U128.from_str_prefix, U128.from_utf8_prefix, U128.to_str), eq)
	both!("I128", wide.to_i128_wrap(), case, tail, Prefix.int_ops(I128.from_str, I128.from_str_prefix, I128.from_utf8_prefix, I128.to_str), eq)
	# Str.inspect renders integers the same way; check it round-trips too.
	round_trip!("I128 inspect", Str.inspect(wide.to_i128_wrap()), case, tail, Prefix.int_ops(I128.from_str, I128.from_str_prefix, I128.from_utf8_prefix, I128.to_str), eq)
	f32 = F32.from_bits(a.to_u32_wrap())
	f64 = F64.from_bits(a)
	f32_ops = Prefix.int_ops(F32.from_str, F32.from_str_prefix, F32.from_utf8_prefix, f32_bits)
	f64_ops = Prefix.int_ops(F64.from_str, F64.from_str_prefix, F64.from_utf8_prefix, f64_bits)
	round_trip!("F32", f32.to_str(), case, tail, f32_ops, same_f32)
	round_trip!("F64", f64.to_str(), case, tail, f64_ops, same_f64)
	round_trip!("F32 inspect", Str.inspect(f32), case, tail, f32_ops, same_f32)
	round_trip!("F64 inspect", Str.inspect(f64), case, tail, f64_ops, same_f64)
	dec_ops = Prefix.dec_ops
	magnitude = wide % 170141183460469231731687303715884105728
	dec = match Dec.from_str(NumText.scaled_text(b % 2 == 0, magnitude)) {
		Ok(d) => d
		Err(_) => crash "canonical Dec text was rejected"
	}
	round_trip!("Dec", dec.to_str(), case, tail, dec_ops, eq)
	round_trip!("Dec inspect", Str.inspect(dec), case, tail, dec_ops, eq)
}

test! : Case => Fuzz.Outcome
test! = |case| {
	Fuzz.expect_no_leaks!(|{}| check!(case))
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "numPrefixRoundTrip",
	generator,
	test!,
	show: |case| Str.inspect(case),
})
