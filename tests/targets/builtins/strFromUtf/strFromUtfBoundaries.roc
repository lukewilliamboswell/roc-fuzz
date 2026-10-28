app [target] { pf: platform "../../../../platform/main.roc" }

import pf.Fuzz
import Utf
import Wide

## Boundary checker for the wide-UTF decoders.
##
## Both decoder passes skip ASCII 16 code units at a time (32 bytes of UTF-16,
## 64 of UTF-32), output of at most 23 bytes is built as a small string, and
## longer output is encoded into one exact-capacity list. Each input is an
## ASCII prefix of chosen length, one probe (a 1-4 byte scalar or an invalid
## unit) placed right at that offset, and a suffix of ASCII or dense
## multi-byte scalars, encoded in either byte order, optionally after a
## marker that shifts everything by one unit, and optionally cut short by a
## partial final unit. The probe so lands on every chunk edge and both sides
## of the small-string limit. All six decoders of the encoding are checked
## against the Utf.roc oracle with pinned allocation counts (`Wide.check!`).
Case : { utf32 : Bool, little : Bool, marked : Bool, prefix : U64, probe : U64, suffix_dense : Bool, suffix : U64, partial : U64, seed : U64 }

flag : Fuzz.Generator(Bool)
flag = Fuzz.map(Fuzz.u8_in(0, 1), |n| n == 1)

generator : Fuzz.Generator(Case)
generator = {
	utf32: flag,
	little: flag,
	marked: flag,
	prefix: Fuzz.u64_in(0, 200),
	probe: Fuzz.u64_in(0, 15),
	suffix_dense: flag,
	suffix: Fuzz.u64_in(0, 300),
	partial: Fuzz.u64_in(0, 3),
	seed: Fuzz.u64,
}.Fuzz

## Probes 0-10 are valid scalars of every UTF-8 width; the rest are invalid.
probe_units : Bool, U64 -> List(U32)
probe_units = |utf32, probe|
	if probe <= 10 {
		[Utf.width_scalar(probe)]
	} else {
		invalid : List(U32)
		invalid = if (utf32) [0xD800, 0xDFFF, 0x110000, 0xFFFFFFFF, 0xDC00] else [0xD800, 0xDBFF, 0xDC00, 0xDFFF, 0xD83D]
		[invalid.get(probe - 11) ?? 0xD800]
	}

scalars : Case -> List(U32)
scalars = |case| {
	suffix = if (case.suffix_dense) List.repeat(Utf.width_scalar(case.seed // 0x80), case.suffix) else Utf.ascii_seq(case.seed, case.suffix)
	marker = if (case.marked) [0xFEFF] else []
	marker.concat(Utf.ascii_seq(case.seed, case.prefix)).concat(probe_units(case.utf32, case.probe)).concat(suffix)
}

## The encoded input, ending with up to three bytes of a cut-short unit.
bytes : Case -> List(U8)
bytes = |case| {
	cps = scalars(case)
	if case.utf32 {
		Utf.units32_bytes(cps, case.little).concat(List.repeat(0x41, case.partial))
	} else {
		units = List.join(cps.map(|cp| if (cp > 0xFFFF) Utf.scalar_utf16(cp) else [cp.to_u16_wrap()]))
		Utf.units16_bytes(units, case.little).concat(List.repeat(0x41, case.partial % 2))
	}
}

test! : Case => Fuzz.Outcome
test! = |case| {
	if case.prefix > 200 or case.suffix > 300 or case.partial > 3 {
		return Fuzz.reject
	}

	input = bytes(case)
	if case.utf32 {
		Wide.check!(Wide.utf32, input)
	} else {
		Wide.check!(Wide.utf16, input)
	}
	Fuzz.keep
}

target = Fuzz.target_with!({
	examples: [],
	name: "strFromUtfBoundaries",
	generator,
	test!,
	show: |case| Str.inspect(case),
})
