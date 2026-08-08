app [target] { fuzz: platform "../platform/main.roc" }

import fuzz.Fuzz

test : Str -> Fuzz.Outcome
test = |input| {
	parsed : Try(U64, _)
	parsed = Json.parse(input)

	# Valid and invalid JSON are both ordinary results. A crash or timeout is
	# the failure this target is looking for.
	match parsed {
		Ok(_) => Fuzz.keep
		Err(_) => Fuzz.keep
	}
}

target = Fuzz.target_with({
	name: "parser-robustness",
	generator: Fuzz.str,
	test,
	show: |input| Str.inspect(input),
})
