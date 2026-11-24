app [target] { fuzz: platform "../../../platform/main.roc" }

import fuzz.Fuzz

# Inconclusive by design: no input can reach "more than sixteen bytes", since
# the generator makes at most sixteen. Every rule holds, so `check` and `run`
# end `inconclusive` with that goal unreached, and replaying an input passes.
test! : List(U8) => Fuzz.Outcome
test! = |bytes| {
	if bytes.len() > 16 {
		Fuzz.mark!("more than sixteen bytes")
	}
	Fuzz.mark!("checked")
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "quality-unreached-goal",
	examples: [Fuzz.example({ name: "bytes", revision: "1", make: || [1.U8, 2, 3] })],
	generator: Fuzz.list(Fuzz.u8, 16),
	test!,
	show: Str.inspect,
}).with_goals(["checked", "more than sixteen bytes"])
