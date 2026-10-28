app [target] { fuzz: platform "../../../platform/main.roc" }

import fuzz.Fuzz

## The native callback must forward rejection to libFuzzer. A completed search
## with zero accepted inputs is inconclusive and must exit unsuccessfully.
target = Fuzz.target_with({
	name: "quality-rejected",
	examples: [],
	generator: Fuzz.u8,
	test: |_| Fuzz.reject,
	show: Str.inspect,
})
