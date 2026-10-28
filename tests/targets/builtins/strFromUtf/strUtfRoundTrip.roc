app [target] { pf: platform "../../../../platform/main.roc" }

import pf.Fuzz
import Utf
import Wide

## Round trip arbitrary strings through hand-encoded UTF-16 and UTF-32, in
## both byte orders and with a leading marker, and back through every
## decoder.
##
## Each decoder must return the original string exactly, independently of the
## oracle; the encoded bytes then also go through `Wide.check!` (oracle,
## allocation counts, no leaks). Decoded strings must be independent of the
## borrowed bytes: growing one in place must not disturb the input, and the
## input must decode the same way afterwards.
round_trip! : Wide.Ops(e, eb), Str, Bool => {}
round_trip! = |ops, original, little| {
	label = "${ops.name} ${if (little) "le" else "be"}"
	bytes = (ops.encode)(original, little)
	marked = (ops.marker)(little).concat(bytes)
	strict = if (little) (ops.le)(bytes) else (ops.be)(bytes)
	lossy = if (little) (ops.le_lossy)(bytes) else (ops.be_lossy)(bytes)
	if (ops.observe)(strict) != Valid(original.to_utf8()) or lossy != original {
		crash "${label} round trip changed the string"
	}
	if (ops.observe_bom)((ops.bom)(marked)) != Got(Valid(original.to_utf8())) or (ops.bom_lossy)(marked) != Ok(original) {
		crash "${label} marker-led round trip changed the string"
	}
	grown = lossy.concat("!")
	if grown != original.concat("!") {
		crash "${label}: growing a decoded string produced the wrong contents"
	}
	if bytes != (ops.encode)(original, little) {
		crash "${label}: decoding or growing mutated the borrowed input bytes"
	}
	Wide.check!(ops, bytes)
	Wide.check!(ops, marked)
}

test! : Str => Fuzz.Outcome
test! = |original| {
	round_trip!(Wide.utf16, original, Bool.True)
	round_trip!(Wide.utf16, original, Bool.False)
	round_trip!(Wide.utf32, original, Bool.True)
	round_trip!(Wide.utf32, original, Bool.False)
	Fuzz.keep
}

target = Fuzz.target_with!({
	examples: [],
	name: "strUtfRoundTrip",
	generator: Fuzz.str,
	test!,
	show: |s| Str.inspect(s),
})
