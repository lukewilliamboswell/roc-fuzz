app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-19-d025939" }

import pf.Fuzz

# Compose integer generators into a full-width Dec, then vary its magnitude.
# Every signed 128-bit payload is reachable (with shift = 0); larger shifts
# also exercise tiny values instead of concentrating near Dec's limits.
decimal : Fuzz.Generator(Dec)
decimal = Fuzz.map(
	{ high: Fuzz.u64, low: Fuzz.u64, shift: Fuzz.u8_in(0, 127) }.Fuzz,
	|{ high, low, shift }| {
		bits = high.to_u128().shl_wrap(64).bitwise_or(low.to_u128())
		Dec.from_attos(bits.to_i128_wrap().shr_wrap(shift))
	},
)

Input : { x : Dec, y : Dec }

test : Input -> Fuzz.Outcome
test = |{ x, y }| {
	tolerance = 0.000000000000000128
	angle = Dec.atan2({ x, y })
	unary = Dec.atan(y)
	if angle.abs() > Dec.pi + tolerance {
		crash "Dec.atan2 outside its range"
	}
	if unary.abs() > Dec.pi / 2 + tolerance {
		crash "Dec.atan outside its range"
	}
	if (unary - Dec.atan2({ x: 1, y })).abs() > tolerance {
		crash "Dec atan and atan2(1,y) disagree"
	}

	# The independent floating implementation catches gross numerical errors.
	# Allow conversion and binary64 rounding error; tight Dec accuracy is checked
	# separately by the builtin's f128 oracle tests.
	reference = F64.atan2({ x: x.to_f64(), y: y.to_f64() })
	if (angle.to_f64() - reference).abs() > 0.000000000000004 {
		crash "Dec.atan2 disagrees with the floating reference"
	}
	if (unary.to_f64() - F64.atan(y.to_f64())).abs() > 0.000000000000004 {
		crash "Dec.atan disagrees with the floating reference"
	}

	if y == 0 {
		if unary != 0 {
			crash "Dec.atan(0) must be zero"
		}
		expected = if x < 0 {
			Dec.pi
		} else {
			0
		}
		if angle != expected {
			crash "Dec.atan2 x-axis or origin"
		}
	} else {
		if y > 0 and angle < -tolerance {
			crash "Dec.atan2 upper-half-plane sign"
		}
		if y < 0 and angle > tolerance {
			crash "Dec.atan2 lower-half-plane sign"
		}
		if x == 0 {
			expected = if y > 0 {
				Dec.pi / 2
			} else {
				-Dec.pi / 2
			}
			if angle != expected {
				crash "Dec.atan2 y-axis"
			}
		}
		# Dec.lowest cannot be negated. It is still covered by all checks above.
		if y != Dec.lowest {
			if (angle + Dec.atan2({ x, y: -y })).abs() > tolerance {
				crash "Dec.atan2 must be approximately odd in y"
			}
			if (unary + Dec.atan(-y)).abs() > tolerance {
				crash "Dec.atan must be approximately odd"
			}
		}
	}
	Fuzz.keep
}

## Numeric arctangent checks must not allocate heap memory.
test! : Input => Fuzz.Outcome
test! = |input| Fuzz.expect_allocs_at_most!(0, |{}| test(input))

target = Fuzz.target_with!({ name: "arctangentDec", generator: { x: decimal, y: decimal }.Fuzz, test!, show: |input| Str.inspect(input) })
