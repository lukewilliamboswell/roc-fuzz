app [target] { pf: platform "../../platform/main.roc" }

import pf.Fuzz

# A value discarded with `_ =` should be released right away. Here it is
# released late when it is the result of a function that uses `?` and is
# called through a function value: the allocation is still live when the next
# effect runs, and is freed only when the enclosing function ends. The same
# call made directly (`make(data)`), or through the function value to an
# equivalent function written with `if` instead of `?`, releases it before
# the second count. Nothing leaks in the end, so the runner's per-input leak
# check passes, but `Fuzz.expect_no_leaks!` reports a leak, since it reads the
# balance after dropping its body's result.
#
# Found while porting the wide-UTF targets: `Str.from_utf16_bom` and the
# other `_bom` decoders use `?`, so calling them through a record field and
# discarding the result inside `Fuzz.expect_no_leaks!` reported one leaked
# allocation whenever the output was longer than 23 bytes (a heap string).
# Reproduces on nightly-2026-10-23-18478ff; this case is an expected failure
# until the compiler releases the value on time.
check : U64 -> Try({}, [Empty])
check = |n| if (n == 0) Err(Empty) else Ok({})

make : List(U8) -> Try(List(U8), [Empty])
make = |bytes| {
	_ = check(bytes.len() + 1)?
	Ok(List.with_capacity(40).concat(bytes))
}

apply : (List(U8) -> Try(List(U8), e)), List(U8) -> Try(List(U8), e)
apply = |f, x| f(x)

main! : List(U8) => U8
main! = |data| {
	before = Fuzz.live_alloc_count!()
	_ = apply(make, data)
	after = Fuzz.live_alloc_count!()
	if after != before {
		crash "apply(make, data) left ${(after - before).to_str()} allocation(s) live after its result was discarded"
	}
	0
}

target = Fuzz.from_bytes!({
	name: "lateDropThroughFunctionValue",
	test!: main!,
})
