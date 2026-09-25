app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-19-d025939" }

import pf.Fuzz

## Allocation balance for `Stream.custom` (roc-lang/roc#11695) with
## heap-backed state and items. Each scenario must release everything it
## allocated once its result is dropped:
## - `collect!` of a finite source,
## - an infinite `Unknown` source abandoned after `pulls` steps,
## - a source that yields an error item paired with a terminal state
##   (the PR's documented way to release a resource early), then is drained.
Case : { items : List(Str), pulls : U8, fail_at : U8, known : Bool }

case_gen : Fuzz.Generator(Case)
case_gen = |state0| {
	{ value: items, state: s1 } = Fuzz.list(Fuzz.str, 40)(state0)
	{ value: pulls, state: s2 } = Fuzz.u8(s1)
	{ value: fail_at, state: s3 } = Fuzz.u8(s2)
	{ value: flag, state: s4 } = Fuzz.u8(s3)
	{ value: { items, pulls, fail_at, known: flag % 2 == 0 }, state: s4 }
}

Src : [Open({ items : List(Str), index : U64 }), Closed]

finite : List(Str), Bool -> Stream(Str)
finite = |items, known|
	Stream.custom(
		{ items, index: 0 },
		if known Known(items.len()) else Unknown,
		|{ items: xs, index }| match xs.get(index) {
			Ok(value) => Ok((value, { items: xs, index: index + 1 }))
			Err(_) => Err(NoMore)
		},
	)

infinite : List(Str) -> Stream(Str)
infinite = |items|
	Stream.custom(
		items,
		Unknown,
		|xs| {
			next = xs.append(Str.concat("x", xs.len().to_str()))
			Ok((Str.join_with(xs.take_last(2), ","), next))
		},
	)

failing : List(Str), U64 -> Stream(Try(Str, [SourceFailed(U64)]))
failing = |items, fail_at|
	Stream.custom(
		Open({ items, index: 0 }),
		Unknown,
		|src| match src {
			Closed => Err(NoMore)
			Open({ items: xs, index }) =>
				if index == fail_at {
					Ok((Err(SourceFailed(index)), Closed))
				} else {
					match xs.get(index) {
						Ok(value) => Ok((Ok(value), Open({ items: xs, index: index + 1 })))
						Err(_) => Err(NoMore)
					}
				}
		},
	)

drop_after! : Stream(Str), U64 => U64
drop_after! = |stream, limit| {
	var $rest = stream
	var $pulled = 0
	while $pulled < limit {
		match Stream.next!($rest) {
			One({ rest, .. }) => {
				$rest = rest
				$pulled = $pulled + 1
			}
			Skip({ rest }) => {
				$rest = rest
			}
			Done => {
				break
			}
		}
	}
	$pulled
}

test! : Case => Fuzz.Outcome
test! = |{ items, pulls, fail_at, known }| {
	Fuzz.expect_no_leaks!(|{}| Stream.collect!(finite(items, known)))
	Fuzz.expect_no_leaks!(|{}| drop_after!(finite(items, known), pulls.to_u64()))
	Fuzz.expect_no_leaks!(|{}| drop_after!(infinite(items), pulls.to_u64()))
	Fuzz.expect_no_leaks!(|{}| {
		out = Stream.collect!(failing(items, fail_at.to_u64()))
		if fail_at.to_u64() < items.len() {
			match out.last() {
				Ok(Err(SourceFailed(i))) if i == fail_at.to_u64() => {}
				_ => {
					crash "failing source did not end with its error item"
				}
			}
		}
		out
	})
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "streamCustomLeaks",
	generator: case_gen,
	test!,
	show: |c| Str.inspect(c),
})
