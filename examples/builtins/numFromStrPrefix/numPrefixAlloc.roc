app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-19-d025939" }

import pf.Fuzz
import NumText
import Prefix

## Ownership of `rest` for the numeric prefix parsers (roc-lang/roc#11705).
##
## `rest` is a slice of the borrowed input. For every numeric type, and for
## small (<= 23 byte) and heap inputs, unique and shared inputs, and inputs
## that are themselves seamless slices (`Str.drop_prefix`, `List.drop_first`,
## or an earlier `rest`), this target checks that:
## * parsing allocates nothing, and `rest` has the right bytes and
##   `Str.count_utf8_bytes`;
## * growing `rest` (concat/append) gives the right contents and leaves the
##   input and every alias of it unchanged, on success and on error;
## * `rest` stays valid after the input is dropped;
## * a chain of prefix parses over successive `rest` slices matches the same
##   chain over fresh copies;
## * nothing leaks (whole check, plus the platform's per-input check).
Case : { body : List(U8), junk : List(U8), shape : U8, tail : List(U8) }

generator : Fuzz.Generator(Case)
generator = {
	body: Fuzz.map2(Prefix.token_pieces(8), Prefix.pieces(6), List.concat),
	junk: Fuzz.map(Fuzz.u64_in(0, 40), |n| List.repeat('#', n)),
	shape: Fuzz.u8_in(0, 3),
	tail: Prefix.pieces(3),
}.Fuzz

## The input under test in one of three allocation shapes: a fresh unique
## copy, a copy with heap capacity, or a seamless slice after `junk`. Shape 3
## is a seamless slice whose parent buffer is kept alive by an alias (see
## `check_list!`).
shaped_list : Case -> List(U8)
shaped_list = |case| match case.shape {
	0 => List.with_capacity(case.body.len()).concat(case.body)
	1 => List.with_capacity(64).concat(case.body)
	_ => case.junk.concat(case.body).drop_first(case.junk.len())
}

shaped_str : Case -> Str
shaped_str = |case| {
	s = Str.from_utf8_lossy(case.body)
	match case.shape {
		0 => Str.with_capacity(0).concat(s)
		1 => Str.with_capacity(64).concat(s)
		_ => {
			junk = Str.from_utf8_lossy(case.junk)
			junk.concat(s).drop_prefix(junk)
		}
	}
}

check_list! : Str, Case, Prefix.Ops(a) => {}
check_list! = |label, case, ops| {
	holder = case.junk.concat(case.body)
	holder_copy = List.with_capacity(holder.len()).concat(holder)
	input = if case.shape == 3 holder.drop_first(case.junk.len()) else shaped_list(case)
	original = List.with_capacity(input.len()).concat(input)
	alias = input
	{ value: result, allocations } = Fuzz.measure_allocs!(|{}| (ops.utf8_prefix)(input))
	if allocations != 0 {
		crash "${label}.from_utf8_prefix allocated ${allocations.to_str()} times"
	}
	match result {
		Ok({ rest, .. }) => {
			if !NumText.is_suffix(original, rest) {
				crash "${label}: rest ${Str.inspect(rest)} is not a suffix of ${Str.inspect(original)}"
			}
			grown = rest.append('!').concat(case.tail)
			if grown != rest.concat(['!']).concat(case.tail) or grown.drop_last(case.tail.len() + 1) != original.drop_first(original.len() - rest.len()) {
				crash "${label}: growing rest gave ${Str.inspect(grown)}"
			}
		}
		Err(_) => {}
	}
	if alias != original or input != original or holder != holder_copy {
		crash "${label}: parsing or growing rest changed the input: ${Str.inspect(alias)} vs ${Str.inspect(original)}"
	}
}

check_str! : Str, Case, Prefix.Ops(a) => {}
check_str! = |label, case, ops| {
	junk = Str.from_utf8_lossy(case.junk)
	holder = junk.concat(Str.from_utf8_lossy(case.body))
	holder_bytes = List.with_capacity(0).concat(holder.to_utf8())
	input = if case.shape == 3 holder.drop_prefix(junk) else shaped_str(case)
	original = List.with_capacity(0).concat(input.to_utf8())
	alias = input
	{ value: result, allocations } = Fuzz.measure_allocs!(|{}| (ops.str_prefix)(input))
	if allocations != 0 {
		crash "${label}.from_str_prefix allocated ${allocations.to_str()} times"
	}
	match result {
		Ok({ rest, .. }) => {
			rest_bytes = rest.to_utf8()
			if rest.count_utf8_bytes() != rest_bytes.len() or !NumText.is_suffix(original, rest_bytes) {
				crash "${label}: rest ${Str.inspect(rest)} (count ${rest.count_utf8_bytes().to_str()}) is not a suffix of ${Str.inspect(input)}"
			}
			tail = Str.from_utf8_lossy(case.tail)
			grown = rest.concat("!").concat(tail)
			if grown.to_utf8() != rest_bytes.append('!').concat(tail.to_utf8()) {
				crash "${label}: growing rest gave ${Str.inspect(grown)}"
			}
		}
		Err(_) => {}
	}
	if alias.to_utf8() != original or input.to_utf8() != original or holder.to_utf8() != holder_bytes {
		crash "${label}: parsing or growing rest changed the input"
	}
}

## `rest` must stay valid once the only other reference to the input is gone.
rest_after_drop : Case, Prefix.Ops(a) -> List(U8)
rest_after_drop = |case, ops| {
	parsed = (ops.str_prefix)(shaped_str(case))
	match parsed {
		Ok({ rest, .. }) => rest.concat("!").to_utf8()
		Err(_) => []
	}
}

rest_after_drop_list : Case, Prefix.Ops(a) -> List(U8)
rest_after_drop_list = |case, ops| {
	parsed = (ops.utf8_prefix)(shaped_list(case))
	match parsed {
		Ok({ rest, .. }) => rest.append('!')
		Err(_) => []
	}
}

## Parse a chain of numbers, stepping over one byte after each, and return
## every observation. `fresh` copies each intermediate input first, so the
## slice chain can be compared with a chain over unshared, unsliced lists.
chain : List(U8), Prefix.Ops(a), Bool -> List(Prefix.Obs)
chain = |start, ops, fresh| {
	var $input = start
	var $out = []
	var $steps = 0
	while $steps < 8 {
		current = if fresh List.with_capacity($input.len()).concat($input) else $input
		obs = Prefix.observe_list((ops.utf8_prefix)(current), ops.render)
		$out = $out.append(obs)
		$input = match (ops.utf8_prefix)(current) {
			Ok({ rest, .. }) => rest.drop_first(1)
			Err(_) => current.drop_first(1)
		}
		$steps = $steps + 1
	}
	$out
}

str_chain : Str, Prefix.Ops(a) -> List(Prefix.Obs)
str_chain = |start, ops| {
	var $input = start
	var $out = []
	var $steps = 0
	while $steps < 8 {
		obs = Prefix.observe_str((ops.str_prefix)($input), ops.render)
		$out = $out.append(obs)
		next = match (ops.str_prefix)($input) {
			Ok({ rest, .. }) => rest
			Err(_) => $input
		}
		# Step over one scalar with a seamless slice.
		first = next.to_utf8().take_first(1)
		$input = match Str.from_utf8(first) {
			Ok(one) => next.drop_prefix(one)
			Err(_) => Str.from_utf8_lossy(next.to_utf8().drop_first(1))
		}
		$steps = $steps + 1
	}
	$out
}

check_type! : Str, Case, Prefix.Ops(a) => {}
check_type! = |label, case, ops| {
	check_list!(label, case, ops)
	check_str!(label, case, ops)
	list_rest = rest_after_drop_list(case, ops)
	if !list_rest.is_empty() and !NumText.is_suffix(case.body.append('!'), list_rest) {
		crash "${label}: rest of a dropped list is ${Str.inspect(list_rest)}"
	}
	str_rest = rest_after_drop(case, ops)
	if !str_rest.is_empty() and !NumText.is_suffix(Str.from_utf8_lossy(case.body).to_utf8().append('!'), str_rest) {
		crash "${label}: rest of a dropped Str is ${Str.inspect(str_rest)}"
	}
	input = shaped_list(case)
	if chain(input, ops, Bool.False) != chain(input, ops, Bool.True) {
		crash "${label}: a chain over rest slices differs from the same chain over fresh copies"
	}
	s = shaped_str(case)
	lossy = Str.from_utf8_lossy(case.body).to_utf8()
	if str_chain(s, ops) != str_chain(Str.from_utf8_lossy(lossy), ops) {
		crash "${label}: a Str chain over seamless slices differs from one over a fresh string"
	}
}

f32_bits : F32 -> Str
f32_bits = |v| v.to_bits().to_str()

f64_bits : F64 -> Str
f64_bits = |v| v.to_bits().to_str()

check! : Case => {}
check! = |case| {
	check_type!("U8", case, Prefix.int_ops(U8.from_str, U8.from_str_prefix, U8.from_utf8_prefix, U8.to_str))
	check_type!("I8", case, Prefix.int_ops(I8.from_str, I8.from_str_prefix, I8.from_utf8_prefix, I8.to_str))
	check_type!("U16", case, Prefix.int_ops(U16.from_str, U16.from_str_prefix, U16.from_utf8_prefix, U16.to_str))
	check_type!("I16", case, Prefix.int_ops(I16.from_str, I16.from_str_prefix, I16.from_utf8_prefix, I16.to_str))
	check_type!("U32", case, Prefix.int_ops(U32.from_str, U32.from_str_prefix, U32.from_utf8_prefix, U32.to_str))
	check_type!("I32", case, Prefix.int_ops(I32.from_str, I32.from_str_prefix, I32.from_utf8_prefix, I32.to_str))
	check_type!("U64", case, Prefix.int_ops(U64.from_str, U64.from_str_prefix, U64.from_utf8_prefix, U64.to_str))
	check_type!("I64", case, Prefix.int_ops(I64.from_str, I64.from_str_prefix, I64.from_utf8_prefix, I64.to_str))
	check_type!("U128", case, Prefix.int_ops(U128.from_str, U128.from_str_prefix, U128.from_utf8_prefix, U128.to_str))
	check_type!("I128", case, Prefix.int_ops(I128.from_str, I128.from_str_prefix, I128.from_utf8_prefix, I128.to_str))
	check_type!("Dec", case, Prefix.dec_ops)
	check_type!("F32", case, Prefix.int_ops(F32.from_str, F32.from_str_prefix, F32.from_utf8_prefix, f32_bits))
	check_type!("F64", case, Prefix.int_ops(F64.from_str, F64.from_str_prefix, F64.from_utf8_prefix, f64_bits))
}

test! : Case => Fuzz.Outcome
test! = |case| {
	Fuzz.expect_no_leaks!(|{}| check!(case))
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "numPrefixAlloc",
	generator,
	test!,
	show: |case| "body=${NumText.show_bytes(case.body)} junk=${case.junk.len().to_str()} shape=${case.shape.to_str()} tail=${NumText.show_bytes(case.tail)}",
})
