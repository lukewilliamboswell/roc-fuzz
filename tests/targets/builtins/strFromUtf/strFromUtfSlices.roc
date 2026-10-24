app [target] { pf: platform "../../../../platform/main.roc" }

import pf.Fuzz
import Utf
import Wide

## Seamless-slice checker for the wide-UTF decoders.
##
## The decoders borrow their bytes and load 16 at a time from them; the
## marker-led forms decode a slice of their own input. A slice shares its
## parent's allocation from an offset, so a slice at any byte offset
## (including ones misaligned for code units and for 16-byte loads) must
## decode exactly like a fresh list of the same bytes, and nothing outside it
## may influence the result. The parent has arbitrary bytes before the slice,
## and after it sometimes a low surrogate / invalid unit, so an out-of-bounds
## read would pair with it or change the problem reported. Every decoder's
## result on the slice must equal its result on a fresh copy, the slice is
## checked against the Utf.roc oracle with the fresh list's allocation counts
## (`Wide.check!`), the parent is unchanged afterwards, and nothing leaks.
Case : { utf32 : Bool, how : U8, before : List(U8), body16 : Utf.Case(U16), body32 : Utf.Case(U32), trap : Bool, after : List(U8) }

generator : Fuzz.Generator(Case)
generator = {
	utf32: Fuzz.map(Fuzz.u8_in(0, 1), |n| n == 1),
	how: Fuzz.u8_in(0, 2),
	before: Fuzz.list(Fuzz.u8, 40),
	body16: Utf.case_generator(Utf.units16(48), 3),
	body32: Utf.case_generator(Utf.units32(48), 7),
	trap: Fuzz.map(Fuzz.u8_in(0, 1), |n| n == 1),
	after: Fuzz.list(Fuzz.u8, 40),
}.Fuzz

## Take `len` bytes at `start` of `parent` as a slice, three ways.
slice_of : List(U8), U8, U64, U64 -> List(U8)
slice_of = |parent, how, start, len| match how {
	0 => parent.sublist({ start, len })
	1 => parent.drop_first(start).drop_last(parent.len() - start - len)
	_ => parent.split_at(start).others.take_first(len)
}

body : Case -> List(U8)
body = |case| if (case.utf32) Utf.case32_bytes(case.body32) else Utf.case16_bytes(case.body16)

## Units that would pair with, or replace, a read past the slice's end.
trap : Case -> List(U8)
trap = |case| {
	little = if (case.utf32) case.body32.little else case.body16.little
	if !case.trap {
		[]
	} else if case.utf32 {
		Utf.units32_bytes([0xDC00, 0x110000], little)
	} else {
		Utf.units16_bytes([0xDC00, 0xD800], little)
	}
}

## Every decoder's result on the slice must equal its result on a fresh list.
same! : Wide.Ops(e, eb), List(U8), List(U8) => {}
same! = |ops, slice, fresh| {
	if (ops.observe)((ops.le)(slice)) != (ops.observe)((ops.le)(fresh)) or (ops.observe)((ops.be)(slice)) != (ops.observe)((ops.be)(fresh)) {
		crash "Str.from_${ops.name}_le/be decoded a slice differently from a fresh list"
	}
	if (ops.le_lossy)(slice) != (ops.le_lossy)(fresh) or (ops.be_lossy)(slice) != (ops.be_lossy)(fresh) {
		crash "Str.from_${ops.name}_le/be_lossy decoded a slice differently from a fresh list"
	}
	if (ops.observe_bom)((ops.bom)(slice)) != (ops.observe_bom)((ops.bom)(fresh)) or (ops.bom_lossy)(slice) != (ops.bom_lossy)(fresh) {
		crash "Str.from_${ops.name}_bom decoded a slice differently from a fresh list"
	}
	Wide.check!(ops, slice)
}

test! : Case => Fuzz.Outcome
test! = |case| {
	content = body(case)
	fresh = List.with_capacity(content.len()).concat(content)
	parent = case.before.concat(content).concat(trap(case)).concat(case.after)
	parent_copy = List.with_capacity(parent.len()).concat(parent)
	start = case.before.len()
	slice = slice_of(parent, case.how, start, content.len())
	if slice != fresh {
		crash "slice construction did not reproduce the body bytes"
	}
	if case.utf32 {
		same!(Wide.utf32, slice, fresh)
	} else {
		same!(Wide.utf16, slice, fresh)
	}
	if parent != parent_copy {
		crash "decoding a slice changed its parent list"
	}
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "strFromUtfSlices",
	generator,
	test!,
	show: |case| "parent=${Str.inspect(case.before.concat(body(case)).concat(trap(case)).concat(case.after))} start=${case.before.len().to_str()} len=${body(case).len().to_str()} how=${case.how.to_str()}",
})
