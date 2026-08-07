app [target] { fuzz: platform "../platform/main.roc" }

import fuzz.Fuzz

test : List(U8) -> Fuzz.Outcome
test = |input| {
	combined = List.concat(input, input)
	if List.len(combined) == List.len(input) * 2 {
		Fuzz.keep
	} else {
		crash "concatenating a list did not double its length"
	}
}

target = Fuzz.target_with({
	name: "list-concat-length",
	generator: Fuzz.bytes,
	test,
	show: |input| Str.inspect(input),
})
