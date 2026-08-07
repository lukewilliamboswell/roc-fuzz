app [target] { fuzz: platform "../platform/main.roc" }

import fuzz.Fuzz

Input := { bytes : List(U8), radix : U8 }.{
	generator_for : Fuzz.FuzzEncoding -> Fuzz.Generator(Input)
	generator_for = |_| {
		{
			bytes: Fuzz.bytes,
			radix: Fuzz.u8_in(2, 36),
		}.Fuzz
	}
}

test : Input -> Fuzz.Outcome
test = |input| {
	# A real target would call the system under test here. This branch gives
	# the fuzzer a constrained input domain without throwing type safety away.
	if List.is_empty(input.bytes) Fuzz.reject else Fuzz.keep
}

show : Input -> Str
show = |input| Str.inspect(input)

target = Fuzz.target({
	name: "typed-target",
	test,
	show,
})
