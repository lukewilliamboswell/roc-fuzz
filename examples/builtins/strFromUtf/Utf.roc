Utf :: {}.{
	# Independent reference oracle for `Str.from_utf16*` / `Str.from_utf32*`.
	# Decoding builds UTF-8 bytes by hand and never calls the decoders under test.
	Problem : [NoProblem, UnpairedHigh(U64), UnpairedLow(U64), TooLarge(U64), Surrogate(U64)]
	Decoded : { bytes : List(U8), problem : Problem }

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

	## Lossy UTF-16 decode plus the first strict-mode problem.
	decode_utf16 : List(U16) -> Decoded
	decode_utf16 = |units| {
		var $bytes = List.with_capacity(units.len() * 3)
		var $problem = NoProblem
		var $i = 0
		n = units.len()
		while $i < n {
			u = units.get($i) ?? 0
			if is_high(u) {
				next = units.get($i + 1) ?? 0
				if $i + 1 < n and is_low(next) {
					cp = 0x10000 + (u.to_u32() - 0xD800) * 0x400 + (next.to_u32() - 0xDC00)
					$bytes = push_scalar($bytes, cp)
					$i = $i + 2
				} else {
					$bytes = push_scalar($bytes, replacement)
					$problem = first_problem($problem, UnpairedHigh($i))
					$i = $i + 1
				}
			} else if is_low(u) {
				$bytes = push_scalar($bytes, replacement)
				$problem = first_problem($problem, UnpairedLow($i))
				$i = $i + 1
			} else {
				$bytes = push_scalar($bytes, u.to_u32())
				$i = $i + 1
			}
		}
		{ bytes: $bytes, problem: $problem }
	}

	## Lossy UTF-32 decode plus the first strict-mode problem.
	decode_utf32 : List(U32) -> Decoded
	decode_utf32 = |units| {
		var $bytes = List.with_capacity(units.len() * 4)
		var $problem = NoProblem
		var $i = 0
		for u in units {
			if u > 0x10FFFF {
				$bytes = push_scalar($bytes, replacement)
				$problem = first_problem($problem, TooLarge($i))
			} else if u >= 0xD800 and u <= 0xDFFF {
				$bytes = push_scalar($bytes, replacement)
				$problem = first_problem($problem, Surrogate($i))
			} else {
				$bytes = push_scalar($bytes, u)
			}
			$i = $i + 1
		}
		{ bytes: $bytes, problem: $problem }
	}

	## Scalars of a valid string, decoded from its UTF-8 bytes by hand.
	scalars : Str -> List(U32)
	scalars = |str| {
		bytes = str.to_utf8()
		n = bytes.len()
		var $out = []
		var $i = 0
		while $i < n {
			b0 = (bytes.get($i) ?? 0).to_u32()
			b1 = ((bytes.get($i + 1) ?? 0x80).to_u32()) % 0x40
			b2 = ((bytes.get($i + 2) ?? 0x80).to_u32()) % 0x40
			b3 = ((bytes.get($i + 3) ?? 0x80).to_u32()) % 0x40
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

	encode_utf16 : Str -> List(U16)
	encode_utf16 = |str| List.join(scalars(str).map(scalar_utf16))

	encode_utf32 : Str -> List(U32)
	encode_utf32 = |str| scalars(str)

	## Scalars whose UTF-8 widths are 1, 2, 3, and 4 bytes.
	width_scalar : U64 -> U32
	width_scalar = |n| {
		samples : List(U32)
		samples = [0x41, 0xE9, 0x20AC, 0x1F426, 0x7F, 0x80, 0x7FF, 0x800, 0xFFFF, 0x10000, 0x10FFFF]
		samples.get(n % samples.len()) ?? 0x41
	}

	scalar_utf16 : U32 -> List(U16)
	scalar_utf16 = |cp|
		if cp < 0x10000 {
			[cp.to_u16_wrap()]
		} else {
			v = cp - 0x10000
			[(0xD800 + v // 0x400).to_u16_wrap(), (0xDC00 + v % 0x400).to_u16_wrap()]
		}

	## Runs long enough to cross the decoder's SIMD lanes (8 UTF-16 / 4 UTF-32
	## units), the 23-byte inline capacity, and the 92-byte stack staging buffer.
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
	## weighted toward surrogate edges and toward runs that cross buffer edges.
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
				specials = [0, 0x7F, 0x80, 0x7FF, 0x800, 0xD7FF, 0xD800, 0xDBFF, 0xDC00, 0xDFFF, 0xE000, 0xFEFF, 0xFFFD, 0xFFFE, 0xFFFF]
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
				specials = [0, 0x7F, 0x80, 0x7FF, 0x800, 0xFFFF, 0x10000, 0x10FFFF, 0x110000, 0xD7FF, 0xD800, 0xDFFF, 0xE000, 0xFFFD, 0xFEFF, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF]
				[specials.get(n % specials.len()) ?? 0]
			}
			6 => [n.to_u32_wrap()]
			7 | 8 => ascii_run(n)
			_ => dense_run(n)
		}
	}

	## Allocations for one successful decode (and for any lossy decode), from
	## the size-then-encode design in roc-lang/roc#11700: output of at most 23
	## bytes is built inline from a stack buffer (none on 64-bit targets); longer
	## output is encoded into one exact-capacity list (exactly one, no regrowth).
	alloc_bound : List(U8) -> U64
	alloc_bound = |output| if output.len() <= 23 0 else 1

	## Strict decoding sizes and validates before allocating, so a failure
	## allocates nothing.
	strict_alloc_bound : Decoded -> U64
	strict_alloc_bound = |decoded| if decoded.problem == NoProblem alloc_bound(decoded.bytes) else 0

	show_problem : Problem -> Str
	show_problem = |p| Str.inspect(p)
}
