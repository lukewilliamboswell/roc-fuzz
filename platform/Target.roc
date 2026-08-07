Target := [Target({ name : Str, run : List(U8) -> U8, show : List(U8) -> Str })].{
	new : { name : Str, run : List(U8) -> U8, show : List(U8) -> Str } -> Target
	new = |inner| Target(inner)

	name : Target -> Str
	name = |Target(inner)| inner.name

	run : Target, List(U8) -> U8
	run = |Target(inner), input| (inner.run)(input)

	show : Target, List(U8) -> Str
	show = |Target(inner), input| (inner.show)(input)
}
