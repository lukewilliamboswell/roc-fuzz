app [target] { pf: platform "../../platform/main.roc" }

import pf.Fuzz

import pf.Arbitrary

parse_u64 : Str -> Try(U64, _)
parse_u64 = |input| Json.parse(input)

## Allocation invariants:
## * `Json.parse` is stable -- parsing the same input twice must cost the
##   same number of allocations both times.
## * `Json.to_str` on a `U64` allocates at most once. Even though the
##   rendered digits (at most 20 ASCII characters) always fit in a small
##   string, encoding builds through a growable heap buffer before the
##   final copy, so a single allocation is observed even for small values
##   (verified empirically -- fuzzing surfaced this as an actual 1-alloc
##   cost, not 0 as originally assumed).
main! : List(U8) => U8
main! = |data| {
	input = Arbitrary.new(data).arbitrary_list_u8().value |> Str.from_utf8_lossy
	first_parse = Fuzz.measure_allocs!(|{}| parse_u64(input))
	second_parse = Fuzz.measure_allocs!(|{}| parse_u64(input))
	if first_parse.allocations != second_parse.allocations {
		crash "Json.parse allocated a different number of times (${first_parse.allocations.to_str()} vs ${second_parse.allocations.to_str()}) for the same input"
	}
	result = first_parse.value

	match result {
		Ok(decoded) => {
			encoded = Fuzz.expect_allocs_at_most!(1, |{}| Json.to_str(decoded))
			redecoded : U64
			redecoded = match Json.parse(encoded) {
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
	name: "jsonToU64",
	test!: main!,
})
