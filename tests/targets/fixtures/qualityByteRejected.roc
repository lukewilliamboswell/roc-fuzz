app [target] { fuzz: platform "../../../platform/main.roc" }

import fuzz.Fuzz

## Byte adapters use zero as Keep and forward a nonzero status as rejection.
target = Fuzz.from_bytes({
	name: "quality-byte-rejected",
	examples: [],
	test: |_| 1,
})
