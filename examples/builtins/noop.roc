app [target] { pf: platform "../../platform/main.roc" }

import pf.Fuzz

main : List(U8) -> U8
main = |_data| 0

target = Fuzz.from_bytes({
	name: "noop",
	test: main,
})
