app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-19-d025939" }

import pf.Fuzz
import Utf

## Differential checker for strict `Str.from_utf32`.
##
## Units are shaped toward surrogate, noncharacter, BOM, and range-boundary
## values, then compared against the hand-written oracle in Utf.roc:
## the exact first problem and code-unit index on failure, the exact string on
## success. Allocation contract: strict failures allocate nothing, successes
## allocate at most once, and nothing leaks either way. A successful decode
## must also agree with the lossy decoder and re-encode to the original units.
generator : Fuzz.Generator(List(U32))
generator = Fuzz.map(
	Fuzz.list(Fuzz.map2(Fuzz.u8_in(0, 7), Fuzz.u64, Utf.utf32_chunk), 96),
	|chunks| List.join(chunks),
)

actual_problem = |result| match result {
	Ok(_) => NoProblem
	Err(BadUtf32({ problem, index })) => match problem {
		CodePointTooLarge => TooLarge(index)
		SurrogateCodePoint => Surrogate(index)
	}
}

test! : List(U32) => Fuzz.Outcome
test! = |units| {
	expected = Utf.decode_utf32(units)
	{ value: result, allocations } = Fuzz.measure_allocs!(|{}| Str.from_utf32(units))
	got = actual_problem(result)
	if got != expected.problem {
		crash "problem mismatch: got ${Str.inspect(got)}, expected ${Str.inspect(expected.problem)}"
	}
	match result {
		Err(_) => {
			if allocations != 0 {
				crash "strict failure allocated ${allocations.to_str()} times (expected 0)"
			}
		}
		Ok(decoded) => {
			if allocations > 1 {
				crash "strict success allocated ${allocations.to_str()} times (expected <= 1)"
			}
			if decoded.to_utf8() != expected.bytes {
				crash "decoded bytes differ from oracle"
			}
			if Str.from_utf32_lossy(units) != decoded {
				crash "lossy decode disagrees with strict decode on valid input"
			}
			if Utf.encode_utf32(decoded) != units {
				crash "decoded string did not re-encode to the original units"
			}
		}
	}
	Fuzz.expect_no_leaks!(|{}| Str.from_utf32(units))
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "strFromUtf32",
	generator,
	test!,
	show: |units| Str.inspect(units),
})
