import fuzz.Model

## Further tests of the platform's `Model`: rules about steps, the full report
## of `Model.explore`, and `Model.apply`. They use only what the platform
## exposes, so they live outside it, where no application's `roc test` runs
## them. `roc test tests/model/main.roc` does.
ModelTests := [].{}

## A counter that may go up to `top`, by `jump` at a time, and down by one,
## with rules about its states only.
plain : U64, U64 -> Model.Machine(U64, [Up, Down])
plain = |top, jump| {
	init: 0,
	actions: |n| if (n == 0) [Up] else if (n >= top) [Down] else [Up, Down],
	step: |n, action| match action {
		Up => n + jump
		Down => n - 1
	},
	rules: [Model.always("stays below ten", |n| n < 10), Model.sometimes("reaches two", |n| n == 2)],
}

## Rules about that counter's steps. A jump of 2 breaks the first, and a jump
## of 12 breaks the state rule "stays below ten" as well.
steps : U64 -> List(Model.Rule(U64, [Up, Down]))
steps = |top| [
	Model.always_step("a step moves by one", |{ before, action: _, after }| after == before + 1 or before == after + 1),
	Model.sometimes_step("comes down from the top", |{ before, action, after: _ }| action == Down and before == top),
	Model.sometimes_step("goes up from five", |{ before, action, after: _ }| action == Up and before == 5),
]

## The same counter with the rules about its steps after the rules about
## its states.
stepped : U64, U64 -> Model.Machine(U64, [Up, Down])
stepped = |top, jump| { ..plain(top, jump), rules: plain(top, jump).rules.concat(steps(top)) }

## The counter of `Model.roc`: a limit it must stay below.
counter : U64, U64 -> Model.Machine(U64, [Up, Down])
counter = |top, limit| {
	init: 0,
	actions: |n| if (n == 0) [Up] else if (n == top) [Down] else [Up, Down],
	step: |n, action| match action {
		Up => n + 1
		Down => n - 1
	},
	rules: [Model.always("stays below the limit", |n| n < limit), Model.sometimes("reaches three", |n| n == 3)],
}

## The lift of `Model.roc`, which jams at the top floor.
lift : Model.Machine(U64, [Up, Down])
lift = {
	init: 0,
	actions: |_| [Up, Down],
	step: |floor, action| match action {
		Up => if (floor < 2) floor + 1 else floor
		Down => if (floor == 2 or floor == 0) floor else floor - 1
	},
	rules: [Model.at_rest("the lift never jams", |_| Bool.False)],
}

## Two search keys: the whole count, and what is left of it after division.
## They are named, and not written out at each use, because every new function
## passed as a key makes the compiler build another copy of `Model.explore`.
whole : U64 -> U64
whole = |n| n

modulo : U64 -> (U64 -> U64)
modulo = |size| |n| n % size

# ---------------------------------------------------------------------------
# The examples in the doc comment at the top of `Model.roc`, word for word
# ---------------------------------------------------------------------------

documented : Model.Machine(U64, [Up, Down])
documented = {
	init: 0,
	actions: |n| if (n == 0) [Up] else if (n == 3) [Down] else [Up, Down],
	step: |n, action| match action {
		Up => n + 1
		Down => n - 1
	},
	rules: [Model.always("never above three", |n| n <= 3), Model.sometimes("reaches three", |n| n == 3)],
}

expect Model.check(documented, { depth: 10 }) == { verdict: Holds(Exhausted), states: 4, depth: 3 }

expect {
	one_at_a_time = Model.always_step("one at a time", |{ before, action: _, after }| after == before + 1 or before == after + 1)
	comes_down = Model.sometimes_step("comes down from three", |{ before, action, after: _ }| action == Down and before == 3)
	report = Model.explore({ ..documented, rules: documented.rules.concat([one_at_a_time, comes_down]) }, { depth: 10, key: |n| n })
	report == {
		verdict: Holds(Exhausted),
		states: 4,
		depth: 3,
		steps: 6,
		broken: [],
		reached: [{ rule: "reaches three", trace: [Up, Up, Up] }, { rule: "comes down from three", trace: [Up, Up, Up, Down] }],
		unreached: [],
	}
}

expect Model.explain(Model.explore(documented, { depth: 10, key: whole })) == "Holds for every reachable state. The search ran out of new states: 4 visited, the farthest 3 actions from the start, and every step from each of them checked (6 steps). Goals reached: 1 of 1."

# ---------------------------------------------------------------------------
# Rules about steps, in every engine
# ---------------------------------------------------------------------------

# A search checks them on every step, and a step goal is met by a step back
# into a state already seen: `Down` from 3.
expect Model.explore(stepped(3, 1), { depth: 10, key: whole }) == {
	verdict: Unreached({ rule: "goes up from five", extent: Exhausted }),
	states: 4,
	depth: 3,
	steps: 6,
	broken: [],
	reached: [{ rule: "reaches two", trace: [Up, Up] }, { rule: "comes down from the top", trace: [Up, Up, Up, Down] }],
	unreached: ["goes up from five"],
}

# A step rule that fails is a violation like any other, with a shortest trace.
expect Model.explore(stepped(3, 2), { depth: 10, key: whole }).verdict == Violated({ rule: "a step moves by one", trace: [Up] })

# `check` is the same search, so it grades them too. Without them the
# counter that jumps by two passes.
expect Model.check(stepped(3, 1), { depth: 10 }) == { verdict: Unreached({ rule: "goes up from five", extent: Exhausted }), states: 4, depth: 3 }
expect Model.check(stepped(3, 2), { depth: 10 }).verdict == Violated({ rule: "a step moves by one", trace: [Up] })
expect Model.check(plain(3, 2), { depth: 10 }).verdict == Holds(Exhausted)

# A walk checks them on every step it takes, and names the step goals it met
# after the state goals, in the order it met them.
expect Model.walk(stepped(3, 1), [0, 0, 0, 0]) == { trace: [Up, Up, Up, Down], state: 2, reached: ["reaches two", "comes down from the top"], verdict: Completed }
expect Model.walk(stepped(3, 2), [0, 0]) == { trace: [Up], state: 2, reached: [], verdict: Violated({ rule: "a step moves by one" }) }

# So does a replayed trace.
expect Model.replay(stepped(3, 1), [Up, Up, Up, Down]).reached == ["reaches two", "comes down from the top"]
expect Model.replay(stepped(3, 2), [Up, Down]).verdict == Violated({ rule: "a step moves by one" })

# One step from any state. From 4 a jump of two breaks the step rule on the
# way up, though both states it joins keep the state rule.
expect Model.step_from(stepped(9, 2), 4) == Broken({ rule: "a step moves by one", action: Up })
expect Model.step_from(plain(9, 2), 4) == Preserved({ actions: 2, reached: [] })

# One step from 5 meets a step goal, and one step from 3 a state goal: the
# 2 that `Down` leads to.
expect Model.step_from(stepped(9, 1), 5) == Preserved({ actions: 2, reached: ["goes up from five"] })
expect Model.step_from(stepped(9, 1), 3) == Preserved({ actions: 2, reached: ["reaches two"] })

# The goals of a machine, by name.
expect Model.goals(stepped(3, 1)) == ["reaches two", "comes down from the top", "goes up from five"]

# Goals are reported in the order the rules are written, whatever they are
# about. Here a step goal is written before the state goal.
expect {
	mixed = { ..plain(3, 1), rules: steps(3).concat(plain(3, 1).rules) }
	report = Model.explore(mixed, { depth: 10, key: whole })
	report.reached.map(|met| met.rule) == ["comes down from the top", "reaches two"] and Model.apply(mixed, [Up]).unreached == ["comes down from the top", "goes up from five", "reaches two"]
}

# ---------------------------------------------------------------------------
# `explore`: the whole report
# ---------------------------------------------------------------------------

expect {
	report = Model.explore(stepped(3, 1), { depth: 10, key: whole })
	Model.witness(report, "comes down from the top") == Ok([Up, Up, Up, Down]) and Model.witness(report, "goes up from five") == Err(NotReached)
}

# All three goals are missed within one action, and all three are named.
expect Model.explore(stepped(3, 1), { depth: 1, key: whole }).unreached == ["reaches two", "comes down from the top", "goes up from five"]

# A jump of 12 breaks a state rule and a step rule at once. `FirstRule` names
# the one that comes first, `EveryRule` names both.
expect Model.explore(stepped(3, 12), { depth: 10, key: whole }).broken == ["stays below ten"]
expect Model.explore(stepped(3, 12), { depth: 10, key: whole, blame: EveryRule }) == {
	verdict: Violated({ rule: "stays below ten", trace: [Up] }),
	states: 2,
	depth: 1,
	steps: 1,
	broken: ["stays below ten", "a step moves by one"],
	reached: [],
	unreached: ["reaches two", "comes down from the top", "goes up from five"],
}

# The trap, and the way out. A key of `n % 4` calls 0 and 4 the same state.
# Under a limit of 4 the count 4 breaks the rule, and by default the search
# drops it unseen and reports that all is well. Checking the rules on every
# step catches it, by the same trace a faithful key gives.
expect Model.explore(counter(9, 4), { depth: 10, key: whole }).verdict == Violated({ rule: "stays below the limit", trace: [Up, Up, Up, Up] })
expect Model.explore(counter(9, 4), { depth: 10, key: modulo(4) }).verdict == Holds(Exhausted)
expect Model.explore(counter(9, 4), { depth: 10, key: modulo(4), verify: EveryStep }).verdict == Violated({ rule: "stays below the limit", trace: [Up, Up, Up, Up] })

# What that cannot do. Under a limit of 5 the count 4 is fine and 5 is not,
# but 4 is still dropped, nothing is stepped from it, and 5 is never made.
expect Model.explore(counter(9, 5), { depth: 10, key: modulo(4), verify: EveryStep }).verdict == Holds(Exhausted)

# Each result in words.
expect Model.explain(Model.explore(counter(9, 10), { depth: 5, key: whole })) == "Holds within 5 actions of the start, and nothing is known beyond that. The depth limit stopped the search: 6 states visited, 9 steps checked, and the farthest states not stepped from. Goals reached: 1 of 1."
expect Model.explain(Model.explore(stepped(3, 1), { depth: 10, key: whole })) == "No rule fails in any reachable state, and 1 of 3 goals can never be reached: \"goes up from five\". The search ran out of new states: 4 visited, the farthest 3 actions from the start, and every step from each of them checked (6 steps)."
expect Model.explain(Model.explore(counter(9, 10), { depth: 2, key: whole })) == "No rule fails within 2 actions of the start, and 1 of 1 goals were not reached there: \"reaches three\". They may be reachable further on. The depth limit stopped the search: 3 states visited, 3 steps checked, and the farthest states not stepped from."
expect Model.explain(Model.explore(stepped(3, 12), { depth: 10, key: whole, blame: EveryRule })) == "Violated: \"stays below ten\" fails at the end of a trace of length 1, and no shorter trace breaks an `always` rule. Rules broken there: \"stays below ten\", \"a step moves by one\". The search stopped there (states visited: 2, steps checked: 1)."
expect Model.explain(Model.explore(lift, { depth: 10, key: whole })) == "Deadlock: a trace of length 2 leaves the machine at rest where \"the lift never jams\" forbids it, and no shorter trace breaks any rule. The search stopped there (states visited: 3, steps checked: 6)."

# ---------------------------------------------------------------------------
# `apply`: a path taken as given
# ---------------------------------------------------------------------------

# At 3, the top, only `Down` is possible. `replay` refuses the fourth `Up`.
# `apply` takes it and says which action it was.
expect Model.apply(stepped(3, 1), [Up, Up, Up, Up, Down]) == {
	trace: [Up, Up, Up, Up, Down],
	state: 3,
	reached: ["reaches two"],
	unreached: ["comes down from the top", "goes up from five"],
	outside: [3],
	verdict: Completed,
}
expect Model.replay(stepped(3, 1), [Up, Up, Up, Up, Down]).verdict == Impossible({ at: 3 })

# A step rule that fails stops the path, and with no step rules it goes on.
expect Model.apply(stepped(3, 2), [Up, Up]) == { trace: [Up], state: 2, reached: [], unreached: ["reaches two", "comes down from the top", "goes up from five"], outside: [], verdict: Violated({ rule: "a step moves by one" }) }
expect Model.apply(plain(3, 2), [Up, Up]) == { trace: [Up, Up], state: 4, reached: ["reaches two"], unreached: [], outside: [], verdict: Completed }
expect Model.apply(lift, [Up, Up]).verdict == Deadlock({ rule: "the lift never jams" })
