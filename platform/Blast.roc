## Terms to circuits. Internal.
##
## Every term becomes two things: its value (a word or a wire) and a wire
## `defined` that is true exactly when `Term.eval` would return `Ok` rather than
## crash. When `defined` is false the value wires may hold anything, so nothing
## may be concluded from a value without its `defined`. A whole claim holds when
## it is both defined and true: see `holds`.
import Term
import Circuit

Blast := [].{
	Out : [Word(List(I32)), Bit(I32)]

	## What a term is built from: the wires of each declared unknown, by
	## position, and the value and `defined` wire of each definition of the
	## `Given` the term is inside.
	Scope : { inputs : List(List(I32)), frame : List((Out, I32)) }

	## A claim as one wire: true exactly when `Term.holds` is `Ok(True)`.
	## `inputs` gives the wires of each declared unknown, by position.
	holds : Circuit.Net, List(List(I32)), Term -> Try((Circuit.Net, I32), Term.Fault)
	holds = |net, inputs, term| {
		(net1, value, defined) = bit(net, { inputs, frame: [] }, term)?
		(net2, wire) = Circuit.and_gate(net1, defined, value)
		Ok((net2, wire))
	}

	blast : Circuit.Net, Scope, Term -> Try((Circuit.Net, Out, I32), Term.Fault)
	blast = |net, scope, term| match term {
		Lit(_) => Err(Malformed)
		Const(value, width) => Ok((net, Word(Circuit.constant(value, width.to_u64())), Circuit.yes))
		Var(id, width) => match scope.inputs.get(id) {
			Ok(wires) => if wires.len() == width.to_u64() {
				Ok((net, Word(wires), Circuit.yes))
			} else {
				Err(Malformed)
			}
			Err(_) => Err(Unbound(id))
		}
		Flag(id) => match scope.inputs.get(id) {
			Ok([wire]) => Ok((net, Bit(wire), Circuit.yes))
			Ok(_) => Err(Malformed)
			Err(_) => Err(Unbound(id))
		}
		Truth(value) => Ok((
			net,
			Bit(
				if value {
					Circuit.yes
				} else {
					Circuit.no
				},
			),
			Circuit.yes,
		))
		Arith(op, a, b) => {
			(net1, xs, ys, both) = words(net, scope, a, b)?
			match op {
				Plus => {
					(net2, sum, carry) = Circuit.add(net1, xs, ys, Circuit.no)
					(net3, defined) = Circuit.and_gate(net2, both, -carry)
					Ok((net3, Word(sum), defined))
				}
				PlusWrap => {
					(net2, sum, _) = Circuit.add(net1, xs, ys, Circuit.no)
					Ok((net2, Word(sum), both))
				}
				Minus => {
					(net2, difference, enough) = Circuit.subtract(net1, xs, ys)
					(net3, defined) = Circuit.and_gate(net2, both, enough)
					Ok((net3, Word(difference), defined))
				}
				MinusWrap => {
					(net2, difference, _) = Circuit.subtract(net1, xs, ys)
					Ok((net2, Word(difference), both))
				}
				Times => {
					(net2, product, spill) = Circuit.multiply(net1, xs, ys)
					(net3, defined) = Circuit.and_gate(net2, both, -spill)
					Ok((net3, Word(product), defined))
				}
				TimesWrap => {
					(net2, product, _) = Circuit.multiply(net1, xs, ys)
					Ok((net2, Word(product), both))
				}
				Div => {
					(net2, quotient, _, nonzero) = Circuit.divide(net1, xs, ys)
					(net3, defined) = Circuit.and_gate(net2, both, nonzero)
					Ok((net3, Word(quotient), defined))
				}
				Rem => {
					(net2, _, remainder, nonzero) = Circuit.divide(net1, xs, ys)
					(net3, defined) = Circuit.and_gate(net2, both, nonzero)
					Ok((net3, Word(remainder), defined))
				}
				BitAnd => {
					(net2, out) = Circuit.bitwise(net1, BitAnd, xs, ys)
					Ok((net2, Word(out), both))
				}
				BitOr => {
					(net2, out) = Circuit.bitwise(net1, BitOr, xs, ys)
					Ok((net2, Word(out), both))
				}
				BitXor => {
					(net2, out) = Circuit.bitwise(net1, BitXor, xs, ys)
					Ok((net2, Word(out), both))
				}
			}
		}
		BitNot(a) => {
			(net1, xs, defined) = word(net, scope, a)?
			Ok((net1, Word(Circuit.invert(xs)), defined))
		}
		Shift(direction, a, count) => {
			(net1, xs, defined) = word(net, scope, a)?
			by = count.to_u64() % xs.len()
			match direction {
				Left => Ok((net1, Word(Circuit.shift_left(xs, by)), defined))
				Right => Ok((net1, Word(Circuit.shift_right(xs, by)), defined))
			}
		}
		Resize(mode, a, to) => {
			(net1, xs, inner) = word(net, scope, a)?
			(net2, out, fits) = Circuit.resize(net1, xs, to.to_u64())
			match mode {
				Checked => {
					(net3, defined) = Circuit.and_gate(net2, inner, fits)
					Ok((net3, Word(out), defined))
				}
				Wrap => Ok((net2, Word(out), inner))
			}
		}
		Overflows(op, a, b) => {
			(net1, xs, ys, both) = words(net, scope, a, b)?
			match op {
				Plus => {
					(net2, _, carry) = Circuit.add(net1, xs, ys, Circuit.no)
					Ok((net2, Bit(carry), both))
				}
				Minus => {
					(net2, _, enough) = Circuit.subtract(net1, xs, ys)
					Ok((net2, Bit(-enough), both))
				}
				Times => {
					(net2, _, spill) = Circuit.multiply(net1, xs, ys)
					Ok((net2, Bit(spill), both))
				}
			}
		}
		Compare(op, a, b) => {
			(net1, xs, ys, both) = words(net, scope, a, b)?
			match op {
				Eq => {
					(net2, same) = Circuit.equal(net1, xs, ys)
					Ok((net2, Bit(same), both))
				}
				Lt => {
					(net2, below) = Circuit.less(net1, xs, ys)
					Ok((net2, Bit(below), both))
				}
				Lte => {
					(net2, above) = Circuit.less(net1, ys, xs)
					Ok((net2, Bit(-above), both))
				}
			}
		}
		Signed(op, a, b) => {
			(net1, xs, ys, both) = words(net, scope, a, b)?
			(net2, out, overflow) = signed(net1, op, xs, ys)
			(net3, defined) = Circuit.and_gate(net2, both, -overflow)
			Ok((net3, Word(out), defined))
		}
		SignedOverflows(op, a, b) => {
			(net1, xs, ys, both) = words(net, scope, a, b)?
			(net2, _, overflow) = signed(net1, op, xs, ys)
			Ok((net2, Bit(overflow), both))
		}
		SignedCompare(op, a, b) => {
			(net1, xs, ys, both) = words(net, scope, a, b)?
			match op {
				Lt => {
					(net2, below) = Circuit.less_signed(net1, xs, ys)
					Ok((net2, Bit(below), both))
				}
				Lte => {
					(net2, above) = Circuit.less_signed(net1, ys, xs)
					Ok((net2, Bit(-above), both))
				}
			}
		}
		SignedResize(a, to) => {
			(net1, xs, inner) = word(net, scope, a)?
			(net2, out, fits) = Circuit.resize_signed(net1, xs, to.to_u64())
			(net3, defined) = Circuit.and_gate(net2, inner, fits)
			Ok((net3, Word(out), defined))
		}
		Not(a) => {
			(net1, value, defined) = bit(net, scope, a)?
			Ok((net1, Bit(-value), defined))
		}
		All(items) => {
			# In `a and b and c`, `b` runs only when `a` is true. So the whole
			# is defined when `a` is, and either `a` is false or the rest is.
			(net1, values, defineds) = bits(net, scope, items)?
			(net2, value) = Circuit.and_all(net1, values)
			var $net = net2
			var $rest = Circuit.yes
			var $i = values.len()
			while $i > 0 {
				$i = $i - 1
				(net3, onward) = Circuit.or_gate($net, -(values.get($i) ?? Circuit.no), $rest)
				(net4, here) = Circuit.and_gate(net3, defineds.get($i) ?? Circuit.no, onward)
				$net = net4
				$rest = here
			}
			Ok(($net, Bit(value), $rest))
		}
		Any(items) => {
			(net1, values, defineds) = bits(net, scope, items)?
			(net2, value) = Circuit.or_all(net1, values)
			var $net = net2
			var $rest = Circuit.yes
			var $i = values.len()
			while $i > 0 {
				$i = $i - 1
				(net3, onward) = Circuit.or_gate($net, values.get($i) ?? Circuit.no, $rest)
				(net4, here) = Circuit.and_gate(net3, defineds.get($i) ?? Circuit.no, onward)
				$net = net4
				$rest = here
			}
			Ok(($net, Bit(value), $rest))
		}
		Implies(a, b) => {
			(net1, premise, premise_defined) = bit(net, scope, a)?
			(net2, conclusion, conclusion_defined) = bit(net1, scope, b)?
			(net3, value) = Circuit.or_gate(net2, -premise, conclusion)
			(net4, onward) = Circuit.or_gate(net3, -premise, conclusion_defined)
			(net5, defined) = Circuit.and_gate(net4, premise_defined, onward)
			Ok((net5, Bit(value), defined))
		}
		Same(a, b) => {
			(net1, left, left_defined) = bit(net, scope, a)?
			(net2, right, right_defined) = bit(net1, scope, b)?
			(net3, differ) = Circuit.xor_gate(net2, left, right)
			(net4, defined) = Circuit.and_gate(net3, left_defined, right_defined)
			Ok((net4, Bit(-differ), defined))
		}
		Choose(c, a, b) => {
			(net1, pick, pick_defined) = bit(net, scope, c)?
			(net2, then, then_defined) = blast(net1, scope, a)?
			(net3, else_, else_defined) = blast(net2, scope, b)?
			(net4, branch_defined) = Circuit.mux(net3, pick, then_defined, else_defined)
			(net5, defined) = Circuit.and_gate(net4, pick_defined, branch_defined)
			match (then, else_) {
				(Word(xs), Word(ys)) => if xs.len() == ys.len() {
					(net6, out) = Circuit.choose(net5, pick, xs, ys)
					Ok((net6, Word(out), defined))
				} else {
					Err(Malformed)
				}
				(Bit(x), Bit(y)) => {
					(net6, out) = Circuit.mux(net5, pick, x, y)
					Ok((net6, Bit(out), defined))
				}
				_ => Err(Malformed)
			}
		}
		Shared(_, inner) => blast(net, scope, inner)
		Given(defs, body) => {
			# Each definition is built once, whether or not anything reads
			# it. Its `defined` wire travels with it, and only counts where a
			# `Ref` is evaluated.
			var $net = net
			var $frame = List.with_capacity(defs.len())
			for def in defs {
				(next, out, defined) = blast($net, { inputs: scope.inputs, frame: $frame }, def)?
				$net = next
				$frame = $frame.append((out, defined))
			}
			blast($net, { inputs: scope.inputs, frame: $frame }, body)
		}
		Ref(index) => match scope.frame.get(index) {
			Ok((out, defined)) => Ok((net, out, defined))
			Err(_) => Err(Malformed)
		}
	}

	## The wrapped result of a signed operation, and whether the true result
	## leaves the width.
	signed : Circuit.Net, [Plus, Minus, Times], List(I32), List(I32) -> (Circuit.Net, List(I32), I32)
	signed = |net, op, xs, ys| match op {
		Plus => {
			(net1, sum, _) = Circuit.add(net, xs, ys, Circuit.no)
			(net2, overflow) = Circuit.add_overflows_signed(net1, xs, ys, sum)
			(net2, sum, overflow)
		}
		Minus => {
			(net1, difference, _) = Circuit.subtract(net, xs, ys)
			(net2, overflow) = Circuit.subtract_overflows_signed(net1, xs, ys, difference)
			(net2, difference, overflow)
		}
		Times => Circuit.multiply_signed(net, xs, ys)
	}

	word : Circuit.Net, Scope, Term -> Try((Circuit.Net, List(I32), I32), Term.Fault)
	word = |net, scope, term| {
		(net1, out, defined) = blast(net, scope, term)?
		match out {
			Word(wires) => Ok((net1, wires, defined))
			Bit(_) => Err(Malformed)
		}
	}

	## Two numbers of the same width, and whether both are defined.
	words : Circuit.Net, Scope, Term, Term -> Try((Circuit.Net, List(I32), List(I32), I32), Term.Fault)
	words = |net, scope, a, b| {
		(net1, xs, left) = word(net, scope, a)?
		(net2, ys, right) = word(net1, scope, b)?
		if xs.len() == ys.len() {
			(net3, both) = Circuit.and_gate(net2, left, right)
			Ok((net3, xs, ys, both))
		} else {
			Err(WidthMismatch({ left: xs.len().to_u8_wrap(), right: ys.len().to_u8_wrap() }))
		}
	}

	bit : Circuit.Net, Scope, Term -> Try((Circuit.Net, I32, I32), Term.Fault)
	bit = |net, scope, term| {
		(net1, out, defined) = blast(net, scope, term)?
		match out {
			Bit(wire) => Ok((net1, wire, defined))
			Word(_) => Err(Malformed)
		}
	}

	bits : Circuit.Net, Scope, List(Term) -> Try((Circuit.Net, List(I32), List(I32)), Term.Fault)
	bits = |net, scope, items| {
		var $net = net
		var $values = List.with_capacity(items.len())
		var $defineds = List.with_capacity(items.len())
		for item in items {
			(next, value, defined) = bit($net, scope, item)?
			$net = next
			$values = $values.append(value)
			$defineds = $defineds.append(defined)
		}
		Ok(($net, $values, $defineds))
	}
}
