app [target] { pf: platform "../../../../platform/main.roc" }

import pf.Fuzz
import Utf
import Wide

## Differential checker for the UTF-32 decoders: `Str.from_utf32_le`,
## `Str.from_utf32_be` and `Str.from_utf32_bom`, each strict and `_lossy`.
##
## Code units are shaped toward surrogates, values past U+10FFFF, byte order
## marks in either order and long runs, encoded in one byte order after an
## optional leading marker, and may end partway through a unit; one input in
## eight is raw bytes. The same bytes go through all six decoders, which are
## compared with the Utf.roc oracle: the exact first problem and its byte
## offset on failure, the exact string on success, and one U+FFFD per invalid
## unit or partial tail in lossy output. Strict must agree with lossy on
## valid input and re-encode to the original bytes. Allocation counts are
## pinned (`Utf.allocs_for`) and nothing leaks.
generator : Fuzz.Generator(Utf.Case(U32))
generator = Utf.case_generator(Utf.units32(128), 7)

test! : Utf.Case(U32) => Fuzz.Outcome
test! = |case| {
	Wide.check!(Wide.utf32, Utf.case32_bytes(case))
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "strFromUtf32",
	generator,
	test!,
	show: |case| Str.inspect(Utf.case32_bytes(case)),
})
