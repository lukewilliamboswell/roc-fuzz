app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-19-d025939" }

import pf.Fuzz

# Compose two typed float generators; both include arbitrary bits and IEEE edges.
Input : { x : F64, y : F64 }

signed : F64, F64 -> F64
signed = |magnitude, sign_source| F64.from_bits(magnitude.to_bits().bitwise_or(sign_source.to_bits().bitwise_and(0x8000000000000000)))

test : Input -> Fuzz.Outcome
test = |{ x, y }| {
	unary = F64.atan(y)
	if y.is_nan() {
		if !unary.is_nan() {
			crash "atan(NaN) must be NaN"
		}
	} else {
		if !unary.is_finite() or unary.abs() > F64.pi / 2 {
			crash "atan outside its range"
		}
		if unary.to_bits() != F64.atan(y.negate()).negate().to_bits() {
			crash "atan must be odd, including signed zero"
		}
	}

	angle = F64.atan2({ x, y })
	if x.is_nan() or y.is_nan() {
		if !angle.is_nan() {
			crash "atan2 must propagate NaN"
		}
		return Fuzz.keep
	}
	if !angle.is_finite() or angle.abs() > F64.pi {
		crash "atan2 outside its range"
	}
	if angle.to_bits().bitwise_and(0x8000000000000000) != y.to_bits().bitwise_and(0x8000000000000000) {
		crash "atan2 must preserve the sign of y"
	}
	if angle.to_bits() != F64.atan2({ x, y: y.negate() }).negate().to_bits() {
		crash "atan2 must be odd in y"
	}

	x_negative = x.to_bits().bitwise_and(0x8000000000000000) != 0
	if y == 0 {
		expected = signed(
			if x_negative {
				F64.pi
			} else {
				0
			},
			y,
		)
		if angle.to_bits() != expected.to_bits() {
			crash "atan2 signed-zero branch cut"
		}
	} else if x == 0 {
		if angle.to_bits() != signed(F64.pi / 2, y).to_bits() {
			crash "atan2 y-axis"
		}
	} else if x.is_infinite() and y.is_infinite() {
		expected = signed(
			if x_negative {
				3 * F64.pi / 4
			} else {
				F64.pi / 4
			},
			y,
		)
		if angle.to_bits() != expected.to_bits() {
			crash "atan2 infinite diagonal"
		}
	} else if y.is_infinite() {
		if angle.to_bits() != signed(F64.pi / 2, y).to_bits() {
			crash "atan2 infinite y"
		}
	} else if x.is_infinite() {
		expected = signed(
			if x_negative {
				F64.pi
			} else {
				0
			},
			y,
		)
		if angle.to_bits() != expected.to_bits() {
			crash "atan2 infinite x"
		}
	} else {
		# Finite transcendental results are approximate; allow two ULP at the axis.
		axis_error = U64.abs_diff(angle.abs().to_bits(), (F64.pi / 2).to_bits())
		if x > 0 and angle.abs() > F64.pi / 2 and axis_error > 2 {
			crash "atan2 right-half-plane quadrant"
		}
		if x < 0 and angle.abs() < F64.pi / 2 and axis_error > 2 {
			crash "atan2 left-half-plane quadrant"
		}
		# Compare the resulting direction with independently normalized coordinates.
		# Scaling before squaring avoids overflow and keeps sqrt's argument in [1, 2].
		scale = x.abs().max(y.abs())
		sx = x / scale
		sy = y / scale
		length = (sx * sx + sy * sy).sqrt()
		if (angle.sin() - sy / length).abs() > 0.000000000000003 {
			crash "atan2 sine does not match the input direction"
		}
		if (angle.cos() - sx / length).abs() > 0.000000000000003 {
			crash "atan2 cosine does not match the input direction"
		}
	}
	Fuzz.keep
}

## Numeric arctangent checks must not allocate heap memory.
test! : Input => Fuzz.Outcome
test! = |input| Fuzz.expect_allocs_at_most!(0, |{}| test(input))

target = Fuzz.target_with!({
	name: "arctangentF64",
	generator: { x: Fuzz.f64, y: Fuzz.f64 }.Fuzz,
	test!,
	show: |{ x, y }| Str.inspect({ x, y, x_bits: x.to_bits(), y_bits: y.to_bits(), angle_bits: F64.atan2({ x, y }).to_bits() }),
})
