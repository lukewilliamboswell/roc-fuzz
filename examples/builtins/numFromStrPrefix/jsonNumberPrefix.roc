app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-19-d025939" }

import pf.Fuzz
import NumText
import Prefix

## The builtin Json number decoders, which now scan with the numeric prefix
## parsers (roc-lang/roc#11705).
##
## * Values of every numeric type encoded with `Json.to_str` decode back to
##   the same value.
## * Random number-like text, including Roc-only continuations (`1_0`, `0x1`,
##   `inf`, `+1`, `1.` for integers, `1e5` for integers), decodes iff the text
##   between JSON whitespace is a JSON number literal of the type's family
##   (`-?(0|[1-9]D*)` for integers, without `-` for unsigned ones, plus
##   fraction and exponent for floats and Dec) that `T.from_str` accepts, and
##   then to `T.from_str` of that literal.
##
## Dec keeps its own Json number path (it does not use the prefix parsers),
## so only its `Json.to_str` round trip is checked here. That path rejects a
## zero whose exponent does not fit in 64 bits (`0e99999999999999999999`),
## which `Dec.from_str` accepts as 0.
Case : { body : List(U8), lead : U8, trail : U8, a : U64, b : U64 }

generator : Fuzz.Generator(Case)
generator = {
	body: Fuzz.map2(Prefix.token_pieces(6), Prefix.pieces(3), List.concat),
	lead: Fuzz.u8_in(0, 7),
	trail: Fuzz.u8_in(0, 7),
	a: Fuzz.u64,
	b: Fuzz.u64,
}.Fuzz

is_ws : U8 -> Bool
is_ws = |b| b == ' ' or b == '\t' or b == '\n' or b == '\r'

whitespace : U8 -> List(U8)
whitespace = |n| match n {
	0 | 1 | 2 | 3 => []
	4 => [' ']
	5 => ['\n', ' ']
	6 => ['\t']
	_ => ['\r', '\n']
}

## End of `D+` at `i`, or `i` when there is no digit.
digits_end : List(U8), U64 -> U64
digits_end = |bytes, i| {
	var $j = i
	while NumText.is_digit(NumText.at(bytes, $j)) and $j < bytes.len() {
		$j = $j + 1
	}
	$j
}

## JSON number grammar, written from RFC 8259. `family` is `UnsignedInt`,
## `SignedInt`, or `Number`.
is_json_literal : List(U8), [UnsignedInt, SignedInt, Number] -> Bool
is_json_literal = |bytes, family| {
	n = bytes.len()
	at = |i| NumText.at(bytes, i)
	start = if at(0) == '-' 1 else 0
	if start == 1 and family == UnsignedInt {
		return Bool.False
	}
	int_end = if at(start) == '0' and start < n {
		start + 1
	} else if at(start) >= '1' and at(start) <= '9' {
		digits_end(bytes, start)
	} else {
		return Bool.False
	}
	if family != Number {
		return int_end == n
	}
	frac_end = if at(int_end) == '.' and int_end < n {
		e = digits_end(bytes, int_end + 1)
		if e == int_end + 1 {
			return Bool.False
		}
		e
	} else {
		int_end
	}
	exp_end = if (at(frac_end) == 'e' or at(frac_end) == 'E') and frac_end < n {
		sign = if at(frac_end + 1) == '+' or at(frac_end + 1) == '-' 1 else 0
		e = digits_end(bytes, frac_end + 1 + sign)
		if e == frac_end + 1 + sign {
			return Bool.False
		}
		e
	} else {
		frac_end
	}
	exp_end == n
}

## Trim JSON whitespace from both ends.
core : List(U8) -> List(U8)
core = |bytes| {
	var $start = 0
	while $start < bytes.len() and is_ws(NumText.at(bytes, $start)) {
		$start = $start + 1
	}
	var $end = bytes.len()
	while $end > $start and is_ws(NumText.at(bytes, $end - 1)) {
		$end = $end - 1
	}
	bytes.sublist({ start: $start, len: $end - $start })
}

## Decode `text` as `T` and compare with the grammar-and-`from_str` oracle.
check_text! : Str, Str, [UnsignedInt, SignedInt, Number], Try(a, _), (Str -> Try(a, [BadNumStr])), (a -> Str) => {}
check_text! = |label, text, family, decoded, from_str, render| {
	literal = core(text.to_utf8())
	expected = if is_json_literal(literal, family) {
		match Str.from_utf8(literal) {
			Ok(s) => match from_str(s) {
				Ok(v) => Ok(render(v))
				Err(_) => Err(Rejected)
			}
			Err(_) => Err(Rejected)
		}
	} else {
		Err(Rejected)
	}
	got = match decoded {
		Ok(v) => Ok(render(v))
		Err(_) => Err(Rejected)
	}
	if got != expected {
		crash "${label}: Json.parse(${Str.inspect(text)}) = ${Str.inspect(got)}, expected ${Str.inspect(expected)}"
	}
}

f32_bits : F32 -> Str
f32_bits = |v| v.to_bits().to_str()

f64_bits : F64 -> Str
f64_bits = |v| v.to_bits().to_str()

parse_u8 : Str -> Try(U8, _)
parse_u8 = |s| Json.parse(s)

parse_i8 : Str -> Try(I8, _)
parse_i8 = |s| Json.parse(s)

parse_u16 : Str -> Try(U16, _)
parse_u16 = |s| Json.parse(s)

parse_i16 : Str -> Try(I16, _)
parse_i16 = |s| Json.parse(s)

parse_u32 : Str -> Try(U32, _)
parse_u32 = |s| Json.parse(s)

parse_i32 : Str -> Try(I32, _)
parse_i32 = |s| Json.parse(s)

parse_u64 : Str -> Try(U64, _)
parse_u64 = |s| Json.parse(s)

parse_i64 : Str -> Try(I64, _)
parse_i64 = |s| Json.parse(s)

parse_u128 : Str -> Try(U128, _)
parse_u128 = |s| Json.parse(s)

parse_i128 : Str -> Try(I128, _)
parse_i128 = |s| Json.parse(s)

parse_f32 : Str -> Try(F32, _)
parse_f32 = |s| Json.parse(s)

parse_f64 : Str -> Try(F64, _)
parse_f64 = |s| Json.parse(s)

parse_dec : Str -> Try(Dec, _)
parse_dec = |s| Json.parse(s)

check_texts! : Str => {}
check_texts! = |text| {
	check_text!("U8", text, UnsignedInt, parse_u8(text), U8.from_str, U8.to_str)
	check_text!("I8", text, SignedInt, parse_i8(text), I8.from_str, I8.to_str)
	check_text!("U16", text, UnsignedInt, parse_u16(text), U16.from_str, U16.to_str)
	check_text!("I16", text, SignedInt, parse_i16(text), I16.from_str, I16.to_str)
	check_text!("U32", text, UnsignedInt, parse_u32(text), U32.from_str, U32.to_str)
	check_text!("I32", text, SignedInt, parse_i32(text), I32.from_str, I32.to_str)
	check_text!("U64", text, UnsignedInt, parse_u64(text), U64.from_str, U64.to_str)
	check_text!("I64", text, SignedInt, parse_i64(text), I64.from_str, I64.to_str)
	check_text!("U128", text, UnsignedInt, parse_u128(text), U128.from_str, U128.to_str)
	check_text!("I128", text, SignedInt, parse_i128(text), I128.from_str, I128.to_str)
	check_text!("F32", text, Number, parse_f32(text), F32.from_str, f32_bits)
	check_text!("F64", text, Number, parse_f64(text), F64.from_str, f64_bits)
}

## `Json.to_str` output of a value decodes back to it.
round_trip! = |label, value, parse, render| {
	encoded = Json.to_str(value)
	match parse(encoded) {
		Ok(back) if render(back) == render(value) => {}
		Ok(back) => crash "${label}: ${render(value)} encoded as ${Str.inspect(encoded)} decoded as ${render(back)}"
		Err(_) => crash "${label}: ${render(value)} encoded as ${Str.inspect(encoded)} did not decode"
	}
}

## Floats encode through `Json.to_str_try`, which rejects non-finite values.
float_round_trip! = |label, value, finite, parse, render| match Json.to_str_try(value) {
	Ok(encoded) => match parse(encoded) {
		Ok(back) if render(back) == render(value) => {}
		Ok(back) => crash "${label}: ${render(value)} encoded as ${Str.inspect(encoded)} decoded as ${render(back)}"
		Err(_) => crash "${label}: ${render(value)} encoded as ${Str.inspect(encoded)} did not decode"
	}
	Err(_) => if finite crash "${label}: finite ${render(value)} could not be encoded" else {}
}

check! : Case => {}
check! = |case| {
	text = Str.from_utf8_lossy(whitespace(case.lead).concat(case.body).concat(whitespace(case.trail)))
	check_texts!(text)
	a = case.a
	wide = a.to_u128() * 18446744073709551616 + case.b.to_u128()
	round_trip!("U8", a.to_u8_wrap(), parse_u8, U8.to_str)
	round_trip!("I8", a.to_i8_wrap(), parse_i8, I8.to_str)
	round_trip!("U16", a.to_u16_wrap(), parse_u16, U16.to_str)
	round_trip!("I16", a.to_i16_wrap(), parse_i16, I16.to_str)
	round_trip!("U32", a.to_u32_wrap(), parse_u32, U32.to_str)
	round_trip!("I32", a.to_i32_wrap(), parse_i32, I32.to_str)
	round_trip!("U64", a, parse_u64, U64.to_str)
	round_trip!("I64", a.to_i64_wrap(), parse_i64, I64.to_str)
	round_trip!("U128", wide, parse_u128, U128.to_str)
	round_trip!("I128", wide.to_i128_wrap(), parse_i128, I128.to_str)
	f32 = F32.from_bits(a.to_u32_wrap())
	float_round_trip!("F32", f32, f32.is_finite(), parse_f32, f32_bits)
	f64 = F64.from_bits(a)
	float_round_trip!("F64", f64, f64.is_finite(), parse_f64, f64_bits)
	magnitude = wide % 170141183460469231731687303715884105728
	match Dec.from_str(NumText.scaled_text(case.b % 2 == 0, magnitude)) {
		Ok(dec) => round_trip!("Dec", dec, parse_dec, Dec.to_str)
		Err(_) => crash "canonical Dec text was rejected"
	}
}

test! : Case => Fuzz.Outcome
test! = |case| {
	Fuzz.expect_no_leaks!(|{}| check!(case))
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "jsonNumberPrefix",
	generator,
	test!,
	show: |case| Str.inspect(case),
})
