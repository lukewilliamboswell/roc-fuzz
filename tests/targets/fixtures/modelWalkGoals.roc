app [target] { fuzz: platform "../../../platform/main.roc" }

import fuzz.Model

# A walk target whose declared example, made from a trace, reaches every goal
# of the machine, so `check` and every campaign pass with all goals reached.
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

target = Model.walk_target({
	name: "model-walk-goals",
	machine: counter,
	examples: [Model.walk_example(counter, { name: "up to three and down", revision: "1", trace: [Up, Up, Up, Down] })],
})

expect target.goals() == ["reaches three", "comes down from three"]
