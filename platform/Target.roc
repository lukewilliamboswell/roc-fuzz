## Advanced, type-erased bridge between a typed Roc property and the native
## runner.
##
## Applications normally construct this value with `Fuzz.target` or
## `Fuzz.target_with` and expose it as `target`. The methods here define the
## small byte-oriented ABI consumed by the embedded runner.
Target := [Target({ name : Str, run! : List(U8) => U8, show : List(U8) -> Str })].{

	## Construct a target from low-level runner callbacks.
	##
	## `run!` returns zero for a kept input and a non-zero status for a rejected
	## input. Failures should use `crash` or `expect` rather than status codes.
	new : { name : Str, run! : List(U8) => U8, show : List(U8) -> Str } -> Target
	new = |inner| Target(inner)

	## Return the human-readable target name reported by the executable.
	name : Target -> Str
	name = |Target(inner)| inner.name

	## Decode and test one raw input, returning the runner status code.
	##
	## This is effectful so a target may read the platform's allocation
	## counters (see `Fuzz.alloc_count!`). A target whose property needs no
	## effects can still be written as a plain pure function; a pure body
	## satisfies this signature unchanged.
	run! : Target, List(U8) => U8
	run! = |Target(inner), input| (inner.run!)(input)

	## Decode one raw input into a human-readable typed value.
	show : Target, List(U8) -> Str
	show = |Target(inner), input| (inner.show)(input)
}
