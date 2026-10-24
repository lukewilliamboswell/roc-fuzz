import pf.Fuzz
import Utf

Wide :: {}.{
	# Shared property checks for the wide-UTF decoder targets. The UTF-16 and
	# UTF-32 decoders are passed in as a record, so one check covers both
	# encodings and every form: little-endian, big-endian and marker-led,
	# each strict and lossy.

	## The six decoders of one encoding, with the oracle and encoder for it.
	Ops(e, eb) : {
		name : Str,
		le : List(U8) -> Try(Str, e),
		be : List(U8) -> Try(Str, e),
		le_lossy : List(U8) -> Str,
		be_lossy : List(U8) -> Str,
		bom : List(U8) -> Try(Str, eb),
		bom_lossy : List(U8) -> Try(Str, [MissingByteOrderMark]),
		observe : Try(Str, e) -> Utf.Strict,
		observe_bom : Try(Str, eb) -> [Missing, Got(Utf.Strict)],
		decode : List(U8), Bool -> Utf.Decoded,
		decode_bom : List(U8) -> Utf.Bom,
		encode : Str, Bool -> List(U8),
		marker : Bool -> List(U8),
		sizes : List(U8) -> U64,
	}

	utf16 : Ops([BadUtf16({ problem : Str.Utf16Problem, index : U64 })], [BadUtf16({ problem : Str.Utf16Problem, index : U64 }), MissingByteOrderMark])
	utf16 = {
		name: "utf16",
		le: Str.from_utf16_le,
		be: Str.from_utf16_be,
		le_lossy: Str.from_utf16_le_lossy,
		be_lossy: Str.from_utf16_be_lossy,
		bom: Str.from_utf16_bom,
		bom_lossy: Str.from_utf16_bom_lossy,
		observe: Utf.strict16,
		observe_bom: |result| match result {
			Ok(s) => Got(Valid(s.to_utf8()))
			Err(BadUtf16(bad)) => Got(Utf.strict16(Err(BadUtf16(bad))))
			Err(MissingByteOrderMark) => Missing
		},
		decode: Utf.decode16,
		decode_bom: Utf.bom16,
		encode: Utf.encode16,
		marker: Utf.bom16_bytes,
		sizes: sizes16,
	}

	utf32 : Ops([BadUtf32({ problem : Str.Utf32Problem, index : U64 })], [BadUtf32({ problem : Str.Utf32Problem, index : U64 }), MissingByteOrderMark])
	utf32 = {
		name: "utf32",
		le: Str.from_utf32_le,
		be: Str.from_utf32_be,
		le_lossy: Str.from_utf32_le_lossy,
		be_lossy: Str.from_utf32_be_lossy,
		bom: Str.from_utf32_bom,
		bom_lossy: Str.from_utf32_bom_lossy,
		observe: Utf.strict32,
		observe_bom: |result| match result {
			Ok(s) => Got(Valid(s.to_utf8()))
			Err(BadUtf32(bad)) => Got(Utf.strict32(Err(BadUtf32(bad))))
			Err(MissingByteOrderMark) => Missing
		},
		decode: Utf.decode32,
		decode_bom: Utf.bom32,
		encode: Utf.encode32,
		marker: Utf.bom32_bytes,
		sizes: sizes32,
	}

	check_allocs! : Str, U64, U64 => {}
	check_allocs! = |label, allocations, expected| {
		if allocations != expected {
			crash "${label} allocated ${allocations.to_str()} times (expected ${expected.to_str()})"
		}
	}

	order_name : Bool -> Str
	order_name = |little| if (little) "le" else "be"

	## One byte order: strict and lossy against the oracle, their allocations,
	## strict agreeing with lossy on valid input, and the re-encoding round trip.
	check_order! : Ops(e, eb), List(U8), Bool => {}
	check_order! = |ops, bytes, little| {
		label = "Str.from_${ops.name}_${order_name(little)}"
		expected = (ops.decode)(bytes, little)
		{ value: strict, allocations: strict_allocs } = Fuzz.measure_allocs!(|{}| if (little) (ops.le)(bytes) else (ops.be)(bytes))
		{ value: lossy, allocations: lossy_allocs } = Fuzz.measure_allocs!(|{}| if (little) (ops.le_lossy)(bytes) else (ops.be_lossy)(bytes))
		got = (ops.observe)(strict)
		if got != Utf.expected_strict(expected) {
			crash "${label}: got ${Str.inspect(got)}, oracle ${Str.inspect(Utf.expected_strict(expected))}"
		}
		if lossy.to_utf8() != expected.bytes {
			crash "${label}_lossy: got ${Str.inspect(lossy.to_utf8())}, oracle ${Str.inspect(expected.bytes)}"
		}
		check_allocs!(label, strict_allocs, Utf.strict_allocs(expected))
		check_allocs!("${label}_lossy", lossy_allocs, Utf.allocs_for(expected.bytes))
		match strict {
			Ok(s) => {
				if s != lossy {
					crash "${label}: lossy decode disagrees with strict decode on valid input"
				}
				if (ops.encode)(s, little) != bytes {
					crash "${label}: decoded string did not re-encode to the original bytes"
				}
			}
			Err(_) => {}
		}
	}

	## The marker-led forms: a missing marker in both, otherwise the payload
	## after exactly one marker, with indices that count the marker.
	check_bom! : Ops(e, eb), List(U8) => {}
	check_bom! = |ops, bytes| {
		label = "Str.from_${ops.name}_bom"
		expected = (ops.decode_bom)(bytes)
		{ value: strict, allocations: strict_allocs } = Fuzz.measure_allocs!(|{}| (ops.bom)(bytes))
		{ value: lossy, allocations: lossy_allocs } = Fuzz.measure_allocs!(|{}| (ops.bom_lossy)(bytes))
		check_allocs!(label, strict_allocs, Utf.bom_allocs(expected, Bool.False))
		check_allocs!("${label}_lossy", lossy_allocs, Utf.bom_allocs(expected, Bool.True))
		got = (ops.observe_bom)(strict)
		match expected {
			MissingBom =>
				if got != Missing or lossy != Err(MissingByteOrderMark) {
					crash "${label}: expected MissingByteOrderMark, got ${Str.inspect(got)} and ${Str.inspect(lossy)}"
				}
			HasBom(little, decoded) => {
				if got != Got(Utf.expected_strict(decoded)) {
					crash "${label}: got ${Str.inspect(got)}, oracle ${Str.inspect(Utf.expected_strict(decoded))}"
				}
				match lossy {
					Ok(text) =>
						if text.to_utf8() != decoded.bytes {
							crash "${label}_lossy: got ${Str.inspect(text.to_utf8())}, oracle ${Str.inspect(decoded.bytes)}"
						}
					Err(MissingByteOrderMark) => crash "${label}_lossy reported a missing marker"
				}
				match strict {
					Ok(s) => {
						if Ok(s) != lossy {
							crash "${label}: lossy decode disagrees with strict decode on valid input"
						}
						if (ops.marker)(little).concat((ops.encode)(s, little)) != bytes {
							crash "${label}: marker plus decoded string did not re-encode to the original bytes"
						}
					}
					Err(_) => {}
				}
			}
		}
	}

	## Every decoder of one encoding on `bytes`: both byte orders (the same
	## bytes read either way), the marker-led forms, and no leaks.
	check! : Ops(e, eb), List(U8) => {}
	check! = |ops, bytes| {
		check_order!(ops, bytes, Bool.True)
		check_order!(ops, bytes, Bool.False)
		check_bom!(ops, bytes)
		Fuzz.expect_no_leaks!(|{}| (ops.sizes)(bytes))
	}

	## The decoders' output sizes, called directly so each result is used and
	## dropped inside this function. Calling them through `Ops`' function
	## fields instead would trip a compiler issue where the result of a call
	## through a function value is released late, after the leak check reads
	## its balance (see trophy-case/repros/late_drop_through_function_value.roc).
	size : Try(Str, e) -> U64
	size = |result| match result {
		Ok(s) => s.count_utf8_bytes() + 1
		Err(_) => 0
	}

	sizes16 : List(U8) -> U64
	sizes16 = |bytes| {
		strict = size(Str.from_utf16_le(bytes)) + size(Str.from_utf16_be(bytes)) + size(Str.from_utf16_bom(bytes))
		lossy = Str.from_utf16_le_lossy(bytes).count_utf8_bytes() + Str.from_utf16_be_lossy(bytes).count_utf8_bytes() + size(Str.from_utf16_bom_lossy(bytes))
		strict + lossy
	}

	sizes32 : List(U8) -> U64
	sizes32 = |bytes| {
		strict = size(Str.from_utf32_le(bytes)) + size(Str.from_utf32_be(bytes)) + size(Str.from_utf32_bom(bytes))
		lossy = Str.from_utf32_le_lossy(bytes).count_utf8_bytes() + Str.from_utf32_be_lossy(bytes).count_utf8_bytes() + size(Str.from_utf32_bom_lossy(bytes))
		strict + lossy
	}
}
