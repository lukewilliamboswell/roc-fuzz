platform "roc-fuzz"
	requires {
		target : Target
	}
	exposes [Arbitrary, Fuzz, Target]
	packages {}
	provides {
		"roc_fuzz_name": name_for_host,
		"roc_fuzz_run": run_for_host,
		"roc_fuzz_show": show_for_host,
	}
	targets: {
		inputs_dir: "targets/",
		x64musl: { inputs: ["crt1.o", "libhost.a", app, "libfuzzer.a", "libc++.a", "libc++abi.a", "libunwind.a", "libc.a", "libzigc.a", "libcompiler_rt.a", "libc.a", "libzigc.a", "libcompiler_rt.a"] },
	}

import Arbitrary
import Fuzz
import Target exposing [Target]

name_for_host : {} -> Str
name_for_host = |_| target.name()

run_for_host : List(U8) -> U8
run_for_host = |input| target.run(input)

show_for_host : List(U8) -> Str
show_for_host = |input| target.show(input)
