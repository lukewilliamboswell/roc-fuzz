import fuzz.Fuzz

Collections :: [].{
	split_roundtrip = Fuzz.target_with({
		name: "list-split-roundtrip",
		generator: Fuzz.list(Fuzz.u8, 256),
		test: |input| {
			middle = input.len() // 2
			if input.take_first(middle).concat(input.drop_first(middle)) != input {
				crash "split list did not rejoin"
			}
			Fuzz.keep
		},
		show: Str.inspect,
		examples: [Fuzz.example({ name: "representative", revision: "1", make: || [1.U8, 2, 3] })],
	})

	concatenate = Fuzz.target_with({
		name: "list-concat",
		generator: Fuzz.list(Fuzz.u8, 256),
		test: |input| {
			joined = input.concat(input)
			if joined.len() != 2 * input.len() or joined.take_first(input.len()) != input or joined.drop_first(input.len()) != input {
				crash "concatenation changed the repeated list"
			}
			Fuzz.keep
		},
		show: Str.inspect,
		examples: [Fuzz.example({ name: "representative", revision: "1", make: || [4.U8, 5] })],
	})
}
