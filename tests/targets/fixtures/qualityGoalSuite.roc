app [target] { fuzz: platform "../../../platform/main.roc" }

import fuzz.Fuzz

# Each member of a suite declares its own goals and has its own outcome:
# `reached` passes, and `unreached` declares a goal no input can reach, so it
# is inconclusive while every rule holds.
member = |name, goals| Fuzz.target_with!({
	name,
	examples: [Fuzz.example({ name: "bytes", revision: "1", make: || [1.U8, 2] })],
	generator: Fuzz.list(Fuzz.u8, 8),
	test!: |bytes| {
		if bytes.len() > 8 {
			Fuzz.mark!("more than eight bytes")
		}
		Fuzz.mark!("checked")
		Fuzz.keep
	},
	show: Str.inspect,
}).with_goals(goals)

target = Fuzz.suite([
	member("reached", ["checked"]),
	member("unreached", ["checked", "more than eight bytes"]),
])
