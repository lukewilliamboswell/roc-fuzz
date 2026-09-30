app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-19-d025939" }

import fuzz.Fuzz

Input := { hi : U64, lo : U64, value_mode : U8, offset_mode : U8, step_raw : U64, step_exp : U8, step_mode : U8, even : Bool }.{
	generator_for : Fuzz.FuzzEncoding -> Fuzz.Generator(Input)
	generator_for = |_| {
		{
			hi: Fuzz.u64,
			lo: Fuzz.u64,
			value_mode: Fuzz.u8_in(0, 4),
			offset_mode: Fuzz.u8_in(0, 6),
			step_raw: Fuzz.u64,
			step_exp: Fuzz.u8_in(0, 38),
			step_mode: Fuzz.u8_in(0, 5),
			even: Fuzz.map(Fuzz.u8_in(0, 1), |bit| bit == 1),
		}.Fuzz
	}
}

pow10 : U8 -> I128
pow10 = |exponent| if exponent == 0 1 else 10 * pow10(exponent - 1)

attos_from : U64, U64 -> I128
attos_from = |hi, lo| I128.bitwise_or(I128.shl_wrap(U64.to_i128(hi), 64), U64.to_i128(lo))

positive : I128 -> I128
positive = |attos|
	if attos > 0 {
		attos
	} else if attos == 0 {
		1
	} else if attos == I128.lowest {
		I128.highest
	} else {
		0 - attos
	}

## Always positive: a non-positive step crashes by design, and every crash is
## a finding.
pick_step : Input -> I128
pick_step = |input| {
	raw = U64.to_i128(input.step_raw)
	match input.step_mode {
		0 => 1
		1 => pow10(input.step_exp)
		2 => pow10(input.step_exp % 19) * (raw % 20 + 1)
		3 => raw + 1
		4 => positive(attos_from(input.step_raw, input.lo))
		_ => Dec.to_attos(Dec.highest)
	}
}

## Most values sit on or next to a multiple of the step, so ties and the
## halfway boundary get hit constantly.
pick_value : Input, I128 -> I128
pick_value = |input, step| {
	base = match input.value_mode {
		0 => Dec.to_attos(Dec.lowest)
		1 => Dec.to_attos(Dec.highest)
		2 => U64.to_i128(input.lo)
		3 => 0 - U64.to_i128(input.lo)
		_ => attos_from(input.hi, input.lo)
	}
	multiple = I128.times_wrap(I128.div_trunc_by(base, step), step)
	half = I128.div_trunc_by(step, 2)
	match input.offset_mode {
		0 => base
		1 => multiple
		2 => I128.plus_wrap(multiple, half)
		3 => I128.minus_wrap(multiple, half)
		4 => I128.plus_wrap(I128.plus_wrap(multiple, half), 1)
		5 => I128.minus_wrap(I128.plus_wrap(multiple, half), 1)
		_ => I128.plus_wrap(multiple, U64.to_i128(input.hi % 1000))
	}
}

## Independent reference, built on floored division and the Euclidean
## remainder instead of the builtin's truncated division.
reference : I128, I128, [AwayFromZero, ToEven] -> Try(Dec, [Overflow])
reference = |x, step, ties| {
	lower = I128.div_floor_by(x, step)
	below = I128.mod_by(x, step)
	above = step - below
	quotient = if below == 0 {
		lower
	} else if below < above {
		lower
	} else if below > above {
		lower + 1
	} else {
		match ties {
			AwayFromZero => if x >= 0 lower + 1 else lower
			ToEven => if I128.is_even(lower) lower else lower + 1
		}
	}
	match I128.times_try(quotient, step) {
		Ok(attos) => Ok(Dec.from_attos(attos))
		Err(_) => Err(Overflow)
	}
}

## `Dec.round_to_try` must match the reference, and `Dec.round_to` must agree
## with it. On success the result is a multiple of the step no more than half
## a step away, `ToEven` ties land on even multiples, rounding is idempotent
## and odd-symmetric, and nothing allocates.
test! : Input => Fuzz.Outcome
test! = |input| {
	step_attos = pick_step(input)
	x_attos = pick_value(input, step_attos)
	x = Dec.from_attos(x_attos)
	step = Dec.from_attos(step_attos)
	ties = if input.even ToEven else AwayFromZero
	options = { step, ties }

	result = Fuzz.expect_allocs_at_most!(0, |{}| Dec.round_to_try(x, options))

	if result != reference(x_attos, step_attos, ties) {
		crash "Dec.round_to_try disagreed with the reference"
	}

	match result {
		Err(Overflow) => Fuzz.keep
		Ok(rounded) => {
			if Dec.round_to(x, options) != rounded {
				crash "Dec.round_to disagreed with Dec.round_to_try"
			}

			rounded_attos = Dec.to_attos(rounded)
			if I128.mod_by(rounded_attos, step_attos) != 0 {
				crash "Dec.round_to returned a value that is not a multiple of step"
			}

			distance = match I128.minus_try(rounded_attos, x_attos) {
				Ok(d) => I128.abs(d)
				Err(_) => {
					crash "Dec.round_to moved further than any step"
				}
			}
			if distance > step_attos - distance {
				crash "Dec.round_to moved more than half a step"
			}

			if input.even and distance == step_attos - distance and I128.is_odd(I128.div_trunc_by(rounded_attos, step_attos)) {
				crash "Dec.round_to with ToEven rounded a tie to an odd multiple"
			}

			if Dec.round_to(rounded, options) != rounded {
				crash "Dec.round_to was not idempotent"
			}

			if x != Dec.lowest and rounded != Dec.lowest {
				mirrored = Dec.round_to_try(Dec.negate(x), options)
				if mirrored != Ok(Dec.negate(rounded)) {
					crash "Dec.round_to was not symmetric under negation"
				}
			}

			Fuzz.keep
		}
	}
}

target = Fuzz.target_with!({
	name: "decRoundTo",
	generator: Input.generator_for(Fuzz.FuzzEncoding.Default),
	test!,
	show: |input| Str.inspect(input),
})
