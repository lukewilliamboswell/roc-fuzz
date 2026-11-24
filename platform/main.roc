## A typed, coverage-guided fuzzing platform with a self-contained libFuzzer
## runner. Start with the `Fuzz` module; `Arbitrary` and `Target` are advanced
## interfaces retained for custom generators and legacy targets.
platform "roc-fuzz"
	requires {
		target : Target
	}
	exposes [Arbitrary, Fuzz, Model, Solve, Target]
	packages { sat: "https://github.com/lukewilliamboswell/rocsat/releases/download/0.0.2/3vAUWAXKSUvBxELd63BG4FjmGjgrJoHscu2GVFQTHhu.tar.zst" }
	provides {
		"roc_fuzz_build": build_for_host,
		"roc_fuzz_example": example_for_host,
		"roc_fuzz_example_count": example_count_for_host,
		"roc_fuzz_goals": goals_for_host,
		"roc_fuzz_name": name_for_host,
		"roc_fuzz_run": run_for_host!,
		"roc_fuzz_show": show_for_host,
		"roc_fuzz_target_count": target_count_for_host,
	}
	hosted {
		"roc_fuzz_alloc_count": Fuzz.alloc_count!,
		"roc_fuzz_before": Fuzz.before!,
		"roc_fuzz_count": Fuzz.count!,
		"roc_fuzz_dealloc_count": Fuzz.dealloc_count!,
		"roc_fuzz_forbidden": Fuzz.forbidden!,
		"roc_fuzz_live_alloc_count": Fuzz.live_alloc_count!,
		"roc_fuzz_mark": Fuzz.mark!,
		"roc_fuzz_prepare_return_box": Fuzz.prepare_return_box!,
		"roc_fuzz_realloc_count": Fuzz.realloc_count!,
		"roc_fuzz_requested_bytes": Fuzz.requested_bytes!,
		"roc_fuzz_scope_finish": Fuzz.scope_finish!,
		"roc_fuzz_scope_finish_return": Fuzz.scope_finish_return!,
		"roc_fuzz_scope_start": Fuzz.scope_start!,
	}
	targets: {
		inputs_dir: "targets/",
		x64musl: { inputs: ["rcrt1.o", "libhost.a", app, "libfuzzer.a", "libc++.a", "libc++abi.a", "libunwind.a", "libc.a", "libzigc.a", "libcompiler_rt.a", "libc.a", "libzigc.a", "libcompiler_rt.a"] },
		arm64mac: { inputs: ["libhost.a", app, "libfuzzer.a", "libc++abi.a", "libc++.a", "libcompiler_rt.a"] },
	}

import Arbitrary
import Fuzz
import Model
import Solve
import Target

# `target` holds functions, so it is not a constant: every function that names
# it evaluates it again. Only `build_for_host` does. The host calls it once in
# a process, holds the box, and passes it back to each of the others.
build_for_host : () -> Box(Target)
build_for_host = || Box.box(target)

target_count_for_host : Box(Target) -> U64
target_count_for_host = |built| Box.unbox(built).count()

selected : Box(Target), U64 -> Target
selected = |built, index| Box.unbox(built).get(index) ?? crash "target index is outside the suite inventory"

name_for_host : Box(Target), U64 -> Str
name_for_host = |built, index| selected(built, index).name()

example_count_for_host : Box(Target), U64 -> U64
example_count_for_host = |built, index| selected(built, index).example_count()

example_for_host : Box(Target), U64, U64 -> { name : Str, revision : Str, bytes : List(U8) }
example_for_host = |built, member, index| selected(built, member).example(index)

goals_for_host : Box(Target), U64 -> List(Str)
goals_for_host = |built, index| selected(built, index).goals()

run_for_host! : Box(Target), U64, List(U8) => U8
run_for_host! = |built, index, input| selected(built, index).run!(input)

show_for_host : Box(Target), U64, List(U8) -> Str
show_for_host = |built, index, input| selected(built, index).show(input)
