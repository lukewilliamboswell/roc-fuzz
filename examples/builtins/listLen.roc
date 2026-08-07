app [target] { pf: platform "../../platform/main.roc" }

import pf.Fuzz

import pf.Arbitrary

main : List(U8) -> U8
main = |data| Arbitrary.new(data).arbitrary_list_u8().value.len().to_u8_wrap()

target = Fuzz.from_bytes({
	name: "listLen",
	test: main,
})
