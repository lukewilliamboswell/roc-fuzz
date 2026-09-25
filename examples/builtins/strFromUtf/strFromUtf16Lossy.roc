app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-19-d025939" }

import pf.Fuzz
import Utf

## Differential checker for `Str.from_utf16_lossy`.
##
## Every invalid unit (unpaired surrogate for UTF-16; surrogate or
## out-of-range value for UTF-32) must become exactly one U+FFFD and decoding
## must resume at the next unit. The output is compared byte-for-byte with the
## Utf.roc oracle, stays within `Utf.alloc_bound`, and never leaks.
generator : Fuzz.Generator(List(U16))
generator = Fuzz.map(
	Fuzz.list(Fuzz.map2(Fuzz.u8_in(0, 9), Fuzz.u64, Utf.utf16_chunk), 128),
	|chunks| List.join(chunks),
)

test! : List(U16) => Fuzz.Outcome
test! = |units| {
	expected = Utf.decode_utf16(units)
	decoded = Fuzz.expect_allocs_at_most!(Utf.alloc_bound(expected.bytes), |{}| Str.from_utf16_lossy(units))
	if decoded.to_utf8() != expected.bytes {
		crash "lossy output differs from oracle"
	}
	if expected.problem == NoProblem and Str.from_utf16(units) != Ok(decoded) {
		crash "lossy decode disagrees with strict decode on valid input"
	}
	Fuzz.expect_no_leaks!(|{}| Str.from_utf16_lossy(units))
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "strFromUtf16Lossy",
	generator,
	test!,
	show: |units| Str.inspect(units),
})
