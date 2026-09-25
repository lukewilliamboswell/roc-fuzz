app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-19-d025939" }

import pf.Fuzz

## `Stream.collect!` pre-sizes from `Known(n)` and uses the unchecked
## `list_append_unsafe` while that reservation lasts. `Stream.custom` takes the
## hint from the caller, so this target passes hints that under- and
## over-count the real items and checks `collect!` still returns exactly the
## produced items without crashing or corrupting memory (roc-lang/roc#11695).
## An undercount used to crash with "Integer subtraction overflowed" from the
## `Known(l - 1)` countdown; it now degrades to `Unknown`.
Case : { items : List(Str), hint : U8 }

case_gen : Fuzz.Generator(Case)
case_gen = Fuzz.map2(Fuzz.list(Fuzz.str, 80), Fuzz.u8, |items, hint| { items, hint })

test! : Case => Fuzz.Outcome
test! = |{ items, hint }| {
	stream = Stream.custom(
		0,
		Known(hint.to_u64()),
		|index| match items.get(index) {
			Ok(value) => Ok((value, index + 1))
			Err(_) => Err(NoMore)
		},
	)
	collected = Stream.collect!(stream)
	if collected != items {
		crash "collect! with Known(${hint.to_str()}) over ${items.len().to_str()} items did not return the source"
	}
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "streamCustomBadHint",
	generator: case_gen,
	test!,
	show: |c| Str.inspect(c),
})
