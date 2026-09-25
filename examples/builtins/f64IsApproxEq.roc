app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-19-d025939" }

import fuzz.Fuzz

Input := { a : F64, b_raw : F64, b_mode : U8, ulps : U8, rel_raw : U64, rel_mode : U8, abs_raw : F64, abs_mode : U8 }.{
	generator_for : Fuzz.FuzzEncoding -> Fuzz.Generator(Input)
	generator_for = |_| {
		{
			a: Fuzz.f64,
			b_raw: Fuzz.f64,
			b_mode: Fuzz.u8_in(0, 5),
			ulps: Fuzz.u8_in(0, 8),
			rel_raw: Fuzz.u64,
			rel_mode: Fuzz.u8_in(0, 3),
			abs_raw: Fuzz.f64,
			abs_mode: Fuzz.u8_in(0, 3),
		}.Fuzz
	}
}

## Derive `b` from `a` most of the time, so the fuzzer spends its effort near
## the tolerance boundary instead of on unrelated pairs that are never close.
pick_b : Input -> F64
pick_b = |input|
	match input.b_mode {
		0 => input.b_raw
		1 => input.a
		2 => F64.negate(input.a)
		3 => F64.from_bits(U64.plus_wrap(F64.to_bits(input.a), U8.to_u64(input.ulps)))
		4 => F64.from_bits(U64.minus_wrap(F64.to_bits(input.a), U8.to_u64(input.ulps)))
		_ => input.a + input.b_raw * 1e-9
	}

## Only valid tolerances are generated (`0 <= rel <= 1`, `abs` finite and
## non-negative): an invalid tolerance crashes by design, and every crash is a
## finding.
pick_rel : Input -> F64
pick_rel = |input| {
	fraction = F64.min(1.0, U64.to_f64(input.rel_raw) / U64.to_f64(U64.highest))
	match input.rel_mode {
		0 => 0.0
		1 => 1.0
		2 => fraction
		_ => fraction * fraction * fraction * 1e-6
	}
}

pick_abs : Input -> F64
pick_abs = |input| {
	magnitude = if F64.is_finite(input.abs_raw) F64.abs(input.abs_raw) else 0.0
	match input.abs_mode {
		0 => 0.0
		1 => magnitude
		2 => 1e-12
		_ => magnitude * 1e-30
	}
}

## Independent reference for `|a - b| <= max(abs, rel * max(|a|, |b|))`,
## written with plain comparisons instead of `is_float_eq`/`is_finite`/`abs`,
## and with the difference taken as `max - min` rather than `abs(a - b)`.
finite_ref : F64 -> Bool
finite_ref = |x| x - x <= 0.0 and x - x >= 0.0

reference : F64, F64, F64, F64 -> Bool
reference = |a, b, rel, abs| {
	if a <= b and a >= b {
		True
	} else if finite_ref(a) and finite_ref(b) {
		diff = F64.max(a, b) - F64.min(a, b)
		magnitude = F64.max(F64.max(a, 0.0 - a), F64.max(b, 0.0 - b))
		scaled = rel * magnitude
		bound = if abs > scaled abs else scaled
		diff <= bound
	} else {
		False
	}
}

## `F64.is_approx_eq` must match the reference definition, be symmetric,
## reject NaN, be reflexive for every non-NaN value, be monotonic in both
## tolerances, reduce to `is_float_eq` with zero tolerances, and never
## allocate.
test! : Input => Fuzz.Outcome
test! = |input| {
	a = input.a
	b = pick_b(input)
	rel = pick_rel(input)
	abs = pick_abs(input)
	tol = { rel, abs }

	result = Fuzz.expect_allocs_at_most!(0, |{}| F64.is_approx_eq(a, b, tol))

	if result != reference(a, b, rel, abs) {
		crash "F64.is_approx_eq disagreed with the reference definition"
	}

	if result != F64.is_approx_eq(b, a, tol) {
		crash "F64.is_approx_eq was not symmetric"
	}

	if (F64.is_nan(a) or F64.is_nan(b)) and result {
		crash "F64.is_approx_eq accepted NaN"
	}

	if !F64.is_nan(a) and !F64.is_approx_eq(a, a, tol) {
		crash "F64.is_approx_eq was not reflexive"
	}

	doubled_abs = if F64.is_finite(abs * 2.0) abs * 2.0 else abs
	looser = { rel: F64.min(1.0, rel * 2.0), abs: doubled_abs }
	if result and !F64.is_approx_eq(a, b, looser) {
		crash "F64.is_approx_eq was not monotonic in its tolerances"
	}

	if F64.is_approx_eq(a, b, { rel: 0.0, abs: 0.0 }) != F64.is_float_eq(a, b) {
		crash "F64.is_approx_eq with zero tolerances differed from is_float_eq"
	}

	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "f64IsApproxEq",
	generator: Input.generator_for(Fuzz.FuzzEncoding.Default),
	test!,
	show: |input| Str.inspect(input),
})
