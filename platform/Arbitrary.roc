## Deterministically turns a fuzzer byte stream into values with varied Roc
## allocation shapes. Entropy is consumed from the end when selecting sizes so
## coverage-guided fuzzers can mutate value bytes without also moving boundaries.
Arbitrary := [Unstructured(List(U8))].{
	new : List(U8) -> Arbitrary
	new = |data| Unstructured(data)

	len : Arbitrary -> U64
	len = |Unstructured(data)| List.len(data)

	is_empty : Arbitrary -> Bool
	is_empty = |unstructured| unstructured.len() == 0

	bytes : Arbitrary, U64 -> Try({ value : List(U8), state : Arbitrary }, [NotEnoughData(U64), ..])
	bytes = |Unstructured(data), requested_len| {
		if List.len(data) >= requested_len {
			{ before, others } = List.split_at(data, requested_len)
			Ok({ value: before, state: Unstructured(others) })
		} else {
			Err(NotEnoughData(List.len(data)))
		}
	}

	u64_in_inclusive_range : Arbitrary, U64, U64 -> { value : U64, state : Arbitrary }
	u64_in_inclusive_range = |Unstructured(data), start, end| {
		if start > end {
			crash "u64_in_inclusive_range requires a non-empty range"
		}

		if start == end {
			return { value: start, state: Unstructured(data) }
		}

		delta = end.minus_wrap(start)
		var $remaining = delta
		var $input = data
		var $integer = 0

		while ($remaining > 0 and !List.is_empty($input)) {
			byte = match List.last($input) {
				Ok(value) => value
				Err(_) => {
					crash "non-empty entropy list had no last element"
				}
			}
			$integer = U64.bitwise_or(U64.shl_wrap($integer, 8), U8.to_u64(byte))
			$input = List.drop_last($input, 1)
			$remaining = U64.shr_zf_wrap($remaining, 8)
		}

		offset = match delta.plus_try(1) {
			Ok(range_width) => $integer % range_width
			Err(_) => $integer
		}

		{ value: start.plus_wrap(offset), state: Unstructured($input) }
	}

	ratio : Arbitrary, U64, U64 -> { value : Bool, state : Arbitrary }
	ratio = |unstructured, numerator, denominator| {
		if numerator > denominator {
			crash "ratio numerator must not exceed its denominator"
		}

		{ value, state } = unstructured.u64_in_inclusive_range(1, denominator)
		{ value: value > denominator - numerator, state }
	}

	arbitrary_byte_size : Arbitrary -> { value : U64, state : Arbitrary }
	arbitrary_byte_size = |Unstructured(data)| {
		data_len = List.len(data)
		if data_len <= 1 {
			return { value: 0, state: Unstructured([]) }
		}

		num_bytes = if data_len <= 0x100 {
			1
		} else if data_len <= 0x1_0000 {
			2
		} else if data_len <= 0x1_0000_0000 {
			4
		} else {
			8
		}

		max_len = data_len - num_bytes
		{ before, others } = List.split_at(data, max_len)
		{ value, .. } = Arbitrary.u64_in_inclusive_range(Unstructured(others), 0, max_len)
		{ value, state: Unstructured(before) }
	}

	next_power_of_two : U64 -> U64
	next_power_of_two = |n| {
		var $power = 1
		while ($power <= n and $power <= U64.highest / 2) {
			$power = $power * 2
		}
		$power
	}

	arbitrary_list_u8 : Arbitrary -> { value : List(U8), state : Arbitrary }
	arbitrary_list_u8 = |unstructured| {
		{ value: seamless_slice, state: after_slice_choice } = unstructured.ratio(1, 2)
		{ value: size, state: after_size } = after_slice_choice.arbitrary_byte_size()
		{ value: data_slice, state: after_data } = match after_size.bytes(size) {
			Ok(value) => value
			Err(_) => {
				crash "arbitrary byte size did not fit its input"
			}
		}

		raw_data = List.release_excess_capacity(data_slice)
		max_capacity = Arbitrary.next_power_of_two(List.len(raw_data)) * 2
		{ value: capacity, state } = after_data.u64_in_inclusive_range(0, max_capacity)
		with_capacity = if capacity > List.len(raw_data) {
			List.reserve(raw_data, capacity - List.len(raw_data))
		} else {
			raw_data
		}

		value = if seamless_slice List.drop_first(with_capacity, 1) else with_capacity
		{ value, state }
	}

	arbitrary_str : Arbitrary -> { value : Str, state : Arbitrary }
	arbitrary_str = |unstructured| {
		{ value: size, state: after_size } = unstructured.arbitrary_byte_size()
		{ value: data, state: after_data } = match after_size.bytes(size) {
			Ok(value) => value
			Err(_) => {
				crash "arbitrary byte size did not fit its input"
			}
		}

		{ value: string_slice, state: after_utf8 } = match Str.from_utf8(data) {
			Ok(value) => { value, state: after_data }
			Err(BadUtf8({ index, .. })) => {
				{ value: valid_data, state } = match after_size.bytes(index) {
					Ok(value) => value
					Err(_) => {
						crash "valid UTF-8 prefix did not fit its input"
					}
				}
				value = match Str.from_utf8(valid_data) {
					Ok(valid) => valid
					Err(_) => {
						crash "prefix before invalid UTF-8 byte was not valid"
					}
				}
				{ value, state }
			}
		}

		raw_string = Str.release_excess_capacity(string_slice)
		byte_len = Str.count_utf8_bytes(raw_string)
		minimum_capacity = Arbitrary.next_power_of_two(byte_len) * 2
		max_capacity = if minimum_capacity < 32 32 else minimum_capacity
		{ value: capacity, state } = after_utf8.u64_in_inclusive_range(0, max_capacity)
		value = if capacity > byte_len {
			Str.reserve(raw_string, capacity - byte_len)
		} else {
			raw_string
		}

		{ value, state }
	}
}

expect Arbitrary.new([1, 2, 3]).len() == 3
expect Arbitrary.new([]).is_empty()
expect Arbitrary.new([49, 50, 51, 52, 9]).arbitrary_str().value == "1234"
expect Arbitrary.new([2, 4, 5, 6, 9]).arbitrary_byte_size().value == 4
expect Arbitrary.new([]).u64_in_inclusive_range(0, 100).value == 0
