app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-12-220fd47" }

import fuzz.Fuzz
import Stack

Input := { initial : List(U8), pushed : U8 }.{
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
	stack = Fuzz.expect_allocs_at_most!(1, |{}| Stack.push(input.initial, input.pushed))

	popped = Fuzz.expect_allocs_at_most!(0, |{}| Stack.pop(stack))

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
	name: "stack-model",
	generator: Input.generator_for(Default),
	test!,
	show: |input| Str.inspect(input),
})
