app [target] { pf: platform "../../../../platform/main.roc" }

import pf.Fuzz
import Utf
import Wide

## Differential checker for the UTF-16 decoders: `Str.from_utf16_le`,
## `Str.from_utf16_be` and `Str.from_utf16_bom`, each strict and `_lossy`.
##
## Code units are shaped toward surrogates, pairs, byte order marks in either
## order, noncharacters and long runs, encoded in one byte order after an
## optional leading marker, and may end partway through a unit; one input in
## eight is raw bytes. The same bytes go through all six decoders, which are
## compared with the Utf.roc oracle: the exact first problem and its byte
## offset on failure, the exact string on success, and one U+FFFD per invalid
## unit or partial tail in lossy output. Strict must agree with lossy on
## valid input and re-encode to the original bytes. Allocation counts are
## pinned (`Utf.allocs_for`) and nothing leaks.
generator : Fuzz.Generator(Utf.Case(U16))
generator = Utf.case_generator(Utf.units16(128), 3)

test! : Utf.Case(U16) => Fuzz.Outcome
test! = |case| {
	Wide.check!(Wide.utf16, Utf.case16_bytes(case))
	Fuzz.keep
}

target = Fuzz.target_with!({
	examples: [],
	name: "strFromUtf16",
	generator,
	test!,
	show: |case| Str.inspect(Utf.case16_bytes(case)),
})
