## Advanced, type-erased bridge between a typed Roc property and the native
## runner.
##
## Applications normally construct this value with `Fuzz.target` or
## `Fuzz.target_with` and expose it as `target`. The methods here define the
## small byte-oriented ABI consumed by the embedded runner.
Target := [Target({ name : Str, run! : List(U8) => U8, show : List(U8) -> Str, example_count : () -> U64, example : U64 -> { name : Str, revision : Str, bytes : List(U8) } }), Targets(List(Target))].{

	## Construct a target from low-level runner callbacks.
	##
	## `run!` returns zero for a kept input and a non-zero status for a rejected
	## input. Failures should use `crash` or `expect` rather than status codes.
	new : { name : Str, run! : List(U8) => U8, show : List(U8) -> Str, example_count : () -> U64, example : U64 -> { name : Str, revision : Str, bytes : List(U8) } } -> Target
	new = |inner| Target(inner)

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
