app [target] { fuzz: platform "../../../platform/main.roc" }

import fuzz.Fuzz

# Registering a rule after its region has emitted an event is an explicit
# trace declaration error. Its original-run trace must preserve valid allocator
# metrics separately from invalid and failed trace rules.
test! : U8 => Fuzz.Outcome
test! = |_| {
	Fuzz.mark!("already emitted")
	Fuzz.count!("late declaration", 0)
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "quality-late-rule",
	examples: [],
	generator: Fuzz.u8,
	test!,
	show: Str.inspect,
})
