import fuzz.Fuzz
import fuzz.Model
import fuzz.Target

## Tests of the fuzz targets `Model` makes, through the parts of a target that
## need no host: its name, its goals, its examples and its `show`. Running an
## input marks goals through the host, so that is tested by the fixtures
## `tests/targets/fixtures/model*.roc` under `blueprint run test-targets`.
ModelTargets := [].{}

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

## A machine whose code under test crashes on `Down` from zero.
fragile : Model.Machine(U64, [Up, Down])
fragile = { ..counter, actions: |_| [Up, Down] }

decode : List(U8) -> List([Up, Down])
decode = |bytes| bytes.map(|byte| if (byte % 2 == 0) Up else Down)

walked : Target
walked = Model.walk_target({
	name: "walked",
	machine: counter,
	examples: [
		Model.walk_example(counter, { name: "up to three and down", revision: "2", trace: [Up, Up, Up, Down] }),
		Fuzz.saved({ name: "retained", revision: "1", bytes: [0, 1] }),
	],
})

pathed : Target
pathed = Model.path_target({ name: "pathed", machine: fragile, decode, examples: [Fuzz.example({ name: "up", revision: "1", make: || [0, 0] })] })

stepped : Target
stepped = Model.step_target({ name: "stepped", machine: counter, generator: Fuzz.u64_in(0, 3), examples: [Fuzz.example({ name: "the top", revision: "1", make: || 3 })] })

# Each target declares the machine's goals, in the order they are written.
expect walked.name() == "walked" and walked.goals() == ["reaches three", "comes down from three"]
expect pathed.goals() == ["reaches three", "comes down from three"]
expect stepped.goals() == ["reaches three", "comes down from three"]

# A walk example holds the bytes that make `walk` take its trace, and a
# saved one holds its bytes as they are. `show` of a walk takes the walk.
expect walked.example_count() == 2
expect {
	made = walked.example(0)
	made.name == "up to three and down" and made.revision == "2" and walked.show(made.bytes) == Str.inspect(Model.walk(counter, [0, 0, 0, 0]))
}
expect walked.example(1) == { name: "retained", revision: "1", bytes: [0, 1] }
expect Model.walk(counter, [0, 0, 0, 0]).reached == ["reaches three", "comes down from three"]

# A path example holds the bytes its maker returns.
expect pathed.show(pathed.example(0).bytes) == Str.inspect([Up, Up])

# `show` of a path prints the path and does not run it, so it prints the
# path of an input on which the code under test crashes.
expect pathed.show([1, 0]) == Str.inspect([Down, Up])

# `show` of a step prints the state and what one step from it found.
expect stepped.show(stepped.example(0).bytes) == Str.inspect({ state: 3.U64, step: Model.step_from(counter, 3) })
