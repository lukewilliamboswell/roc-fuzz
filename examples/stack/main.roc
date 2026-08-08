app [target] { fuzz: platform "../../platform/main.roc" }

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

test : Input -> Fuzz.Outcome
test = |input| {
	stack = Stack.push(input.initial, input.pushed)

	match Stack.pop(stack) {
		Ok({ value, rest }) if value == input.pushed and rest == input.initial => Fuzz.keep
		Ok(_) => {
			crash "pop did not undo push"
		}
		Err(Empty) => {
			crash "a stack was empty immediately after push"
		}
	}
}

target = Fuzz.target({
	name: "stack-model",
	test,
	show: |input| Str.inspect(input),
})
