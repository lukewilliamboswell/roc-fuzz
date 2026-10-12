import pf.Fuzz
import NumText

Prefix :: {}.{
	# Shared input shape and property checks for the numeric prefix-parser
	# targets. The generic checks take the parsers of one type as a record, so
	# the same property runs over every numeric type.

	## One generated input: the body under test (a run of token pieces, then
	## any pieces), a tail used by the round-trip property, and a terminator
	## selector. `use_raw` switches the body to fully random bytes.
	Case : { body : List(U8), raw : List(U8), use_raw : Bool, tail : List(U8), terminator : U8 }

	case_generator : Fuzz.Generator(Case)
	case_generator = {
		body: Fuzz.map2(token_pieces(8), pieces(6), List.concat),
		raw: Fuzz.bytes,
		use_raw: Fuzz.map(Fuzz.u8_in(0, 15), |n| n == 0),
		tail: pieces(4),
		terminator: Fuzz.u8_in(0, 3),
	}.Fuzz

	token_pieces : U64 -> Fuzz.Generator(List(U8))
	token_pieces = |max| Fuzz.map(Fuzz.list(Fuzz.map2(Fuzz.u8_in(0, 13), Fuzz.u64, NumText.token_piece), max), List.join)

	pieces : U64 -> Fuzz.Generator(List(U8))
	pieces = |max| Fuzz.map(Fuzz.list(Fuzz.map2(Fuzz.u8_in(0, 19), Fuzz.u64, NumText.piece), max), List.join)

	input : Case -> List(U8)
	input = |case| if case.use_raw case.raw else case.body

	show_case : Case -> Str
	show_case = |case| "input=${NumText.show_bytes(input(case))} raw_bytes=${Str.inspect(input(case))} tail=${NumText.show_bytes(case.tail)}"

	## A prefix-parse result reduced to comparable data: the rendered value and
	## the bytes of `rest`, or the error.
	Obs : [Parsed(Str, List(U8)), NotANumber, OutOfRange]

	observe_str : Try({ value : a, rest : Str }, [OutOfRange, NotANumber]), (a -> Str) -> Obs
	observe_str = |result, render| match result {
		Ok({ value, rest }) => Parsed(render(value), rest.to_utf8())
		Err(NotANumber) => NotANumber
		Err(OutOfRange) => OutOfRange
	}

	observe_list : Try({ value : a, rest : List(U8) }, [OutOfRange, NotANumber]), (a -> Str) -> Obs
	observe_list = |result, render| match result {
		Ok({ value, rest }) => Parsed(render(value), rest)
		Err(NotANumber) => NotANumber
		Err(OutOfRange) => OutOfRange
	}

	show_obs : Obs -> Str
	show_obs = |obs| match obs {
		Parsed(text, rest) => "Ok(${text}, rest=${NumText.show_bytes(rest)})"
		NotANumber => "Err(NotANumber)"
		OutOfRange => "Err(OutOfRange)"
	}

	## The parsers of one numeric type.
	Ops(a) : {
		from_str : Str -> Try(a, [BadNumStr]),
		str_prefix : Str -> Try({ value : a, rest : Str }, [OutOfRange, NotANumber]),
		utf8_prefix : List(U8) -> Try({ value : a, rest : List(U8) }, [OutOfRange, NotANumber]),
		render : a -> Str,
	}

	## Bundle one type's parsers.
	int_ops : (Str -> Try(a, [BadNumStr])), (Str -> Try({ value : a, rest : Str }, [OutOfRange, NotANumber])), (List(U8) -> Try({ value : a, rest : List(U8) }, [OutOfRange, NotANumber])), (a -> Str) -> Ops(a)
	int_ops = |from_str, str_prefix, utf8_prefix, render| { from_str, str_prefix, utf8_prefix, render }

	## `T.from_str` of some bytes, rendered, or `Err` for invalid UTF-8 or a
	## rejected string.
	whole : Ops(a), List(U8) -> Try(Str, [NoValue])
	whole = |ops, bytes| match Str.from_utf8(bytes) {
		Ok(s) => match (ops.from_str)(s) {
			Ok(v) => Ok((ops.render)(v))
			Err(_) => Err(NoValue)
		}
		Err(_) => Err(NoValue)
	}

	## The observation the contract requires for a token of `len` bytes whose
	## whole-token value is `parsed`.
	expected_obs : List(U8), U64, Try(Str, [NoValue]) -> Obs
	expected_obs = |bytes, len, parsed|
		if len == 0 {
			NotANumber
		} else {
			match parsed {
				Ok(text) => Parsed(text, bytes.drop_first(len))
				Err(NoValue) => OutOfRange
			}
		}

	## Run both prefix parsers on `bytes` (the `Str` one only when the bytes
	## are valid UTF-8), with no allocation and no leak, and require that they
	## agree with `expected`, with `T.from_str` on the consumed token, and with
	## maximality: no longer prefix (up to 32 bytes past the token) is accepted
	## by `T.from_str`.
	check_bytes! : Str, Ops(a), List(U8), U64, Obs => {}
	check_bytes! = |label, ops, bytes, token_len, expected| {
		{ value: list_result, allocations: list_allocs } = Fuzz.measure_allocs!(|{}| (ops.utf8_prefix)(bytes))
		if list_allocs != 0 {
			crash "${label}.from_utf8_prefix allocated ${list_allocs.to_str()} times on ${NumText.show_bytes(bytes)}"
		}
		list_obs = observe_list(list_result, ops.render)
		if list_obs != expected {
			crash "${label}.from_utf8_prefix(${Str.inspect(bytes)}) = ${show_obs(list_obs)}, expected ${show_obs(expected)}"
		}
		match Str.from_utf8(bytes) {
			Ok(s) => {
				{ value: str_result, allocations: str_allocs } = Fuzz.measure_allocs!(|{}| (ops.str_prefix)(s))
				if str_allocs != 0 {
					crash "${label}.from_str_prefix allocated ${str_allocs.to_str()} times on ${Str.inspect(s)}"
				}
				str_obs = observe_str(str_result, ops.render)
				if str_obs != list_obs {
					crash "${label}.from_str_prefix(${Str.inspect(s)}) = ${show_obs(str_obs)} but from_utf8_prefix = ${show_obs(list_obs)}"
				}
			}
			Err(_) => {}
		}
		# Split property and error classification against `T.from_str`.
		token = bytes.take_first(token_len)
		match (list_obs, whole(ops, token)) {
			(Parsed(text, _), Ok(from_str_text)) if text == from_str_text => {}
			(Parsed(text, _), got) => crash "${label}: prefix value ${text} but from_str(${NumText.show_bytes(token)}) = ${Str.inspect(got)}"
			(OutOfRange, Err(NoValue)) => {}
			(OutOfRange, Ok(text)) => crash "${label}: OutOfRange but from_str(${NumText.show_bytes(token)}) = ${text}"
			(NotANumber, _) => {}
		}
		# Maximality.
		limit = if bytes.len() < token_len + 32 bytes.len() else token_len + 32
		var $k = token_len + 1
		while $k <= limit {
			match whole(ops, bytes.take_first($k)) {
				Ok(text) => crash "${label}: token has ${token_len.to_str()} bytes but from_str accepts the longer prefix ${NumText.show_bytes(bytes.take_first($k))} = ${text}"
				Err(NoValue) => {}
			}
			$k = $k + 1
		}
	}

	## Round trip: when `T.from_str` accepts `body`, `body ++ terminator ++
	## tail` parses as the whole body with the terminator and tail as `rest`.
	check_round_trip! : Str, Ops(a), List(U8), U8, List(U8) => {}
	check_round_trip! = |label, ops, body, terminator_index, tail| match whole(ops, body) {
		Err(NoValue) => {}
		Ok(text) => {
			terminator = NumText.terminators.get(terminator_index.to_u64()) ?? ','
			after = [terminator].concat(tail)
			joined = body.concat(after)
			obs = observe_list((ops.utf8_prefix)(joined), ops.render)
			if obs != Parsed(text, after) {
				crash "${label}: from_str accepts ${NumText.show_bytes(body)} = ${text} but the prefix parse of ${NumText.show_bytes(joined)} is ${show_obs(obs)}"
			}
			match Str.from_utf8(joined) {
				Ok(s) => {
					str_obs = observe_str((ops.str_prefix)(s), ops.render)
					if str_obs != obs {
						crash "${label}: Str and List(U8) prefix parsers disagree on ${Str.inspect(s)}"
					}
				}
				Err(_) => {}
			}
		}
	}

	## Integer family: the reference oracle decides the whole result.
	## `negative_max` is the magnitude of the type's minimum.
	check_int! : Case, Str, U128, U128, Ops(a) => {}
	check_int! = |case, label, positive_max, negative_max, ops| {
		raw = input(case)
		lossy = Str.from_utf8_lossy(raw).to_utf8()
		for bytes in [raw, lossy] {
			token = NumText.int_token(bytes)
			parsed = match NumText.expect_int(token, positive_max, negative_max) {
				Value(text) => Ok(text)
				_ => Err(NoValue)
			}
			check_bytes!(label, ops, bytes, token.len, expected_obs(bytes, token.len, parsed))
		}
		check_round_trip!(label, ops, lossy, case.terminator, case.tail)
	}

	## Float family: the reference scanner decides the token, `T.from_str`
	## the value. A decimal token below `10^max_decimal_order` or a hex token
	## below `2^max_binary_order` is finite in the type and must not be
	## `OutOfRange`, and only `inf`/`infinity`/`nan` words may parse to a
	## non-finite value.
	check_float! : Case, Str, I64, I64, Ops(a), (a -> Bool) => {}
	check_float! = |case, label, max_decimal_order, max_binary_order, ops, is_finite| {
		raw = input(case)
		lossy = Str.from_utf8_lossy(raw).to_utf8()
		for bytes in [raw, lossy] {
			token = NumText.float_token(bytes)
			token_bytes = bytes.take_first(token.len)
			parsed = whole(ops, token_bytes)
			if token.len > 0 and parsed == Err(NoValue) {
				fits = if token.special {
					Bool.True
				} else if token.hex {
					token.order <= max_binary_order
				} else {
					token.order <= max_decimal_order
				}
				if fits {
					crash "${label}: token ${NumText.show_bytes(token_bytes)} (order ${token.order.to_str()}) is rejected by from_str although its value is finite in the type"
				}
			}
			if token.len > 0 and !token.special {
				match Str.from_utf8(token_bytes) {
					Ok(s) => match (ops.from_str)(s) {
						Ok(v) => if !is_finite(v) crash "${label}: finite-syntax token ${Str.inspect(s)} parsed to a non-finite value" else {}
						Err(_) => {}
					}
					Err(_) => {}
				}
			}
			check_bytes!(label, ops, bytes, token.len, expected_obs(bytes, token.len, parsed))
		}
		check_round_trip!(label, ops, lossy, case.terminator, case.tail)
	}

	## Dec: the reference scanner decides the token and the exact scaled
	## value, so `OutOfRange` must mean the token is inexact or out of range,
	## and every `Ok` value must equal the exact value (compared through a
	## canonical plain rendering parsed by `Dec.from_str`).
	check_dec! : Case => {}
	check_dec! = |case| {
		ops = dec_ops
		raw = input(case)
		lossy = Str.from_utf8_lossy(raw).to_utf8()
		for bytes in [raw, lossy] {
			token = NumText.dec_token(bytes)
			canonical = match token.value {
				Scaled(negative, m) if dec_fits(negative, m) => {
					text = NumText.scaled_text(negative, m)
					match Dec.from_str(text) {
						Ok(v) => Ok(v.to_str())
						Err(_) => crash "Dec.from_str rejected canonical text ${text}"
					}
				}
				_ => Err(NoValue)
			}
			token_bytes = bytes.take_first(token.len)
			parsed = whole(ops, token_bytes)
			if token.len > 0 and canonical != parsed {
				crash "Dec: token ${NumText.show_bytes(token_bytes)} has exact value ${Str.inspect(canonical)} but from_str gives ${Str.inspect(parsed)}"
			}
			check_bytes!("Dec", ops, bytes, token.len, expected_obs(bytes, token.len, canonical))
		}
		check_round_trip!("Dec", ops, lossy, case.terminator, case.tail)
	}

	dec_ops : Ops(Dec)
	dec_ops = int_ops(Dec.from_str, Dec.from_str_prefix, Dec.from_utf8_prefix, Dec.to_str)

	## Dec is an I128 scaled by 10^18.
	dec_fits : Bool, U128 -> Bool
	dec_fits = |negative, m| if negative m <= 170141183460469231731687303715884105728 else m <= 170141183460469231731687303715884105727
}
