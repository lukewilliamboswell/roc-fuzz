app [target] { pf: platform "../../platform/main.roc" }

import pf.Fuzz

# `roc check` on this file panics instead of reporting a type error:
#
#     thread N panic: postcheck invariant violated:
#     erroneous checked type reached Monotype instantiation
#     src/postcheck/monotype/lower.zig:18752 in instNodeContent
#
# `List.set : List(a), U64, a -> Try(List(a), [OutOfBounds, ..])`, so assigning
# its result straight into `$l` is a type error. The compiler should say so
# rather than abort in Monotype lowering.
main! : List(U8) => U8
main! = |_data| {
	var $l = List.with_capacity(4)
	$l = List.append($l, 0.U64)
	$l = List.set($l, 0, 5)
	crash "len=${List.len($l).to_str()}"
}

target = Fuzz.from_bytes!({ name: "postcheckPanic", test!: main! })
