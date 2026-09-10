app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", model: "../../../tests/set-model/main.roc", roc: "nightly-2026-09-10-a670e34" }

import pf.Fuzz
import model.Model

# Equality ignores payload; every key deliberately hashes to the same bucket.
# Payload and nested list allocations exercise copying, retention, and release.
Key := { raw : U8, payload : Str, nested : List(Str) }.{
	is_eq : Key, Key -> Bool
	is_eq = |a, b| a.raw % 32 == b.raw % 32

	to_hash : Key, Hasher -> Hasher
	to_hash = |_, hasher| Hasher.write_u64(hasher, 0)
}

make : U8 -> Key
make = |raw| {
	payload = "a heap allocated Set key representative: ${raw.to_str()}"
	Key.{ raw, payload, nested: [payload, payload] }
}

generator : Fuzz.Generator(Model.Input)
generator = {
	initial: Fuzz.list(Fuzz.u8, 64),
	capacity: Fuzz.u64_in(0, 100),
	stop: Fuzz.u64_in(0, 35),
	shared: Fuzz.map(Fuzz.u8_in(0, 1), |n| n == 1),
	ops: Fuzz.list(Fuzz.map({ kind: Fuzz.u8_in(0, 12), value: Fuzz.u8, capacity: Fuzz.u64_in(0, 100), items: Fuzz.list(Fuzz.u8, 32) }.Fuzz, |op| Model.operation(op.kind, op.value, op.capacity, op.items)), 32),
}.Fuzz

## Refcounted keys allocate while they are constructed for Set operations and
## verification. The generator bounds the operation sequence and all nested
## lists, so the complete model comparison has a fixed conservative ceiling.
target = Fuzz.target_with!({
	name: "setCollisions",
	generator,
	test!: |input| {
		Fuzz.expect_allocs_at_most!(
			100000,
			|{}|
				Model.run(
					input,
					make,
					|item| {
						if item.payload != "a heap allocated Set key representative: ${item.raw.to_str()}" or item.nested != [item.payload, item.payload] {
							crash "Set corrupted a refcounted key payload"
						}
						item.raw
					},
				),
		)
		Fuzz.keep
	},
	show: |input| Str.inspect(input),
})
