## Self-validation. A bit-blaster is where soundness bugs live, so nothing in
## `Circuit` or `Blast` is trusted on inspection: the solver's answers are
## compared with brute force through the plain evaluator.
##
## For a claim over a few narrow unknowns there are few enough assignments to
## try them all. `census` does that with `Term.holds` and counts the ones where
## the claim is true, false, or crashes. `compare` then asks the solver to list
## every assignment where the claim holds, every one where its negation holds,
## and every one where it fails. Each listed assignment is re-run through the
## evaluator (inside `Engine`), the lists have no repeats, and their lengths
## must equal the three counts. Together that means the circuit and the
## evaluator split the assignments identically.
##
## The claims come from two places: one per operator, with both operands free
## at 4 bits and the result compared with a third unknown, and a seeded random
## generator that nests every construct of the term language. `varied` turns
## each random claim into one that also uses the signed forms and shared
## terms.
##
## The evaluator itself is the reference, so `native` checks it against Roc's
## own `U8`, `U64`, `I8` and `I64` arithmetic.
##
## The other promises are checked the same way, against all assignments:
##
## - Steering (`steering_agrees`): the values a steered query returns are the
##   best there are in the order `Solve.find_near` documents, found here by
##   trying every assignment. The same for a prepared claim with extra claims
##   assumed.
## - Budgets (`budget_agrees`, `listing_agrees`): under any budget an answer
##   is the answer without one, and giving up reports the budget as spent.
## - Sharing (`sharing_agrees`): a term with shared parts gives the same
##   result as the same term with the marks removed, on every assignment.
## - Loading (`loads_alike`): one call with every clause builds the solver
##   that one call per clause builds.
import sat.Rocsat
import solver.Term
import solver.Engine

Validate := [].{
	Counts : { holding : U64, refuted : U64, crashing : U64 }

	# -- Brute force ---------------------------------------------------------

	## The lowest assignment of the declared ranges.
	lowest : List(Engine.Decl) -> List(U64)
	lowest = |decls| decls.map(|decl| decl.lo)

	## The assignment after this one, counting like an odometer.
	advance : List(Engine.Decl), List(U64) -> Try(List(U64), [Done])
	advance = |decls, values| {
		var $out = values
		var $i = 0
		var $carry = Bool.True
		while $carry and $i < decls.len() {
			top = match decls.get($i) {
				Ok(decl) => decl
				Err(_) => { sort: Flag, lo: 0, hi: 0 }
			}
			current = $out.get($i) ?? 0
			if current < top.hi {
				$out = $out.set($i, current + 1) ?? $out
				$carry = Bool.False
			} else {
				$out = $out.set($i, top.lo) ?? $out
				$i = $i + 1
			}
		}
		if $carry {
			Err(Done)
		} else {
			Ok($out)
		}
	}

	## Where an assignment falls in odometer order.
	position : List(Engine.Decl), List(U64) -> U64
	position = |decls, values| {
		var $at = 0
		var $scale = 1
		var $i = 0
		for decl in decls {
			$at = $at + ((values.get($i) ?? decl.lo) - decl.lo) * $scale
			$scale = $scale * (decl.hi - decl.lo + 1)
			$i = $i + 1
		}
		$at
	}

	## Run an elaborated claim on every assignment.
	census : List(Engine.Decl), Term -> Try(Counts, Term.Fault)
	census = |decls, term| {
		var $values = lowest(decls)
		var $holding = 0
		var $refuted = 0
		var $crashing = 0
		var $more = Bool.True
		while $more {
			match Term.holds(term, $values) {
				Ok(held) => {
					if held {
						$holding = $holding + 1
					} else {
						$refuted = $refuted + 1
					}
				}
				Err(Overflow) => {
					$crashing = $crashing + 1
				}
				Err(DivByZero) => {
					$crashing = $crashing + 1
				}
				Err(other) => {
					return Err(other)
				}
			}
			match advance(decls, $values) {
				Ok(next) => {
					$values = next
				}
				Err(Done) => {
					$more = Bool.False
				}
			}
		}
		Ok({ holding: $holding, refuted: $refuted, crashing: $crashing })
	}

	## Are the assignments all different?
	distinct : List(Engine.Decl), List(List(U64)), U64 -> Bool
	distinct = |decls, found, total| {
		var $seen = List.repeat(Bool.False, total)
		var $ok = Bool.True
		for values in found {
			at = position(decls, values)
			if $seen.get(at) ?? Bool.True {
				$ok = Bool.False
			}
			$seen = $seen.set(at, Bool.True) ?? $seen
		}
		$ok
	}

	# -- Solver against brute force -------------------------------------------

	Report : [Agree(Counts), Differ({ brute : Counts, solver : Counts, failing : U64, repeats : Bool, single : Bool })]

	## Compare the solver with brute force on one claim. `Thorough` lists the
	## assignments for all three questions; `HoldingOnly` lists only those
	## where the claim holds, for claims that mostly fail.
	compare : List(Engine.Decl), Term, [Thorough, HoldingOnly] -> Try(Report, Term.Fault)
	compare = |decls, raw, depth| {
		compiled = Engine.compile(decls, raw)?
		against(compiled, compiled.term, depth)
	}

	## Compare the circuit in `compiled` with brute force over `reference`.
	## They are the same term except in the test that shows a wrong circuit is
	## caught.
	against : Engine.Compiled, Term, [Thorough, HoldingOnly] -> Try(Report, Term.Fault)
	against = |compiled, reference, depth| {
		decls = compiled.decls
		brute = census(decls, reference)?
		total = brute.holding + brute.refuted + brute.crashing
		judged = { ..compiled, term: reference }
		holding = Engine.many(judged, Holding, total + 1)?
		first_holding = Engine.one(judged, Holding, [])?
		first_failing = Engine.one(judged, Failing, [])?
		single = (first_holding == Nothing) == (brute.holding == 0) and (first_failing == Nothing) == (brute.refuted + brute.crashing == 0)
		match depth {
			HoldingOnly => {
				repeats = !distinct(decls, holding, total)
				if holding.len() == brute.holding and !repeats and single {
					Ok(Agree(brute))
				} else {
					Ok(Differ({ brute, solver: { holding: holding.len(), refuted: 0, crashing: 0 }, failing: 0, repeats, single }))
				}
			}
			Thorough => {
				failing = Engine.many(judged, Failing, total + 1)?
				# The negation holds exactly where the claim is false: a crash
				# is still a crash.
				negated = Engine.compile(decls, Not(reference))?
				refuted = Engine.many(negated, Holding, total + 1)?
				repeats = !(distinct(decls, holding, total) and distinct(decls, failing, total) and distinct(decls, refuted, total))
				solver = { holding: holding.len(), refuted: refuted.len(), crashing: failing.len() - U64.min(failing.len(), refuted.len()) }
				if solver == brute and failing.len() == brute.refuted + brute.crashing and !repeats and single {
					Ok(Agree(brute))
				} else {
					Ok(Differ({ brute, solver, failing: failing.len(), repeats, single }))
				}
			}
		}
	}

	agrees : List(Engine.Decl), Term, [Thorough, HoldingOnly] -> Bool
	agrees = |decls, raw, depth| match compare(decls, raw, depth) {
		Ok(Agree(_)) => Bool.True
		_ => Bool.False
	}

	# -- One claim per operator ----------------------------------------------

	## Three unknowns of the same width: two operands and a result.
	triple : U8 -> List(Engine.Decl)
	triple = |width| List.repeat({ sort: Number(width), lo: 0, hi: Term.mask(width) }, 3)

	## `x op y == z` for every `x`, `y` and `z`: the solver must list exactly
	## one `z` for each pair on which the operator does not crash.
	arith_agrees : U8 -> Bool
	arith_agrees = |width| {
		x = Var(0, width)
		y = Var(1, width)
		z = Var(2, width)
		ops = [Plus, Minus, Times, Div, Rem, PlusWrap, MinusWrap, TimesWrap, BitAnd, BitOr, BitXor]
		ops.all(|op| agrees(triple(width), Compare(Eq, Arith(op, x, y), z), HoldingOnly))
	}

	## The one-operand forms, and division and remainder by each constant.
	unary_agrees : U8 -> Bool
	unary_agrees = |width| {
		x = Var(0, width)
		z = Var(1, width)
		pair = List.repeat({ sort: Number(width), lo: 0, hi: Term.mask(width) }, 2)
		narrow = width - 1
		wide = width + 3
		var $ok = agrees(pair, Compare(Eq, BitNot(x), z), HoldingOnly)
		var $count = 0
		while $count <= width + 1 {
			$ok = $ok and agrees(pair, Compare(Eq, Shift(Left, x, $count), z), HoldingOnly)
			$ok = $ok and agrees(pair, Compare(Eq, Shift(Right, x, $count), z), HoldingOnly)
			$count = $count + 1
		}
		var $divisor = 0
		while $divisor <= Term.mask(width) {
			$ok = $ok and agrees(pair, Compare(Eq, Arith(Div, x, Const($divisor, width)), z), HoldingOnly)
			$ok = $ok and agrees(pair, Compare(Eq, Arith(Rem, x, Const($divisor, width)), z), HoldingOnly)
			$divisor = $divisor + 1
		}
		$ok = $ok and agrees(pair, Compare(Eq, Resize(Checked, Resize(Checked, x, narrow), width), z), Thorough)
		$ok = $ok and agrees(pair, Compare(Eq, Resize(Checked, Resize(Wrap, x, narrow), width), z), Thorough)
		$ok = $ok and agrees(pair, Compare(Eq, Resize(Checked, Arith(Plus, Resize(Checked, x, wide), Resize(Wrap, z, wide)), width), x), Thorough)
		$ok
	}

	## Comparisons and overflow questions, in both directions.
	compare_agrees : U8 -> Bool
	compare_agrees = |width| {
		x = Var(0, width)
		y = Var(1, width)
		pair = List.repeat({ sort: Number(width), lo: 0, hi: Term.mask(width) }, 2)
		agrees(pair, Compare(Eq, x, y), Thorough)
			and agrees(pair, Compare(Lt, x, y), Thorough)
			and agrees(pair, Compare(Lte, x, y), Thorough)
			and agrees(pair, Overflows(Plus, x, y), Thorough)
			and agrees(pair, Overflows(Minus, x, y), Thorough)
			and agrees(pair, Overflows(Times, x, y), Thorough)
	}

	# -- Random claims -------------------------------------------------------

	## The unknowns random claims are about: two 3-bit numbers (one with a
	## range cut at both ends), a 2-bit number and a truth value. 384
	## assignments in all.
	shape : List(Engine.Decl)
	shape = [
		{ sort: Number(3), lo: 0, hi: 7 },
		{ sort: Number(3), lo: 1, hi: 6 },
		{ sort: Number(2), lo: 0, hi: 3 },
		{ sort: Flag, lo: 0, hi: 1 },
	]

	## xorshift64: the next state of the generator. Never zero from nonzero.
	step : U64 -> U64
	step = |seed| {
		a = seed.bitwise_xor(seed.shl_wrap(13))
		b = a.bitwise_xor(a.shr_wrap(7))
		b.bitwise_xor(b.shl_wrap(17))
	}

	## A number below `bound` from a generator state.
	pick : U64, U64 -> U64
	pick = |seed, bound| seed.shr_wrap(24) % bound

	## A random number term of width 3 or 2.
	number : U64, U64, U8 -> (Term, U64)
	number = |seed0, depth, width| {
		seed = step(seed0)
		choice = pick(
			seed,
			if depth == 0 {
				5
			} else {
				22
			},
		)
		other = if width == 3 {
			2
		} else {
			3
		}
		if choice < 2 {
			(
				if width == 3 {
					Var(choice, 3)
				} else {
					Var(2, 2)
				},
				seed,
			)
		} else if choice == 2 {
			(Const(pick(step(seed), Term.mask(width) + 1), width), step(seed))
		} else if choice == 3 {
			(Lit(pick(step(seed), 4)), step(seed))
		} else if choice == 4 {
			(
				if width == 3 {
					Var(1, 3)
				} else {
					Const(2, 2)
				},
				seed,
			)
		} else if choice < 16 {
			(a, seed1) = number(seed, depth - 1, width)
			(b, seed2) = number(seed1, depth - 1, width)
			op = match choice {
				5 => Plus
				6 => Minus
				7 => Times
				8 => Div
				9 => Rem
				10 => PlusWrap
				11 => MinusWrap
				12 => TimesWrap
				13 => BitAnd
				14 => BitOr
				_ => BitXor
			}
			(Arith(op, a, b), seed2)
		} else if choice == 16 {
			(a, seed1) = number(seed, depth - 1, width)
			(BitNot(a), seed1)
		} else if choice == 17 {
			(a, seed1) = number(seed, depth - 1, width)
			seed2 = step(seed1)
			count = pick(seed2, 5).to_u8_wrap()
			(
				Shift(
					if pick(seed2, 2) == 0 {
						Left
					} else {
						Right
					},
					a,
					count,
				),
				seed2,
			)
		} else if choice < 20 {
			(a, seed1) = number(seed, depth - 1, other)
			(
				Resize(
					if choice == 18 {
						Checked
					} else {
						Wrap
					},
					a,
					width,
				),
				seed1,
			)
		} else {
			(c, seed1) = claim(seed, depth - 1)
			(a, seed2) = number(seed1, depth - 1, width)
			(b, seed3) = number(seed2, depth - 1, width)
			(Choose(c, a, b), seed3)
		}
	}

	## A random claim.
	claim : U64, U64 -> (Term, U64)
	claim = |seed0, depth| {
		seed = step(seed0)
		choice = pick(
			seed,
			if depth == 0 {
				5
			} else {
				16
			},
		)
		width = if pick(step(seed), 3) == 0 {
			2
		} else {
			3
		}
		below = if depth == 0 {
			0
		} else {
			depth - 1
		}
		if choice == 0 {
			(Flag(3), seed)
		} else if choice == 1 {
			(Truth(pick(step(seed), 2) == 0), step(seed))
		} else if choice < 7 {
			(a, seed1) = number(seed, below, width)
			(b, seed2) = number(seed1, below, width)
			op = match choice % 3 {
				0 => Eq
				1 => Lt
				_ => Lte
			}
			(Compare(op, a, b), seed2)
		} else if choice == 7 {
			(a, seed1) = number(seed, below, width)
			(b, seed2) = number(seed1, below, width)
			op = match pick(step(seed2), 3) {
				0 => Plus
				1 => Minus
				_ => Times
			}
			(Overflows(op, a, b), seed2)
		} else if choice == 8 {
			(a, seed1) = claim(seed, below)
			(Not(a), seed1)
		} else if choice < 11 {
			(a, seed1) = claim(seed, below)
			(b, seed2) = claim(seed1, below)
			(c, seed3) = claim(seed2, below)
			(
				if choice == 9 {
					All([a, b, c])
				} else {
					Any([a, b, c])
				},
				seed3,
			)
		} else if choice < 14 {
			(a, seed1) = claim(seed, below)
			(b, seed2) = claim(seed1, below)
			(
				if choice == 13 {
					Same(a, b)
				} else {
					Implies(a, b)
				},
				seed2,
			)
		} else if choice == 14 {
			(a, seed1) = claim(seed, below)
			(b, seed2) = claim(seed1, below)
			(
				if pick(step(seed2), 2) == 0 {
					All([a, b])
				} else {
					Any([a, b])
				},
				seed2,
			)
		} else {
			(c, seed1) = claim(seed, below)
			(a, seed2) = claim(seed1, below)
			(b, seed3) = claim(seed2, below)
			(Choose(c, a, b), seed3)
		}
	}

	## The random claim with this number.
	sample : U64 -> Term
	sample = |index| {
		(term, _) = claim((index + 1).times_wrap(0x9E3779B97F4A7C15), 3)
		term
	}

	Sweep : {
		## Claims on which the solver and brute force agreed.
		agreed : U64,

		## Numbers of the claims on which they did not. Must be empty.
		differed : List(U64),

		## Of those that agreed: claims true on some assignments and not on
		## others, and claims that crash on some assignment.
		mixed : U64,
		crashing : U64,

		## Assignments the solver had to list across all claims.
		listed : U64,
	}

	## Compare the solver with brute force on `count` random claims.
	sweep : U64, U64 -> Sweep
	sweep = |start, count| {
		var $agreed = 0
		var $differed = []
		var $mixed = 0
		var $crashing = 0
		var $listed = 0
		var $index = start
		while $index < start + count {
			match compare(shape, sample($index), Thorough) {
				Ok(Agree(counts)) => {
					$agreed = $agreed + 1
					$listed = $listed + 2 * (counts.holding + counts.refuted + counts.crashing) - counts.crashing
					if counts.holding > 0 and counts.refuted + counts.crashing > 0 {
						$mixed = $mixed + 1
					}
					if counts.crashing > 0 {
						$crashing = $crashing + 1
					}
				}
				_ => {
					$differed = $differed.append($index)
				}
			}
			$index = $index + 1
		}
		{ agreed: $agreed, differed: $differed, mixed: $mixed, crashing: $crashing, listed: $listed }
	}

	# -- The signed forms and shared terms -----------------------------------

	## The signed forms, with both operands free. `x op y == z` must list
	## exactly one `z` for each pair on which the operator does not crash, and
	## the questions split every assignment as the evaluator does.
	signed_agrees : U8 -> Bool
	signed_agrees = |width| {
		x = Var(0, width)
		y = Var(1, width)
		z = Var(2, width)
		pair = List.repeat({ sort: Number(width), lo: 0, hi: Term.mask(width) }, 2)
		narrow = if width > 1 {
			width - 1
		} else {
			1
		}
		wide = width + 3
		[Plus, Minus, Times].all(|op| agrees(triple(width), Compare(Eq, Signed(op, x, y), z), HoldingOnly))
			and [Plus, Minus, Times].all(|op| agrees(pair, SignedOverflows(op, x, y), Thorough))
			and agrees(pair, SignedCompare(Lt, x, y), Thorough)
			and agrees(pair, SignedCompare(Lte, x, y), Thorough)
			and agrees(pair, Compare(Eq, SignedResize(SignedResize(x, wide), width), y), Thorough)
			and agrees(pair, Compare(Eq, SignedResize(SignedResize(x, narrow), width), y), Thorough)
			and agrees(pair, SignedCompare(Lt, SignedResize(x, wide), Resize(Checked, y, wide)), Thorough)
	}

	## The term with some of its parts marked as shared and some of its
	## unsigned operators made signed, chosen by `seed`. The marks land on
	## whole subterms, so a subterm that appears twice is shared twice.
	varied : Term, U64 -> Term
	varied = |term, seed| {
		chosen = |salt, one_in| Term.mix(seed, Term.mix(salt, Term.fingerprint(term))) % one_in == 0
		mark = |made| if chosen(1, 3) {
			Term.shared(made)
		} else {
			made
		}
		match term {
			Arith(op, a, b) => {
				a1 = varied(a, seed)
				b1 = varied(b, seed)
				made = match op {
					Plus => if chosen(2, 2) {
						Signed(Plus, a1, b1)
					} else {
						Arith(op, a1, b1)
					}
					Minus => if chosen(2, 2) {
						Signed(Minus, a1, b1)
					} else {
						Arith(op, a1, b1)
					}
					Times => if chosen(2, 2) {
						Signed(Times, a1, b1)
					} else {
						Arith(op, a1, b1)
					}
					_ => Arith(op, a1, b1)
				}
				mark(made)
			}
			BitNot(a) => mark(BitNot(varied(a, seed)))
			Shift(direction, a, count) => mark(Shift(direction, varied(a, seed), count))
			Resize(mode, a, to) => {
				a1 = varied(a, seed)
				made = match mode {
					Checked => if chosen(2, 2) {
						SignedResize(a1, to)
					} else {
						Resize(mode, a1, to)
					}
					Wrap => Resize(mode, a1, to)
				}
				mark(made)
			}
			Overflows(op, a, b) => {
				a1 = varied(a, seed)
				b1 = varied(b, seed)
				mark(
					if chosen(2, 2) {
						SignedOverflows(op, a1, b1)
					} else {
						Overflows(op, a1, b1)
					},
				)
			}
			Compare(op, a, b) => {
				a1 = varied(a, seed)
				b1 = varied(b, seed)
				made = match op {
					Eq => Compare(op, a1, b1)
					Lt => if chosen(2, 2) {
						SignedCompare(Lt, a1, b1)
					} else {
						Compare(op, a1, b1)
					}
					Lte => if chosen(2, 2) {
						SignedCompare(Lte, a1, b1)
					} else {
						Compare(op, a1, b1)
					}
				}
				mark(made)
			}
			Not(a) => mark(Not(varied(a, seed)))
			All(items) => mark(All(items.map(|item| varied(item, seed))))
			Any(items) => mark(Any(items.map(|item| varied(item, seed))))
			Implies(a, b) => mark(Implies(varied(a, seed), varied(b, seed)))
			Same(a, b) => mark(Same(varied(a, seed), varied(b, seed)))
			Choose(c, a, b) => mark(Choose(varied(c, seed), varied(a, seed), varied(b, seed)))
			Lit(_) => mark(term)
			Var(_, _) => mark(term)
			_ => term
		}
	}

	## The term with every sharing mark removed.
	unmarked : Term -> Term
	unmarked = |term| match term {
		Shared(_, inner) => unmarked(inner)
		Arith(op, a, b) => Arith(op, unmarked(a), unmarked(b))
		BitNot(a) => BitNot(unmarked(a))
		Shift(direction, a, count) => Shift(direction, unmarked(a), count)
		Resize(mode, a, to) => Resize(mode, unmarked(a), to)
		Overflows(op, a, b) => Overflows(op, unmarked(a), unmarked(b))
		Compare(op, a, b) => Compare(op, unmarked(a), unmarked(b))
		Signed(op, a, b) => Signed(op, unmarked(a), unmarked(b))
		SignedOverflows(op, a, b) => SignedOverflows(op, unmarked(a), unmarked(b))
		SignedCompare(op, a, b) => SignedCompare(op, unmarked(a), unmarked(b))
		SignedResize(a, to) => SignedResize(unmarked(a), to)
		Not(a) => Not(unmarked(a))
		All(items) => All(items.map(unmarked))
		Any(items) => Any(items.map(unmarked))
		Implies(a, b) => Implies(unmarked(a), unmarked(b))
		Same(a, b) => Same(unmarked(a), unmarked(b))
		Choose(c, a, b) => Choose(unmarked(c), unmarked(a), unmarked(b))
		_ => term
	}

	## How many definitions elaboration made, and how many of the term's parts
	## are in them and in the body together.
	weigh : Term -> { definitions : U64, parts : U64 }
	weigh = |term| match term {
		Given(defs, body) => { definitions: defs.len(), parts: defs.fold(parts(body), |sum, def| sum + parts(def)) }
		_ => { definitions: 0, parts: parts(term) }
	}

	parts : Term -> U64
	parts = |term| match term {
		Arith(_, a, b) => 1 + parts(a) + parts(b)
		BitNot(a) => 1 + parts(a)
		Shift(_, a, _) => 1 + parts(a)
		Resize(_, a, _) => 1 + parts(a)
		Overflows(_, a, b) => 1 + parts(a) + parts(b)
		Compare(_, a, b) => 1 + parts(a) + parts(b)
		Signed(_, a, b) => 1 + parts(a) + parts(b)
		SignedOverflows(_, a, b) => 1 + parts(a) + parts(b)
		SignedCompare(_, a, b) => 1 + parts(a) + parts(b)
		SignedResize(a, _) => 1 + parts(a)
		Not(a) => 1 + parts(a)
		All(items) => items.fold(1, |sum, item| sum + parts(item))
		Any(items) => items.fold(1, |sum, item| sum + parts(item))
		Implies(a, b) => 1 + parts(a) + parts(b)
		Same(a, b) => 1 + parts(a) + parts(b)
		Choose(c, a, b) => 1 + parts(c) + parts(a) + parts(b)
		Shared(_, inner) => 1 + parts(inner)
		Given(defs, body) => defs.fold(1 + parts(body), |sum, def| sum + parts(def))
		_ => 1
	}

	## Does the claim with its marks give, on every assignment, exactly what
	## the claim without them gives: the same truth or the same crash?
	sharing_agrees : List(Engine.Decl), Term -> Try(Bool, Term.Fault)
	sharing_agrees = |decls, raw| {
		marked = Term.elaborate(raw)?
		plain = Term.elaborate(unmarked(raw))?
		var $values = lowest(decls)
		var $ok = Bool.True
		var $more = Bool.True
		while $more {
			if Term.holds(marked, $values) != Term.holds(plain, $values) {
				$ok = Bool.False
			}
			match advance(decls, $values) {
				Ok(next) => {
					$values = next
				}
				Err(Done) => {
					$more = Bool.False
				}
			}
		}
		Ok($ok)
	}

	## The random claim with this number, with shared parts and signed forms.
	varied_sample : U64 -> Term
	varied_sample = |index| {
		base = sample(index)
		other = sample(index + 5000)
		a = varied(base, index + 1)
		b = Term.shared(varied(other, index + 2))
		# Both halves appear more than once, and `b` also behind a guard.
		Choose(b, Any([a, Not(b)]), Implies(a, b))
	}

	## `sweep` over `varied_sample`, and each claim checked against itself
	## without its sharing marks.
	varied_sweep : U64, U64 -> { agreed : U64, differed : List(U64), unshared : List(U64), definitions : U64 }
	varied_sweep = |start, count| {
		var $agreed = 0
		var $differed = []
		var $unshared = []
		var $definitions = 0
		var $index = start
		while $index < start + count {
			raw = varied_sample($index)
			match compare(shape, raw, Thorough) {
				Ok(Agree(_)) => {
					$agreed = $agreed + 1
				}
				_ => {
					$differed = $differed.append($index)
				}
			}
			if sharing_agrees(shape, raw) != Ok(Bool.True) {
				$unshared = $unshared.append($index)
			}
			$definitions = $definitions + (
				match Term.elaborate(raw) {
					Ok(term) => weigh(term).definitions
					Err(_) => 0
				}
			)
			$index = $index + 1
		}
		{ agreed: $agreed, differed: $differed, unshared: $unshared, definitions: $definitions }
	}

	## A running maximum over `count` unknowns of `width` bits, each step used
	## three times: "no element is `window` or more below an earlier one".
	running : U64, U8, U64, [Marked, WrittenOut] -> Term
	running = |count, width, window, how| {
		var $highest = Const(0, width)
		var $claims = []
		var $index = 0
		while $index < count {
			item = Var($index, width)
			$claims = $claims.append(Compare(Lt, $highest, Arith(PlusWrap, item, Const(window, width))))
			next = Choose(Compare(Lt, $highest, item), item, $highest)
			$highest = match how {
				Marked => Term.shared(next)
				WrittenOut => next
			}
			$index = $index + 1
		}
		All($claims)
	}

	## The same rule on ordinary numbers, as the code that keeps a running
	## maximum would check it.
	running_holds : List(U64), U64, U64 -> Bool
	running_holds = |values, window, top| {
		var $highest = 0
		var $ok = Bool.True
		for value in values {
			if $highest >= (value + window) % (top + 1) {
				$ok = Bool.False
			}
			if value > $highest {
				$highest = value
			}
		}
		$ok
	}

	# -- Steering ------------------------------------------------------------

	## How far each proposed unknown is from its proposal, in the order
	## `Solve.find_near` promises: the bits in which the value differs from
	## the proposal (moved into range), read as a number, so that a higher bit
	## that differs counts for more than all the lower ones together.
	distance : List(Engine.Decl), List(U64), List(U64) -> List(U64)
	distance = |decls, proposed, values| {
		var $out = []
		var $id = 0
		for decl in decls {
			match proposed.get($id) {
				Ok(proposal) => {
					target = U64.max(decl.lo, U64.min(decl.hi, proposal))
					$out = $out.append((values.get($id) ?? 0).bitwise_xor(target))
				}
				Err(_) => {}
			}
			$id = $id + 1
		}
		$out
	}

	## Is the first list smaller, comparing first elements first?
	before : List(U64), List(U64) -> Bool
	before = |a, b| {
		var $verdict = Level
		var $i = 0
		while $i < a.len() and $verdict == Level {
			x = a.get($i) ?? 0
			y = b.get($i) ?? 0
			if x < y {
				$verdict = Less
			} else if x > y {
				$verdict = More
			}
			$i = $i + 1
		}
		$verdict == Less
	}

	## By trying every assignment: the smallest `distance` any assignment has
	## among those on which the claim and every listed extra claim hold.
	nearest : List(Engine.Decl), Term, List(Term), List(U64) -> Try([Best(List(U64)), Empty], Term.Fault)
	nearest = |decls, term, extras, proposed| {
		var $values = lowest(decls)
		var $best = Empty
		var $more = Bool.True
		while $more {
			holding = Term.holds(term, $values) == Ok(Bool.True) and extras.all(|extra| Term.holds(extra, $values) == Ok(Bool.True))
			if holding {
				here = distance(decls, proposed, $values)
				$best = match $best {
					Empty => Best(here)
					Best(old) => if before(here, old) {
						Best(here)
					} else {
						Best(old)
					}
				}
			}
			match advance(decls, $values) {
				Ok(next) => {
					$values = next
				}
				Err(Done) => {
					$more = Bool.False
				}
			}
		}
		Ok($best)
	}

	## Values on which the claim holds, steered towards `proposed`.
	steered : List(Engine.Decl), Term, List(U64) -> Try([Values(List(U64)), Nothing], Term.Fault)
	steered = |decls, raw, proposed| {
		compiled = Engine.compile(decls, raw)?
		Engine.one(compiled, Holding, proposed)
	}

	## Proposals to steer the random claims with: a full set, sets that stop
	## early, and numbers outside every range.
	proposals : U64 -> List(List(U64))
	proposals = |seed| {
		a = step(seed + 77)
		b = step(a)
		c = step(b)
		[
			[pick(a, 8), pick(b, 8), pick(c, 4), pick(a, 2)],
			[pick(c, 8), pick(a, 8), pick(b, 4), pick(c, 2)],
			[0, 0, 0, 0],
			[7, 7, 3, 1],
			[pick(b, 8), pick(c, 8)],
			[pick(a, 300)],
			[900, 0, 900, 900],
			[],
		]
	}

	## Steered answers against brute force on one claim, for each set of
	## proposals: asked once, and asked of a prepared claim with and without
	## an extra claim assumed. Returns how many answers were compared, and how
	## many of them were values rather than "none".
	steering_agrees : List(Engine.Decl), Term, Term, U64 -> Try({ compared : U64, found : U64, wrong : U64 }, Term.Fault)
	steering_agrees = |decls, raw, raw_extra, seed| {
		compiled = Engine.compile_with(decls, raw, [raw_extra])?
		ready = Engine.prepare(compiled, Holding)?
		extra = match compiled.extras.get(0) {
			Ok(built) => built.term
			Err(_) => Truth(Bool.True)
		}
		var $compared = 0
		var $found = 0
		var $wrong = 0
		for proposed in proposals(seed) {
			once = Engine.one_within(compiled, Holding, proposed, Engine.no_limit)?
			plain = Engine.respond(ready, proposed, [], Engine.no_limit)?
			assuming = Engine.respond(ready, proposed, [0], Engine.no_limit)?
			again = Engine.respond(ready, proposed, [], Engine.no_limit)?
			unloaded = Engine.fresh(compiled, Holding, proposed, [0], Engine.no_limit)?
			if once != plain or again != plain or unloaded != assuming {
				$wrong = $wrong + 1
			}
			best = nearest(decls, compiled.term, [], proposed)?
			best_assuming = nearest(decls, compiled.term, [extra], proposed)?
			for (answer, wanted) in [(plain, best), (assuming, best_assuming)] {
				$compared = $compared + 1
				match (answer, wanted) {
					(Nothing, Empty) => {}
					(Values(values), Best(smallest)) => {
						$found = $found + 1
						if distance(decls, proposed, values) != smallest {
							$wrong = $wrong + 1
						}
					}
					_ => {
						$wrong = $wrong + 1
					}
				}
			}
		}
		Ok({ compared: $compared, found: $found, wrong: $wrong })
	}

	## `steering_agrees` over `count` random claims, each with the next random
	## claim as its extra.
	steering_sweep : U64, U64 -> { compared : U64, found : U64, wrong : U64, failed : U64 }
	steering_sweep = |start, count| {
		var $compared = 0
		var $found = 0
		var $wrong = 0
		var $failed = 0
		var $index = start
		while $index < start + count {
			match steering_agrees(shape, sample($index), sample($index + 1), $index) {
				Ok(tally) => {
					$compared = $compared + tally.compared
					$found = $found + tally.found
					$wrong = $wrong + tally.wrong
				}
				Err(_) => {
					$failed = $failed + 1
				}
			}
			$index = $index + 1
		}
		{ compared: $compared, found: $found, wrong: $wrong, failed: $failed }
	}

	# -- Budgets -------------------------------------------------------------

	Spending : { answered : U64, gave_up : U64, wrong : U64 }

	## One claim asked under growing budgets. Whatever the budget, an answer
	## must be the answer given without one, values and all, and giving up
	## must report exactly the budget as spent.
	budget_agrees : List(Engine.Decl), Term, [Holding, Failing], List(U64) -> Try(Spending, Term.Fault)
	budget_agrees = |decls, raw, wanted, proposed| {
		compiled = Engine.compile(decls, raw)?
		full = Engine.one_within(compiled, wanted, proposed, Engine.no_limit)?
		var $answered = 0
		var $gave_up = 0
		var $wrong = 0
		for budget in [0, 1, 2, 3, 5, 8, 13, 21, 55, 144] {
			match Engine.one_within(compiled, wanted, proposed, budget)? {
				GaveUp(effort) => {
					if effort.conflicts == budget and full != GaveUp(effort) {
						$gave_up = $gave_up + 1
					} else {
						$wrong = $wrong + 1
					}
				}
				answer => {
					if answer == full {
						$answered = $answered + 1
					} else {
						$wrong = $wrong + 1
					}
				}
			}
		}
		Ok({ answered: $answered, gave_up: $gave_up, wrong: $wrong })
	}

	## A list asked for under growing budgets: what was found is always the
	## start of the list found without a budget, and the whole of it when the
	## search finished. Giving up can come after the last answer, while the
	## solver is still showing there are no more, and it reports exactly the
	## budget as spent over the whole list.
	listing_agrees : List(Engine.Decl), Term, U64 -> Try(Spending, Term.Fault)
	listing_agrees = |decls, raw, limit| {
		compiled = Engine.compile(decls, raw)?
		full = Engine.many(compiled, Holding, limit)?
		var $answered = 0
		var $gave_up = 0
		var $wrong = 0
		for budget in [0, 1, 3, 8, 21, 55, 144, 1000] {
			listed = Engine.many_within(compiled, Holding, limit, budget)?
			match listed.stopped {
				Finished => {
					if listed.found == full {
						$answered = $answered + 1
					} else {
						$wrong = $wrong + 1
					}
				}
				GaveUp(effort) => {
					if effort.conflicts == budget and listed.found == full.take_first(listed.found.len()) {
						$gave_up = $gave_up + 1
					} else {
						$wrong = $wrong + 1
					}
				}
			}
		}
		Ok({ answered: $answered, gave_up: $gave_up, wrong: $wrong })
	}

	## `budget_agrees` both ways round, and `listing_agrees`, over `count`
	## random claims and the operators that make the solver work hardest.
	budget_sweep : U64, U64 -> { answered : U64, gave_up : U64, wrong : U64, failed : U64 }
	budget_sweep = |start, count| {
		x = Var(0, 4)
		y = Var(1, 4)
		z = Var(2, 4)
		hard = [
			(triple(4), Compare(Eq, Arith(Times, x, y), z)),
			(triple(4), Compare(Eq, Arith(Div, x, y), z)),
			(triple(4), All([Compare(Eq, Arith(TimesWrap, x, y), Const(12, 4)), Compare(Lt, x, y), Compare(Eq, z, Arith(Rem, x, y))])),
			(triple(4), Compare(Eq, Arith(TimesWrap, x, y), Arith(TimesWrap, y, x))),
			(triple(4), Not(Compare(Eq, Arith(TimesWrap, x, y), Arith(TimesWrap, y, x)))),
		]
		var $cases = hard
		var $index = start
		while $index < start + count {
			$cases = $cases.append((shape, sample($index)))
			$index = $index + 1
		}
		var $answered = 0
		var $gave_up = 0
		var $wrong = 0
		var $failed = 0
		for (decls, raw) in $cases {
			for outcome in [budget_agrees(decls, raw, Holding, []), budget_agrees(decls, raw, Failing, []), budget_agrees(decls, raw, Holding, [5, 2, 3, 1]), listing_agrees(decls, raw, 40)] {
				match outcome {
					Ok(spending) => {
						$answered = $answered + spending.answered
						$gave_up = $gave_up + spending.gave_up
						$wrong = $wrong + spending.wrong
					}
					Err(_) => {
						$failed = $failed + 1
					}
				}
			}
		}
		{ answered: $answered, gave_up: $gave_up, wrong: $wrong, failed: $failed }
	}

	# -- Loading -------------------------------------------------------------

	## Does one call with every clause build the very solver that one call per
	## clause builds, and does it then answer alike?
	loads_alike : List(Engine.Decl), Term, [Holding, Failing] -> Bool
	loads_alike = |decls, raw, wanted| match Engine.compile(decls, raw) {
		Ok(compiled) => {
			var $single = Ok(Rocsat.new({}))
			var $clause = []
			var $count = 0
			for lit in Engine.clauses(compiled, wanted) {
				if lit == 0 {
					$single = match $single {
						Ok(sat) => Rocsat.add_clause(sat, $clause)
						Err(problem) => Err(problem)
					}
					$clause = []
					$count = $count + 1
				} else {
					$clause = $clause.append(lit)
				}
			}
			match (Engine.load(compiled, wanted), $single) {
				(Ok(bulk), Ok(single)) => bulk == single and $clause.is_empty() and $count == compiled.net.count + 2
				_ => Bool.False
			}
		}
		Err(_) => Bool.False
	}

	# -- The evaluator against Roc -------------------------------------------

	## Operands worth trying at 8 bits: the edges and a spread between.
	edges : List(U64)
	edges = [0, 1, 2, 3, 7, 8, 9, 15, 16, 17, 31, 32, 50, 100, 127, 128, 129, 200, 254, 255]

	## What Roc's own `U8` arithmetic gives, in the evaluator's vocabulary.
	native8 : [Plus, Minus, Times, Div, Rem, PlusWrap, MinusWrap, TimesWrap, BitAnd, BitOr, BitXor], U8, U8 -> Try(U64, [Overflow, DivByZero])
	native8 = |op, x, y| match op {
		Plus => match x.plus_try(y) {
			Ok(n) => Ok(n.to_u64())
			Err(_) => Err(Overflow)
		}
		Minus => match x.minus_try(y) {
			Ok(n) => Ok(n.to_u64())
			Err(_) => Err(Overflow)
		}
		Times => match x.times_try(y) {
			Ok(n) => Ok(n.to_u64())
			Err(_) => Err(Overflow)
		}
		Div => if y == 0 {
			Err(DivByZero)
		} else {
			Ok((x // y).to_u64())
		}
		Rem => if y == 0 {
			Err(DivByZero)
		} else {
			Ok((x % y).to_u64())
		}
		PlusWrap => Ok(x.plus_wrap(y).to_u64())
		MinusWrap => Ok(x.minus_wrap(y).to_u64())
		TimesWrap => Ok(x.times_wrap(y).to_u64())
		BitAnd => Ok(x.bitwise_and(y).to_u64())
		BitOr => Ok(x.bitwise_or(y).to_u64())
		BitXor => Ok(x.bitwise_xor(y).to_u64())
	}

	native64 : [Plus, Minus, Times, Div, Rem, PlusWrap, MinusWrap, TimesWrap, BitAnd, BitOr, BitXor], U64, U64 -> Try(U64, [Overflow, DivByZero])
	native64 = |op, x, y| match op {
		Plus => match x.plus_try(y) {
			Ok(n) => Ok(n)
			Err(_) => Err(Overflow)
		}
		Minus => match x.minus_try(y) {
			Ok(n) => Ok(n)
			Err(_) => Err(Overflow)
		}
		Times => match x.times_try(y) {
			Ok(n) => Ok(n)
			Err(_) => Err(Overflow)
		}
		Div => if y == 0 {
			Err(DivByZero)
		} else {
			Ok(x // y)
		}
		Rem => if y == 0 {
			Err(DivByZero)
		} else {
			Ok(x % y)
		}
		PlusWrap => Ok(x.plus_wrap(y))
		MinusWrap => Ok(x.minus_wrap(y))
		TimesWrap => Ok(x.times_wrap(y))
		BitAnd => Ok(x.bitwise_and(y))
		BitOr => Ok(x.bitwise_or(y))
		BitXor => Ok(x.bitwise_xor(y))
	}

	## The evaluator's answer with its width dropped, in the same vocabulary.
	evaluated : Term -> Try(U64, [Overflow, DivByZero])
	evaluated = |term| match Term.eval(term, []) {
		Ok(Word(n, _)) => Ok(n)
		Err(Overflow) => Err(Overflow)
		Err(DivByZero) => Err(DivByZero)
		_ => Ok(U64.highest)
	}

	truth_of : Term -> Try(Bool, [Wrong])
	truth_of = |term| match Term.eval(term, []) {
		Ok(Bit(answer)) => Ok(answer)
		_ => Err(Wrong)
	}

	## Every `U8` against every edge operand, for every operator.
	native8_agrees : {} -> Bool
	native8_agrees = |{}| {
		ops = [Plus, Minus, Times, Div, Rem, PlusWrap, MinusWrap, TimesWrap, BitAnd, BitOr, BitXor]
		var $ok = Bool.True
		var $x = 0
		while $x < 256 {
			for y in edges {
				a = Const($x, 8)
				b = Const(y, 8)
				x8 = $x.to_u8_wrap()
				y8 = y.to_u8_wrap()
				for op in ops {
					if evaluated(Arith(op, a, b)) != native8(op, x8, y8) {
						$ok = Bool.False
					}
				}
				same = truth_of(Compare(Eq, a, b)) == Ok(x8 == y8) and truth_of(Compare(Lt, a, b)) == Ok(x8 < y8) and truth_of(Compare(Lte, a, b)) == Ok(x8 <= y8)
				overflow = truth_of(Overflows(Plus, a, b)) == Ok(x8.plus_overflows(y8)) and truth_of(Overflows(Minus, a, b)) == Ok(x8.minus_overflows(y8)) and truth_of(Overflows(Times, a, b)) == Ok(x8.times_overflows(y8))
				count = y8 % 19
				shifts = evaluated(Shift(Left, a, count)) == Ok(x8.shl_wrap(count).to_u64()) and evaluated(Shift(Right, a, count)) == Ok(x8.shr_wrap(count).to_u64()) and evaluated(BitNot(a)) == Ok(x8.bitwise_not().to_u64())
				if !(same and overflow and shifts) {
					$ok = Bool.False
				}
			}
			$x = $x + 1
		}
		$ok
	}

	## The edges of `U64`, where the evaluator cannot lean on a wider type.
	native64_agrees : {} -> Bool
	native64_agrees = |{}| {
		ops = [Plus, Minus, Times, Div, Rem, PlusWrap, MinusWrap, TimesWrap, BitAnd, BitOr, BitXor]
		top = U64.highest
		values = [0, 1, 2, 3, 255, 65_536, 0xFFFF_FFFF, 0x1_0000_0000, 0x1_0000_0001, 0x7FFF_FFFF_FFFF_FFFF, 0x8000_0000_0000_0000, top - 1, top]
		var $ok = Bool.True
		for x in values {
			for y in values {
				a = Const(x, 64)
				b = Const(y, 64)
				for op in ops {
					if evaluated(Arith(op, a, b)) != native64(op, x, y) {
						$ok = Bool.False
					}
				}
				overflow = truth_of(Overflows(Plus, a, b)) == Ok(x.plus_overflows(y)) and truth_of(Overflows(Minus, a, b)) == Ok(x.minus_overflows(y)) and truth_of(Overflows(Times, a, b)) == Ok(x.times_overflows(y))
				count = (y % 70).to_u8_wrap()
				shifts = evaluated(Shift(Left, a, count)) == Ok(x.shl_wrap(count)) and evaluated(Shift(Right, a, count)) == Ok(x.shr_wrap(count)) and evaluated(BitNot(a)) == Ok(x.bitwise_not())
				if !(overflow and shifts) {
					$ok = Bool.False
				}
			}
		}
		$ok
	}

	## What Roc's own `I8` arithmetic gives, as the bits of the answer.
	native_i8 : [Plus, Minus, Times], I8, I8 -> Try(U64, [Overflow, DivByZero])
	native_i8 = |op, x, y| {
		answer = match op {
			Plus => x.plus_try(y)
			Minus => x.minus_try(y)
			Times => x.times_try(y)
		}
		match answer {
			Ok(n) => Ok(n.to_u8_wrap().to_u64())
			Err(_) => Err(Overflow)
		}
	}

	native_i64 : [Plus, Minus, Times], I64, I64 -> Try(U64, [Overflow, DivByZero])
	native_i64 = |op, x, y| {
		answer = match op {
			Plus => x.plus_try(y)
			Minus => x.minus_try(y)
			Times => x.times_try(y)
		}
		match answer {
			Ok(n) => Ok(n.to_u64_wrap())
			Err(_) => Err(Overflow)
		}
	}

	## Every `I8` against every other, for every signed form.
	native_i8_agrees : {} -> Bool
	native_i8_agrees = |{}| {
		var $ok = Bool.True
		var $x = 0
		while $x < 256 {
			var $y = 0
			while $y < 256 {
				a = Const($x, 8)
				b = Const($y, 8)
				x8 = $x.to_u8_wrap().to_i8_wrap()
				y8 = $y.to_u8_wrap().to_i8_wrap()
				for op in [Plus, Minus, Times] {
					real = native_i8(op, x8, y8)
					if evaluated(Signed(op, a, b)) != real or truth_of(SignedOverflows(op, a, b)) != Ok(real == Err(Overflow)) {
						$ok = Bool.False
					}
				}
				if truth_of(SignedCompare(Lt, a, b)) != Ok(x8 < y8) or truth_of(SignedCompare(Lte, a, b)) != Ok(x8 <= y8) {
					$ok = Bool.False
				}
				$y = $y + 1
			}
			# Widening is `to_i16`, and narrowing back gives the same number.
			wide = $x.to_u8_wrap().to_i8_wrap().to_i16().to_u16_wrap().to_u64()
			if evaluated(SignedResize(Const($x, 8), 16)) != Ok(wide) or evaluated(SignedResize(Const(wide, 16), 8)) != Ok($x) {
				$ok = Bool.False
			}
			$x = $x + 1
		}
		# Narrowing crashes exactly outside -128..=127.
		var $w = 0
		while $w < 65_536 {
			w16 = $w.to_u16_wrap().to_i16_wrap()
			fits = w16 >= -128 and w16 <= 127
			narrowed = evaluated(SignedResize(Const($w, 16), 8))
			if narrowed != (
				if fits {
					Ok($w.bitwise_and(255))
				} else {
					Err(Overflow)
				}
			) {
				$ok = Bool.False
			}
			$w = $w + 251
		}
		$ok
	}

	## The edges of `I64`, where the evaluator cannot lean on a wider type.
	native_i64_agrees : {} -> Bool
	native_i64_agrees = |{}| {
		top = U64.highest
		values = [0, 1, 2, 3, 255, 46_341, 65_536, 0x7FFF_FFFF, 0x8000_0000, 0xB504_F333, 0xB504_F334, 0xFFFF_FFFF, 0x1_0000_0000, 0x1_0000_0001, 3_037_000_499, 3_037_000_500, 0x3FFF_FFFF_FFFF_FFFF, 0x4000_0000_0000_0000, 0x7FFF_FFFF_FFFF_FFFE, 0x7FFF_FFFF_FFFF_FFFF, 0x8000_0000_0000_0000, 0x8000_0000_0000_0001, 0xC000_0000_0000_0000, 0xFFFF_FFFF_0000_0000, 0xFFFF_FFFF_7FFF_FFFF, 0xFFFF_FFFF_8000_0000, top - 3_037_000_499, top - 2, top - 1, top]
		var $ok = Bool.True
		for x in values {
			for y in values {
				a = Const(x, 64)
				b = Const(y, 64)
				x64 = x.to_i64_wrap()
				y64 = y.to_i64_wrap()
				for op in [Plus, Minus, Times] {
					real = native_i64(op, x64, y64)
					if evaluated(Signed(op, a, b)) != real or truth_of(SignedOverflows(op, a, b)) != Ok(real == Err(Overflow)) {
						$ok = Bool.False
					}
				}
				if truth_of(SignedCompare(Lt, a, b)) != Ok(x64 < y64) or truth_of(SignedCompare(Lte, a, b)) != Ok(x64 <= y64) {
					$ok = Bool.False
				}
			}
			# Narrowing to 32 bits crashes exactly outside `I32`, and widening
			# the low half is `to_i64`.
			x64 = x.to_i64_wrap()
			fits = x64 >= -2_147_483_648 and x64 <= 2_147_483_647
			low = x.bitwise_and(0xFFFF_FFFF)
			narrowed = evaluated(SignedResize(Const(x, 64), 32))
			widened = evaluated(SignedResize(Const(low, 32), 64))
			if narrowed != (
				if fits {
					Ok(low)
				} else {
					Err(Overflow)
				}
			) or widened != Ok(low.to_u32_wrap().to_i32_wrap().to_i64().to_u64_wrap()) {
				$ok = Bool.False
			}
		}
		$ok
	}
}

# The evaluator is the reference for everything below, so it goes first:
# against Roc's own integers.
expect Validate.native8_agrees({})
expect Validate.native64_agrees({})
expect Validate.native_i8_agrees({})
expect Validate.native_i64_agrees({})

# Every operator, both operands free, against brute force over all 4,096
# assignments of three 4-bit numbers.
expect Validate.arith_agrees(4)
expect Validate.unary_agrees(4)
expect Validate.compare_agrees(4)

# A width that is not a power of two, and the narrowest there is.
expect Validate.arith_agrees(3)
expect Validate.unary_agrees(3)
expect Validate.compare_agrees(3)
expect Validate.arith_agrees(1)
expect Validate.compare_agrees(1)

# Guards: the same two facts in the order that protects and the order that
# crashes, each split three ways exactly as the evaluator splits it.
expect {
	x = Var(0, 4)
	y = Var(1, 4)
	pair = List.repeat({ sort: Number(4), lo: 0, hi: 15 }, 2)
	safe = Compare(Lt, Arith(Minus, x, y), Const(5, 4))
	guarded = Validate.compare(pair, Implies(Compare(Lte, y, x), safe), Thorough)
	ordered = Validate.compare(pair, All([Compare(Lte, y, x), safe]), Thorough)
	reversed = Validate.compare(pair, All([safe, Compare(Lte, y, x)]), Thorough)
	divided = Validate.compare(pair, Any([Compare(Eq, y, Const(0, 4)), Compare(Lte, Arith(Div, x, y), x)]), Thorough)
	chosen = Validate.compare(pair, Compare(Lte, Choose(Compare(Lte, y, x), Arith(Minus, x, y), Arith(Minus, y, x)), Const(15, 4)), Thorough)
	guarded == Ok(Agree({ holding: 190, refuted: 66, crashing: 0 }))
		and ordered == Ok(Agree({ holding: 70, refuted: 186, crashing: 0 }))
		and reversed == Ok(Agree({ holding: 70, refuted: 66, crashing: 120 }))
		and divided == Ok(Agree({ holding: 256, refuted: 0, crashing: 0 }))
		and chosen == Ok(Agree({ holding: 256, refuted: 0, crashing: 0 }))
}

# The check has teeth: a circuit built for `<` is caught when the reference
# says `<=`, and so is one built for wrapping addition when the reference
# crashes on overflow.
expect {
	pair = List.repeat({ sort: Number(4), lo: 0, hi: 15 }, 2)
	wrong = |built, reference| match Engine.compile(pair, built) {
		Ok(compiled) => match Validate.against(compiled, reference, Thorough) {
			Ok(Agree(_)) => Bool.False
			_ => Bool.True
		}
		Err(_) => Bool.False
	}
	sum = |op| Compare(Lt, Arith(op, Var(0, 4), Var(1, 4)), Const(9, 4))
	wrong(Compare(Lt, Var(0, 4), Var(1, 4)), Compare(Lte, Var(0, 4), Var(1, 4)))
		and wrong(sum(PlusWrap), sum(Plus))
		and !wrong(sum(Plus), sum(Plus))
}

# Random claims that nest everything: none may differ. Of these 60, 36 are
# true on some assignments and not on others, 15 crash somewhere, and the
# solver lists 43,556 assignments, each one re-run through the evaluator.
# `Validate.sweep(60, 340)` has been run once by hand with the same result:
# 340 agreed, none differed, 243,756 assignments listed.
expect Validate.sweep(0, 60) == { agreed: 60, differed: [], mixed: 36, crashing: 15, listed: 43_556 }

# -- The signed forms -----------------------------------------------------------

# Every signed form against brute force, at 4 bits, at a width that is not a
# power of two, and at 2 bits where every number is an edge.
expect Validate.signed_agrees(4)
expect Validate.signed_agrees(3)
expect Validate.signed_agrees(2)

# -- Shared terms ----------------------------------------------------------------

# A running maximum over three 3-bit unknowns, each step shared: the same on
# all 512 assignments as the term written out, which is what removing the
# marks gives, and split by the solver exactly as by the evaluator.
expect {
	three = List.repeat({ sort: Number(3), lo: 0, hi: 7 }, 3)
	marked = Validate.running(3, 3, 2, Marked)
	Validate.unmarked(marked) == Validate.running(3, 3, 2, WrittenOut)
		and Validate.sharing_agrees(three, marked) == Ok(Bool.True)
		and Validate.compare(three, marked, Thorough) == Ok(Agree({ holding: 97, refuted: 415, crashing: 0 }))
}

# The blow-up: written out, each step of the maximum holds the one before it
# twice, so sixteen steps elaborate to 327,676 parts. Shared, they are
# fifteen definitions and 171 parts, and two hundred steps are 2,195.
expect Term.elaborate(Validate.running(16, 8, 3, WrittenOut)).map_ok(Validate.weigh) == Ok({ definitions: 0, parts: 327_676 })
expect Term.elaborate(Validate.running(16, 8, 3, Marked)).map_ok(Validate.weigh) == Ok({ definitions: 15, parts: 171 })
expect Term.elaborate(Validate.running(200, 8, 3, Marked)).map_ok(Validate.weigh) == Ok({ definitions: 199, parts: 2195 })

# Twelve steps over 8-bit unknowns, steered: the values the solver returns
# satisfy the same rule written as ordinary Roc, which the proposals do not.
expect {
	decls = List.repeat({ sort: Number(8), lo: 0, hi: 240 }, 12)
	proposed = List.repeat(0, 12).map_with_index(|_, index| (index * 97 + 100) % 240)
	match Validate.steered(decls, Validate.running(12, 8, 8, Marked), proposed) {
		Ok(Values(values)) => Validate.running_holds(values, 8, 255) and !Validate.running_holds(proposed, 8, 255)
		_ => Bool.False
	}
}

# A shared term crashes where it is used and nowhere else. The division is
# worked out once, yet the guard still protects it, and the unguarded order
# still crashes on the sixteen assignments with a zero divisor.
expect {
	x = Var(0, 4)
	y = Var(1, 4)
	pair = List.repeat({ sort: Number(4), lo: 0, hi: 15 }, 2)
	quotient = Term.shared(Arith(Div, x, y))
	nonzero = Not(Compare(Eq, y, Const(0, 4)))
	small = All([Compare(Lte, quotient, x), Compare(Lte, Arith(Times, quotient, y), x)])
	Validate.compare(pair, Implies(nonzero, small), Thorough) == Ok(Agree({ holding: 256, refuted: 0, crashing: 0 }))
		and Validate.compare(pair, All([small, nonzero]), Thorough) == Ok(Agree({ holding: 240, refuted: 0, crashing: 16 }))
		and Term.elaborate(Implies(nonzero, small)).map_ok(Validate.weigh) == Ok({ definitions: 1, parts: 17 })
}

# A shared literal has no width of its own: it takes one where it is used,
# here 4 bits and then 3, exactly as the unshared literal does.
expect {
	three = Term.shared(Lit(3))
	raw = All([Compare(Lt, Var(0, 4), three), Compare(Eq, Var(1, 3), three)])
	Term.elaborate(raw) == Term.elaborate(Validate.unmarked(raw))
		and Term.elaborate(raw) == Ok(All([Compare(Lt, Var(0, 4), Const(3, 4)), Compare(Eq, Var(1, 3), Const(3, 3))]))
}

# Random claims with shared parts and signed forms: none may differ from
# brute force, and none may differ from itself with the marks removed. The
# 24 claims elaborate to 137 definitions between them.
expect Validate.varied_sweep(0, 24) == { agreed: 24, differed: [], unshared: [], definitions: 137 }

# -- Steering --------------------------------------------------------------------

# Twenty-four random claims, eight sets of proposals each, asked plainly and with
# the next random claim assumed: every steered answer is the best there is by
# brute force over all 384 assignments, a prepared claim answers as a fresh
# one does, and asking again changes nothing. Of the 384 answers compared,
# 248 are values and 136 are "none".
expect Validate.steering_sweep(0, 24) == { compared: 384, found: 248, wrong: 0, failed: 0 }

# The order itself, on a claim small enough to read. With only 7 and 12
# possible, a proposal of 8 gives 12, which shares its top bit, though 7 is
# one away. A proposal of 3 gives 7, and one past the range counts as 15.
expect {
	one = [{ sort: Number(4), lo: 0, hi: 15 }]
	x = Var(0, 4)
	either = Any([Compare(Eq, x, Const(7, 4)), Compare(Eq, x, Const(12, 4))])
	asked = |proposal| Validate.steered(one, either, [proposal])
	asked(8) == Ok(Values([12])) and asked(3) == Ok(Values([7])) and asked(0) == Ok(Values([7])) and asked(15) == Ok(Values([12])) and asked(99) == Ok(Values([12]))
}

# -- Budgets ---------------------------------------------------------------------

# Five claims that make the solver work and twelve random ones, each asked
# three ways under ten budgets from none to 144 conflicts and listed under
# eight: every answer is the answer given without a budget, and every time
# the solver gives up it has spent exactly the budget. It answers 499 times
# and gives up 147 times.
expect Validate.budget_sweep(0, 12) == { answered: 499, gave_up: 147, wrong: 0, failed: 0 }

# -- Loading ---------------------------------------------------------------------

# One call with every clause builds the same solver as one call per clause.
expect {
	x = Var(0, 4)
	y = Var(1, 4)
	z = Var(2, 4)
	Validate.loads_alike(Validate.triple(4), Compare(Eq, Arith(Times, x, y), z), Holding)
		and Validate.loads_alike(Validate.triple(4), Compare(Eq, Arith(Div, x, y), z), Failing)
		and Validate.loads_alike(Validate.shape, Validate.sample(7), Holding)
		and Validate.loads_alike(Validate.shape, Validate.varied_sample(3), Failing)
}
