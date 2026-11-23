## The term language behind `Solve.Uint` and `Solve.Claim`, with its concrete
## evaluator. Internal: users build terms through the two typed wrappers in
## `Solve`, which keep numbers and truth values apart in the type checker.
##
## A term means what the same expression means in Roc. A number has a width in
## bits and is unsigned. `Plus`, `Minus`, `Times`, `Div` and `Rem` crash when
## Roc would: on overflow, on going below zero, on dividing by zero. `All`,
## `Any`, `Implies` and `Choose` evaluate left to right and stop early exactly
## like `and`, `or` and `if`, so a guard written first protects what follows.
##
## The `Signed` forms read the same bits as a two's complement integer of the
## same width, which is what Roc's `I8` to `I64` are.
##
## `eval` is the reference meaning. `Blast` must agree with it on every input,
## and the tests in `Validate` check that it does.
Term := [
	## A number literal that has no width yet. It takes the width of whatever
	## it is combined with, and must fit in it.
	Lit(U64),

	## A number of a known width: value, then width in bits.
	Const(U64, U8),

	## An unknown number: its position among the declared unknowns, then width.
	Var(U64, U8),

	## An unknown truth value: its position among the declared unknowns.
	Flag(U64),
	Truth(Bool),
	Arith([Plus, Minus, Times, Div, Rem, PlusWrap, MinusWrap, TimesWrap, BitAnd, BitOr, BitXor], Term, Term),
	BitNot(Term),

	## Shift by a fixed count. Like Roc, the count is taken modulo the width.
	Shift([Left, Right], Term, U8),

	## Change width. Widening adds zero bits. Narrowing either crashes when the
	## value does not fit (`Checked`) or drops the high bits (`Wrap`).
	Resize([Checked, Wrap], Term, U8),

	## Would the checked operation crash? Never crashes itself.
	Overflows([Plus, Minus, Times], Term, Term),
	Compare([Eq, Lt, Lte], Term, Term),

	## Arithmetic on the bits as signed integers. Crashes when the true result
	## does not fit the width as a signed number, as Roc's `I32` does.
	Signed([Plus, Minus, Times], Term, Term),

	## Would the signed operation crash? Never crashes itself.
	SignedOverflows([Plus, Minus, Times], Term, Term),

	## Order on the bits as signed integers.
	SignedCompare([Lt, Lte], Term, Term),

	## The same signed number at another width. Widening copies the sign bit.
	## Narrowing crashes when the number does not fit.
	SignedResize(Term, U8),
	Not(Term),
	All(List(Term)),
	Any(List(Term)),
	Implies(Term, Term),
	Same(Term, Term),

	## `if` on either sort: condition, then, else.
	Choose(Term, Term, Term),

	## A term to work out once however often it appears: its fingerprint, then
	## the term. It means exactly what the term means. Only in terms that have
	## not been elaborated.
	Shared(U64, Term),

	## What elaboration turns shared terms into: definitions, then a body. A
	## definition may refer to the ones before it, and the body to all of them.
	Given(List(Term), Term),

	## Definition number `n` of the nearest enclosing `Given`. It crashes where
	## it is used if its definition crashes, and nowhere else.
	Ref(U64),
].{
	is_eq : _

	## Everything that can go wrong. `Overflow` and `DivByZero` are what the
	## term does on particular values (Roc would crash). `GaveUp` means a
	## search spent its whole budget without an answer, and carries what it
	## spent: the question is still open. `NoSuchExtra` means a query assumed
	## an extra claim at a position the prepared claim has none at. `Solver`
	## is an error from the SAT
	## package and `Disagreement` means the solver returned values the
	## evaluator rejects: both are bugs, not user errors. The rest mean the
	## term itself is ill-formed, whatever the values.
	Fault : [
		Overflow,
		DivByZero,
		WidthMismatch({ left : U8, right : U8 }),
		LiteralTooLarge({ literal : U64, width : U8 }),
		BadWidth(U8),
		BadRange({ lo : U64, hi : U64, width : U8 }),
		Unbound(U64),
		NoSuchExtra(U64),
		Malformed,
		GaveUp({ conflicts : U64, decisions : U64, propagations : U64, restarts : U64 }),
		Solver([ZeroLiteral, LiteralOutOfRange(I32), UnknownVariable(I32), VariableLimit]),
		Disagreement,
	]

	## What a term evaluates to.
	Value : [Word(U64, U8), Bit(Bool)]

	Width : [Known(U8), Flex, Truth]

	## The largest number of the given width.
	mask : U8 -> U64
	mask = |width| if width >= 64 {
		U64.highest
	} else {
		U64.shl_wrap(1, width) - 1
	}

	good_width : U8 -> Try({}, Fault)
	good_width = |width| if width >= 1 and width <= 64 {
		Ok({})
	} else {
		Err(BadWidth(width))
	}

	# -- Sharing -------------------------------------------------------------

	## Stir one more number into a fingerprint.
	mix : U64, U64 -> U64
	mix = |seed, value| {
		a = seed.bitwise_xor(value).times_wrap(0x9E3779B97F4A7C15)
		b = a.bitwise_xor(a.shr_wrap(29)).times_wrap(0xBF58476D1CE4E5B9)
		b.bitwise_xor(b.shr_wrap(32))
	}

	## A 64-bit summary of a term's structure, for telling shared terms apart.
	## Equal terms have equal fingerprints. A `Shared` term carries its own, so
	## this never walks into one: marking each step of a long computation as
	## shared keeps the walk short.
	fingerprint : Term -> U64
	fingerprint = |term| match term {
		Lit(value) => mix(1, value)
		Const(value, width) => mix(mix(2, value), width.to_u64())
		Var(id, width) => mix(mix(3, id), width.to_u64())
		Flag(id) => mix(4, id)
		Truth(value) => mix(
			5,
			if value {
				1
			} else {
				0
			},
		)
		Arith(op, a, b) => {
			code = match op {
				Plus => 0
				Minus => 1
				Times => 2
				Div => 3
				Rem => 4
				PlusWrap => 5
				MinusWrap => 6
				TimesWrap => 7
				BitAnd => 8
				BitOr => 9
				BitXor => 10
			}
			mix(mix(mix(6, code), fingerprint(a)), fingerprint(b))
		}
		BitNot(a) => mix(7, fingerprint(a))
		Shift(direction, a, count) => {
			code = match direction {
				Left => 0
				Right => 1
			}
			mix(mix(mix(8, code), fingerprint(a)), count.to_u64())
		}
		Resize(mode, a, to) => {
			code = match mode {
				Checked => 0
				Wrap => 1
			}
			mix(mix(mix(9, code), fingerprint(a)), to.to_u64())
		}
		Overflows(op, a, b) => mix(mix(mix(10, three(op)), fingerprint(a)), fingerprint(b))
		Compare(op, a, b) => {
			code = match op {
				Eq => 0
				Lt => 1
				Lte => 2
			}
			mix(mix(mix(11, code), fingerprint(a)), fingerprint(b))
		}
		Signed(op, a, b) => mix(mix(mix(12, three(op)), fingerprint(a)), fingerprint(b))
		SignedOverflows(op, a, b) => mix(mix(mix(13, three(op)), fingerprint(a)), fingerprint(b))
		SignedCompare(op, a, b) => {
			code = match op {
				Lt => 0
				Lte => 1
			}
			mix(mix(mix(14, code), fingerprint(a)), fingerprint(b))
		}
		SignedResize(a, to) => mix(mix(15, fingerprint(a)), to.to_u64())
		Not(a) => mix(16, fingerprint(a))
		All(items) => fingerprints(mix(17, items.len()), items)
		Any(items) => fingerprints(mix(18, items.len()), items)
		Implies(a, b) => mix(mix(19, fingerprint(a)), fingerprint(b))
		Same(a, b) => mix(mix(20, fingerprint(a)), fingerprint(b))
		Choose(c, a, b) => mix(mix(mix(21, fingerprint(c)), fingerprint(a)), fingerprint(b))
		Shared(key, _) => key
		Given(defs, body) => mix(fingerprints(mix(22, defs.len()), defs), fingerprint(body))
		Ref(index) => mix(23, index)
	}

	three : [Plus, Minus, Times] -> U64
	three = |op| match op {
		Plus => 0
		Minus => 1
		Times => 2
	}

	fingerprints : U64, List(Term) -> U64
	fingerprints = |seed, items| {
		var $out = seed
		for item in items {
			$out = mix($out, fingerprint(item))
		}
		$out
	}

	## Mark a term to be worked out once. See `Shared`.
	shared : Term -> Term
	shared = |term| match term {
		Shared(_, _) => term
		_ => Shared(fingerprint(term), term)
	}

	## The shared terms met so far, by fingerprint, and their definitions in
	## the order they must be worked out.
	Lifting : { seen : Dict(U64, U64), defs : List(Term) }

	## Replace every `Shared` term by a `Ref` to one definition of it. A shared
	## term seen before is not walked again, which is what keeps a term that
	## reuses its parts from costing as much as the same term written out.
	##
	## A shared term made only of literals has no width of its own, so it is
	## left in place: it is settled where it is used, like any literal.
	lift : Term, Lifting -> (Term, Lifting)
	lift = |term, state| match term {
		Lit(_) => (term, state)
		Const(_, _) => (term, state)
		Var(_, _) => (term, state)
		Flag(_) => (term, state)
		Truth(_) => (term, state)
		Arith(op, a, b) => {
			(a1, b1, after) = lift2(a, b, state)
			(Arith(op, a1, b1), after)
		}
		BitNot(a) => {
			(a1, after) = lift(a, state)
			(BitNot(a1), after)
		}
		Shift(direction, a, count) => {
			(a1, after) = lift(a, state)
			(Shift(direction, a1, count), after)
		}
		Resize(mode, a, to) => {
			(a1, after) = lift(a, state)
			(Resize(mode, a1, to), after)
		}
		Overflows(op, a, b) => {
			(a1, b1, after) = lift2(a, b, state)
			(Overflows(op, a1, b1), after)
		}
		Compare(op, a, b) => {
			(a1, b1, after) = lift2(a, b, state)
			(Compare(op, a1, b1), after)
		}
		Signed(op, a, b) => {
			(a1, b1, after) = lift2(a, b, state)
			(Signed(op, a1, b1), after)
		}
		SignedOverflows(op, a, b) => {
			(a1, b1, after) = lift2(a, b, state)
			(SignedOverflows(op, a1, b1), after)
		}
		SignedCompare(op, a, b) => {
			(a1, b1, after) = lift2(a, b, state)
			(SignedCompare(op, a1, b1), after)
		}
		SignedResize(a, to) => {
			(a1, after) = lift(a, state)
			(SignedResize(a1, to), after)
		}
		Not(a) => {
			(a1, after) = lift(a, state)
			(Not(a1), after)
		}
		All(items) => {
			(out, after) = lift_all(items, state)
			(All(out), after)
		}
		Any(items) => {
			(out, after) = lift_all(items, state)
			(Any(out), after)
		}
		Implies(a, b) => {
			(a1, b1, after) = lift2(a, b, state)
			(Implies(a1, b1), after)
		}
		Same(a, b) => {
			(a1, b1, after) = lift2(a, b, state)
			(Same(a1, b1), after)
		}
		Choose(c, a, b) => {
			(c1, state1) = lift(c, state)
			(a1, b1, after) = lift2(a, b, state1)
			(Choose(c1, a1, b1), after)
		}
		Shared(key, inner) => match state.seen.get(key) {
			Ok(index) => (Ref(index), state)
			Err(_) => {
				(inner1, after) = lift(inner, state)
				if literal_only(inner1) {
					(inner1, after)
				} else {
					index = after.defs.len()
					(Ref(index), { seen: after.seen.insert(key, index), defs: after.defs.append(inner1) })
				}
			}
		}
		# Already elaborated: its `Ref`s count from its own definitions.
		Given(_, _) => (term, state)
		Ref(_) => (term, state)
	}

	lift2 : Term, Term, Lifting -> (Term, Term, Lifting)
	lift2 = |a, b, state| {
		(a1, state1) = lift(a, state)
		(b1, state2) = lift(b, state1)
		(a1, b1, state2)
	}

	lift_all : List(Term), Lifting -> (List(Term), Lifting)
	lift_all = |items, state| {
		var $state = state
		var $out = List.with_capacity(items.len())
		for item in items {
			(item1, next) = lift(item, $state)
			$state = next
			$out = $out.append(item1)
		}
		($out, $state)
	}

	## Is this a number that has no width until it meets one? Exactly the
	## terms `infer` calls `Flex`.
	literal_only : Term -> Bool
	literal_only = |term| match term {
		Lit(_) => Bool.True
		Arith(_, a, b) => literal_only(a) and literal_only(b)
		BitNot(a) => literal_only(a)
		Shift(_, a, _) => literal_only(a)
		Signed(_, a, b) => literal_only(a) and literal_only(b)
		Choose(_, a, b) => literal_only(a) and literal_only(b)
		_ => Bool.False
	}

	# -- Elaboration ---------------------------------------------------------

	## Check a term and give every literal a width. The result has no `Lit`
	## and no `Shared` left in it; `eval` and `Blast` only accept elaborated
	## terms.
	##
	## A literal takes the width of the number it meets (`x + 1`), and must fit.
	## An expression made only of literals is 64 bits wide. Shared terms become
	## the definitions of one `Given` around the whole term; a term without
	## any comes back without one.
	elaborate : Term -> Try(Term, Fault)
	elaborate = |term| {
		(lifted, state) = lift(term, { seen: Dict.empty(), defs: [] })
		if state.defs.is_empty() {
			(out, width) = infer(lifted, [])?
			match width {
				Flex => settle(out, 64)
				_ => Ok(out)
			}
		} else {
			(defs, widths) = infer_defs(state.defs)?
			body = settled_in(lifted, widths)?
			Ok(Given(defs, body))
		}
	}

	## Elaborate definitions in order. Each sees the widths of those before it.
	infer_defs : List(Term) -> Try((List(Term), List(Width)), Fault)
	infer_defs = |defs| {
		var $out = List.with_capacity(defs.len())
		var $widths = List.with_capacity(defs.len())
		for def in defs {
			(out, width) = infer(def, $widths)?
			match width {
				Flex => {
					fixed = settle(out, 64)?
					$out = $out.append(fixed)
					$widths = $widths.append(Known(64))
				}
				_ => {
					$out = $out.append(out)
					$widths = $widths.append(width)
				}
			}
		}
		Ok(($out, $widths))
	}

	## Either sort, with its literals settled at 64 bits if nothing said otherwise.
	settled_in : Term, List(Width) -> Try(Term, Fault)
	settled_in = |term, given| {
		(out, width) = infer(term, given)?
		match width {
			Flex => settle(out, 64)
			_ => Ok(out)
		}
	}

	## `given` holds the width of each definition a `Ref` here may name.
	infer : Term, List(Width) -> Try((Term, Width), Fault)
	infer = |term, given| match term {
		Lit(_) => Ok((term, Flex))
		Const(value, width) => {
			good_width(width)?
			if value > mask(width) {
				Err(LiteralTooLarge({ literal: value, width }))
			} else {
				Ok((term, Known(width)))
			}
		}
		Var(_, width) => {
			good_width(width)?
			Ok((term, Known(width)))
		}
		Flag(_) => Ok((term, Truth))
		Truth(_) => Ok((term, Truth))
		Arith(op, a, b) => {
			(a1, b1, width) = pair(a, b, given)?
			Ok((Arith(op, a1, b1), width))
		}
		BitNot(a) => {
			(a1, width) = number(a, given)?
			Ok((BitNot(a1), width))
		}
		Shift(direction, a, count) => {
			(a1, width) = number(a, given)?
			Ok((Shift(direction, a1, count), width))
		}
		Resize(mode, a, to) => {
			good_width(to)?
			a1 = settled(a, given)?
			Ok((Resize(mode, a1, to), Known(to)))
		}
		Overflows(op, a, b) => {
			(a1, b1) = settled_pair(a, b, given)?
			Ok((Overflows(op, a1, b1), Truth))
		}
		Compare(op, a, b) => {
			(a1, b1) = settled_pair(a, b, given)?
			Ok((Compare(op, a1, b1), Truth))
		}
		Signed(op, a, b) => {
			(a1, b1, width) = pair(a, b, given)?
			Ok((Signed(op, a1, b1), width))
		}
		SignedOverflows(op, a, b) => {
			(a1, b1) = settled_pair(a, b, given)?
			Ok((SignedOverflows(op, a1, b1), Truth))
		}
		SignedCompare(op, a, b) => {
			(a1, b1) = settled_pair(a, b, given)?
			Ok((SignedCompare(op, a1, b1), Truth))
		}
		SignedResize(a, to) => {
			good_width(to)?
			a1 = settled(a, given)?
			Ok((SignedResize(a1, to), Known(to)))
		}
		Not(a) => {
			a1 = truth(a, given)?
			Ok((Not(a1), Truth))
		}
		All(items) => {
			out = truths(items, given)?
			Ok((All(out), Truth))
		}
		Any(items) => {
			out = truths(items, given)?
			Ok((Any(out), Truth))
		}
		Implies(a, b) => {
			a1 = truth(a, given)?
			b1 = truth(b, given)?
			Ok((Implies(a1, b1), Truth))
		}
		Same(a, b) => {
			a1 = truth(a, given)?
			b1 = truth(b, given)?
			Ok((Same(a1, b1), Truth))
		}
		Choose(c, a, b) => {
			c1 = truth(c, given)?
			(a0, wa) = infer(a, given)?
			(b0, wb) = infer(b, given)?
			match (wa, wb) {
				(Truth, Truth) => Ok((Choose(c1, a0, b0), Truth))
				(Truth, _) => Err(Malformed)
				(_, Truth) => Err(Malformed)
				_ => {
					(a1, b1, width) = unify(a0, wa, b0, wb)?
					Ok((Choose(c1, a1, b1), width))
				}
			}
		}
		# Only met inside a `Given` written by hand: `lift` removed the rest.
		Shared(_, inner) => infer(inner, given)
		Given(defs, body) => {
			(defs1, widths) = infer_defs(defs)?
			(body0, width) = infer(body, widths)?
			match width {
				Flex => {
					body1 = settle(body0, 64)?
					Ok((Given(defs1, body1), Known(64)))
				}
				_ => Ok((Given(defs1, body0), width))
			}
		}
		Ref(index) => match given.get(index) {
			Ok(width) => Ok((term, width))
			Err(_) => Err(Malformed)
		}
	}

	truth : Term, List(Width) -> Try(Term, Fault)
	truth = |term, given| {
		(out, width) = infer(term, given)?
		match width {
			Truth => Ok(out)
			_ => Err(Malformed)
		}
	}

	truths : List(Term), List(Width) -> Try(List(Term), Fault)
	truths = |items, given| {
		var $out = List.with_capacity(items.len())
		for item in items {
			checked = truth(item, given)?
			$out = $out.append(checked)
		}
		Ok($out)
	}

	number : Term, List(Width) -> Try((Term, Width), Fault)
	number = |term, given| {
		(out, width) = infer(term, given)?
		match width {
			Truth => Err(Malformed)
			_ => Ok((out, width))
		}
	}

	## A number whose literals all have widths, 64 bits if nothing said otherwise.
	settled : Term, List(Width) -> Try(Term, Fault)
	settled = |term, given| {
		(out, width) = number(term, given)?
		match width {
			Flex => settle(out, 64)
			_ => Ok(out)
		}
	}

	pair : Term, Term, List(Width) -> Try((Term, Term, Width), Fault)
	pair = |a, b, given| {
		(a0, wa) = number(a, given)?
		(b0, wb) = number(b, given)?
		unify(a0, wa, b0, wb)
	}

	settled_pair : Term, Term, List(Width) -> Try((Term, Term), Fault)
	settled_pair = |a, b, given| {
		(a1, b1, width) = pair(a, b, given)?
		match width {
			Flex => {
				a2 = settle(a1, 64)?
				b2 = settle(b1, 64)?
				Ok((a2, b2))
			}
			_ => Ok((a1, b1))
		}
	}

	unify : Term, Width, Term, Width -> Try((Term, Term, Width), Fault)
	unify = |a, wa, b, wb| match (wa, wb) {
		(Known(x), Known(y)) => if x == y {
			Ok((a, b, Known(x)))
		} else {
			Err(WidthMismatch({ left: x, right: y }))
		}
		(Known(x), Flex) => {
			b1 = settle(b, x)?
			Ok((a, b1, Known(x)))
		}
		(Flex, Known(y)) => {
			a1 = settle(a, y)?
			Ok((a1, b, Known(y)))
		}
		(Flex, Flex) => Ok((a, b, Flex))
		_ => Err(Malformed)
	}

	## Give a width to every literal of a number that had none. Only called on
	## subterms `infer` reported as `Flex`, whose number parts are all `Flex`.
	settle : Term, U8 -> Try(Term, Fault)
	settle = |term, width| match term {
		Lit(value) => if value > mask(width) {
			Err(LiteralTooLarge({ literal: value, width }))
		} else {
			Ok(Const(value, width))
		}
		Arith(op, a, b) => {
			a1 = settle(a, width)?
			b1 = settle(b, width)?
			Ok(Arith(op, a1, b1))
		}
		Signed(op, a, b) => {
			a1 = settle(a, width)?
			b1 = settle(b, width)?
			Ok(Signed(op, a1, b1))
		}
		BitNot(a) => {
			a1 = settle(a, width)?
			Ok(BitNot(a1))
		}
		Shift(direction, a, count) => {
			a1 = settle(a, width)?
			Ok(Shift(direction, a1, count))
		}
		Choose(c, a, b) => {
			a1 = settle(a, width)?
			b1 = settle(b, width)?
			Ok(Choose(c, a1, b1))
		}
		_ => Ok(term)
	}

	# -- Signed numbers ------------------------------------------------------

	## The bit that says a number of this width is negative.
	sign_bit : U8 -> U64
	sign_bit = |width| U64.shl_wrap(1, width - 1)

	is_negative : U64, U8 -> Bool
	is_negative = |value, width| value.bitwise_and(sign_bit(width)) != 0

	## How far a signed number is from zero.
	magnitude : U64, U8 -> U64
	magnitude = |value, width| if is_negative(value, width) {
		U64.minus_wrap(0, value).bitwise_and(mask(width))
	} else {
		value
	}

	## Does the signed operation leave the range of the width?
	signed_overflows : [Plus, Minus, Times], U64, U64, U8 -> Bool
	signed_overflows = |op, x, y, width| {
		top = mask(width)
		sign = sign_bit(width)
		match op {
			# Same signs in, a different sign out.
			Plus => {
				sum = x.plus_wrap(y).bitwise_and(top)
				x.bitwise_xor(sum).bitwise_and(y.bitwise_xor(sum)).bitwise_and(sign) != 0
			}
			# Different signs in, and the result's differs from the first.
			Minus => {
				difference = x.minus_wrap(y).bitwise_and(top)
				x.bitwise_xor(y).bitwise_and(x.bitwise_xor(difference)).bitwise_and(sign) != 0
			}
			# The product of the magnitudes must not pass the largest number of
			# its sign: 2^(width-1) below zero, one less above.
			Times => {
				a = magnitude(x, width)
				b = magnitude(y, width)
				negative = is_negative(x, width) != is_negative(y, width)
				limit = if negative {
					sign
				} else {
					sign - 1
				}
				a.times_overflows(b) or a.times_wrap(b) > limit
			}
		}
	}

	## The low bits of the signed operation.
	signed_wrapped : [Plus, Minus, Times], U64, U64, U8 -> U64
	signed_wrapped = |op, x, y, width| match op {
		Plus => x.plus_wrap(y).bitwise_and(mask(width))
		Minus => x.minus_wrap(y).bitwise_and(mask(width))
		Times => x.times_wrap(y).bitwise_and(mask(width))
	}

	## A signed number of width `from` at width `to`, or nothing if it does
	## not fit.
	signed_resized : U64, U8, U8 -> Try(U64, [Overflow])
	signed_resized = |value, from, to| {
		if to >= from {
			if is_negative(value, from) {
				Ok(value.bitwise_or(mask(to).bitwise_xor(mask(from))))
			} else {
				Ok(value)
			}
		} else {
			kept = value.bitwise_and(mask(to))
			back = if is_negative(kept, to) {
				kept.bitwise_or(mask(from).bitwise_xor(mask(to)))
			} else {
				kept
			}
			if back == value {
				Ok(kept)
			} else {
				Err(Overflow)
			}
		}
	}

	# -- Evaluation ----------------------------------------------------------

	## Run an elaborated term on ordinary values: `env` holds one value per
	## declared unknown, in declaration order (0 or 1 for a truth value).
	eval : Term, List(U64) -> Try(Value, Fault)
	eval = |term, env| run(term, env, [])

	## `eval` inside a `Given`: `frame` holds what each of its definitions came
	## to. A definition is worked out once, and a crash in it is kept and only
	## raised where a `Ref` to it is evaluated, so sharing a term never changes
	## what a guard protects.
	run : Term, List(U64), List(Try(Value, Fault)) -> Try(Value, Fault)
	run = |term, env, frame| match term {
		Lit(_) => Err(Malformed)
		Const(value, width) => Ok(Word(value, width))
		Var(id, width) => match env.get(id) {
			Ok(value) => Ok(Word(value.bitwise_and(mask(width)), width))
			Err(_) => Err(Unbound(id))
		}
		Flag(id) => match env.get(id) {
			Ok(value) => Ok(Bit(value != 0))
			Err(_) => Err(Unbound(id))
		}
		Truth(value) => Ok(Bit(value))
		Arith(op, a, b) => {
			(x, y, width) = words(a, b, env, frame)?
			top = mask(width)
			match op {
				Plus => if x.plus_overflows(y) or x.plus_wrap(y) > top {
					Err(Overflow)
				} else {
					Ok(Word(x + y, width))
				}
				Minus => if x < y {
					Err(Overflow)
				} else {
					Ok(Word(x - y, width))
				}
				Times => if x.times_overflows(y) or x.times_wrap(y) > top {
					Err(Overflow)
				} else {
					Ok(Word(x * y, width))
				}
				Div => if y == 0 {
					Err(DivByZero)
				} else {
					Ok(Word(x // y, width))
				}
				Rem => if y == 0 {
					Err(DivByZero)
				} else {
					Ok(Word(x % y, width))
				}
				PlusWrap => Ok(Word(x.plus_wrap(y).bitwise_and(top), width))
				MinusWrap => Ok(Word(x.minus_wrap(y).bitwise_and(top), width))
				TimesWrap => Ok(Word(x.times_wrap(y).bitwise_and(top), width))
				BitAnd => Ok(Word(x.bitwise_and(y), width))
				BitOr => Ok(Word(x.bitwise_or(y), width))
				BitXor => Ok(Word(x.bitwise_xor(y), width))
			}
		}
		BitNot(a) => {
			(x, width) = word(a, env, frame)?
			Ok(Word(x.bitwise_xor(mask(width)), width))
		}
		Shift(direction, a, count) => {
			(x, width) = word(a, env, frame)?
			by = count % width
			match direction {
				Left => Ok(Word(x.shl_wrap(by).bitwise_and(mask(width)), width))
				Right => Ok(Word(x.shr_wrap(by), width))
			}
		}
		Resize(mode, a, to) => {
			(x, _) = word(a, env, frame)?
			match mode {
				Checked => if x > mask(to) {
					Err(Overflow)
				} else {
					Ok(Word(x, to))
				}
				Wrap => Ok(Word(x.bitwise_and(mask(to)), to))
			}
		}
		Overflows(op, a, b) => {
			(x, y, width) = words(a, b, env, frame)?
			top = mask(width)
			match op {
				Plus => Ok(Bit(x.plus_overflows(y) or x.plus_wrap(y) > top))
				Minus => Ok(Bit(x < y))
				Times => Ok(Bit(x.times_overflows(y) or x.times_wrap(y) > top))
			}
		}
		Compare(op, a, b) => {
			(x, y, _) = words(a, b, env, frame)?
			match op {
				Eq => Ok(Bit(x == y))
				Lt => Ok(Bit(x < y))
				Lte => Ok(Bit(x <= y))
			}
		}
		Signed(op, a, b) => {
			(x, y, width) = words(a, b, env, frame)?
			if signed_overflows(op, x, y, width) {
				Err(Overflow)
			} else {
				Ok(Word(signed_wrapped(op, x, y, width), width))
			}
		}
		SignedOverflows(op, a, b) => {
			(x, y, width) = words(a, b, env, frame)?
			Ok(Bit(signed_overflows(op, x, y, width)))
		}
		SignedCompare(op, a, b) => {
			(x, y, width) = words(a, b, env, frame)?
			# Flipping the sign bit puts the negative numbers below the rest.
			sign = sign_bit(width)
			match op {
				Lt => Ok(Bit(x.bitwise_xor(sign) < y.bitwise_xor(sign)))
				Lte => Ok(Bit(x.bitwise_xor(sign) <= y.bitwise_xor(sign)))
			}
		}
		SignedResize(a, to) => {
			(x, from) = word(a, env, frame)?
			match signed_resized(x, from, to) {
				Ok(value) => Ok(Word(value, to))
				Err(Overflow) => Err(Overflow)
			}
		}
		Not(a) => {
			x = bit(a, env, frame)?
			Ok(Bit(!x))
		}
		All(items) => {
			var $answer = Bool.True
			for item in items {
				if $answer {
					$answer = bit(item, env, frame)?
				}
			}
			Ok(Bit($answer))
		}
		Any(items) => {
			var $answer = Bool.False
			for item in items {
				if !$answer {
					$answer = bit(item, env, frame)?
				}
			}
			Ok(Bit($answer))
		}
		Implies(a, b) => {
			x = bit(a, env, frame)?
			if x {
				y = bit(b, env, frame)?
				Ok(Bit(y))
			} else {
				Ok(Bit(Bool.True))
			}
		}
		Same(a, b) => {
			x = bit(a, env, frame)?
			y = bit(b, env, frame)?
			Ok(Bit(x == y))
		}
		Choose(c, a, b) => {
			x = bit(c, env, frame)?
			if x {
				run(a, env, frame)
			} else {
				run(b, env, frame)
			}
		}
		Shared(_, inner) => run(inner, env, frame)
		Given(defs, body) => {
			var $frame = List.with_capacity(defs.len())
			for def in defs {
				$frame = $frame.append(run(def, env, $frame))
			}
			run(body, env, $frame)
		}
		Ref(index) => match frame.get(index) {
			Ok(result) => result
			Err(_) => Err(Malformed)
		}
	}

	word : Term, List(U64), List(Try(Value, Fault)) -> Try((U64, U8), Fault)
	word = |term, env, frame| match run(term, env, frame)? {
		Word(value, width) => Ok((value, width))
		Bit(_) => Err(Malformed)
	}

	words : Term, Term, List(U64), List(Try(Value, Fault)) -> Try((U64, U64, U8), Fault)
	words = |a, b, env, frame| {
		(x, wx) = word(a, env, frame)?
		(y, wy) = word(b, env, frame)?
		if wx == wy {
			Ok((x, y, wx))
		} else {
			Err(WidthMismatch({ left: wx, right: wy }))
		}
	}

	bit : Term, List(U64), List(Try(Value, Fault)) -> Try(Bool, Fault)
	bit = |term, env, frame| match run(term, env, frame)? {
		Bit(value) => Ok(value)
		Word(_, _) => Err(Malformed)
	}

	## Does the claim hold on these values? `Err(Overflow)` and `Err(DivByZero)`
	## mean the equivalent Roc expression would have crashed.
	holds : Term, List(U64) -> Try(Bool, Fault)
	holds = |term, env| bit(term, env, [])
}

# A literal takes the width of the number it meets.
expect Term.elaborate(Arith(Plus, Var(0, 8), Lit(1))) == Ok(Arith(Plus, Var(0, 8), Const(1, 8)))
expect Term.elaborate(Compare(Lt, Arith(Plus, Lit(1), Lit(2)), Var(0, 16))) == Ok(Compare(Lt, Arith(Plus, Const(1, 16), Const(2, 16)), Var(0, 16)))
expect Term.elaborate(Compare(Lt, Lit(1), Lit(2))) == Ok(Compare(Lt, Const(1, 64), Const(2, 64)))
expect Term.elaborate(Choose(Flag(0), Lit(3), Var(1, 4))) == Ok(Choose(Flag(0), Const(3, 4), Var(1, 4)))

# Ill-formed terms are reported, not guessed at.
expect Term.elaborate(Arith(Plus, Var(0, 8), Lit(256))) == Err(LiteralTooLarge({ literal: 256, width: 8 }))
expect Term.elaborate(Arith(Plus, Var(0, 8), Var(1, 16))) == Err(WidthMismatch({ left: 8, right: 16 }))
expect Term.elaborate(Var(0, 65)) == Err(BadWidth(65))
expect Term.elaborate(Not(Var(0, 8))) == Err(Malformed)

# Checked arithmetic crashes where Roc does; the `Wrap` forms do not.
expect Term.eval(Arith(Plus, Const(250, 8), Const(10, 8)), []) == Err(Overflow)
expect Term.eval(Arith(PlusWrap, Const(250, 8), Const(10, 8)), []) == Ok(Word(4, 8))
expect Term.eval(Arith(Minus, Const(3, 8), Const(4, 8)), []) == Err(Overflow)
expect Term.eval(Arith(MinusWrap, Const(3, 8), Const(4, 8)), []) == Ok(Word(255, 8))
expect Term.eval(Arith(Times, Const(16, 8), Const(16, 8)), []) == Err(Overflow)
expect Term.eval(Arith(TimesWrap, Const(17, 8), Const(16, 8)), []) == Ok(Word(16, 8))
expect Term.eval(Arith(Div, Const(7, 8), Const(0, 8)), []) == Err(DivByZero)
expect Term.eval(Arith(Plus, Const(U64.highest, 64), Const(1, 64)), []) == Err(Overflow)
expect Term.eval(Arith(Times, Const(U64.highest, 64), Const(2, 64)), []) == Err(Overflow)

# Guards stop evaluation, as `and`, `or` and `if` do.
expect Term.holds(Implies(Truth(Bool.False), Compare(Eq, Arith(Div, Const(1, 8), Const(0, 8)), Const(0, 8))), []) == Ok(Bool.True)
expect Term.holds(All([Truth(Bool.False), Compare(Eq, Arith(Minus, Const(0, 8), Const(1, 8)), Const(0, 8))]), []) == Ok(Bool.False)
expect Term.holds(All([Compare(Eq, Arith(Minus, Const(0, 8), Const(1, 8)), Const(0, 8)), Truth(Bool.False)]), []) == Err(Overflow)
expect Term.holds(Any([Truth(Bool.True), Compare(Eq, Arith(Minus, Const(0, 8), Const(1, 8)), Const(0, 8))]), []) == Ok(Bool.True)
expect Term.eval(Choose(Truth(Bool.True), Const(1, 8), Arith(Div, Const(1, 8), Const(0, 8))), []) == Ok(Word(1, 8))
