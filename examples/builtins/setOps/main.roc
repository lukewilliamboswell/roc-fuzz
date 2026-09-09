app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", model: "../../../tests/set-model/main.roc", roc: "nightly-2026-09-08-39a3f89" }

import pf.Fuzz
import model.Model

generator : Fuzz.Generator(Model.Input)
generator = {
	initial: Fuzz.list(Fuzz.u8, 64),
	capacity: Fuzz.u64_in(0, 100),
	stop: Fuzz.u64_in(0, 35),
	shared: Fuzz.map(Fuzz.u8_in(0, 1), |n| n == 1),
	ops: Fuzz.list(Fuzz.map({ kind: Fuzz.u8_in(0, 12), value: Fuzz.u8, capacity: Fuzz.u64_in(0, 100), items: Fuzz.list(Fuzz.u8, 32) }.Fuzz, |op| Model.operation(op.kind, op.value, op.capacity, op.items)), 32),
}.Fuzz

## The generator caps the initial list at 64 items and the operation sequence at
## 32 steps, with at most 32 items in each nested operation. Keep the complete
## model comparison within a fixed allocation budget for that bounded input.
## Observed fuzz inputs remain well below this conservative ceiling.
target = Fuzz.target_with!({
	name: "setOps",
	generator,
	test!: |input| {
		Fuzz.expect_allocs_at_most!(20000, |{}| Model.run(input, |raw| raw % 32, |item| item))
		Fuzz.keep
	},
	show: |input| Str.inspect(input),
})
