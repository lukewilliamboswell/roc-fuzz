app [main] { pf: platform "../main.roc" }

main : List(U8) -> U8
main = |data| {
	if List.is_empty(data) {
		0
	} else {
		crash "intentional roc-fuzz artifact test failure"
	}
}
