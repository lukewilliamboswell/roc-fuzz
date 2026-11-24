app [target] { fuzz: platform "../../platform/main.roc" }

# A model of real code, checked two ways. Read `IndexModel.roc` first, then
# `IndexPaths.roc`.
#
#     roc test main.roc
#
# runs the search over six keys, grades the module's own test, catches the
# seeded bug of `SeededIndex.roc`, and checks the paths written out in
# `IndexPaths.roc`.
#
#     roc build --fuzz main.roc --output=index
#     ./index check
#     ./index run corpus --time=60
#
# builds the same machine as a fuzz target, on paths with keys of all 64
# bits. `check` runs the declared example, a tour that reaches all 73
# goals, and `run` adds a search. To see what the search reaches on its
# own, empty `examples`: the report lists each goal with the first input
# that reached it. Then decode with `IndexPaths.uniform` and the campaign
# breaks no rule, reaches about 30 goals, and is `inconclusive`; or build
# the machine from `SeededIndex.empty()` and the campaign is a finding.

import fuzz.Fuzz
import fuzz.Model
import IndexModel
import IndexPaths
import ReadyIndex

machine = IndexPaths.widen(IndexModel.machine(ReadyIndex.empty()))

target = Model.path_target({
	name: "index",
	machine,
	decode: IndexPaths.shaped,
	examples: [Fuzz.example({ name: "a tour of every goal", revision: "1", make: || IndexPaths.tour })],
})
