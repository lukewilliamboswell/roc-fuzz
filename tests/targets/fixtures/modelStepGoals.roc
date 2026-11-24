app [target] { fuzz: platform "../../../platform/main.roc" }

import fuzz.Fuzz
import fuzz.Model

# A step target: one step from each generated count. Every count the
# generator makes keeps the rules, and the declared example, the top count,
# reaches both goals, so `check` and every campaign pass.
counter : Model.Machine(U64, [Up, Down])
counter = {
	init: 0,
	actions: |n| if (n == 0) [Up] else if (n == 3) [Down] else [Up, Down],
	step: |n, action| match action {
		Up => n + 1
		Down => n - 1
	},
	rules: [
		Model.always("never above three", |n| n <= 3),
		Model.sometimes("reaches three", |n| n == 3),
		Model.sometimes_step("comes down from three", |{ before, action, after: _ }| action == Down and before == 3),
	],
}

target = Model.step_target({
	name: "model-step-goals",
	machine: counter,
	generator: Fuzz.u64_in(0, 3),
	examples: [Fuzz.example({ name: "the top", revision: "1", make: || 3 })],
})

expect Model.step_from(counter, 3) == Preserved({ actions: 1, reached: ["reaches three", "comes down from three"] })
