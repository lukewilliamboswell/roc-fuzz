app [target] { fuzz: platform "../../../platform/main.roc" }

import fuzz.Fuzz

## Nominal inputs explicitly opt into binary parsing and encoding. Generation
## is a bias; the same precondition below validates both decoded and generated
## inputs before arithmetic uses radix.
Input := { bytes : List(U8), radix : U8 }.{
	parser_for : _
	encoder_for : _

	generator_for = |_| { bytes: Fuzz.bytes, radix: Fuzz.u8_in(2, 36) }.Fuzz
}

test! : Input => Fuzz.Outcome
test! = |input| {
	if input.radix < 2 or input.radix > 36 {
		return Fuzz.reject
	}
	Fuzz.trace_rules!([Before("copy", "checked"), Count("checked", 1), Forbidden("failed")])
	measured = Fuzz.measure!("copy", || List.map(input.bytes, |byte| byte))
	if measured.value != input.bytes {
		crash "copy changed bytes"
	}
	if measured.stats.reallocs != 0 {
		crash "copy unexpectedly reallocated"
	}
	Fuzz.mark!("checked")
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "quality-inputs",
	examples: [
		Fuzz.example({ name: "empty", revision: "1", make: || Input.{ bytes: [], radix: 10 } }),
		Fuzz.example({ name: "bytes", revision: "1", make: || Input.{ bytes: [0, 1, 255], radix: 16 } }),
		Fuzz.saved({ name: "original-entropy", revision: "1", bytes: [1, 2, 3, 4, 5] }),
	],
	generator: |state| Input.generator_for(Default)(state),
	test!,
	show: Str.inspect,
})

expect target.example_count() == 3
expect target.example(0).name == "empty"
expect target.example(0).revision == "1"
expect target.example(0).bytes.take_first(5) == [82, 70, 90, 1, 1]
expect target.example(2).bytes == [1, 2, 3, 4, 5]
expect target.show(target.example(0).bytes) == Str.inspect(Input.{ bytes: [], radix: 10 })
expect target.show([82, 70, 90, 255, 255]) == "<rejected: malformed input or decoding budget exceeded>"
