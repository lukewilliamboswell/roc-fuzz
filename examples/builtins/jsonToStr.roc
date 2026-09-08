app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-08-39a3f89" }

import pf.Fuzz

import pf.Arbitrary

parse_str : Str -> Try(Str, _)
parse_str = |input| Json.parse(input)

## Allocation invariant: parsing stays within a linear budget based on input
## size. The decoded `Str` can be arbitrarily long, so unlike the U64 target
## we cannot assume `Json.to_str` stays inline.
main! : List(U8) => U8
main! = |data| {
	input = Arbitrary.new(data).arbitrary_list_u8().value |> Str.from_utf8_lossy
	limit = 4 * input.count_utf8_bytes() + 16
	result = Fuzz.expect_allocs_at_most!(limit, |{}| parse_str(input))

	match result {
		Ok(decoded) => {
			redecoded : Str
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
	name: "jsonToStr",
	test!: main!,
})
