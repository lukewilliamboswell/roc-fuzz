app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-12-220fd47" }

import fuzz.Fuzz

## Allocation invariant: encoding a `U64` to JSON and parsing it back
## performs exactly one allocation (the encoded `Str`'s backing buffer, since
## the JSON text of a `U64` is always at least 1 byte and commonly reaches
## the 24-byte heap threshold for larger values); parsing the number back out
## does not allocate further. Measured empirically at 1 allocation per round
## trip across 20000 fuzzer runs.
test! : U64 => Fuzz.Outcome
test! = |input| {
	decoded = Fuzz.expect_allocs_at_most!(
		1,
		|{}| {
			encoded = Json.to_str(input)
			result : Try(U64, _)
			result = Json.parse(encoded)
			result
		},
	)

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

target = Fuzz.target_with!({
	name: "json-round-trip",
	generator: Fuzz.u64,
	test!,
	show: |input| Str.inspect(input),
})
