app [target] { fuzz: platform "../../../platform/main.roc" }

import fuzz.Fuzz

# A goal is judged over a campaign, and a declared example reaches each of
# these, so `check` passes with no exploration. One is reached by a mark and
# one by a measured region, and `Count` holds a goal's mark to the rules of
# its region like any other event.
test! : List(U8) => Fuzz.Outcome
test! = |bytes| {
	if bytes.len() > 16 {
		return Fuzz.reject
	}
	Fuzz.trace_rules!([Count("checked", 1), Forbidden("failed")])
	if bytes.is_empty() {
		Fuzz.mark!("saw nothing")
	} else {
		measured = Fuzz.measure!("saw something", || bytes.len())
		if measured.value == 0 {
			Fuzz.mark!("failed")
		}
	}
	Fuzz.mark!("checked")
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "quality-goals",
	examples: [
		Fuzz.example({ name: "empty", revision: "1", make: || [] }),
		Fuzz.example({ name: "bytes", revision: "1", make: || [1.U8, 2, 3] }),
	],
	generator: Fuzz.list(Fuzz.u8, 16),
	test!,
	show: Str.inspect,
}).with_goals(["saw nothing", "saw something", "checked"])

expect target.goals() == ["saw nothing", "saw something", "checked"]
