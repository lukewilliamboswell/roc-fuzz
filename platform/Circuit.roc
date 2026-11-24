## Gates and fixed-width unsigned arithmetic as clauses. Internal.
##
## A wire is a signed DIMACS literal. Variable 1 is fixed true, so `yes` and
## `no` are wires like any other and every gate can be asked of constants.
## Gates fold constants and are remembered by their inputs, so building the same
## gate twice gives the same wire and costs no clauses. A word is a list of
## wires, least significant bit first.
Circuit := [].{

	## Clauses are stored flat, each one ended by a 0.
	Net : {
		clauses : List(I32),
		count : U64,
		next : I32,
		ands : Dict(U64, I32),
		xors : Dict(U64, I32),
	}

	Word : List(I32)

	yes : I32
	yes = 1

	no : I32
	no = -1

	new : {} -> Net
	new = |{}| { clauses: [1, 0], count: 1, next: 2, ands: Dict.empty(), xors: Dict.empty() }

	## How many variables the net uses, the constant included.
	variables : Net -> U64
	variables = |net| (net.next - 1).to_u64_wrap()

	fresh : Net -> (Net, I32)
	fresh = |net| {
		{ clauses, count, next, ands, xors } = net
		({ clauses, count, next: next + 1, ands, xors }, next)
	}

	## `width` fresh wires, most significant first in variable order (the
	## solver branches on low variables first, so it settles high bits first),
	## returned as a word.
	input : Net, U64 -> (Net, Word)
	input = |net, width| {
		{ clauses, count, next, ands, xors } = net
		var $bits = List.with_capacity(width)
		var $i = 0
		while $i < width {
			$bits = $bits.append(next + (width - 1 - $i).to_i32_wrap())
			$i = $i + 1
		}
		({ clauses, count, next: next + width.to_i32_wrap(), ands, xors }, $bits)
	}

	## Add a clause as it stands.
	require : Net, List(I32) -> Net
	require = |net, lits| {
		{ clauses, count, next, ands, xors } = net
		{ clauses: clauses.concat(lits).append(0), count: count + 1, next, ands, xors }
	}

	key : I32, I32 -> U64
	key = |a, b| a.to_u32_wrap().to_u64().shl_wrap(32).bitwise_or(b.to_u32_wrap().to_u64())

	and_gate : Net, I32, I32 -> (Net, I32)
	and_gate = |net, a, b| {
		if a == no or b == no or a == -b {
			(net, no)
		} else if a == yes or a == b {
			(net, b)
		} else if b == yes {
			(net, a)
		} else {
			lo = if a < b {
				a
			} else {
				b
			}
			hi = if a < b {
				b
			} else {
				a
			}
			k = key(lo, hi)
			match net.ands.get(k) {
				Ok(out) => (net, out)
				Err(_) => {
					{ clauses, count, next, ands, xors } = net
					added = clauses.append(-lo).append(-hi).append(next).append(0).append(lo).append(-next).append(0).append(hi).append(-next).append(0)
					({ clauses: added, count: count + 3, next: next + 1, ands: ands.insert(k, next), xors }, next)
				}
			}
		}
	}

	or_gate : Net, I32, I32 -> (Net, I32)
	or_gate = |net, a, b| {
		(net1, out) = and_gate(net, -a, -b)
		(net1, -out)
	}

	xor_gate : Net, I32, I32 -> (Net, I32)
	xor_gate = |net, a, b| {
		if a == no {
			(net, b)
		} else if a == yes {
			(net, -b)
		} else if b == no {
			(net, a)
		} else if b == yes {
			(net, -a)
		} else if a == b {
			(net, no)
		} else if a == -b {
			(net, yes)
		} else {
			pa = a.abs()
			pb = b.abs()
			flipped = (a < 0) != (b < 0)
			lo = if pa < pb {
				pa
			} else {
				pb
			}
			hi = if pa < pb {
				pb
			} else {
				pa
			}
			k = key(lo, hi)
			match net.xors.get(k) {
				Ok(out) => (
					net,
					if flipped {
						-out
					} else {
						out
					},
				)
				Err(_) => {
					{ clauses, count, next, ands, xors } = net
					added = clauses.append(-lo).append(-hi).append(-next).append(0).append(lo).append(hi).append(-next).append(0).append(lo).append(-hi).append(next).append(0).append(-lo).append(hi).append(next).append(0)
					(
						{ clauses: added, count: count + 4, next: next + 1, ands, xors: xors.insert(k, next) },
						if flipped {
							-next
						} else {
							next
						},
					)
				}
			}
		}
	}

	## `then` when `pick` is true, otherwise `else`.
	mux : Net, I32, I32, I32 -> (Net, I32)
	mux = |net, pick, then, else_| {
		if pick == yes or then == else_ {
			(net, then)
		} else if pick == no {
			(net, else_)
		} else {
			(net1, first) = and_gate(net, pick, then)
			(net2, second) = and_gate(net1, -pick, else_)
			or_gate(net2, first, second)
		}
	}

	and_all : Net, List(I32) -> (Net, I32)
	and_all = |net, wires| {
		var $net = net
		var $out = yes
		for wire in wires {
			(next, out) = and_gate($net, $out, wire)
			$net = next
			$out = out
		}
		($net, $out)
	}

	or_all : Net, List(I32) -> (Net, I32)
	or_all = |net, wires| {
		var $net = net
		var $out = no
		for wire in wires {
			(next, out) = or_gate($net, $out, wire)
			$net = next
			$out = out
		}
		($net, $out)
	}

	# -- Words ---------------------------------------------------------------

	constant : U64, U64 -> Word
	constant = |value, width| {
		var $bits = List.with_capacity(width)
		var $i = 0
		while $i < width {
			set = $i < 64 and value.shr_wrap($i.to_u8_wrap()).bitwise_and(1) == 1
			$bits = $bits.append(
				if set {
					yes
				} else {
					no
				},
			)
			$i = $i + 1
		}
		$bits
	}

	## The value of a word made only of constants.
	known : Word -> Try(U64, [Symbolic])
	known = |word| {
		var $value = 0
		var $weight = 1
		var $fixed = Bool.True
		for wire in word {
			if wire == yes {
				$value = $value.bitwise_or($weight)
			} else if wire != no {
				$fixed = Bool.False
			}
			$weight = $weight.shl_wrap(1)
		}
		if $fixed {
			Ok($value)
		} else {
			Err(Symbolic)
		}
	}

	wire_at : Word, U64 -> I32
	wire_at = |word, index| word.get(index) ?? no

	## Sum of three wires and the carry out of it.
	full_add : Net, I32, I32, I32 -> (Net, I32, I32)
	full_add = |net, a, b, carry| {
		(net1, differ) = xor_gate(net, a, b)
		(net2, sum) = xor_gate(net1, differ, carry)
		(net3, both) = and_gate(net2, a, b)
		(net4, through) = and_gate(net3, differ, carry)
		(net5, out) = or_gate(net4, both, through)
		(net5, sum, out)
	}

	## The low bits of `xs + ys + carry`, and the carry out of the top bit.
	add : Net, Word, Word, I32 -> (Net, Word, I32)
	add = |net, xs, ys, carry_in| {
		var $net = net
		var $carry = carry_in
		var $sum = List.with_capacity(xs.len())
		var $i = 0
		while $i < xs.len() {
			(next, bit, carry) = full_add($net, wire_at(xs, $i), wire_at(ys, $i), $carry)
			$net = next
			$carry = carry
			$sum = $sum.append(bit)
			$i = $i + 1
		}
		($net, $sum, $carry)
	}

	invert : Word -> Word
	invert = |word| word.map(|wire| -wire)

	## The low bits of `xs - ys`, and a wire that is true when `xs >= ys`.
	subtract : Net, Word, Word -> (Net, Word, I32)
	subtract = |net, xs, ys| add(net, xs, invert(ys), yes)

	equal : Net, Word, Word -> (Net, I32)
	equal = |net, xs, ys| {
		var $net = net
		var $same = yes
		var $i = 0
		while $i < xs.len() {
			(net1, differ) = xor_gate($net, wire_at(xs, $i), wire_at(ys, $i))
			(net2, still) = and_gate(net1, $same, -differ)
			$net = net2
			$same = still
			$i = $i + 1
		}
		($net, $same)
	}

	## Unsigned `xs < ys`. From the low bit up: where the bits differ the
	## answer is the bit of `ys`, otherwise it is the answer so far.
	less : Net, Word, Word -> (Net, I32)
	less = |net, xs, ys| {
		var $net = net
		var $lt = no
		var $i = 0
		while $i < xs.len() {
			b = wire_at(ys, $i)
			(net1, differ) = xor_gate($net, wire_at(xs, $i), b)
			(net2, lt) = mux(net1, differ, b, $lt)
			$net = net2
			$lt = lt
			$i = $i + 1
		}
		($net, $lt)
	}

	choose : Net, I32, Word, Word -> (Net, Word)
	choose = |net, pick, xs, ys| {
		var $net = net
		var $out = List.with_capacity(xs.len())
		var $i = 0
		while $i < xs.len() {
			(next, wire) = mux($net, pick, wire_at(xs, $i), wire_at(ys, $i))
			$net = next
			$out = $out.append(wire)
			$i = $i + 1
		}
		($net, $out)
	}

	bitwise : Net, [BitAnd, BitOr, BitXor], Word, Word -> (Net, Word)
	bitwise = |net, op, xs, ys| {
		var $net = net
		var $out = List.with_capacity(xs.len())
		var $i = 0
		while $i < xs.len() {
			a = wire_at(xs, $i)
			b = wire_at(ys, $i)
			(next, wire) = match op {
				BitAnd => and_gate($net, a, b)
				BitOr => or_gate($net, a, b)
				BitXor => xor_gate($net, a, b)
			}
			$net = next
			$out = $out.append(wire)
			$i = $i + 1
		}
		($net, $out)
	}

	## Shift towards the high end, dropping what leaves and filling with zeros.
	shift_left : Word, U64 -> Word
	shift_left = |word, by| List.repeat(no, by).concat(word).take_first(word.len())

	shift_right : Word, U64 -> Word
	shift_right = |word, by| word.drop_first(by).concat(List.repeat(no, U64.min(by, word.len())))

	## The word at a new width, and a wire that is true when no set bit was lost.
	resize : Net, Word, U64 -> (Net, Word, I32)
	resize = |net, word, width| {
		if width >= word.len() {
			(net, word.concat(List.repeat(no, width - word.len())), yes)
		} else {
			(net1, lost) = or_all(net, word.drop_first(width))
			(net1, word.take_first(width), -lost)
		}
	}

	## The low bits of `xs * ys`, and a wire that is true when the product does
	## not fit. Shift and add, one row per bit of `ys`. Every partial product is
	## non-negative, so the true product fits exactly when no row loses a set
	## bit off the top and no addition carries out.
	multiply : Net, Word, Word -> (Net, Word, I32)
	multiply = |net, xs, ys| {
		width = xs.len()
		# above[k] is true when any of xs[k..] is set.
		var $net = net
		var $above = List.repeat(no, width + 1)
		var $k = width
		while $k > 0 {
			$k = $k - 1
			(next, any) = or_gate($net, wire_at(xs, $k), wire_at($above, $k + 1))
			$net = next
			$above = $above.set($k, any) ?? $above
		}
		var $acc = List.repeat(no, width)
		var $spill = no
		var $i = 0
		while $i < width {
			y = wire_at(ys, $i)
			var $row = List.with_capacity(width)
			var $j = 0
			while $j < width {
				if $j < $i {
					$row = $row.append(no)
				} else {
					(next, wire) = and_gate($net, wire_at(xs, $j - $i), y)
					$net = next
					$row = $row.append(wire)
				}
				$j = $j + 1
			}
			(net1, sum, carry) = add($net, $acc, $row, no)
			(net2, lost) = and_gate(net1, y, wire_at($above, width - $i))
			(net3, spill1) = or_gate(net2, $spill, carry)
			(net4, spill2) = or_gate(net3, spill1, lost)
			$net = net4
			$acc = sum
			$spill = spill2
			$i = $i + 1
		}
		($net, $acc, $spill)
	}

	# -- Signed words --------------------------------------------------------

	## The wire that says a word is negative as a two's complement number.
	sign : Word -> I32
	sign = |word| if word.is_empty() {
		no
	} else {
		wire_at(word, word.len() - 1)
	}

	## Signed `xs < ys`. Flipping both sign bits puts the negative numbers
	## below the others, and then the order is the unsigned one.
	less_signed : Net, Word, Word -> (Net, I32)
	less_signed = |net, xs, ys| less(net, flip_sign(xs), flip_sign(ys))

	flip_sign : Word -> Word
	flip_sign = |word| if word.is_empty() {
		word
	} else {
		word.take_first(word.len() - 1).append(-sign(word))
	}

	## The signed word at a new width, and a wire that is true when the number
	## still fits. Widening repeats the sign bit. Narrowing fits when every
	## bit dropped equals the sign bit that is left.
	resize_signed : Net, Word, U64 -> (Net, Word, I32)
	resize_signed = |net, word, width| {
		if width >= word.len() {
			(net, word.concat(List.repeat(sign(word), width - word.len())), yes)
		} else {
			kept = word.take_first(width)
			top = sign(kept)
			var $net = net
			var $fits = yes
			for dropped in word.drop_first(width) {
				(net1, differ) = xor_gate($net, dropped, top)
				(net2, still) = and_gate(net1, $fits, -differ)
				$net = net2
				$fits = still
			}
			($net, kept, $fits)
		}
	}

	## Would signed `xs + ys` leave the width? `sum` is their wrapped sum. It
	## does when both have the same sign and the sum has the other one.
	add_overflows_signed : Net, Word, Word, Word -> (Net, I32)
	add_overflows_signed = |net, xs, ys, sum| {
		(net1, x_turned) = xor_gate(net, sign(xs), sign(sum))
		(net2, y_turned) = xor_gate(net1, sign(ys), sign(sum))
		and_gate(net2, x_turned, y_turned)
	}

	## Would signed `xs - ys` leave the width? `difference` is their wrapped
	## difference. It does when the signs differ and the result's is not the
	## sign of `xs`.
	subtract_overflows_signed : Net, Word, Word, Word -> (Net, I32)
	subtract_overflows_signed = |net, xs, ys, difference| {
		(net1, apart) = xor_gate(net, sign(xs), sign(ys))
		(net2, turned) = xor_gate(net1, sign(xs), sign(difference))
		and_gate(net2, apart, turned)
	}

	## The low bits of signed `xs * ys`, and a wire that is true when the
	## product does not fit the width as a signed number. Both are widened to
	## twice the width, where the product is exact, and it fits when every bit
	## from the sign bit of the narrow result upwards is the same.
	multiply_signed : Net, Word, Word -> (Net, Word, I32)
	multiply_signed = |net, xs, ys| {
		width = xs.len()
		(net1, wide_x, _) = resize_signed(net, xs, 2 * width)
		(net2, wide_y, _) = resize_signed(net1, ys, 2 * width)
		(net3, product, _) = multiply(net2, wide_x, wide_y)
		low = product.take_first(width)
		top = sign(low)
		var $net = net3
		var $spill = no
		for above in product.drop_first(width) {
			(net4, differ) = xor_gate($net, above, top)
			(net5, spill) = or_gate(net4, $spill, differ)
			$net = net5
			$spill = spill
		}
		($net, low, $spill)
	}

	## Quotient and remainder of `xs` by `ys`, and a wire that is true when
	## `ys` is not zero. A constant power of two is a shift and a mask. Anything
	## else introduces the quotient and remainder as fresh wires and requires
	## `q * ys + r == xs` and `r < ys` whenever `ys` is not zero; when it is
	## zero they are left free, and the caller must not use them.
	divide : Net, Word, Word -> (Net, Word, Word, I32)
	divide = |net, xs, ys| {
		width = xs.len()
		zero = List.repeat(no, width)
		shift = match known(ys) {
			Ok(0) => Zero
			Ok(d) if d.bitwise_and(d - 1) == 0 => PowerOfTwo(d.count_trailing_zero_bits().to_u64())
			_ => General
		}
		match shift {
			Zero => (net, zero, zero, no)
			PowerOfTwo(by) => (net, shift_right(xs, by), xs.take_first(by).concat(List.repeat(no, width - by)), yes)
			General => {
				(net1, quotient) = input(net, width)
				(net2, remainder) = input(net1, width)
				(net3, product, spill) = multiply(net2, quotient, ys)
				(net4, sum, carry) = add(net3, product, remainder, no)
				(net5, same) = equal(net4, sum, xs)
				(net6, small) = less(net5, remainder, ys)
				(net7, exact) = and_all(net6, [-spill, -carry, same, small])
				(net8, nonzero) = or_all(net7, ys)
				(require(net8, [-nonzero, exact]), quotient, remainder, nonzero)
			}
		}
	}
}

# Constants fold away, and a repeated gate is the same wire.
expect {
	net0 = Circuit.new({})
	(net1, a) = Circuit.fresh(net0)
	(net2, b) = Circuit.fresh(net1)
	(net3, first) = Circuit.and_gate(net2, a, b)
	(net4, second) = Circuit.and_gate(net3, b, a)
	(net5, third) = Circuit.xor_gate(net4, -a, b)
	(net6, fourth) = Circuit.xor_gate(net5, b, a)
	(net7, fifth) = Circuit.and_gate(net6, a, Circuit.yes)
	(net8, sixth) = Circuit.xor_gate(net7, a, Circuit.yes)
	first == second and third == -fourth and fifth == a and sixth == -a and net8.count == 8 and Circuit.variables(net8) == 5
}

# Arithmetic on constant words needs no clauses at all.
expect {
	net0 = Circuit.new({})
	(net1, sum, carry) = Circuit.add(net0, Circuit.constant(200, 8), Circuit.constant(100, 8), Circuit.no)
	(net2, product, spill) = Circuit.multiply(net1, Circuit.constant(13, 8), Circuit.constant(11, 8))
	(net3, wide, lost) = Circuit.multiply(net2, Circuit.constant(16, 8), Circuit.constant(16, 8))
	(net4, quotient, remainder, nonzero) = Circuit.divide(net3, Circuit.constant(77, 8), Circuit.constant(8, 8))
	Circuit.known(sum) == Ok(44) and carry == Circuit.yes
		and Circuit.known(product) == Ok(143) and spill == Circuit.no
		and Circuit.known(wide) == Ok(0) and lost == Circuit.yes
		and Circuit.known(quotient) == Ok(9) and Circuit.known(remainder) == Ok(5) and nonzero == Circuit.yes
		and net4.count == 1
}

expect Circuit.known(Circuit.shift_left(Circuit.constant(0b1011, 4), 1)) == Ok(0b0110)
expect Circuit.known(Circuit.shift_right(Circuit.constant(0b1011, 4), 1)) == Ok(0b0101)
expect Circuit.known(Circuit.shift_right(Circuit.constant(0b1011, 4), 9)) == Ok(0)
