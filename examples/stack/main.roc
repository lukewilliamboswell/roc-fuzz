app [target] { fuzz: platform "../../platform/main.roc" }

import fuzz.Fuzz
import Stack
import "regressions/nonempty.bin" as regression_bytes : List(U8)

Input := { initial : List(U8), pushed : U8 }.{
	parser_for : _
	encoder_for : _

	generator_for : Fuzz.FuzzEncoding -> Fuzz.Generator(Input)
	generator_for = |_| {
		{
			initial: Fuzz.list(Fuzz.u8, 64),
			pushed: Fuzz.u8,
		}.Fuzz
	}
}

## `push`/`pop` each perform at most one allocation.
##
## `push` is `List.prepend`, which reallocates to shift every existing
## element over for the new one; `pop` slices off the front without copying,
## so it should not allocate at all. Observed: `push` allocates 1 time,
## `pop` allocates 0 times, regardless of `input.initial`'s length.
test! : Input => Fuzz.Outcome
test! = |input| {
	stack = Fuzz.expect_allocs_at_most!(1, || Stack.push(input.initial, input.pushed))

	popped = Fuzz.expect_allocs_at_most!(0, || Stack.pop(stack))

	match popped {
		Ok({ value, rest }) if value == input.pushed and rest == input.initial => Fuzz.keep
		Ok(_) => {
			crash "pop did not undo push"
		}
		Err(Empty) => {
			crash "a stack was empty immediately after push"
		}
	}
}

target = Fuzz.target_with!({
	examples: [
		Fuzz.saved({ name: "nonempty-entropy", revision: "1", bytes: regression_bytes }),
		Fuzz.example({ name: "empty-or-zero", revision: "1", make: || Input.{ initial: [], pushed: 7 } }),
		Fuzz.example({ name: "representative", revision: "1", make: || Input.{ initial: [1, 2, 3], pushed: 9 } }),
	],
	name: "stack-model",
	generator: Input.generator_for(Default),
	test!,
	show: |input| Str.inspect(input),
})
