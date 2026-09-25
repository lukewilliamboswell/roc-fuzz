app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-19-d025939" }

import pf.Fuzz

## Laziness and `map`/`map!` over `Stream.custom` (roc-lang/roc#11695).
## Building a stream, reading its size hint, and wrapping it in `map`/`map!`
## layers must never run `advance!` (the probe source crashes if it does).
## Driving a mapped list-backed source for `pulls` steps must yield the
## transformed items in source order, one source index per pull, and stopping
## early must not disturb anything.
Case : { items : List(Str), layers : U8, pulls : U8, known : Bool }

case_gen : Fuzz.Generator(Case)
case_gen = |state0| {
	{ value: items, state: s1 } = Fuzz.list(Fuzz.str, 40)(state0)
	{ value: layers, state: s2 } = Fuzz.u8_in(0, 3)(s1)
	{ value: pulls, state: s3 } = Fuzz.u8(s2)
	{ value: flag, state: s4 } = Fuzz.u8(s3)
	{ value: { items, layers, pulls, known: flag % 2 == 0 }, state: s4 }
}

wrap : Stream(Str), U8, Bool -> Stream(Str)
wrap = |stream, layers, effectful|
	if layers == 0 {
		stream
	} else if effectful {
		wrap(Stream.map(stream, |s| Str.concat(s, "!")), layers - 1, !effectful)
	} else {
		wrap(Stream.map(stream, |s| Str.concat(s, "?")), layers - 1, !effectful)
	}

suffix : U8, Bool -> Str
suffix = |layers, effectful|
	if layers == 0 {
		""
	} else if effectful {
		Str.concat("!", suffix(layers - 1, !effectful))
	} else {
		Str.concat("?", suffix(layers - 1, !effectful))
	}

test! : Case => Fuzz.Outcome
test! = |{ items, layers, pulls, known }| {
	probe_hint = if known Known(items.len()) else Unknown
	probe : Stream(Str)
	probe = Stream.custom({}, probe_hint, |_| crash "advance! ran before the stream was pulled")
	if Stream.size_hint(probe) != probe_hint {
		crash "size_hint changed the probe hint"
	}
	_ = wrap(probe, layers, known)
	_ = Stream.map!(probe, |s| Str.concat(s, "#"))

	hint = if known Known(items.len()) else Unknown
	indexed = Stream.custom(
		0,
		hint,
		|index| match items.get(index) {
			Ok(value) => Ok((Str.concat("${index.to_str()}:", value), index + 1))
			Err(_) => Err(NoMore)
		},
	)
	mapped = wrap(indexed, layers, known)
	if Stream.size_hint(mapped) != hint {
		crash "map changed the size hint"
	}
	tail = suffix(layers, known)
	limit = pulls.to_u64()
	var $rest = mapped
	var $pulled = 0
	var $done = Bool.False
	while !$done and $pulled < limit {
		match Stream.next!($rest) {
			One({ item, rest }) => {
				expected = match items.get($pulled) {
					Ok(value) => Str.concat(Str.concat("${$pulled.to_str()}:", value), tail)
					Err(_) => {
						crash "mapped stream produced more items than the source"
					}
				}
				if item != expected {
					crash "pull ${$pulled.to_str()} produced the wrong mapped item"
				}
				$pulled = $pulled + 1
				$rest = rest
			}
			Skip(_) => {
				crash "mapped Stream.custom produced a Skip"
			}
			Done => {
				$done = Bool.True
			}
		}
	}
	if $done and $pulled != items.len() {
		crash "mapped stream ended after ${$pulled.to_str()} of ${items.len().to_str()} items"
	}
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "streamCustomLazyMap",
	generator: case_gen,
	test!,
	show: |c| Str.inspect(c),
})
