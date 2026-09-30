app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-19-d025939" }

import pf.Fuzz

## Differential check for `Stream.custom` (roc-lang/roc#11695). A list-backed
## source is wrapped with a `Known(len)` or `Unknown` hint and driven two ways:
## by `collect!` and by a manual `next!` loop. Both must reproduce the list.
## Each item carries the source index it was produced from, so an `advance!`
## that ran more (or less) than once per pull shows up as a skipped index.
## The manual loop also checks the `Known` hint counts down per item and that
## a finished stream stays `Done`.
Case : { items : List(Str), known : Bool }

case_gen : Fuzz.Generator(Case)
case_gen = Fuzz.map2(Fuzz.list(Fuzz.str, 80), Fuzz.u8, |items, flag| { items, known: flag % 2 == 0 })

source : List(Str), Bool -> Stream({ index : U64, value : Str })
source = |items, known| {
	hint = if known Known(items.len()) else Unknown
	Stream.custom(
		0,
		hint,
		|index| match items.get(index) {
			Ok(value) => Ok(({ index, value }, index + 1))
			Err(_) => Err(NoMore)
		},
	)
}

test! : Case => Fuzz.Outcome
test! = |{ items, known }| {
	collected = Stream.collect!(source(items, known))
	if collected.len() != items.len() {
		crash "collect! returned ${collected.len().to_str()} items, expected ${items.len().to_str()}"
	}
	var $i = 0
	while $i < collected.len() {
		match (collected.get($i), items.get($i)) {
			(Ok(got), Ok(want)) => {
				if got.index != $i or got.value != want {
					crash "collect! item ${$i.to_str()} did not match the source"
				}
			}
			_ => {
				crash "index out of bounds while comparing"
			}
		}
		$i = $i + 1
	}

	var $rest = source(items, known)
	var $pulled = 0
	var $done = Bool.False
	while !$done {
		expected_hint = if known Known(items.len() - $pulled) else Unknown
		if Stream.size_hint($rest) != expected_hint {
			crash "size_hint did not count down after ${$pulled.to_str()} pulls"
		}
		match Stream.next!($rest) {
			One({ item, rest }) => {
				if item.index != $pulled {
					crash "pull ${$pulled.to_str()} produced source index ${item.index.to_str()}"
				}
				$pulled = $pulled + 1
				$rest = rest
			}
			Skip(_) => {
				crash "Stream.custom produced a Skip"
			}
			Done => {
				$done = Bool.True
			}
		}
	}
	if $pulled != items.len() {
		crash "next! loop produced ${$pulled.to_str()} items, expected ${items.len().to_str()}"
	}
	match Stream.next!($rest) {
		Done => {}
		_ => {
			crash "a finished stream produced another step"
		}
	}
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "streamCustomCollect",
	generator: case_gen,
	test!,
	show: |c| Str.inspect(c),
})
