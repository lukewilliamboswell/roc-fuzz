app [target] { fuzz: platform "../platform/main.roc" }
import fuzz.Fuzz

unsigned = Fuzz.target_with({
	name: "u64-roundtrip",
	generator: Fuzz.u64,
	test: |value| {
		if U64.from_str(value.to_str()) != Ok(value) {
			crash "unsigned decimal round trip failed"
		}
		Fuzz.keep
	},
	show: Str.inspect,
	examples: [Fuzz.example({ name: "representative", revision: "1", make: || 42.U64 })],
})

signed = Fuzz.target_with({
	name: "i64-roundtrip",
	generator: Fuzz.map(Fuzz.u64, |raw| raw.to_i64_wrap()),
	test: |value| {
		if I64.from_str(value.to_str()) != Ok(value) {
			crash "signed decimal round trip failed"
		}
		Fuzz.keep
	},
	show: Str.inspect,
	examples: [Fuzz.example({ name: "negative", revision: "1", make: || -42.I64 }), Fuzz.example({ name: "minimum", revision: "1", make: || I64.lowest })],
})

target = Fuzz.suite([unsigned, signed])
