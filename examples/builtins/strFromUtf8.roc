app [target] { pf: platform "../../platform/main.roc" }

import pf.Fuzz

import pf.Arbitrary

main : List(U8) -> U8
main = |data| {
	bytes = Arbitrary.new(data).arbitrary_list_u8().value
	string = match Str.from_utf8(bytes) {
		Ok(value) => value
		Err(BadUtf8({ index, .. })) => {
			prefix = List.take_first(bytes, index)
			match Str.from_utf8(prefix) {
				Ok(value) => value
				Err(_) => {
					crash "prefix before invalid UTF-8 byte was not valid"
				}
			}
		}
	}

	if Str.to_utf8(string) != List.take_first(bytes, Str.count_utf8_bytes(string)) {
		crash "bytes changed while round-tripping through Str"
	}

	0
}

target = Fuzz.from_bytes({
	name: "strFromUtf8",
	test: main,
})
