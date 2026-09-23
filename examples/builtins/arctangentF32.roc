app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-19-d025939" }

import pf.Fuzz

# Compose two typed float generators; both include arbitrary bits and IEEE edges.
Input : { x : F32, y : F32 }

signed : F32, F32 -> F32
signed = |magnitude, sign_source| F32.from_bits(magnitude.to_bits().bitwise_or(sign_source.to_bits().bitwise_and(0x80000000)))

test : Input -> Fuzz.Outcome
test = |{ x, y }| {
	unary = F32.atan(y)
	if y.is_nan() {
		if !unary.is_nan() {
			crash "atan(NaN) must be NaN"
		}
	} else {
		if !unary.is_finite() or unary.abs() > F32.pi / 2 {
			crash "atan outside its range"
		}
		if unary.to_bits() != F32.atan(y.negate()).negate().to_bits() {
			crash "atan must be odd, including signed zero"
		}
	}

	angle = F32.atan2({ x, y })
	if x.is_nan() or y.is_nan() {
		if !angle.is_nan() {
			crash "atan2 must propagate NaN"
		}
		return Fuzz.keep
	}
	if !angle.is_finite() or angle.abs() > F32.pi {
		crash "atan2 outside its range"
	}
	if angle.to_bits().bitwise_and(0x80000000) != y.to_bits().bitwise_and(0x80000000) {
		crash "atan2 must preserve the sign of y"
	}
	if angle.to_bits() != F32.atan2({ x, y: y.negate() }).negate().to_bits() {
		crash "atan2 must be odd in y"
	}

	x_negative = x.to_bits().bitwise_and(0x80000000) != 0
	if y == 0 {
		expected = signed(
			if x_negative {
				F32.pi
			} else {
				0
			},
			y,
		)
		if angle.to_bits() != expected.to_bits() {
			crash "atan2 signed-zero branch cut"
		}
	} else if x == 0 {
		if angle.to_bits() != signed(F32.pi / 2, y).to_bits() {
			crash "atan2 y-axis"
		}
	} else if x.is_infinite() and y.is_infinite() {
		expected = signed(
			if x_negative {
				3 * F32.pi / 4
			} else {
				F32.pi / 4
			},
			y,
		)
		if angle.to_bits() != expected.to_bits() {
			crash "atan2 infinite diagonal"
		}
	} else if y.is_infinite() {
		if angle.to_bits() != signed(F32.pi / 2, y).to_bits() {
			crash "atan2 infinite y"
		}
	} else if x.is_infinite() {
		expected = signed(
			if x_negative {
				F32.pi
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
		axis_error = U32.abs_diff(angle.abs().to_bits(), (F32.pi / 2).to_bits())
		if x > 0 and angle.abs() > F32.pi / 2 and axis_error > 2 {
			crash "atan2 right-half-plane quadrant"
		}
		if x < 0 and angle.abs() < F32.pi / 2 and axis_error > 2 {
			crash "atan2 left-half-plane quadrant"
		}
		# Binary64 supplies an independent-width numerical comparison.
		reference = F64.atan2({ x: x.to_f64(), y: y.to_f64() }).to_f32_wrap()
		if U32.abs_diff(angle.to_bits(), reference.to_bits()) > 2 {
			crash "F32 atan2 differs from binary64 reference by more than 2 ULP"
		}
		unary_reference = F64.atan(y.to_f64()).to_f32_wrap()
		if U32.abs_diff(unary.to_bits(), unary_reference.to_bits()) > 2 {
			crash "F32 atan differs from binary64 reference by more than 2 ULP"
		}
	}
	Fuzz.keep
}

## Numeric arctangent checks must not allocate heap memory.
test! : Input => Fuzz.Outcome
test! = |input| Fuzz.expect_allocs_at_most!(0, |{}| test(input))

target = Fuzz.target_with!({
	name: "arctangentF32",
	generator: { x: Fuzz.f32, y: Fuzz.f32 }.Fuzz,
	test!,
	show: |{ x, y }| Str.inspect({ x, y, x_bits: x.to_bits(), y_bits: y.to_bits(), angle_bits: F32.atan2({ x, y }).to_bits(), reference_bits: F64.atan2({ x: x.to_f64(), y: y.to_f64() }).to_f32_wrap().to_bits() }),
})
