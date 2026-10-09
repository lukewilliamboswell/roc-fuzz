app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-19-d025939" }

import pf.Fuzz
import Utf

## Round trip arbitrary strings through hand-encoded UTF-16 and UTF-32 and back
## through `Str.from_utf16` / `Str.from_utf32` (strict and lossy).
##
## Also checks ownership: decoded strings must be independent of the borrowed
## unit list, so growing the result in place must not disturb the input, and
## the input must remain decodable afterwards.
test! : Str => Fuzz.Outcome
test! = |original| {
	u16s = Utf.encode_utf16(original)
	u32s = Utf.encode_utf32(original)
	if Str.from_utf16(u16s) != Ok(original) {
		crash "UTF-16 round trip changed the string"
	}
	if Str.from_utf32(u32s) != Ok(original) {
		crash "UTF-32 round trip changed the string"
	}
	if Str.from_utf16_lossy(u16s) != original or Str.from_utf32_lossy(u32s) != original {
		crash "lossy round trip changed the string"
	}
	grown16 = Str.from_utf16_lossy(u16s).concat("!")
	grown32 = Str.from_utf32_lossy(u32s).concat("!")
	if grown16 != original.concat("!") or grown32 != original.concat("!") {
		crash "growing a decoded string produced the wrong contents"
	}
	if Utf.encode_utf16(original) != u16s or Utf.encode_utf32(original) != u32s {
		crash "decoding mutated the borrowed input list"
	}
	Fuzz.expect_no_leaks!(|{}| (Str.from_utf16(u16s), Str.from_utf32(u32s)))
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "strUtfRoundTrip",
	generator: Fuzz.str,
	test!,
	show: |s| Str.inspect(s),
})
