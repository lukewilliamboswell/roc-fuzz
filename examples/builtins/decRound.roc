app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-19-d025939" }

import fuzz.Fuzz

Input := { hi : U64, lo : U64, mode : U8, fraction : U64 }.{
	generator_for : Fuzz.FuzzEncoding -> Fuzz.Generator(Input)
	generator_for = |_| {
		{
			hi: Fuzz.u64,
			lo: Fuzz.u64,
			mode: Fuzz.u8_in(0, 7),
			fraction: Fuzz.u64,
		}.Fuzz
	}
}

one : I128
one = 1_000_000_000_000_000_000

half : I128
half = 500_000_000_000_000_000

## Biased toward whole numbers, exact halves, values one atto either side of
## a half, and the extremes where rounding overflows.
pick_value : Input -> I128
pick_value = |input| {
	raw = I128.bitwise_or(I128.shl_wrap(U64.to_i128(input.hi), 64), U64.to_i128(input.lo))
	whole = I128.times_wrap(I128.div_trunc_by(raw, one), one)
	sign = if raw < 0 -1 else 1
	match input.mode {
		0 => Dec.to_attos(Dec.lowest)
		1 => Dec.to_attos(Dec.highest)
		2 => whole
		3 => I128.plus_wrap(whole, sign * half)
		4 => I128.plus_wrap(whole, sign * (half - 1))
		5 => I128.plus_wrap(whole, sign * (half + 1))
		6 => I128.plus_wrap(whole, sign * (U64.to_i128(input.fraction) % one))
		_ => raw
	}
}

to_dec_try : Try(I128, _) -> Try(Dec, [Overflow])
to_dec_try = |attos|
	match attos {
		Ok(value) => Ok(Dec.from_attos(value))
		Err(_) => Err(Overflow)
	}

## Independent references, built on the Euclidean remainder (`mod_by`) and
## checked `I128` arithmetic rather than the builtins' division helpers.
floor_ref : I128 -> Try(Dec, [Overflow])
floor_ref = |x| to_dec_try(I128.minus_try(x, I128.mod_by(x, one)))

ceiling_ref : I128 -> Try(Dec, [Overflow])
ceiling_ref = |x| {
	below = I128.mod_by(x, one)
	if below == 0 Ok(Dec.from_attos(x)) else to_dec_try(I128.plus_try(x, one - below))
}

round_ref : I128 -> Try(Dec, [Overflow])
round_ref = |x| {
	below = I128.mod_by(x, one)
	if below < half {
		floor_ref(x)
	} else if below > half {
		ceiling_ref(x)
	} else if x >= 0 {
		ceiling_ref(x)
	} else {
		floor_ref(x)
	}
}

## The whole-number rounding functions must match their references, agree
## with their `_try` forms and with `Dec.round_to`, bracket the input, mirror
## each other under negation, fix whole numbers, and never allocate.
test! : Input => Fuzz.Outcome
test! = |input| {
	x_attos = pick_value(input)
	x = Dec.from_attos(x_attos)

	{ rounded, floored, ceiled, truncated } = Fuzz.expect_allocs_at_most!(
		0,
		|{}| {
			rounded: Dec.round_try(x),
			floored: Dec.floor_try(x),
			ceiled: Dec.ceiling_try(x),
			truncated: Dec.trunc(x),
		},
	)

	if rounded != round_ref(x_attos) {
		crash "Dec.round_try disagreed with the reference"
	}
	if floored != floor_ref(x_attos) {
		crash "Dec.floor_try disagreed with the reference"
	}
	if ceiled != ceiling_ref(x_attos) {
		crash "Dec.ceiling_try disagreed with the reference"
	}
	if Dec.to_attos(truncated) != x_attos - I128.rem_by(x_attos, one) {
		crash "Dec.trunc disagreed with the reference"
	}

	if rounded != Dec.round_to_try(x, { step: 1.0, ties: AwayFromZero }) {
		crash "Dec.round_try disagreed with Dec.round_to_try at step 1"
	}

	match rounded {
		Ok(r) => if Dec.round(x) != r {
			crash "Dec.round disagreed with Dec.round_try"
		}
		Err(_) => {}
	}
	match floored {
		Ok(f) => {
			if Dec.floor(x) != f {
				crash "Dec.floor disagreed with Dec.floor_try"
			}
			if f > x {
				crash "Dec.floor returned a value above its input"
			}
			if Dec.floor_try(f) != Ok(f) {
				crash "Dec.floor did not fix a whole number"
			}
		}
		Err(_) => {}
	}
	match ceiled {
		Ok(c) => {
			if Dec.ceiling(x) != c {
				crash "Dec.ceiling disagreed with Dec.ceiling_try"
			}
			if c < x {
				crash "Dec.ceiling returned a value below its input"
			}
		}
		Err(_) => {}
	}

	match (floored, ceiled) {
		(Ok(f), Ok(c)) => if !(c == f or c == f + 1.0) {
			crash "Dec.ceiling and Dec.floor were not adjacent whole numbers"
		}
		_ => {}
	}

	if x >= 0.0 and Ok(truncated) != floored {
		crash "Dec.trunc of a non-negative value differed from Dec.floor"
	}
	if x < 0.0 and Ok(truncated) != ceiled {
		crash "Dec.trunc of a negative value differed from Dec.ceiling"
	}

	if x != Dec.lowest {
		negated = Dec.negate(x)
		match floored {
			Ok(f) if f != Dec.lowest => if Dec.ceiling_try(negated) != Ok(Dec.negate(f)) {
				crash "Dec.floor(x) was not -Dec.ceiling(-x)"
			}
			_ => {}
		}
		match rounded {
			Ok(r) if r != Dec.lowest => if Dec.round_try(negated) != Ok(Dec.negate(r)) {
				crash "Dec.round was not symmetric under negation"
			}
			_ => {}
		}
	}

	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "decRound",
	generator: Input.generator_for(Fuzz.FuzzEncoding.Default),
	test!,
	show: |input| Str.inspect(input),
})
