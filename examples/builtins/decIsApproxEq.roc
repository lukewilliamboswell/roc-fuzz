app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-19-d025939" }

import fuzz.Fuzz

Input := { a_hi : U64, a_lo : U64, a_mode : U8, b_hi : U64, b_lo : U64, b_mode : U8, delta : U64, rel_raw : U64, rel_mode : U8, abs_raw : U64, abs_mode : U8 }.{
	generator_for : Fuzz.FuzzEncoding -> Fuzz.Generator(Input)
	generator_for = |_| {
		{
			a_hi: Fuzz.u64,
			a_lo: Fuzz.u64,
			a_mode: Fuzz.u8_in(0, 5),
			b_hi: Fuzz.u64,
			b_lo: Fuzz.u64,
			b_mode: Fuzz.u8_in(0, 5),
			delta: Fuzz.u64,
			rel_raw: Fuzz.u64,
			rel_mode: Fuzz.u8_in(0, 3),
			abs_raw: Fuzz.u64,
			abs_mode: Fuzz.u8_in(0, 3),
		}.Fuzz
	}
}

attos_from : U64, U64 -> I128
attos_from = |hi, lo| I128.bitwise_or(I128.shl_wrap(U64.to_i128(hi), 64), U64.to_i128(lo))

## Biased toward the extremes, where `abs` and subtraction can overflow.
pick_a : Input -> Dec
pick_a = |input|
	match input.a_mode {
		0 => Dec.lowest
		1 => Dec.highest
		2 => Dec.from_attos(U64.to_i128(input.a_lo))
		3 => Dec.from_attos(0 - U64.to_i128(input.a_lo))
		_ => Dec.from_attos(attos_from(input.a_hi, input.a_lo))
	}

## `b` is usually a small offset from `a`, so pairs land near the tolerance.
pick_b : Input, Dec -> Dec
pick_b = |input, a| {
	offset = Dec.from_attos(U64.to_i128(input.delta))
	match input.b_mode {
		0 => Dec.from_attos(attos_from(input.b_hi, input.b_lo))
		1 => a
		2 => Dec.plus_try(a, offset) ?? a
		3 => Dec.minus_try(a, offset) ?? a
		4 => if a == Dec.lowest Dec.highest else Dec.negate(a)
		_ => Dec.lowest
	}
}

one_attos : I128
one_attos = 1_000_000_000_000_000_000

## Only valid tolerances are generated (`0 <= rel <= 1`, `abs >= 0`): an
## invalid tolerance crashes by design, and every crash is a finding.
pick_rel : Input -> Dec
pick_rel = |input|
	match input.rel_mode {
		0 => 0.0
		1 => 1.0
		2 => Dec.from_attos(U64.to_i128(input.rel_raw) % (one_attos + 1))
		_ => Dec.from_attos(U64.to_i128(input.rel_raw) % 1_000_000)
	}

pick_abs : Input -> Dec
pick_abs = |input|
	match input.abs_mode {
		0 => 0.0
		1 => Dec.from_attos(U64.to_i128(input.abs_raw))
		2 => Dec.from_attos(I128.shl_wrap(U64.to_i128(input.abs_raw), 63))
		_ => Dec.highest
	}

## Reference with the difference computed in raw `I128` attos, independently
## of `Dec` subtraction and `Dec.abs`. A difference that overflows `I128`
## exceeds every valid tolerance.
reference : Dec, Dec, Dec, Dec -> Bool
reference = |a, b, rel, abs| {
	a_attos = Dec.to_attos(a)
	b_attos = Dec.to_attos(b)
	larger = if a_attos > b_attos a_attos else b_attos
	smaller = if a_attos > b_attos b_attos else a_attos
	match I128.minus_try(larger, smaller) {
		Err(_) => False
		Ok(diff) => {
			magnitude = if a == Dec.lowest or b == Dec.lowest {
				Dec.highest
			} else {
				Dec.max(Dec.abs(a), Dec.abs(b))
			}
			scaled = rel * magnitude
			bound = if abs > scaled abs else scaled
			diff <= Dec.to_attos(bound)
		}
	}
}

## `Dec.is_approx_eq` must never crash on valid tolerances (including at
## `Dec.lowest`/`Dec.highest`), match the reference, be symmetric, reflexive
## and monotonic, reduce to `==` with zero tolerances, and never allocate.
test! : Input => Fuzz.Outcome
test! = |input| {
	a = pick_a(input)
	b = pick_b(input, a)
	rel = pick_rel(input)
	abs = pick_abs(input)
	tol = { rel, abs }

	result = Fuzz.expect_allocs_at_most!(0, |{}| Dec.is_approx_eq(a, b, tol))

	if result != reference(a, b, rel, abs) {
		crash "Dec.is_approx_eq disagreed with the reference definition"
	}

	if result != Dec.is_approx_eq(b, a, tol) {
		crash "Dec.is_approx_eq was not symmetric"
	}

	if !Dec.is_approx_eq(a, a, tol) {
		crash "Dec.is_approx_eq was not reflexive"
	}

	looser = { rel: Dec.min(1.0, rel * 2.0), abs: Dec.plus_try(abs, abs) ?? abs }
	if result and !Dec.is_approx_eq(a, b, looser) {
		crash "Dec.is_approx_eq was not monotonic in its tolerances"
	}

	if Dec.is_approx_eq(a, b, { rel: 0.0, abs: 0.0 }) != (a == b) {
		crash "Dec.is_approx_eq with zero tolerances differed from =="
	}

	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "decIsApproxEq",
	generator: Input.generator_for(Fuzz.FuzzEncoding.Default),
	test!,
	show: |input| Str.inspect(input),
})
