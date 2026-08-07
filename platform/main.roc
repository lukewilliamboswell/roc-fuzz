platform "roc-fuzz"
	requires {
		main : List(U8) -> U8
	}
	exposes [Arbitrary]
	packages {}
	provides { "roc_fuzz": main_for_host }
	targets: {
		inputs_dir: ".",
		x64glibc: {
			inputs: [app],
			output: Archive,
		},
	}

import Arbitrary

main_for_host : List(U8) -> U8
main_for_host = |input| main(input)
