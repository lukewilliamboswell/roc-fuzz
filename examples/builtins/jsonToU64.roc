app [target] { pf: platform "../../platform/main.roc" }

import pf.Fuzz

import pf.Arbitrary

main : List(U8) -> U8
main = |data| {
	input = Arbitrary.new(data).arbitrary_list_u8().value |> Str.from_utf8_lossy
	result : Try(U64, _)
	result = Json.parse(input)

	match result {
		Ok(decoded) => {
			redecoded : U64
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

target = Fuzz.from_bytes({
	name: "jsonToU64",
	test: main,
})
