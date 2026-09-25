NumText :: {}.{
	# Numeric text generation and independent reference scanners for the
	# `T.from_str_prefix` / `T.from_utf8_prefix` targets (roc-lang/roc#11705).
	#
	# Inputs are random compositions of small typed pieces: signs, digit runs,
	# `_`, radix prefixes, `.`, exponent markers, special-value words,
	# terminators, rendered numbers, and arbitrary (possibly non-UTF-8) bytes.
	# The scanners below are written from the documented token grammar and
	# never call the parsers under test.

	## One integer token as the reference scanner sees it. `value` is the exact
	## magnitude, or `NoInteger` when the token denotes no 128-bit integer
	## (`2e-1`, `1e40`, or a magnitude past `U128.highest`).
	IntToken : { len : U64, value : [Magnitude(Bool, U128), NoInteger] }

	## One float token: its length, whether it is an `inf`/`nan` word, and an
	## upper bound on its magnitude's order (decimal digits for a decimal
	## mantissa, bits for a hex mantissa). Every value is below
	## `radix^order`; an all-zero mantissa has order `zero_order`.
	FloatToken : { len : U64, special : Bool, hex : Bool, order : I64 }

	## One Dec token: its length and the exact value scaled by 10^18, or
	## `NotExact` when the value has more than 18 fractional digits or does not
	## fit in 128 bits.
	DecToken : { len : U64, value : [Scaled(Bool, U128), NotExact] }

	zero_order : I64
	zero_order = -1_000_000_000

	# ── Generation ──

	## Bytes for one generated piece. `class` picks the construct, `n` supplies
	## its entropy.
	piece : U8, U64 -> List(U8)
	piece = |class, n| match class {
		0 => if n % 2 == 0 ['-'] else ['+']
		1 | 2 | 3 | 4 => digit_run(n)
		5 => ['_']
		6 => radix_prefix(n)
		7 => radix_digit_run(n)
		8 => ['.']
		9 => exponent_marker(n)
		10 => special_word(n)
		11 => terminator(n)
		12 => [n.to_u8_wrap()]
		13 => [(0x20 + n % 0x5F).to_u8_wrap()]
		14 => multibyte(n)
		15 => rendered_boundary(n)
		16 => rendered_value(n)
		17 => List.repeat('0', n % 30 + 1)
		_ => random_bytes(n)
	}

	## A piece that can continue a numeric token: signs, digits, `_`, radix
	## prefixes and digits, `.`, exponent markers, special words, zero runs,
	## and rendered boundary values. Bodies start with a run of these so
	## that most inputs begin with a token.
	token_piece : U8, U64 -> List(U8)
	token_piece = |class, n| {
		classes : List(U8)
		classes = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 15, 16, 17]
		piece(classes.get(class.to_u64() % classes.len()) ?? 1, n)
	}

	## Mix the entropy word so that consecutive positions look independent.
	mix : U64, U64 -> U64
	mix = |seed, i| {
		x = seed.bitwise_xor(i.times_wrap(0x9E3779B97F4A7C15))
		y = x.bitwise_xor(x.shr_zf_wrap(31)).times_wrap(0xBF58476D1CE4E5B9)
		y.bitwise_xor(y.shr_zf_wrap(29))
	}

	## Mostly short runs of decimal digits, sometimes long enough to cross
	## every width's overflow boundary (U128 has 39 digits).
	digit_run : U64 -> List(U8)
	digit_run = |n| {
		len = if n % 8 == 0 1 + (n // 8) % 48 else 1 + (n // 8) % 4
		var $out = List.with_capacity(len)
		var $i = 0
		while $i < len {
			$out = $out.append(('0' + mix(n, $i) % 10).to_u8_wrap())
			$i = $i + 1
		}
		$out
	}

	radix_prefix : U64 -> List(U8)
	radix_prefix = |n| {
		letters : List(U8)
		letters = ['x', 'X', 'o', 'O', 'b', 'B']
		['0', letters.get(n % 6) ?? 'x']
	}

	## Digits drawn from the hex alphabet (both cases), so runs mix valid and
	## invalid digits for binary and octal.
	radix_digit_run : U64 -> List(U8)
	radix_digit_run = |n| {
		alphabet = "0123456789abcdefABCDEF01".to_utf8()
		len = 1 + (n % 34)
		var $out = List.with_capacity(len)
		var $i = 0
		while $i < len {
			$out = $out.append(alphabet.get(mix(n, $i) % alphabet.len()) ?? '0')
			$i = $i + 1
		}
		$out
	}

	exponent_marker : U64 -> List(U8)
	exponent_marker = |n| {
		letter = match n % 4 {
			0 => 'e'
			1 => 'E'
			2 => 'p'
			_ => 'P'
		}
		match (n // 4) % 3 {
			0 => [letter]
			1 => [letter, '+']
			_ => [letter, '-']
		}
	}

	## A prefix of `infinity` or `nan` in random letter case.
	special_word : U64 -> List(U8)
	special_word = |n| {
		word = if n % 2 == 0 "infinity".to_utf8() else "nan".to_utf8()
		len = 1 + (n // 2) % word.len()
		word.take_first(len).map_with_index(|c, i| if mix(n, i) % 2 == 0 c else c - 0x20)
	}

	terminator : U64 -> List(U8)
	terminator = |n| {
		bytes = ", ]}\n\t\rxg:\"".to_utf8()
		[bytes.get(n % bytes.len()) ?? ',']
	}

	multibyte : U64 -> List(U8)
	multibyte = |n| {
		scalars : List(Str)
		scalars = ["é", "€", "𝟘", "٣", "０", "\u(FEFF)", "\u(10FFFF)", "ﬀ"]
		(scalars.get(n % scalars.len()) ?? "é").to_utf8()
	}

	random_bytes : U64 -> List(U8)
	random_bytes = |n| {
		len = n % 9
		var $out = List.with_capacity(len)
		var $i = 0
		while $i < len {
			$out = $out.append(mix(n, $i).to_u8_wrap())
			$i = $i + 1
		}
		$out
	}

	## `2^k - 1`, `2^k`, or `2^k + 1` in decimal, with a sign, so every integer
	## width's edges and Dec's edges come up often.
	rendered_boundary : U64 -> List(U8)
	rendered_boundary = |n| {
		k = n % 129
		text = if k == 128 {
			match (n // 129) % 3 {
				0 => "340282366920938463463374607431768211455"
				1 => "340282366920938463463374607431768211456"
				_ => "340282366920938463463374607431768211457"
			}
		} else {
			var $p = 1.U128
			var $i = 0
			while $i < k {
				$p = $p * 2
				$i = $i + 1
			}
			match (n // 129) % 3 {
				0 => ($p - 1).to_str()
				1 => $p.to_str()
				_ => ($p + 1).to_str()
			}
		}
		sign = match (n // 387) % 3 {
			0 => ""
			1 => "-"
			_ => "+"
		}
		sign.concat(text).to_utf8()
	}

	## A random value of some numeric type rendered by `to_str`.
	rendered_value : U64 -> List(U8)
	rendered_value = |n| {
		m = mix(n, 7)
		text = match n % 6 {
			0 => m.to_str()
			1 => m.to_i64_wrap().to_str()
			2 => F64.from_bits(m).to_str()
			3 => F32.from_bits(m.to_u32_wrap()).to_str()
			4 => (m.to_u128() * 1_000_003).to_str()
			_ => m.to_u8_wrap().to_str()
		}
		text.to_utf8()
	}

	# ── Reference scanners ──

	at : List(U8), U64 -> U8
	at = |bytes, i| bytes.get(i) ?? 0

	is_digit : U8 -> Bool
	is_digit = |b| b >= '0' and b <= '9'

	digit_value : U8 -> U64
	digit_value = |b|
		if b >= '0' and b <= '9' {
			(b - '0').to_u64()
		} else if b >= 'a' and b <= 'z' {
			(b - 'a').to_u64() + 10
		} else if b >= 'A' and b <= 'Z' {
			(b - 'A').to_u64() + 10
		} else {
			99
		}

	is_radix_digit : U8, U64 -> Bool
	is_radix_digit = |b, radix| digit_value(b) < radix

	sign_len : List(U8) -> U64
	sign_len = |bytes| if at(bytes, 0) == '-' or at(bytes, 0) == '+' 1 else 0

	radix_of : U8 -> U64
	radix_of = |b| match b {
		'x' | 'X' => 16
		'o' | 'O' => 8
		'b' | 'B' => 2
		_ => 0
	}

	## End of a run of `radix` digits starting at `start`, with `_` only
	## between two digits. Returns `start` when there is no digit.
	digit_run_end : List(U8), U64, U64 -> U64
	digit_run_end = |bytes, start, radix| {
		var $i = start
		var $end = start
		n = bytes.len()
		while $i < n {
			b = at(bytes, $i)
			if is_radix_digit(b, radix) {
				$end = $i + 1
				$i = $i + 1
			} else if b == '_' and $i > start and is_radix_digit(at(bytes, $i - 1), radix) and $i + 1 < n and is_radix_digit(at(bytes, $i + 1), radix) {
				$i = $i + 1
			} else {
				break
			}
		}
		$end
	}

	## Accumulate the digits (skipping `_`) of `bytes[start..end]` in `radix`,
	## or `Err` when the magnitude exceeds `U128.highest`.
	accumulate : List(U8), U64, U64, U128 -> Try(U128, [Overflow])
	accumulate = |bytes, start, end, radix| {
		var $value = 0.U128
		var $i = start
		while $i < end {
			b = at(bytes, $i)
			if b != '_' {
				d = digit_value(b).to_u128()
				if $value > (U128.highest - d) // radix {
					return Err(Overflow)
				}
				$value = $value * radix + d
			}
			$i = $i + 1
		}
		Ok($value)
	}

	## Optional exponent `marker sign? D (_? D)*` at `start`. Returns the end
	## (== `start` when absent), its sign, and its magnitude saturated at
	## 1_000_000.
	exponent : List(U8), U64, U8 -> { end : U64, negative : Bool, magnitude : U64 }
	exponent = |bytes, start, marker| {
		absent = { end: start, negative: Bool.False, magnitude: 0 }
		b = at(bytes, start)
		if b != marker and b != marker - 0x20 {
			return absent
		}
		sign = at(bytes, start + 1)
		digits_start = if sign == '-' or sign == '+' start + 2 else start + 1
		end = digit_run_end(bytes, digits_start, 10)
		if end == digits_start {
			return absent
		}
		var $m = 0
		var $i = digits_start
		while $i < end {
			c = at(bytes, $i)
			if c != '_' and $m < 1_000_000 {
				$m = $m * 10 + (c - '0').to_u64()
			}
			$i = $i + 1
		}
		{ end, negative: sign == '-', magnitude: $m }
	}

	## Longest integer token: `sign? 0[xob] radix-digits`, else
	## `sign? D (_? D)* (e sign? D (_? D)*)?`.
	int_token : List(U8) -> IntToken
	int_token = |bytes| {
		s = sign_len(bytes)
		negative = at(bytes, 0) == '-'
		radix = radix_of(at(bytes, s + 1))
		radix_end = if at(bytes, s) == '0' and radix != 0 digit_run_end(bytes, s + 2, radix) else s + 2
		if radix != 0 and at(bytes, s) == '0' and radix_end > s + 2 {
			value = match accumulate(bytes, s + 2, radix_end, radix.to_u128()) {
				Ok(m) => Magnitude(negative, m)
				Err(Overflow) => NoInteger
			}
			return { len: radix_end, value }
		}
		mantissa_end = digit_run_end(bytes, s, 10)
		if mantissa_end == s {
			return { len: 0, value: NoInteger }
		}
		exp = exponent(bytes, mantissa_end, 'e')
		coefficient = accumulate(bytes, s, mantissa_end, 10)
		is_zero = coefficient == Ok(0)
		value = if exp.negative and exp.magnitude != 0 {
			NoInteger
		} else if is_zero {
			Magnitude(negative, 0)
		} else if exp.magnitude > 38 {
			NoInteger
		} else {
			match coefficient {
				Err(Overflow) => NoInteger
				Ok(c) => match scale_up(c, exp.magnitude) {
					Ok(m) => Magnitude(negative, m)
					Err(Overflow) => NoInteger
				}
			}
		}
		{ len: exp.end, value }
	}

	scale_up : U128, U64 -> Try(U128, [Overflow])
	scale_up = |value, zeros| {
		var $v = value
		var $i = 0
		while $i < zeros {
			if $v > U128.highest // 10 {
				return Err(Overflow)
			}
			$v = $v * 10
			$i = $i + 1
		}
		Ok($v)
	}

	## Expected integer result for a type whose positive range ends at
	## `positive_max` and whose negative range ends at `-negative_max`, as the
	## `to_str` rendering of the value.
	expect_int : IntToken, U128, U128 -> [NotANumber, OutOfRange, Value(Str)]
	expect_int = |token, positive_max, negative_max|
		if token.len == 0 {
			NotANumber
		} else {
			match token.value {
				NoInteger => OutOfRange
				Magnitude(_, 0) => Value("0")
				Magnitude(Bool.True, m) => if m <= negative_max Value("-".concat(m.to_str())) else OutOfRange
				Magnitude(Bool.False, m) => if m <= positive_max Value(m.to_str()) else OutOfRange
			}
		}

	## Mantissa `(D+ | D+ . D* | . D+)` in `radix`, `_` only between digits.
	## Returns its end (== `start` when it has no digit), the number of
	## significant digits before the point, and the leading zeros after it
	## when there are none before.
	mantissa : List(U8), U64, U64 -> { end : U64, int_digits : I64, frac_zeros : I64, nonzero : Bool }
	mantissa = |bytes, start, radix| {
		n = bytes.len()
		var $i = start
		var $digits = 0
		var $point = Bool.False
		var $int_digits = 0
		var $frac_zeros = 0
		var $nonzero = Bool.False
		while $i < n {
			b = at(bytes, $i)
			if is_radix_digit(b, radix) {
				$digits = $digits + 1
				if b != '0' {
					$nonzero = Bool.True
				}
				if !$point and $nonzero {
					$int_digits = $int_digits + 1
				}
				if $point and !$nonzero {
					$frac_zeros = $frac_zeros + 1
				}
				$i = $i + 1
			} else if b == '_' and $i > start and is_radix_digit(at(bytes, $i - 1), radix) and $i + 1 < n and is_radix_digit(at(bytes, $i + 1), radix) {
				$i = $i + 1
			} else if b == '.' and !$point {
				$point = Bool.True
				$i = $i + 1
			} else {
				break
			}
		}
		{ end: if $digits == 0 start else $i, int_digits: $int_digits, frac_zeros: $frac_zeros, nonzero: $nonzero }
	}

	signed_exponent : { end : U64, negative : Bool, magnitude : U64 } -> I64
	signed_exponent = |exp| if exp.negative -(exp.magnitude.to_i64_wrap()) else exp.magnitude.to_i64_wrap()

	## Longest float token: sign, then a hex mantissa with `p` exponent, a
	## decimal mantissa with `e` exponent, or `infinity` / `inf` / `nan`.
	float_token : List(U8) -> FloatToken
	float_token = |bytes| {
		s = sign_len(bytes)
		if at(bytes, s) == '0' and (at(bytes, s + 1) == 'x' or at(bytes, s + 1) == 'X') {
			m = mantissa(bytes, s + 2, 16)
			if m.end > s + 2 {
				exp = exponent(bytes, m.end, 'p')
				order = if m.nonzero 4 * m.int_digits + signed_exponent(exp) else zero_order
				return { len: exp.end, special: Bool.False, hex: Bool.True, order }
			}
		}
		m = mantissa(bytes, s, 10)
		if m.end > s {
			exp = exponent(bytes, m.end, 'e')
			order = if m.nonzero m.int_digits - m.frac_zeros + signed_exponent(exp) else zero_order
			return { len: exp.end, special: Bool.False, hex: Bool.False, order }
		}
		rest = bytes.drop_first(s).map(|b| if b >= 'A' and b <= 'Z' b + 0x20 else b)
		len = if rest.starts_with("infinity".to_utf8()) {
			8
		} else if rest.starts_with("inf".to_utf8()) {
			3
		} else if rest.starts_with("nan".to_utf8()) {
			3
		} else {
			0
		}
		{ len: if len == 0 0 else s + len, special: Bool.True, hex: Bool.False, order: 0 }
	}

	## Longest Dec token: sign, decimal mantissa, optional `e` exponent. The
	## value is exact when it has at most 18 fractional digits and fits.
	dec_token : List(U8) -> DecToken
	dec_token = |bytes| {
		s = sign_len(bytes)
		negative = at(bytes, 0) == '-'
		m = mantissa(bytes, s, 10)
		if m.end == s {
			return { len: 0, value: NotExact }
		}
		exp = exponent(bytes, m.end, 'e')
		digits = bytes.sublist({ start: s, len: m.end - s }).keep_if(is_digit)
		mantissa_bytes = bytes.sublist({ start: s, len: m.end - s })
		frac = match mantissa_bytes.find_first_index(|b| b == '.') {
			Ok(p) => mantissa_bytes.drop_first(p + 1).count_if(is_digit).to_i64_wrap()
			Err(_) => 0
		}
		{ len: exp.end, value: scaled_dec(negative, digits, 18 + signed_exponent(exp) - frac) }
	}

	## `digits × 10^scale` as an exact 128-bit magnitude, if there is one.
	scaled_dec : Bool, List(U8), I64 -> [Scaled(Bool, U128), NotExact]
	scaled_dec = |negative, digits, scale| {
		if digits.all(|d| d == '0') {
			return Scaled(negative, 0)
		}
		kept = if scale >= 0 {
			digits
		} else {
			drop = (-scale).to_u64_wrap()
			if drop > digits.len() or !digits.take_last(drop).all(|d| d == '0') {
				return NotExact
			}
			digits.drop_last(drop)
		}
		zeros = if scale > 0 scale.to_u64_wrap() else 0
		if zeros > 38 {
			return NotExact
		}
		match accumulate(kept, 0, kept.len(), 10) {
			Err(Overflow) => NotExact
			Ok(c) => match scale_up(c, zeros) {
				Ok(v) => Scaled(negative, v)
				Err(Overflow) => NotExact
			}
		}
	}

	## Canonical decimal text of a scaled Dec magnitude, e.g. `-1.5`.
	scaled_text : Bool, U128 -> Str
	scaled_text = |negative, magnitude| {
		one = 1_000_000_000_000_000_000.U128
		whole = (magnitude // one).to_str()
		frac_digits = (magnitude % one + one).to_str().to_utf8().drop_first(1)
		sign = if negative and magnitude != 0 "-" else ""
		"${sign}${whole}.${Str.from_utf8_lossy(frac_digits)}"
	}

	# ── Shared checks ──

	## The input text of a byte composition, and its bytes as a `Str` sees them.
	as_str : List(U8) -> Str
	as_str = |bytes| Str.from_utf8_lossy(bytes)

	## Whether `rest` is exactly the byte suffix of `input` after `consumed`
	## bytes.
	is_suffix : List(U8), List(U8) -> Bool
	is_suffix = |input, rest| rest.len() <= input.len() and input.drop_first(input.len() - rest.len()) == rest

	## The consumed prefix of `input` whose unconsumed suffix is `rest`.
	consumed_prefix : List(U8), List(U8) -> List(U8)
	consumed_prefix = |input, rest| input.take_first(input.len() - rest.len())

	show_bytes : List(U8) -> Str
	show_bytes = |bytes| Str.inspect(Str.from_utf8_lossy(bytes))

	## Terminators after which no token of any numeric family can continue.
	terminators : List(U8)
	terminators = [',', ' ', ']', '\n']
}
