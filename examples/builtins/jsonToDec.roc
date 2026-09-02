app [target] { pf: platform "../../platform/main.roc" }

import pf.Fuzz

import pf.Arbitrary

parse_dec : Str -> Try(Dec, _)
parse_dec = |input| Json.parse(input)

## Allocation invariant: `Json.parse` is stable -- parsing the same input
## twice must cost the same number of allocations both times. (`Dec` can
## render up to ~40 ASCII characters, so unlike the U64 target we can't
## also assume `Json.to_str` stays inline.)
main! : List(U8) => U8
main! = |data| {
	input = Arbitrary.new(data).arbitrary_list_u8().value |> Str.from_utf8_lossy
	first_parse = Fuzz.measure_allocs!(|{}| parse_dec(input))
	second_parse = Fuzz.measure_allocs!(|{}| parse_dec(input))
	if first_parse.allocations != second_parse.allocations {
		crash "Json.parse allocated a different number of times (${first_parse.allocations.to_str()} vs ${second_parse.allocations.to_str()}) for the same input"
	}
	result = first_parse.value

	match result {
		Ok(decoded) => {
			redecoded : Dec
			redecoded = match Json.parse(Json.to_str(decoded)) {
				Ok(value) => value
				Err(_) => {
					crash "could not decode JSON after encoding it"
				}
			}
			if decoded != redecoded {
				crash "JSON value changed during round trip"
			}
			0
		}
		Err(_) => 1
	}
}

target = Fuzz.from_bytes!({
	name: "jsonToDec",
	test!: main!,
})
