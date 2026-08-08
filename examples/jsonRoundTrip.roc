app [target] { fuzz: platform "../platform/main.roc" }

import fuzz.Fuzz

test : U64 -> Fuzz.Outcome
test = |input| {
	encoded = Json.to_str(input)
	decoded : Try(U64, _)
	decoded = Json.parse(encoded)

	match decoded {
		Ok(value) if value == input => Fuzz.keep
		Ok(_) => {
			crash "JSON round trip changed the value"
		}
		Err(_) => {
			crash "JSON output could not be parsed"
		}
	}
}

target = Fuzz.target_with({
	name: "json-round-trip",
	generator: Fuzz.u64,
	test,
	show: |input| Str.inspect(input),
})
