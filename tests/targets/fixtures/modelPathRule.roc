app [target] { fuzz: platform "../../../platform/main.roc" }

import fuzz.Fuzz
import fuzz.Model

# A path target on a counter that goes past its limit when it is told to.
# The declared example breaks no rule and reaches every goal, so `check`
# passes; the seed, four `Up`s, breaks "never above three", so its replay and
# every campaign are a finding. `show` prints the seed's path without running
# it.
counter : Model.Machine(U64, [Up, Down])
counter = {
	init: 0,
	actions: |n| if (n == 0) [Up] else if (n == 3) [Down] else [Up, Down],
	step: |n, action| match action {
		Up => n + 1
		Down => if (n == 0) 0 else n - 1
	},
	rules: [
		Model.always("never above three", |n| n <= 3),
		Model.sometimes("reaches three", |n| n == 3),
		Model.sometimes_step("comes down from three", |{ before, action, after: _ }| action == Down and before == 3),
	],
}

decode : List(U8) -> List([Up, Down])
decode = |bytes| bytes.map(|byte| if (byte % 2 == 0) Up else Down)

target = Model.path_target({
	name: "model-path-rule",
	machine: counter,
	decode,
	examples: [Fuzz.saved({ name: "up to three and down", revision: "1", bytes: [0, 0, 0, 1] })],
})

expect target.show([0, 0, 0, 0]) == "[Up, Up, Up, Up]"
expect Model.apply(counter, decode([0, 0, 0, 0])).verdict == Violated({ rule: "never above three" })
