## Advanced, type-erased bridge between a typed Roc property and the native
## runner.
##
## Applications normally construct this value with `Fuzz.target` or
## `Fuzz.target_with` and expose it as `target`. The methods here define the
## small byte-oriented ABI consumed by the embedded runner.
Target := [Target({ name : Str, run! : List(U8) => U8, show : List(U8) -> Str, example_count : () -> U64, example : U64 -> { name : Str, revision : Str, bytes : List(U8) }, goals : () -> List(Str) }), Targets(List(Target))].{

	## Construct a target from low-level runner callbacks.
	##
	## `run!` returns zero for a kept input and a non-zero status for a rejected
	## input. Failures should use `crash` or `expect` rather than status codes.
	new : { name : Str, run! : List(U8) => U8, show : List(U8) -> Str, example_count : () -> U64, example : U64 -> { name : Str, revision : Str, bytes : List(U8) } } -> Target
	new = |inner| Target({ name: inner.name, run!: inner.run!, show: inner.show, example_count: inner.example_count, example: inner.example, goals: || [] })

	## Declare goals: named events that some kept input of a campaign must
	## reach. An input reaches a goal by recording an event of that name with
	## [`Fuzz.mark!`](#Fuzz.mark) or by completing a measured region of that
	## name. A campaign is the declared examples, the saved corpus and
	## exploration together.
	##
	## ```roc
	## target = Fuzz.target_with!({
	## 	name: "parse",
	## 	examples: [],
	## 	generator: Fuzz.bytes,
	## 	test!: |input| {
	## 		match parse(input) {
	## 			Ok(_) => Fuzz.mark!("parsed a document")
	## 			Err(_) => Fuzz.mark!("refused a document")
	## 		}
	## 		Fuzz.keep
	## 	},
	## 	show: Str.inspect,
	## }).with_goals(["parsed a document", "refused a document"])
	## ```
	##
	## Every other trace rule is judged on each input. A goal is judged once,
	## over the campaign: the report lists the goals reached, each with the
	## first input that reached it, and the goals never reached. A goal no
	## input reached makes the campaign `inconclusive`. Reaching one is never
	## a finding.
	##
	## The inventory is part of the target, so the runner knows every goal
	## before any input runs. It refuses an inventory whose names are not
	## unique, nonempty and at most 128 bytes each, or that has more than 1024.
	## Calling this again adds to the goals already declared.
	with_goals : Target, List(Str) -> Target
	with_goals = |value, names| with_goals_from(value, || names)

	## As [`with_goals`](#Target.with_goals), for an inventory that is worked
	## out rather than written down: `names` is called when the runner asks
	## for the inventory, once in a process, and not when the target is built.
	## A target is built again for every input, so work done there is paid
	## for by every input.
	with_goals_from : Target, (() -> List(Str)) -> Target
	with_goals_from = |value, names| match value {
		Target(inner) => {
			declared = inner.goals
			Target({ ..inner, goals: || declared().concat(names()) })
		}
		Targets(_) => crash "declare goals on each member before combining them with Fuzz.suite"
	}

	## The goals this target declares, in declaration order.
	goals : Target -> List(Str)
	goals = |value| match value {
		Target(inner) => (inner.goals)()
		Targets(_) => crash "select a suite member before using its bridge callbacks"
	}

	## Assemble a flat inventory for the native runner. Prefer `Fuzz.suite`.
	new_suite : List(Target) -> Target
	new_suite = |properties| {
		var $members = []
		for member in properties {
			match member {
				Target(_) => {
					$members = $members.append(member)
				}
				Targets(values) => {
					$members = $members.concat(values)
				}
			}
		}
		Targets($members)
	}

	## Number of independently selectable properties.
	count : Target -> U64
	count = |value| match value {
		Target(_) => 1
		Targets(values) => values.len()
	}

	## Select a member without decoding or changing its corpus bytes.
	get : Target, U64 -> Try(Target, [OutOfBounds])
	get = |value, index| match value {
		Target(_) => if index == 0 {
			Ok(value)
		} else {
			Err(OutOfBounds)
		}
		Targets(values) => values.get(index)
	}

	## Return the human-readable target name reported by the executable.
	name : Target -> Str
	name = |value| match value {
		Target(inner) => inner.name
		Targets(_) => crash "select a suite member before using its bridge callbacks"
	}

	## Decode and test one raw input, returning the runner status code.
	##
	## This is effectful so a target may read the platform's allocation
	## counters (see `Fuzz.alloc_count!`). A target whose property needs no
	## effects can still be written as a plain pure function
	## a pure body
	## satisfies this signature unchanged.
	run! : Target, List(U8) => U8
	run! = |value, input| match value {
		Target(inner) => (inner.run!)(input)
		Targets(_) => crash "select a suite member before using its bridge callbacks"
	}

	## Decode one raw input into a human-readable typed value.
	show : Target, List(U8) -> Str
	show = |value, input| match value {
		Target(inner) => (inner.show)(input)
		Targets(_) => crash "select a suite member before using its bridge callbacks"
	}

	## Number of source-declared examples, independent of corpus retention.
	example_count : Target -> U64
	example_count = |value| match value {
		Target(inner) => (inner.example_count)()
		Targets(_) => crash "select a suite member before using its bridge callbacks"
	}

	## Prepare one source example as corpus bytes. The native host copies the
	## returned fields and releases all temporary Roc values before execution.
	example : Target, U64 -> { name : Str, revision : Str, bytes : List(U8) }
	example = |value, index| match value {
		Target(inner) => (inner.example)(index)
		Targets(_) => crash "select a suite member before using its bridge callbacks"
	}
}
