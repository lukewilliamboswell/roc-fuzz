app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-19-d025939" }

import pf.Fuzz

## Differential check for `Iter.custom` with caller-supplied size hints. A
## list-backed source is driven three ways -- `List.from_iter` (which
## pre-sizes from `Known(n)` and appends unchecked), `List.from_iter` through
## a `map`, and a manual `Iter.next` walk -- and each must reproduce the list.
## The walk also checks the hint counts down per item and that a finished
## iterator stays `Done`. Everything must release its allocations.
##
## Hints are exact, over-counted, or `Unknown`. `Known(n)` is a promise: a
## source that yields more than n items deliberately crashes on the countdown
## before the extra item reaches the unchecked append, so under-counts are
## not generated.
Case : { items : List(Str), hint : [Known(U64), Unknown] }

case_gen : Fuzz.Generator(Case)
case_gen = Fuzz.map2(
	Fuzz.list(Fuzz.str, 80),
	Fuzz.u8,
	|items, h| {
		hint = if h == 255 Unknown else if h >= 128 Known(items.len()) else Known(items.len() + h.to_u64())
		{ items, hint }
	},
)

source : List(Str), [Known(U64), Unknown] -> Iter({ index : U64, value : Str })
source = |items, hint|
	Iter.custom(
		0,
		hint,
		|index| match items.get(index) {
			Ok(value) => Ok(({ index, value }, index + 1))
			Err(_) => Err(NoMore)
		},
	)

expected_hint : [Known(U64), Unknown], U64 -> [Known(U64), Unknown]
expected_hint = |hint, pulled|
	match hint {
		Known(n) => Known(n - pulled)
		Unknown => Unknown
	}

check! : Case => {}
check! = |{ items, hint }| {
	values = List.from_iter(source(items, hint)).map(|item| item.value)
	if values != items {
		crash "List.from_iter over Iter.custom with ${Str.inspect(hint)} did not return the source"
	}
	mapped = List.from_iter(source(items, hint).map(|item| item.value))
	if mapped != items {
		crash "List.from_iter over a mapped Iter.custom did not return the source"
	}

	var $rest = source(items, hint)
	var $pulled = 0
	var $done = Bool.False
	while !$done {
		if Iter.size_hint($rest) != expected_hint(hint, $pulled) {
			crash "size_hint was ${Str.inspect(Iter.size_hint($rest))} after ${$pulled.to_str()} pulls from ${Str.inspect(hint)}"
		}
		match Iter.next($rest) {
			One({ item, rest }) => {
				if item.index != $pulled {
					crash "pull ${$pulled.to_str()} produced source index ${item.index.to_str()}"
				}
				$pulled = $pulled + 1
				$rest = rest
			}
			Skip(_) => {
				crash "Iter.custom produced a Skip"
			}
			Done => {
				$done = Bool.True
			}
		}
	}
	if $pulled != items.len() {
		crash "Iter.next walk produced ${$pulled.to_str()} items, expected ${items.len().to_str()}"
	}
	match Iter.next($rest) {
		Done => {}
		_ => {
			crash "a finished iterator produced another step"
		}
	}
}

test! : Case => Fuzz.Outcome
test! = |case| {
	Fuzz.expect_no_leaks!(|{}| check!(case))
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "iterCustom",
	generator: case_gen,
	test!,
	show: |c| Str.inspect(c),
})
