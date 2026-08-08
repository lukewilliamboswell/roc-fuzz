import Arbitrary exposing [Arbitrary]
import Target exposing [Target]

## Define typed, deterministic inputs and the pure property that roc-fuzz tests.
##
## Most targets use [`target`](#Fuzz.target), return [`keep`](#Fuzz.keep) for useful
## inputs, and build their input generator from `u8`, `u64`, `str`, `bytes`,
## and `list`. Generators for record fields compose with Roc's `.Fuzz` record
## builder.
##
## ```roc
## Input := { bytes : List(U8), radix : U8 }.{
## 	generator_for = |_| {
## 		{ bytes: Fuzz.bytes, radix: Fuzz.u8_in(2, 36) }.Fuzz
## 	}
## }
##
## target = Fuzz.target({
## 	name: "decode",
## 	test: |input| if input.bytes.is_empty() Fuzz.reject else Fuzz.keep,
## 	show: Str.inspect,
## })
## ```
##
## Start with these typed combinators. [`target_with`](#Fuzz.target_with),
## [`from_bytes`](#Fuzz.from_bytes), and the `Arbitrary` module support advanced or
## migration use cases.
Fuzz := [].{

	## Whether a generated value belongs to the useful input domain.
	##
	## Return `Keep` after the property holds. Return `Reject` when a generated
	## value does not satisfy a precondition. A `crash` or failed `expect` is a
	## fuzz failure; `Reject` is not.
	Outcome := [Keep, Reject]

	## Mark a generated value as useful after the property has held.
	keep : Outcome
	keep = Keep

	## Discard a generated value that is outside the property's valid domain.
	##
	## Prefer generators that produce valid inputs directly. Use `reject` for
	## preconditions that are awkward or expensive to encode in a generator.
	reject : Outcome
	reject = Reject

	## A deterministic decoder from fuzzer bytes to a typed Roc value.
	##
	## Each generator returns the generated `value` and the unconsumed `state`, so
	## combinators can decode several values from one input. Most applications do
	## not need to inspect `Arbitrary` directly.
	Generator(a) : Arbitrary -> { value : a, state : Arbitrary }

	## Selects the generator used by a nominal type's `generator_for` method.
	##
	## `Default` is currently the only encoding. The marker gives static dispatch
	## the same shape as APIs such as `Json.parser_for` and leaves room for future
	## generation policies.
	FuzzEncoding := [Default]

	## Build a fuzz target using the input type's statically dispatched generator.
	##
	## The input type must define `generator_for : FuzzEncoding -> Generator(a)`.
	## For each fuzzer input, `target` generates one value, calls `test`, and uses
	## `show` when a person asks the runner to render that saved input.
	target : { name : Str, test : a -> Outcome, show : a -> Str } -> Target
		where [a.generator_for : FuzzEncoding -> Generator(a)]
	target = |config| {
		Shape : a
		generator = Shape.generator_for(Default)
		Fuzz.target_with({
			name: config.name,
			generator,
			test: config.test,
			show: config.show,
		})
	}

	## Build a target from an explicit generator.
	##
	## This is useful for a one-off structural input that does not need a nominal
	## `generator_for` method. Prefer [`target`](#Fuzz.target) when the input type owns
	## its generation policy.
	target_with : { name : Str, generator : Generator(a), test : a -> Outcome, show : a -> Str } -> Target
	target_with = |config|
		Target.new({
			name: config.name,
			run: |input| {
				generated = (config.generator)(Arbitrary.new(input))
				match (config.test)(generated.value) {
					Keep => 0
					Reject => 1
				}
			},
			show: |input| {
				generated = (config.generator)(Arbitrary.new(input))
				(config.show)(generated.value)
			},
		})

	## Adapt an existing `List(U8) -> U8` quality target.
	##
	## The returned byte is ignored; a `crash` or failed `expect` still reports a
	## failure. This is a migration bridge for existing byte-oriented targets.
	## New targets should prefer [`target`](#Fuzz.target) and typed generators.
	from_bytes : { name : Str, test : List(U8) -> U8 } -> Target
	from_bytes = |config|
		Fuzz.target_with({
			name: config.name,
			generator: Fuzz.raw_bytes,
			test: |input| {
				_ = (config.test)(input)
				Keep
			},
			show: |input| Str.inspect(input),
		})

	## Generate the same value without consuming any input bytes.
	constant : a -> Generator(a)
	constant = |value| |state| { value, state }

	## Transform the value produced by a generator while preserving its state.
	map : Generator(a), (a -> b) -> Generator(b)
	map = |generator, transform| |state| {
		generated = generator(state)
		{ value: transform(generated.value), state: generated.state }
	}

	## Generate two values in sequence and combine them.
	##
	## Roc's `{ first: gen_a, second: gen_b }.Fuzz` record-builder syntax lowers
	## to this combinator and chains it for larger records. Calling `map2`
	## directly is useful for tuples and custom constructors.
	map2 : Generator(a), Generator(b), (a, b -> c) -> Generator(c)
	map2 = |first, second, combine| |state| {
		left = first(state)
		right = second(left.state)
		{ value: combine(left.value, right.value), state: right.state }
	}

	## Generate any `U8` value.
	u8 : Generator(U8)
	u8 = |state| {
		generated = state.u64_in_inclusive_range(0, 255)
		{ value: U64.to_u8_wrap(generated.value), state: generated.state }
	}

	## Generate a `U8` in the inclusive range from `low` through `high`.
	##
	## The generator crashes if `low` is greater than `high`.
	u8_in : U8, U8 -> Generator(U8)
	u8_in = |low, high| |state| {
		generated = state.u64_in_inclusive_range(U8.to_u64(low), U8.to_u64(high))
		{ value: U64.to_u8_wrap(generated.value), state: generated.state }
	}

	## Generate any `U64` value.
	u64 : Generator(U64)
	u64 = |state| state.u64_in_inclusive_range(0, U64.highest)

	## Generate a `U64` in the inclusive range from `low` through `high`.
	##
	## The generator crashes if `low` is greater than `high`.
	u64_in : U64, U64 -> Generator(U64)
	u64_in = |low, high| |state| state.u64_in_inclusive_range(low, high)

	## Generate a byte list with a length and allocation shape chosen from input.
	##
	## Use [`raw_bytes`](#Fuzz.raw_bytes) when the target must receive every fuzzer
	## byte unchanged.
	bytes : Generator(List(U8))
	bytes = |state| state.arbitrary_list_u8()

	## Generate the complete fuzzer input as one byte list without decoding it.
	##
	## This is mainly useful for migration and byte-format targets. Typed targets
	## usually get better mutations and clearer properties from smaller
	## generators composed into their real input shape.
	raw_bytes : Generator(List(U8))
	raw_bytes = |state| {
		value: state.remaining(),
		state: Arbitrary.new([]),
	}

	## Generate a valid UTF-8 `Str` with varied length and allocation shape.
	str : Generator(Str)
	str = |state| state.arbitrary_str()

	## Generate a list containing at most `max_len` values.
	##
	## Lengths range from zero through `max_len`, inclusive. `max_len` limits the
	## decoded list length; the runner's maximum raw input size is configured
	## separately.
	list : Generator(a), U64 -> Generator(List(a))
	list = |item_generator, max_len| |initial_state| {
		length_choice = initial_state.u64_in_inclusive_range(0, max_len)
		var $state = length_choice.state
		var $items = []
		var $index = 0

		while $index < length_choice.value {
			generated = item_generator($state)
			$items = List.append($items, generated.value)
			$state = generated.state
			$index = $index + 1
		}

		{ value: $items, state: $state }
	}
}
