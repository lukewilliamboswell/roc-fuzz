import fuzz.Fuzz

Input := { value : Str, delimiter : Str }.{
	parser_for : _
	encoder_for : _
}

Text :: [].{
	roundtrip = Fuzz.target_with({
		name: "text-roundtrip",
		generator: { value: Fuzz.str, delimiter: Fuzz.str }.Fuzz,
		test: |input| {
			if Str.join_with(input.value.split_on(input.delimiter), input.delimiter) != input.value {
				crash "split text did not rejoin"
			}
			Fuzz.keep
		},
		show: |input| Str.inspect(input),
		examples: [Fuzz.example({ name: "unicode-and-empty-fields", revision: "1", make: || Input.{ value: "π,,é", delimiter: "," } })],
	})
}
