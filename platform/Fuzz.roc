import Arbitrary exposing [Arbitrary]
import Target exposing [Target]

Fuzz := [].{

	## Reject tells the runner that a generated value is outside the useful
	## input domain. A crash or failed expect remains a fuzz failure.
	Outcome := [Keep, Reject]

	keep : Outcome
	keep = Keep

	reject : Outcome
	reject = Reject

	## A generator consumes deterministic entropy and returns its remaining state.
	Generator(a) : Arbitrary -> { value : a, state : Arbitrary }

	## The marker passed to generator_for leaves room for future policies.
	FuzzEncoding := [Default]

	## Resolve a.generator_for at compile time, following Json.parser_for's
	## Shape/method pattern.
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

	## Construct a target from an explicit generator for one-off structural types.
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

	constant : a -> Generator(a)
	constant = |value| |state| { value, state }

	map : Generator(a), (a -> b) -> Generator(b)
	map = |generator, transform| |state| {
		generated = generator(state)
		{ value: transform(generated.value), state: generated.state }
	}

	## Roc's `{ first: gen_a, second: gen_b }.Fuzz` record-builder syntax
	## lowers to this combinator and chains it for larger records.
	map2 : Generator(a), Generator(b), (a, b -> c) -> Generator(c)
	map2 = |first, second, combine| |state| {
		left = first(state)
		right = second(left.state)
		{ value: combine(left.value, right.value), state: right.state }
	}

	u8 : Generator(U8)
	u8 = |state| {
		generated = state.u64_in_inclusive_range(0, 255)
		{ value: U64.to_u8_wrap(generated.value), state: generated.state }
	}

	u8_in : U8, U8 -> Generator(U8)
	u8_in = |low, high| |state| {
		generated = state.u64_in_inclusive_range(U8.to_u64(low), U8.to_u64(high))
		{ value: U64.to_u8_wrap(generated.value), state: generated.state }
	}

	u64 : Generator(U64)
	u64 = |state| state.u64_in_inclusive_range(0, U64.highest)

	u64_in : U64, U64 -> Generator(U64)
	u64_in = |low, high| |state| state.u64_in_inclusive_range(low, high)

	bytes : Generator(List(U8))
	bytes = |state| state.arbitrary_list_u8()

	str : Generator(Str)
	str = |state| state.arbitrary_str()

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
