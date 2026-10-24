import pf.Fuzz

Utf :: {}.{
	# Independent reference oracle for the byte-based wide-UTF decoders
	# (`Str.from_utf16_le`, `_be`, `_bom` and `Str.from_utf32_*`, each with a
	# `_lossy` form). It reads code units out of the bytes itself, builds UTF-8
	# by hand, and never calls the decoders under test.
	#
	# Semantics, from the builtin's documentation:
	# * a problem's index is the zero-based byte offset of the offending code
	#   unit in the original input (so it includes a consumed byte order mark);
	# * a final code unit cut short by the end of the input is
	#   `UnexpectedEndOfSequence`, and its partial bytes become one U+FFFD;
	# * a high surrogate not followed by a complete low surrogate is unpaired,
	#   even when the bytes after it are a partial unit;
	# * every other invalid unit becomes one U+FFFD and decoding resumes at the
	#   next unit;
	# * U+FEFF is ordinary text, except the one leading marker that a `_bom`
	#   form requires and consumes.

	## The first problem strict decoding reports, as a byte offset.
	Problem : [NoProblem, UnpairedHigh(U64), UnpairedLow(U64), TooLarge(U64), Surrogate(U64), EndOfSequence(U64)]

	## The lossy output's UTF-8 bytes, plus the first strict-mode problem.
	Decoded : { bytes : List(U8), problem : Problem }

	## What a strict decoder returned, reduced to comparable data.
	Strict : [Valid(List(U8)), Invalid(Problem)]

	## What a `_bom` decoder returned, reduced to comparable data.
	Bom : [MissingBom, HasBom(Bool, Decoded)]

	replacement : U32
	replacement = 0xFFFD

	push_scalar : List(U8), U32 -> List(U8)
	push_scalar = |bytes, cp|
		if cp < 0x80 {
			bytes.append(cp.to_u8_wrap())
		} else if cp < 0x800 {
			bytes.append((0xC0 + cp // 0x40).to_u8_wrap()).append((0x80 + cp % 0x40).to_u8_wrap())
		} else if cp < 0x10000 {
			bytes
				.append((0xE0 + cp // 0x1000).to_u8_wrap())
				.append((0x80 + (cp // 0x40) % 0x40).to_u8_wrap())
				.append((0x80 + cp % 0x40).to_u8_wrap())
		} else {
			bytes
				.append((0xF0 + cp // 0x40000).to_u8_wrap())
				.append((0x80 + (cp // 0x1000) % 0x40).to_u8_wrap())
				.append((0x80 + (cp // 0x40) % 0x40).to_u8_wrap())
				.append((0x80 + cp % 0x40).to_u8_wrap())
		}

	first_problem : Problem, Problem -> Problem
	first_problem = |current, candidate| match current {
		NoProblem => candidate
		_ => current
	}

	is_high : U16 -> Bool
	is_high = |u| u >= 0xD800 and u <= 0xDBFF

	is_low : U16 -> Bool
	is_low = |u| u >= 0xDC00 and u <= 0xDFFF

	byte : List(U8), U64 -> U32
	byte = |bytes, i| (bytes.get(i) ?? 0).to_u32()

	## The UTF-16 code unit at byte offset `i`; the caller checks it is complete.
	read16 : List(U8), U64, Bool -> U16
	read16 = |bytes, i, little| {
		lo = if (little) byte(bytes, i) else byte(bytes, i + 1)
		hi = if (little) byte(bytes, i + 1) else byte(bytes, i)
		(hi * 0x100 + lo).to_u16_wrap()
	}

	## The UTF-32 code unit at byte offset `i`; the caller checks it is complete.
	read32 : List(U8), U64, Bool -> U32
	read32 = |bytes, i, little| {
		var $value = 0.U32
		var $k = 0
		while $k < 4 {
			b = if (little) byte(bytes, i + 3 - $k) else byte(bytes, i + $k)
			$value = $value * 0x100 + b
			$k = $k + 1
		}
		$value
	}

	## Decode UTF-16 from byte offset `start`, reporting absolute offsets.
	decode16_from : List(U8), U64, Bool -> Decoded
	decode16_from = |bytes, start, little| {
		n = bytes.len()
		var $out = List.with_capacity(n * 2)
		var $problem = NoProblem
		var $i = start
		while $i < n {
			if n - $i < 2 {
				$out = push_scalar($out, replacement)
				$problem = first_problem($problem, EndOfSequence($i))
				$i = n
			} else {
				u = read16(bytes, $i, little)
				if is_high(u) {
					paired = n - $i >= 4 and is_low(read16(bytes, $i + 2, little))
					if paired {
						low = read16(bytes, $i + 2, little)
						cp = 0x10000 + (u.to_u32() - 0xD800) * 0x400 + (low.to_u32() - 0xDC00)
						$out = push_scalar($out, cp)
						$i = $i + 4
					} else {
						$out = push_scalar($out, replacement)
						$problem = first_problem($problem, UnpairedHigh($i))
						$i = $i + 2
					}
				} else if is_low(u) {
					$out = push_scalar($out, replacement)
					$problem = first_problem($problem, UnpairedLow($i))
					$i = $i + 2
				} else {
					$out = push_scalar($out, u.to_u32())
					$i = $i + 2
				}
			}
		}
		{ bytes: $out, problem: $problem }
	}

	## Decode UTF-32 from byte offset `start`, reporting absolute offsets.
	decode32_from : List(U8), U64, Bool -> Decoded
	decode32_from = |bytes, start, little| {
		n = bytes.len()
		var $out = List.with_capacity(n)
		var $problem = NoProblem
		var $i = start
		while $i < n {
			if n - $i < 4 {
				$out = push_scalar($out, replacement)
				$problem = first_problem($problem, EndOfSequence($i))
				$i = n
			} else {
				u = read32(bytes, $i, little)
				if u > 0x10FFFF {
					$out = push_scalar($out, replacement)
					$problem = first_problem($problem, TooLarge($i))
				} else if u >= 0xD800 and u <= 0xDFFF {
					$out = push_scalar($out, replacement)
					$problem = first_problem($problem, Surrogate($i))
				} else {
					$out = push_scalar($out, u)
				}
				$i = $i + 4
			}
		}
		{ bytes: $out, problem: $problem }
	}

	decode16 : List(U8), Bool -> Decoded
	decode16 = |bytes, little| decode16_from(bytes, 0, little)

	decode32 : List(U8), Bool -> Decoded
	decode32 = |bytes, little| decode32_from(bytes, 0, little)

	## A `_bom` decode: the marker's byte order and the payload after it.
	bom16 : List(U8) -> Bom
	bom16 = |bytes| {
		b0 = byte(bytes, 0)
		b1 = byte(bytes, 1)
		if bytes.len() < 2 {
			MissingBom
		} else if b0 == 0xFF and b1 == 0xFE {
			HasBom(Bool.True, decode16_from(bytes, 2, Bool.True))
		} else if b0 == 0xFE and b1 == 0xFF {
			HasBom(Bool.False, decode16_from(bytes, 2, Bool.False))
		} else {
			MissingBom
		}
	}

	bom32 : List(U8) -> Bom
	bom32 = |bytes| {
		if bytes.len() < 4 {
			MissingBom
		} else if read32(bytes, 0, Bool.True) == 0xFEFF {
			HasBom(Bool.True, decode32_from(bytes, 4, Bool.True))
		} else if read32(bytes, 0, Bool.False) == 0xFEFF {
			HasBom(Bool.False, decode32_from(bytes, 4, Bool.False))
		} else {
			MissingBom
		}
	}

	expected_strict : Decoded -> Strict
	expected_strict = |decoded| if (decoded.problem == NoProblem) Valid(decoded.bytes) else Invalid(decoded.problem)

	strict16 : Try(Str, [BadUtf16({ problem : Str.Utf16Problem, index : U64 })]) -> Strict
	strict16 = |result| match result {
		Ok(s) => Valid(s.to_utf8())
		Err(BadUtf16({ problem, index })) => match problem {
			UnpairedHighSurrogate => Invalid(UnpairedHigh(index))
			UnpairedLowSurrogate => Invalid(UnpairedLow(index))
			UnexpectedEndOfSequence => Invalid(EndOfSequence(index))
		}
	}

	strict32 : Try(Str, [BadUtf32({ problem : Str.Utf32Problem, index : U64 })]) -> Strict
	strict32 = |result| match result {
		Ok(s) => Valid(s.to_utf8())
		Err(BadUtf32({ problem, index })) => match problem {
			CodePointTooLarge => Invalid(TooLarge(index))
			SurrogateCodePoint => Invalid(Surrogate(index))
			UnexpectedEndOfSequence => Invalid(EndOfSequence(index))
		}
	}

	## Allocations for one decode that produces `output` (any lossy decode, or
	## a successful strict one), measured on the nightly that the targets run
	## on: output of at most 23 bytes is a small string built without
	## allocating, and longer output is one exact-capacity list. A strict
	## decode that fails, and a `_bom` decode without a marker, allocate
	## nothing.
	allocs_for : List(U8) -> U64
	allocs_for = |output| if (output.len() <= 23) 0 else 1

	strict_allocs : Decoded -> U64
	strict_allocs = |decoded| if (decoded.problem == NoProblem) allocs_for(decoded.bytes) else 0

	bom_allocs : Bom, Bool -> U64
	bom_allocs = |bom, lossy| match bom {
		MissingBom => 0
		HasBom(_, decoded) => if (lossy) allocs_for(decoded.bytes) else strict_allocs(decoded)
	}

	## Scalars of a valid string, decoded from its UTF-8 bytes by hand.
	scalars : Str -> List(U32)
	scalars = |str| {
		bytes = str.to_utf8()
		n = bytes.len()
		var $out = []
		var $i = 0
		while $i < n {
			b0 = byte(bytes, $i)
			b1 = (bytes.get($i + 1) ?? 0x80).to_u32() % 0x40
			b2 = (bytes.get($i + 2) ?? 0x80).to_u32() % 0x40
			b3 = (bytes.get($i + 3) ?? 0x80).to_u32() % 0x40
			if b0 < 0x80 {
				$out = $out.append(b0)
				$i = $i + 1
			} else if b0 < 0xE0 {
				$out = $out.append((b0 % 0x20) * 0x40 + b1)
				$i = $i + 2
			} else if b0 < 0xF0 {
				$out = $out.append((b0 % 0x10) * 0x1000 + b1 * 0x40 + b2)
				$i = $i + 3
			} else {
				$out = $out.append((b0 % 0x08) * 0x40000 + b1 * 0x1000 + b2 * 0x40 + b3)
				$i = $i + 4
			}
		}
		$out
	}

	scalar_utf16 : U32 -> List(U16)
	scalar_utf16 = |cp|
		if cp < 0x10000 {
			[cp.to_u16_wrap()]
		} else {
			v = cp - 0x10000
			[(0xD800 + v // 0x400).to_u16_wrap(), (0xDC00 + v % 0x400).to_u16_wrap()]
		}

	## UTF-16 code units as bytes in the given byte order.
	units16_bytes : List(U16), Bool -> List(U8)
	units16_bytes = |units, little| {
		var $out = List.with_capacity(units.len() * 2)
		for u in units {
			lo = (u % 0x100).to_u8_wrap()
			hi = (u // 0x100).to_u8_wrap()
			$out = if (little) $out.append(lo).append(hi) else $out.append(hi).append(lo)
		}
		$out
	}

	## UTF-32 code units as bytes in the given byte order.
	units32_bytes : List(U32), Bool -> List(U8)
	units32_bytes = |units, little| {
		var $out = List.with_capacity(units.len() * 4)
		for u in units {
			b3 = (u // 0x1000000).to_u8_wrap()
			b2 = ((u // 0x10000) % 0x100).to_u8_wrap()
			b1 = ((u // 0x100) % 0x100).to_u8_wrap()
			b0 = (u % 0x100).to_u8_wrap()
			$out = if (little) $out.concat([b0, b1, b2, b3]) else $out.concat([b3, b2, b1, b0])
		}
		$out
	}

	encode16 : Str, Bool -> List(U8)
	encode16 = |str, little| units16_bytes(List.join(scalars(str).map(scalar_utf16)), little)

	encode32 : Str, Bool -> List(U8)
	encode32 = |str, little| units32_bytes(scalars(str), little)

	bom16_bytes : Bool -> List(U8)
	bom16_bytes = |little| units16_bytes([0xFEFF], little)

	bom32_bytes : Bool -> List(U8)
	bom32_bytes = |little| units32_bytes([0xFEFF], little)

	## Scalars whose UTF-8 widths are 1, 2, 3, and 4 bytes.
	width_scalar : U64 -> U32
	width_scalar = |n| {
		samples : List(U32)
		samples = [0x41, 0xE9, 0x20AC, 0x1F426, 0x7F, 0x80, 0x7FF, 0x800, 0xFFFF, 0x10000, 0x10FFFF]
		samples.get(n % samples.len()) ?? 0x41
	}

	## Runs long enough to cross the decoders' ASCII chunks (16 units, so 32
	## UTF-16 or 64 UTF-32 bytes) and the 23-byte small-string limit.
	ascii_run : U64 -> List(U32)
	ascii_run = |n| ascii_seq(n, n % 128 + 1)

	## `len` consecutive ASCII scalars starting at `seed % 0x80`.
	ascii_seq : U64, U64 -> List(U32)
	ascii_seq = |seed, len| {
		var $out = List.with_capacity(len)
		var $i = 0
		while $i < len {
			$out = $out.append(((seed % 0x80 + $i) % 0x80).to_u32_wrap())
			$i = $i + 1
		}
		$out
	}

	dense_run : U64 -> List(U32)
	dense_run = |n| List.repeat(width_scalar(n // 128), n % 64 + 1)

	## Shape a UTF-16 chunk from a class selector and raw entropy. Classes are
	## weighted toward surrogate edges, byte order marks in either order, and
	## runs that cross the decoder's chunk and small-string edges.
	utf16_chunk : U8, U64 -> List(U16)
	utf16_chunk = |class, n| {
		u = n.to_u16_wrap()
		match class {
			0 => [(n % 0x80).to_u16_wrap()]
			1 => [(0x80 + n % (0xD800 - 0x80)).to_u16_wrap()]
			2 => [(0xD800 + n % 0x400).to_u16_wrap()]
			3 => [(0xDC00 + n % 0x400).to_u16_wrap()]
			4 => {
				specials : List(U16)
				specials = [0, 0x7F, 0x80, 0x7FF, 0x800, 0xD7FF, 0xD800, 0xDBFF, 0xDC00, 0xDFFF, 0xE000, 0xFEFF, 0xFFFD, 0xFFFE, 0xFFFF, 0xFEFF, 0xFFFE]
				[specials.get(n % specials.len()) ?? 0]
			}
			5 => [u]
			6 => [(0xD800 + n % 0x400).to_u16_wrap(), (0xDC00 + (n // 0x400) % 0x400).to_u16_wrap()]
			7 | 8 => ascii_run(n).map(|cp| cp.to_u16_wrap())
			_ => List.join(dense_run(n).map(scalar_utf16))
		}
	}

	utf32_chunk : U8, U64 -> List(U32)
	utf32_chunk = |class, n| {
		match class {
			0 => [(n % 0x80).to_u32_wrap()]
			1 => [(0x80 + n % (0xD800 - 0x80)).to_u32_wrap()]
			2 => [(0x10000 + n % 0x100000).to_u32_wrap()]
			3 => [(0xD800 + n % 0x800).to_u32_wrap()]
			4 => [(0x110000 + n % 0x100).to_u32_wrap()]
			5 => {
				specials : List(U32)
				specials = [0, 0x7F, 0x80, 0x7FF, 0x800, 0xFFFF, 0x10000, 0x10FFFF, 0x110000, 0xD7FF, 0xD800, 0xDFFF, 0xE000, 0xFFFD, 0xFEFF, 0xFFFE, 0xFFFE0000, 0xFEFF0000, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF]
				[specials.get(n % specials.len()) ?? 0]
			}
			6 => [n.to_u32_wrap()]
			7 | 8 => ascii_run(n)
			_ => dense_run(n)
		}
	}

	## Code units shaped by `utf16_chunk`, up to `max` chunks.
	units16 : U64 -> Fuzz.Generator(List(U16))
	units16 = |max| Fuzz.map(Fuzz.list(Fuzz.map2(Fuzz.u8_in(0, 9), Fuzz.u64, utf16_chunk), max), List.join)

	units32 : U64 -> Fuzz.Generator(List(U32))
	units32 = |max| Fuzz.map(Fuzz.list(Fuzz.map2(Fuzz.u8_in(0, 9), Fuzz.u64, utf32_chunk), max), List.join)

	## One encoded input: code units in a byte order, after an optional
	## leading marker, followed by a few trailing bytes so the input can end
	## partway through a code unit. One input in eight is raw fuzzer bytes.
	Case(unit) : { little : Bool, lead : U8, units : List(unit), tail : List(U8), raw : List(U8), use_raw : Bool }

	case_generator : Fuzz.Generator(List(unit)), U64 -> Fuzz.Generator(Case(unit))
	case_generator = |units, max_tail| {
		little: Fuzz.map(Fuzz.u8_in(0, 1), |n| n == 1),
		lead: Fuzz.u8_in(0, 5),
		units: units,
		tail: Fuzz.list(Fuzz.map2(Fuzz.u8_in(0, 3), Fuzz.u8, tail_byte), max_tail),
		raw: Fuzz.bytes,
		use_raw: Fuzz.map(Fuzz.u8_in(0, 7), |n| n == 0),
	}.Fuzz

	## Trailing bytes are weighted toward marker and surrogate bytes.
	tail_byte : U8, U8 -> U8
	tail_byte = |class, n| match class {
		0 => 0xFF
		1 => 0xFE
		2 => 0xD8 + n % 8
		_ => n
	}

	## Lead 0 and 1 are no marker; 2 a marker in the encoding's byte order;
	## 3 one in the other order; 4 two markers; 5 a lone marker byte.
	lead_units : U8, unit, unit -> List(unit)
	lead_units = |lead, bom, swapped| match lead {
		2 => [bom]
		3 => [swapped]
		4 => [bom, bom]
		_ => []
	}

	case16_bytes : Case(U16) -> List(U8)
	case16_bytes = |case|
		if case.use_raw {
			case.raw
		} else {
			lone = if (case.lead == 5) [0xFF] else []
			lone.concat(units16_bytes(lead_units(case.lead, 0xFEFF, 0xFFFE).concat(case.units), case.little)).concat(case.tail)
		}

	case32_bytes : Case(U32) -> List(U8)
	case32_bytes = |case|
		if case.use_raw {
			case.raw
		} else {
			lone = if (case.lead == 5) [0xFF, 0xFE] else []
			lone.concat(units32_bytes(lead_units(case.lead, 0xFEFF, 0xFFFE0000).concat(case.units), case.little)).concat(case.tail)
		}
}
