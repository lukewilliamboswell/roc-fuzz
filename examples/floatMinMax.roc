app [target] { fuzz: platform "../platform/main.roc" }

import fuzz.Fuzz

Input := { left : F64, right : F64 }.{
	generator_for : Fuzz.FuzzEncoding -> Fuzz.Generator(Input)
	generator_for = |_| {
		{
			left: Fuzz.f64,
			right: Fuzz.f64,
		}.Fuzz
	}
}

## `F64.min` and `F64.max` must agree on which of two values is smaller.
##
## `NaN` is outside the property's domain because it does not compare equal to
## anything, including itself, so those inputs are rejected rather than tested.
## Every other value `Fuzz.f64` produces is fair game, including the infinities,
## both zeros, and the subnormals.
##
## Allocation invariant: comparing two `F64` values is a pure numeric
## operation, so `F64.min`/`F64.max` must not allocate.
test! : Input => Fuzz.Outcome
test! = |input| {
	if F64.is_nan(input.left) or F64.is_nan(input.right) {
		return Fuzz.reject
	}

	before = Fuzz.alloc_count!()
	smaller = F64.min(input.left, input.right)
	larger = F64.max(input.left, input.right)
	after = Fuzz.alloc_count!()
	if after != before {
		crash "F64.min/F64.max allocated ${(after - before).to_str()} times (expected 0)"
	}

	if smaller > larger {
		crash "min returned a value above max"
	}

	if !(smaller == input.left or smaller == input.right) {
		crash "min returned a value that was not an input"
	}

	if !(larger == input.left or larger == input.right) {
		crash "max returned a value that was not an input"
	}

	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "floatMinMax",
	generator: Input.generator_for(Fuzz.FuzzEncoding.Default),
	test!,
	show: |input| Str.inspect(input),
})
