app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-19-d025939" }

import pf.Fuzz
import Utf

## Differential checker for strict `Str.from_utf16`.
##
## Units are shaped toward surrogate, noncharacter, BOM, and range-boundary
## values, then compared against the hand-written oracle in Utf.roc:
## the exact first problem and code-unit index on failure, the exact string on
## success. Allocation contract (`Utf.strict_alloc_bound`): failures allocate
## nothing, inline-sized output allocates nothing, and longer output allocates
## exactly once. A successful decode must also agree with the lossy decoder and
## re-encode to the original units, and nothing leaks.
generator : Fuzz.Generator(List(U16))
generator = Fuzz.map(
	Fuzz.list(Fuzz.map2(Fuzz.u8_in(0, 9), Fuzz.u64, Utf.utf16_chunk), 128),
	|chunks| List.join(chunks),
)

actual_problem = |result| match result {
	Ok(_) => NoProblem
	Err(BadUtf16({ problem, index })) => match problem {
		UnpairedHighSurrogate => UnpairedHigh(index)
		UnpairedLowSurrogate => UnpairedLow(index)
	}
}

test! : List(U16) => Fuzz.Outcome
test! = |units| {
	expected = Utf.decode_utf16(units)
	{ value: result, allocations } = Fuzz.measure_allocs!(|{}| Str.from_utf16(units))
	got = actual_problem(result)
	if got != expected.problem {
		crash "problem mismatch: got ${Str.inspect(got)}, expected ${Str.inspect(expected.problem)}"
	}
	bound = Utf.strict_alloc_bound(expected)
	if allocations > bound {
		crash "strict decode allocated ${allocations.to_str()} times (expected <= ${bound.to_str()})"
	}
	match result {
		Err(_) => {}
		Ok(decoded) => {
			if decoded.to_utf8() != expected.bytes {
				crash "decoded bytes differ from oracle"
			}
			if Str.from_utf16_lossy(units) != decoded {
				crash "lossy decode disagrees with strict decode on valid input"
			}
			if Utf.encode_utf16(decoded) != units {
				crash "decoded string did not re-encode to the original units"
			}
		}
	}
	Fuzz.expect_no_leaks!(|{}| Str.from_utf16(units))
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "strFromUtf16",
	generator,
	test!,
	show: |units| Str.inspect(units),
})
