app [target] { pf: platform "../../platform/main.roc" }

import pf.Fuzz

main : List(U8) -> U8
main = |data| {
	set = List.fold(data, Set.empty(), Set.insert)
	for element in data {
		if !Set.contains(set, element) {
			crash "set did not contain an inserted element"
		}
	}

	empty = List.fold(data, set, Set.remove)
	if !Set.is_empty(empty) {
		crash "set did not remove every inserted element"
	}
	0
}

target = Fuzz.from_bytes({
	name: "setInsert",
	test: main,
})
