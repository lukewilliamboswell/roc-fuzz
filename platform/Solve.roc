## Proofs and counterexamples about fixed-width integers. Describe some
## numbers not yet chosen, state a claim about them, and ask either for values
## that make the claim true or for a proof that it holds for every value.
##
## ```roc
## import fuzz.Solve
##
## ## The usual midpoint. Is it always between its bounds?
## expect Solve.prove(
##     { lo: Solve.u8, hi: Solve.u8 }.Solve,
##     |v| {
##         mid = (v.lo + v.hi) // 2
##         v.lo.lte(v.hi).implies(Solve.all([v.lo.lte(mid), mid.lte(v.hi)]))
##     },
## ) == Ok(Crashes({ lo: 1, hi: 255 }))
## ```
##
## The answer covers all 65,536 pairs of bytes, and it says the addition
## overflows on `lo = 1, hi = 255`. Written as `v.lo + (v.hi - v.lo) // 2` the
## same claim is `Proved`.
##
## ## Unknowns, terms and claims
##
## `{ lo: Solve.u8, hi: Solve.u8 }.Solve` declares two unknowns. Inside the
## claim each one is a `Uint`: a term standing for a number not yet chosen. A
## claim is a `Claim`: a fact about such numbers.
##
## `+ - * // %` and number literals work on a `Uint` as they do on a `U8`.
## Comparisons are methods (`eq`, `neq`, `lt`, `lte`, `gt`, `gte`) because
## Roc's `<` must return a `Bool`, and `Solve.all`, `Solve.any`, `implies` and
## `Solve.if_else` stand in for `and`, `or` and `if`. A function written
## without a type annotation, like `|lo, hi| lo + (hi - lo) // 2`, runs on
## `U32`s and builds a term on `Uint`s, so the code you test and the term you
## prove can be one definition.
##
## ## What a term means
##
## A term means what the same expression means in Roc.
##
## - Every `Uint` has a width in bits, from 1 to 64. Both sides of an
##   operator must have the same width. A literal takes the width of what it
##   meets and must fit in it.
## - `+`, `-` and `*` crash on overflow, and `//` and `%` crash on a zero
##   divisor, exactly as Roc's unsigned integers do. The `_wrap` forms wrap
##   around instead, and the `_overflows` forms ask whether the crash would
##   happen.
## - A `Uint` is a row of bits, and the forms above read it as an unsigned
##   number. The `_signed` forms (`lt_signed`, `plus_signed`,
##   `plus_overflows_signed`, `to_width_signed`, ...) read the same bits as a
##   two's complement integer, which is what `I8` to `I64` are, and crash
##   where those crash. There is no signed division or remainder.
## - `Solve.all`, `Solve.any`, `implies` and `Solve.if_else` evaluate left to
##   right and stop early like `and`, `or` and `if`. A guard written first
##   protects what follows: `b.neq(0).implies((a // b).lte(a))` never divides
##   by zero.
##
## A claim holds on some values when it evaluates to true without crashing.
## `find` looks for values where it holds. `prove` shows it holds everywhere,
## or returns values where it is false (`Refuted`) or where it crashes
## (`Crashes`), so a proof is also a proof that nothing overflowed.
##
## ## Sharing
##
## A Roc name is not a name inside a term. After `m = a + b`, every use of
## `m` puts the whole of `a + b` into the term again. That is usually
## harmless, but a value worked out step by step from the step before, like a
## running maximum, then doubles at every step: twenty steps make a term of a
## million parts. `x.shared()` is the fix. It means exactly what `x` means,
## guards and crashes included, and is worked out once wherever it appears.
##
## ```roc
## $highest = Solve.if_else(item.gt($highest), item, $highest).shared()
## ```
##
## Shared terms are told apart by a 64-bit fingerprint of their structure. Two
## different shared terms with the same fingerprint would be taken for one,
## silently. Nothing checks for it, because checking would mean walking the
## terms that sharing exists to avoid walking. With a thousand shared terms
## the chance is about one in 10^13.
##
## ## How long a query runs
##
## Every search has a budget, counted in conflicts: the dead ends the solver
## meets and learns from. Conflicts are the solver's own unit of work. They
## do not depend on the machine or the build, so a question that fits a
## budget once fits it every time, and a budget is not a timeout.
##
## - `find_within`, `find_near_within`, `prove_within` and `enumerate_within`
##   take the budget and answer `GaveUp(effort)` when it runs out. That says
##   nothing about the claim, only what was spent.
## - `find`, `find_near`, `prove` and `enumerate` use `default_budget`, a
##   million conflicts, and report running out as `Err(GaveUp(effort))`.
## - A search that ends inside its budget is the same search whatever the
##   budget was, so a larger budget never changes an answer.
##
## Multiplication is where questions get hard: proving `a * b == b * a` takes
## about a thousand conflicts at 5 bits, about 900,000 at 10 bits, and more
## than the default budget at 16. Comparisons, addition, subtraction,
## division by a constant power of two and the bitwise forms stay cheap at 64
## bits.
##
## `roc test` runs on the default backend, which runs the solver thirty to a
## hundred and fifty times slower than `--opt=speed`. Claims that need a few
## thousand conflicts are comfortable there. For anything larger use
## `--opt=speed`, or give the test a small budget of its own: a million
## conflicts on the default backend is tens of minutes.
##
## ## What to trust
##
## Every set of values this module returns has been run through a plain
## evaluator of terms before it is returned, so `Found`, `Refuted` and
## `Crashes` never depend on the solver being right. `Proved` and `None` do:
## they say the solver found nothing. `GaveUp` claims nothing. roc-fuzz's own
## tests compare the solver with brute-force enumeration at small widths: the
## verdicts, the order `find_near` promises, the answers under a budget, and
## shared terms against the same terms written out.
import Term
import Engine

Solve := [].{

	## A number not yet chosen, or a term built from such numbers: a row of
	## bits of a fixed width, read as an unsigned number except by the
	## `_signed` forms. Unknowns come from declarations like `Solve.u32`, and
	## known numbers from literals and the `from_` functions.
	##
	## ```roc
	## Solve.find(Solve.map(Solve.u8, |x| { x: x }), |v| (v.x * 3).eq(51)) == Ok(Found({ x: 17 }))
	## ```
	Uint :: Term.{

		## Lets a number literal stand for a `Uint`, as in `v.x + 1`. The
		## literal takes the width of the term it meets.
		from_numeral : Numeral -> Try(Uint, [InvalidNumeral(Str)])
		from_numeral = |numeral| match U64.from_numeral(numeral) {
			Ok(number) => Ok(Uint.(Lit(number)))
			Err(problem) => Err(problem)
		}

		## A `U8` as a term 8 bits wide: `Solve.Uint.from_u8(250) + 6`
		## crashes, as `250.U8 + 6` does.
		from_u8 : U8 -> Uint
		from_u8 = |number| Uint.(Const(number.to_u64(), 8))

		## A `U16` as a term 16 bits wide.
		from_u16 : U16 -> Uint
		from_u16 = |number| Uint.(Const(number.to_u64(), 16))

		## A `U32` as a term 32 bits wide.
		from_u32 : U32 -> Uint
		from_u32 = |number| Uint.(Const(number.to_u64(), 32))

		## A `U64` as a term 64 bits wide.
		from_u64 : U64 -> Uint
		from_u64 = |number| Uint.(Const(number, 64))

		## A number as a term of the given width in bits, for widths Roc has
		## no type for: `Solve.Uint.of_width(5, 4)` is 5 in four bits.
		of_width : U64, U8 -> Uint
		of_width = |number, width| Uint.(Const(number, width))

		## An `I8` as its 8 bits: `Solve.Uint.from_i8(-56).value() == 200`.
		from_i8 : I8 -> Uint
		from_i8 = |number| Uint.(Const(number.to_u8_wrap().to_u64(), 8))

		## An `I16` as its 16 bits.
		from_i16 : I16 -> Uint
		from_i16 = |number| Uint.(Const(number.to_u16_wrap().to_u64(), 16))

		## An `I32` as its 32 bits.
		from_i32 : I32 -> Uint
		from_i32 = |number| Uint.(Const(number.to_u32_wrap().to_u64(), 32))

		## An `I64` as its 64 bits.
		from_i64 : I64 -> Uint
		from_i64 = |number| Uint.(Const(number.to_u64_wrap(), 64))

		## `a + b`. Crashes when the sum does not fit the width.
		plus : Uint, Uint -> Uint
		plus = |Uint.(a), Uint.(b)| Uint.(Arith(Plus, a, b))

		## `a - b`. Crashes when `b` is larger than `a`.
		minus : Uint, Uint -> Uint
		minus = |Uint.(a), Uint.(b)| Uint.(Arith(Minus, a, b))

		## `a * b`. Crashes when the product does not fit the width. A product
		## of two unknowns is the costly part of most questions: see "How long
		## a query runs" at the top of this module.
		times : Uint, Uint -> Uint
		times = |Uint.(a), Uint.(b)| Uint.(Arith(Times, a, b))

		## `a // b`. Crashes when `b` is zero. A divisor that is a constant
		## power of two costs nothing; any other divisor costs a multiplier.
		div_trunc_by : Uint, Uint -> Uint
		div_trunc_by = |Uint.(a), Uint.(b)| Uint.(Arith(Div, a, b))

		## `a % b`. Crashes when `b` is zero.
		rem_by : Uint, Uint -> Uint
		rem_by = |Uint.(a), Uint.(b)| Uint.(Arith(Rem, a, b))

		## `a + b` wrapping around, as `U8.plus_wrap` does: never crashes.
		plus_wrap : Uint, Uint -> Uint
		plus_wrap = |Uint.(a), Uint.(b)| Uint.(Arith(PlusWrap, a, b))

		## `a - b` wrapping around below zero: never crashes.
		minus_wrap : Uint, Uint -> Uint
		minus_wrap = |Uint.(a), Uint.(b)| Uint.(Arith(MinusWrap, a, b))

		## `a * b` keeping the low bits of the product: never crashes.
		times_wrap : Uint, Uint -> Uint
		times_wrap = |Uint.(a), Uint.(b)| Uint.(Arith(TimesWrap, a, b))

		## Would `a + b` crash? `a.plus_overflows(b).not().implies(...)` is a
		## claim about the sum that only looks at sums that fit.
		plus_overflows : Uint, Uint -> Claim
		plus_overflows = |Uint.(a), Uint.(b)| Claim.(Overflows(Plus, a, b))

		## Would `a - b` crash? True exactly when `b` is larger than `a`.
		minus_overflows : Uint, Uint -> Claim
		minus_overflows = |Uint.(a), Uint.(b)| Claim.(Overflows(Minus, a, b))

		## Would `a * b` crash?
		times_overflows : Uint, Uint -> Claim
		times_overflows = |Uint.(a), Uint.(b)| Claim.(Overflows(Times, a, b))

		## The bits set in both, as `U32.bitwise_and` does.
		bitwise_and : Uint, Uint -> Uint
		bitwise_and = |Uint.(a), Uint.(b)| Uint.(Arith(BitAnd, a, b))

		## The bits set in either.
		bitwise_or : Uint, Uint -> Uint
		bitwise_or = |Uint.(a), Uint.(b)| Uint.(Arith(BitOr, a, b))

		## The bits set in exactly one.
		bitwise_xor : Uint, Uint -> Uint
		bitwise_xor = |Uint.(a), Uint.(b)| Uint.(Arith(BitXor, a, b))

		## Every bit flipped.
		bitwise_not : Uint -> Uint
		bitwise_not = |Uint.(a)| Uint.(BitNot(a))

		## Shift left by a fixed count, taken modulo the width as in Roc:
		## `x.shl_wrap(3)` is `x * 8` keeping the low bits.
		shl_wrap : Uint, U8 -> Uint
		shl_wrap = |Uint.(a), count| Uint.(Shift(Left, a, count))

		## Shift right by a fixed count, taken modulo the width as in Roc:
		## `x.shr_wrap(1)` is `x // 2`.
		shr_wrap : Uint, U8 -> Uint
		shr_wrap = |Uint.(a), count| Uint.(Shift(Right, a, count))

		## The same number at another width. Crashes when it does not fit.
		## Widening first is how to compute with a bit to spare:
		## `(a.to_width(33) + b.to_width(33)) // 2` never overflows.
		to_width : Uint, U8 -> Uint
		to_width = |Uint.(a), width| Uint.(Resize(Checked, a, width))

		## The low bits of the number at another width, as `U32.to_u8_wrap`
		## does.
		to_width_wrap : Uint, U8 -> Uint
		to_width_wrap = |Uint.(a), width| Uint.(Resize(Wrap, a, width))

		## The same number, to be worked out once however often it is used.
		## See "Sharing" at the top of this module.
		shared : Uint -> Uint
		shared = |Uint.(a)| Uint.(Term.shared(a))

		## `a + b` on signed integers. Crashes when the sum does not fit the
		## width as a signed number, as `I32`'s `+` does.
		plus_signed : Uint, Uint -> Uint
		plus_signed = |Uint.(a), Uint.(b)| Uint.(Signed(Plus, a, b))

		## `a - b` on signed integers. Crashes when the difference does not
		## fit: `Solve.num(0).minus_signed(x)` is `-x`, and crashes at the
		## lowest number of the width.
		minus_signed : Uint, Uint -> Uint
		minus_signed = |Uint.(a), Uint.(b)| Uint.(Signed(Minus, a, b))

		## `a * b` on signed integers. Crashes when the product does not fit.
		## Built from a multiplier of twice the width, so it costs several
		## times what `times` costs.
		times_signed : Uint, Uint -> Uint
		times_signed = |Uint.(a), Uint.(b)| Uint.(Signed(Times, a, b))

		## Would `a + b` on signed integers crash?
		plus_overflows_signed : Uint, Uint -> Claim
		plus_overflows_signed = |Uint.(a), Uint.(b)| Claim.(SignedOverflows(Plus, a, b))

		## Would `a - b` on signed integers crash?
		minus_overflows_signed : Uint, Uint -> Claim
		minus_overflows_signed = |Uint.(a), Uint.(b)| Claim.(SignedOverflows(Minus, a, b))

		## Would `a * b` on signed integers crash?
		times_overflows_signed : Uint, Uint -> Claim
		times_overflows_signed = |Uint.(a), Uint.(b)| Claim.(SignedOverflows(Times, a, b))

		## The same signed number at another width. Widening copies the sign
		## bit, as `I32.to_i64` does. Narrowing crashes when it does not fit;
		## `to_width_wrap` keeps the low bits instead, as `to_i8_wrap` does.
		to_width_signed : Uint, U8 -> Uint
		to_width_signed = |Uint.(a), width| Uint.(SignedResize(a, width))

		## `a < b` on signed integers: 200 in 8 bits is -56, so it is less
		## than 3 here and greater than 3 under `lt`.
		lt_signed : Uint, Uint -> Claim
		lt_signed = |Uint.(a), Uint.(b)| Claim.(SignedCompare(Lt, a, b))

		## `a <= b` on signed integers.
		lte_signed : Uint, Uint -> Claim
		lte_signed = |Uint.(a), Uint.(b)| Claim.(SignedCompare(Lte, a, b))

		## `a > b` on signed integers.
		gt_signed : Uint, Uint -> Claim
		gt_signed = |Uint.(a), Uint.(b)| Claim.(SignedCompare(Lt, b, a))

		## `a >= b` on signed integers.
		gte_signed : Uint, Uint -> Claim
		gte_signed = |Uint.(a), Uint.(b)| Claim.(SignedCompare(Lte, b, a))

		## `a == b`, as a claim: `(v.x + v.y).eq(44)`.
		eq : Uint, Uint -> Claim
		eq = |Uint.(a), Uint.(b)| Claim.(Compare(Eq, a, b))

		## `a != b`, as a claim.
		neq : Uint, Uint -> Claim
		neq = |Uint.(a), Uint.(b)| Claim.(Not(Compare(Eq, a, b)))

		## `a < b`, as a claim.
		lt : Uint, Uint -> Claim
		lt = |Uint.(a), Uint.(b)| Claim.(Compare(Lt, a, b))

		## `a <= b`, as a claim.
		lte : Uint, Uint -> Claim
		lte = |Uint.(a), Uint.(b)| Claim.(Compare(Lte, a, b))

		## `a > b`, as a claim.
		gt : Uint, Uint -> Claim
		gt = |Uint.(a), Uint.(b)| Claim.(Compare(Lt, b, a))

		## `a >= b`, as a claim.
		gte : Uint, Uint -> Claim
		gte = |Uint.(a), Uint.(b)| Claim.(Compare(Lte, b, a))

		## Run a term that has no unknowns left in it:
		## `(Solve.Uint.from_u8(250) + 6).eval() == Err(Overflow)`.
		eval : Uint -> Try(U64, Problem)
		eval = |Uint.(raw)| {
			term = Term.elaborate(raw)?
			match Term.eval(term, [])? {
				Word(number, _) => Ok(number)
				Bit(_) => Err(Malformed)
			}
		}

		## The number a solved unknown stands for. The records inside `Found`,
		## `Refuted` and `Crashes` hold nothing but such numbers, so
		## `v.x.value()` is how to take them out as `U64`s.
		##
		## Crashes on a term that still has unknowns in it or that overflows;
		## use `eval` when that can happen.
		value : Uint -> U64
		value = |Uint.(term)| match term {
			Const(number, _) => number
			Lit(number) => number
			_ => match eval(Uint.(term)) {
				Ok(number) => number
				Err(_) => {
					crash "Solve.Uint.value: the term has no value; use Uint.eval"
				}
			}
		}

		## `eval`, with the number read as a signed integer of its width.
		eval_signed : Uint -> Try(I64, Problem)
		eval_signed = |Uint.(raw)| {
			term = Term.elaborate(raw)?
			match Term.eval(term, [])? {
				Word(number, width) => match Term.signed_resized(number, width, 64) {
					Ok(wide) => Ok(wide.to_i64_wrap())
					Err(Overflow) => Err(Overflow)
				}
				Bit(_) => Err(Malformed)
			}
		}

		## `value`, with the number read as a signed integer of its width: a
		## solved 8-bit unknown holding 255 is -1. Crashes like `value`.
		value_signed : Uint -> I64
		value_signed = |number| match eval_signed(number) {
			Ok(signed) => signed
			Err(_) => {
				crash "Solve.Uint.value_signed: the term has no value or no width; use Uint.eval_signed"
			}
		}

		## Two terms are equal when they are the same term. A solved number
		## equals a literal of the same value, so an expected answer can be
		## written `Ok(Refuted({ awaited: 65_536, frame: 0 }))`.
		is_eq : Uint, Uint -> Bool
		is_eq = |Uint.(a), Uint.(b)| match (a, b) {
			(Const(x, _), Lit(y)) => x == y
			(Lit(x), Const(y, _)) => x == y
			_ => a == b
		}

		## How `Str.inspect` and a failing `expect` show a term: a solved
		## number as its digits.
		to_inspect : Uint -> Str
		to_inspect = |Uint.(term)| match term {
			Const(number, _) => number.to_str()
			Lit(number) => number.to_str()
			_ => Str.inspect(term)
		}
	}

	## A fact about numbers not yet chosen, built from comparisons such as
	## `v.lo.lte(v.hi)` and combined with `implies`, `Solve.all` and the
	## rest. A claim is what `find` and `prove` take, and an unknown declared
	## with `Solve.bool` is one too.
	Claim :: Term.{

		## Two claims are equal when they are the same term. A solved truth
		## value equals `Solve.truth` of the same `Bool`.
		is_eq : Claim, Claim -> Bool
		is_eq = |Claim.(a), Claim.(b)| a == b

		## `!a`.
		not : Claim -> Claim
		not = |Claim.(a)| Claim.(Not(a))

		## `!a or b`: whenever `a` is true, `b` is too. `b` is only evaluated
		## when `a` is true, so `v.y.neq(0).implies((v.x // v.y).lte(v.x))`
		## never divides by zero.
		implies : Claim, Claim -> Claim
		implies = |Claim.(a), Claim.(b)| Claim.(Implies(a, b))

		## Both are true or both are false: `trick(x).iff(definition(x))`
		## says two ways of stating a rule agree.
		iff : Claim, Claim -> Claim
		iff = |Claim.(a), Claim.(b)| Claim.(Same(a, b))

		## `a and b`. `Solve.all` takes any number of claims.
		both : Claim, Claim -> Claim
		both = |Claim.(a), Claim.(b)| Claim.(All([a, b]))

		## `a or b`. `Solve.any` takes any number of claims.
		either : Claim, Claim -> Claim
		either = |Claim.(a), Claim.(b)| Claim.(Any([a, b]))

		## The same claim, to be worked out once however often it is used.
		## See "Sharing" at the top of this module.
		shared : Claim -> Claim
		shared = |Claim.(a)| Claim.(Term.shared(a))

		## Run a claim that has no unknowns left in it:
		## `Solve.Uint.from_u8(3).lt(4).eval() == Ok(Bool.True)`.
		eval : Claim -> Try(Bool, Problem)
		eval = |Claim.(raw)| {
			term = Term.elaborate(raw)?
			Term.holds(term, [])
		}

		## The answer a solved truth value stands for: `v.urgent.value()` on
		## a `Found` record. Crashes like `Uint.value`.
		value : Claim -> Bool
		value = |Claim.(term)| match term {
			Truth(answer) => answer
			_ => match eval(Claim.(term)) {
				Ok(answer) => answer
				Err(_) => {
					crash "Solve.Claim.value: the term has no value; use Claim.eval"
				}
			}
		}

		## How `Str.inspect` and a failing `expect` show a claim: a solved
		## truth value as `True` or `False`.
		to_inspect : Claim -> Str
		to_inspect = |Claim.(term)| match term {
			Truth(answer) => if answer {
				"True"
			} else {
				"False"
			}
			_ => Str.inspect(term)
		}
	}

	## Why a query could not be answered.
	##
	## - `GaveUp` means a query without a budget of its own spent
	##   `default_budget` and stopped: the claim is neither proved nor
	##   refuted, and the record says what was spent.
	## - `Overflow` and `DivByZero` come only from running a term on values
	##   (`check`, `eval`): Roc would crash there.
	## - `WidthMismatch`, `LiteralTooLarge`, `BadWidth`, `BadRange`,
	##   `Unbound` and `Malformed` say the terms themselves are ill-formed,
	##   whatever the values: `v.x.lt(v.y)` with an 8-bit `x` and a 16-bit `y`
	##   is `WidthMismatch({ left: 8, right: 16 })`.
	## - `NoSuchExtra` means an `ask` assumed an extra claim the prepared
	##   claim does not have.
	## - `Solver` and `Disagreement` are bugs in roc-fuzz, not in the claim.
	Problem : [
		Overflow,
		DivByZero,
		WidthMismatch({ left : U8, right : U8 }),
		LiteralTooLarge({ literal : U64, width : U8 }),
		BadWidth(U8),
		BadRange({ lo : U64, hi : U64, width : U8 }),
		Unbound(U64),
		NoSuchExtra(U64),
		Malformed,
		GaveUp(Effort),
		Solver([ZeroLiteral, LiteralOutOfRange(I32), UnknownVariable(I32), VariableLimit]),
		Disagreement,
	]

	# -- Building terms ------------------------------------------------------

	## A number known only when the program runs, as a literal: it takes the
	## width of what it meets, like `1` in `x + 1`. `v.x.lt(Solve.num(limit))`
	## compares with a `U64` variable.
	num : U64 -> Uint
	num = |value| Uint.(Lit(value))

	## A `Bool` as a claim: `Solve.truth(strict).implies(...)` switches part
	## of a claim on with an ordinary value.
	truth : Bool -> Claim
	truth = |value| Claim.(Truth(value))

	## Every claim is true. Later claims are only evaluated while the earlier
	## ones are true, as with `and`: `Solve.all([v.y.neq(0), (v.x // v.y).eq(3)])`.
	all : List(Claim) -> Claim
	all = |claims| Claim.(All(claims.map(|Claim.(term)| term)))

	## At least one claim is true. Later claims are only evaluated while the
	## earlier ones are false, as with `or`: `Solve.any([v.x.eq(7), v.x.eq(12)])`.
	any : List(Claim) -> Claim
	any = |claims| Claim.(Any(claims.map(|Claim.(term)| term)))

	## `if condition { then } else { otherwise }` on numbers. Only the chosen
	## side is evaluated: `Solve.if_else(v.a.gt(v.b), v.a, v.b)` is the larger.
	if_else : Claim, Uint, Uint -> Uint
	if_else = |Claim.(condition), Uint.(then), Uint.(otherwise)| Uint.(Choose(condition, then, otherwise))

	## `if condition { then } else { otherwise }` on claims.
	if_else_claim : Claim, Claim, Claim -> Claim
	if_else_claim = |Claim.(condition), Claim.(then), Claim.(otherwise)| Claim.(Choose(condition, then, otherwise))

	# -- Declaring unknowns --------------------------------------------------

	## A description of the unknowns of a problem, giving a value of type `v`
	## to state claims about. Combine several with the record builder:
	##
	## ```roc
	## { start: Solve.u16, count: Solve.u16_in(1, 512), urgent: Solve.bool }.Solve
	## ```
	##
	## The same description hands the claim a record of unknowns, and hands
	## back the same record with numbers filled in inside `Found`, `Refuted`
	## and `Crashes`. Unknowns are numbered in the order the fields are
	## written, which is the order `find_near` and `check` take values in.
	Vars(v) :: (Source -> { value : v, source : Source })

	## What the record builder `{ ... }.Solve` calls to combine two fields.
	## It is rarely called by name.
	map2 : Vars(a), Vars(b), (a, b -> c) -> Vars(c)
	map2 = |Vars.(first), Vars.(second), combine| Vars.(
		|source| {
			left = first(source)
			right = second(left.source)
			{ value: combine(left.value, right.value), source: right.source }
		},
	)

	## Change the value a description gives, for example to a tuple or to a
	## nominal type. A single unknown needs it to become a record:
	## `Solve.map(Solve.u8, |x| { x: x })`.
	map : Vars(a), (a -> b) -> Vars(b)
	map = |Vars.(vars), change| Vars.(
		|source| {
			made = vars(source)
			{ value: change(made.value), source: made.source }
		},
	)

	## An unknown of `width` bits, anywhere from `lo` to `hi` inclusive.
	##
	## A narrow range in a wide type is cheap: `Solve.uint_in(64, 0, 999)`
	## behaves like a `U64` in arithmetic but gives the solver only ten bits to
	## choose.
	uint_in : U8, U64, U64 -> Vars(Uint)
	uint_in = |width, lo, hi| Vars.(
		|source| {
			id = source.decls.len()
			value = if source.concrete {
				Uint.(Const(source.solved.get(id) ?? 0, width))
			} else {
				Uint.(Var(id, width))
			}
			{ value, source: { ..source, decls: source.decls.append({ sort: Number(width), lo, hi }) } }
		},
	)

	## An unknown of `width` bits, for widths Roc has no type for:
	## `Solve.uint(4)` is a number from 0 to 15.
	uint : U8 -> Vars(Uint)
	uint = |width| uint_in(width, 0, Term.mask(width))

	## An unknown that behaves like a `U8`: `{ lo: Solve.u8, hi: Solve.u8 }.Solve`.
	u8 : Vars(Uint)
	u8 = uint(8)

	## An unknown that behaves like a `U16`.
	u16 : Vars(Uint)
	u16 = uint(16)

	## An unknown that behaves like a `U32`.
	u32 : Vars(Uint)
	u32 = uint(32)

	## An unknown that behaves like a `U64`.
	u64 : Vars(Uint)
	u64 = uint(64)

	## An 8-bit unknown from `lo` to `hi` inclusive: `Solve.u8_in(1, 100)`.
	u8_in : U64, U64 -> Vars(Uint)
	u8_in = |lo, hi| uint_in(8, lo, hi)

	## A 16-bit unknown from `lo` to `hi` inclusive.
	u16_in : U64, U64 -> Vars(Uint)
	u16_in = |lo, hi| uint_in(16, lo, hi)

	## A 32-bit unknown from `lo` to `hi` inclusive.
	u32_in : U64, U64 -> Vars(Uint)
	u32_in = |lo, hi| uint_in(32, lo, hi)

	## A 64-bit unknown from `lo` to `hi` inclusive: `Solve.u64_in(0, 999_999)`
	## is a counter that stays below a million and costs the solver 20 bits.
	u64_in : U64, U64 -> Vars(Uint)
	u64_in = |lo, hi| uint_in(64, lo, hi)

	## `count` unknowns of the same kind, declared one after another, as a
	## list: `Solve.several(Solve.u8, 8)` is eight bytes.
	several : Vars(item), U64 -> Vars(List(item))
	several = |Vars.(one), count| Vars.(
		|source| {
			var $source = source
			var $items = List.with_capacity(count)
			var $made = 0
			while $made < count {
				next = one($source)
				$items = $items.append(next.value)
				$source = next.source
				$made = $made + 1
			}
			{ value: $items, source: $source }
		},
	)

	## An unknown truth value, a `Claim`: `{ urgent: Solve.bool }.Solve`.
	bool : Vars(Claim)
	bool = Vars.(
		|source| {
			id = source.decls.len()
			value = if source.concrete {
				Claim.(Truth((source.solved.get(id) ?? 0) != 0))
			} else {
				Claim.(Flag(id))
			}
			{ value, source: { ..source, decls: source.decls.append({ sort: Flag, lo: 0, hi: 1 }) } }
		},
	)

	# -- Queries -------------------------------------------------------------

	## What a search cost, in the solver's own counters. The counters depend
	## only on the question, never on the machine or the build, so a budget
	## that is enough once is enough every time. `conflicts` is what a budget
	## counts.
	Effort : { conflicts : U64, decisions : U64, propagations : U64, restarts : U64 }

	## The budget of the queries that do not take one: a million conflicts,
	## which an optimised build spends in about a minute. When the number was
	## chosen, the hardest proof in roc-fuzz's own tests needed 22,562.
	default_budget : U64
	default_budget = 1_000_000

	## A budget that never runs out, for `prove_within` and the other
	## `_within` queries: the query returns when the solver does, which for a
	## hard question may be never.
	no_limit : U64
	no_limit = Engine.no_limit

	## Values that make the claim hold, or `None` when there are none. Which
	## values, when there are several, is the solver's choice: the same every
	## time, but nothing more is promised. `find_near` promises more.
	##
	## ```roc
	## Solve.find({ x: Solve.u8, y: Solve.u8 }.Solve, |v| Solve.all([v.x.lt(v.y), v.y.lt(v.x)])) == Ok(None)
	## ```
	##
	## Gives up after `default_budget` conflicts with `Err(GaveUp(effort))`.
	find : Vars(v), (v -> Claim) -> Try([Found(v), None], Problem)
	find = |vars, claim| find_near(vars, claim, [])

	## `find` within a budget of conflicts. `GaveUp` means the budget ran out
	## before the solver found values or showed there are none.
	find_within : Vars(v), (v -> Claim), U64 -> Try([Found(v), None, GaveUp(Effort)], Problem)
	find_within = |vars, claim, budget| find_near_within(vars, claim, [], budget)

	## Like `find`, steered towards the proposed values: one per unknown, in
	## the order the unknowns were declared. A fuzzer's bytes can propose and
	## the solver repairs what does not fit.
	##
	## ```roc
	## Solve.find_near({ x: Solve.u16, y: Solve.u16 }.Solve, |v| v.x.lt(v.y), [1000, 2000]) == Ok(Found({ x: 1000, y: 2000 }))
	## ```
	##
	## The answer is fixed by the claim and the proposals, by this rule. Of
	## all the values that make the claim hold:
	##
	## - Earlier unknowns win. The first unknown gets the value nearest its
	##   proposal that any solution has. The second gets the nearest value it
	##   can have beside that one, and so on through the proposals.
	## - Within a number, high bits win. The nearest value is the one whose
	##   highest bit that differs from the proposal is as low as possible;
	##   among those, the one whose next differing bit is as low as possible;
	##   and so on. In one line: `value xor proposal`, read as a number, is as
	##   small as it can be.
	##
	## What follows from the rule:
	##
	## - Proposals that already make the claim hold come back unchanged, and
	##   so does any leading part of them that some solution agrees with.
	## - For an unknown whose range starts at 0, proposing 0 gives the smallest
	##   value there is: all zeros give the smallest first unknown, then the
	##   smallest second unknown beside it, and so on. For an unknown that
	##   uses its whole width, proposing its largest number gives the largest.
	##   Neither holds for other ranges: there the bits of the end of the
	##   range decide.
	## - Each answer keeps the longest run of leading bits of its proposal
	##   that it can. In numbers: it lies in the smallest aligned power-of-two
	##   block around the proposal that holds a value the unknown can still
	##   take.
	## - It is not the solution at the smallest distance. With only 7 and 12
	##   possible, a proposal of 8 gives 12, which shares its top bit, though
	##   7 is one away.
	##
	## A proposal outside an unknown's range is first moved to the nearest end
	## of the range. A truth value is proposed as 0 or anything else. Unknowns
	## past the end of the proposals are the solver's choice, as in `find`.
	##
	## The solver has to settle the proposed bits in this order, so a steered
	## search can take many times longer than `find`, or less. Gives up after
	## `default_budget` conflicts with `Err(GaveUp(effort))`.
	find_near : Vars(v), (v -> Claim), List(U64) -> Try([Found(v), None], Problem)
	find_near = |vars, claim, proposed| match find_near_within(vars, claim, proposed, default_budget)? {
		Found(values) => Ok(Found(values))
		None => Ok(None)
		GaveUp(spent) => Err(GaveUp(spent))
	}

	## `find_near` within a budget of conflicts.
	find_near_within : Vars(v), (v -> Claim), List(U64), U64 -> Try([Found(v), None, GaveUp(Effort)], Problem)
	find_near_within = |vars, claim, proposed, budget| {
		compiled = compile(vars, claim, |_| [])?
		match Engine.one_within(compiled, Holding, proposed, budget)? {
			Values(values) => Ok(Found(fill(vars, values)))
			Nothing => Ok(None)
			GaveUp(spent) => Ok(GaveUp(spent))
		}
	}

	## Does the claim hold for every value of its unknowns?
	##
	## `Proved` means it does. `Refuted` carries values that make it false,
	## and `Crashes` values on which evaluating it overflows or divides by
	## zero. The example at the top of this module is a `Crashes`.
	##
	## Gives up after `default_budget` conflicts with `Err(GaveUp(effort))`:
	## the claim is then neither proved nor refuted.
	prove : Vars(v), (v -> Claim) -> Try([Proved, Refuted(v), Crashes(v)], Problem)
	prove = |vars, claim| match prove_within(vars, claim, default_budget)? {
		Proved => Ok(Proved)
		Refuted(values) => Ok(Refuted(values))
		Crashes(values) => Ok(Crashes(values))
		GaveUp(spent) => Err(GaveUp(spent))
	}

	## `prove` within a budget of conflicts. `GaveUp` means the budget ran out
	## first: nothing is known about the claim, and `effort` says what was
	## spent. The budget is exact: the solver stops at the conflict that uses
	## it up, so `effort.conflicts` is the budget.
	##
	## ```roc
	## Solve.prove_within({ a: Solve.uint(10), b: Solve.uint(10) }.Solve, |v| v.a.times_wrap(v.b).eq(v.b.times_wrap(v.a)), 1_000)
	## ```
	##
	## gives `Ok(GaveUp({ conflicts: 1000, .. }))` quickly. The whole proof
	## takes 913,801 conflicts, about forty seconds of an optimised build.
	prove_within : Vars(v), (v -> Claim), U64 -> Try([Proved, Refuted(v), Crashes(v), GaveUp(Effort)], Problem)
	prove_within = |vars, claim, budget| {
		compiled = compile(vars, claim, |_| [])?
		match Engine.one_within(compiled, Failing, [], budget)? {
			Nothing => Ok(Proved)
			GaveUp(spent) => Ok(GaveUp(spent))
			Values(values) => match Term.holds(compiled.term, values) {
				Ok(_) => Ok(Refuted(fill(vars, values)))
				Err(_) => Ok(Crashes(fill(vars, values)))
			}
		}
	}

	## Up to `limit` different sets of values that make the claim hold. Fewer
	## than `limit` means these are all there are.
	##
	## ```roc
	## Solve.enumerate({ x: Solve.uint(4), y: Solve.uint(4) }.Solve, |v| (v.x * v.y).eq(12), 100)
	## ```
	##
	## lists the six ways to make 12 from two 4-bit numbers. Gives up after
	## `default_budget` conflicts in all with `Err(GaveUp(effort))`.
	enumerate : Vars(v), (v -> Claim), U64 -> Try(List(v), Problem)
	enumerate = |vars, claim, limit| match enumerate_within(vars, claim, limit, default_budget)? {
		Listed(found) => Ok(found)
		GaveUp(_, spent) => Err(GaveUp(spent))
	}

	## `enumerate` within a budget of conflicts for the whole list. `GaveUp`
	## carries the sets found before the budget ran out, which may not be all.
	enumerate_within : Vars(v), (v -> Claim), U64, U64 -> Try([Listed(List(v)), GaveUp(List(v), Effort)], Problem)
	enumerate_within = |vars, claim, limit, budget| {
		compiled = compile(vars, claim, |_| [])?
		listed = Engine.many_within(compiled, Holding, limit, budget)?
		found = listed.found.map(|values| fill(vars, values))
		match listed.stopped {
			Finished => Ok(Listed(found))
			GaveUp(spent) => Ok(GaveUp(found, spent))
		}
	}

	# -- Asking the same claim many times ------------------------------------

	## A claim built once, to be asked any number of times with `ask`.
	## Building the formula and loading it into a solver is most of the cost
	## of a `find_near`, so a generator that is called again and again should
	## hold one of these, in a top-level constant: the compiler works it out
	## once, when the program is built.
	Prepared(v) :: { vars : Vars(v), ready : Engine.Ready }

	## Build the claim's formula and load it into a solver. Every answer `ask`
	## gives from it makes the claim hold.
	##
	## ```roc
	## ordered = Solve.prepare({ x: Solve.u8, y: Solve.u8 }.Solve, |v| v.x.lt(v.y))
	## ```
	prepare : Vars(v), (v -> Claim) -> Try(Prepared(v), Problem)
	prepare = |vars, claim| prepare_with(vars, claim, |_| [])

	## `prepare`, with further claims over the same unknowns that each query
	## may switch on by their positions in the list. They are built into the
	## formula once and cost a query nothing until it assumes them.
	##
	## ```roc
	## Solve.prepare_with({ x: Solve.u8, y: Solve.u8 }.Solve, |v| v.x.lt(v.y), |v| [(v.x + v.y).eq(100)])
	## ```
	prepare_with : Vars(v), (v -> Claim), (v -> List(Claim)) -> Try(Prepared(v), Problem)
	prepare_with = |vars, claim, extras| {
		compiled = compile(vars, claim, extras)?
		ready = Engine.prepare(compiled, Holding)?
		Ok(Prepared.({ vars, ready }))
	}

	## One query of a prepared claim: proposals to steer towards as in
	## `find_near`, the extra claims that must hold as well, by their
	## positions in the list given to `prepare_with`, and a budget of
	## conflicts.
	Query : { near : List(U64), assuming : List(U64), within : U64 }

	## Values that make a prepared claim hold, and every assumed extra claim
	## with it. The promises of `find_near` hold among the values that do.
	## `None` means no values satisfy the claim together with these extras.
	##
	## ```roc
	## Solve.ask(prepared, { near: [60, 60], assuming: [0], within: 1000 }) == Ok(Found({ x: 48, y: 52 }))
	## ```
	##
	## Every query starts from the claim as it was prepared: no query sees
	## what another one did, so the same query always gives the same answer.
	ask : Prepared(v), Query -> Try([Found(v), None, GaveUp(Effort)], Problem)
	ask = |Prepared.(prepared), query| {
		match Engine.respond(prepared.ready, query.near, query.assuming, query.within)? {
			Values(values) => Ok(Found(fill(prepared.vars, values)))
			Nothing => Ok(None)
			GaveUp(spent) => Ok(GaveUp(spent))
		}
	}

	# -- Looking at a claim without solving it -------------------------------

	## Run the claim on ordinary values, one per unknown in declaration order
	## (0 or 1 for a truth value). This is the plain evaluator: no solver is
	## involved, so it is the way to test a term against real Roc code.
	##
	## ```roc
	## Solve.check({ x: Solve.u8, y: Solve.u8 }.Solve, |v| (v.x + v.y).eq(44), [200, 100]) == Err(Overflow)
	## ```
	##
	## `Err(Overflow)` and `Err(DivByZero)` mean the claim crashes on these
	## values. Declared ranges are not enforced here.
	check : Vars(v), (v -> Claim), List(U64) -> Try(Bool, Problem)
	check = |Vars.(vars), claim, values| {
		declared = vars(symbolic)
		Claim.(raw) = claim(declared.value)
		term = Term.elaborate(raw)?
		Term.holds(term, values)
	}

	## How large the problem handed to the solver is: the unknowns declared,
	## the bits the solver is free to choose, and the variables and clauses of
	## the formula. A formula of a few thousand clauses loads in
	## milliseconds; the number of clauses says little about how long a
	## search takes.
	measure : Vars(v), (v -> Claim) -> Try({ unknowns : U64, bits : U64, variables : U64, clauses : U64 }, Problem)
	measure = |vars, claim| {
		compiled = compile(vars, claim, |_| [])?
		Ok(Engine.size(compiled))
	}

	## What answering the question once costs, for choosing a budget: `Find`
	## asks what `find` asks and `Prove` what `prove` asks. Gives up after
	## `default_budget` conflicts like those do.
	##
	## ```roc
	## Solve.effort({ a: Solve.uint(5), b: Solve.uint(5) }.Solve, |v| v.a.times_wrap(v.b).eq(v.b.times_wrap(v.a)), Prove)
	## ```
	effort : Vars(v), (v -> Claim), [Find, Prove] -> Try(Effort, Problem)
	effort = |vars, claim, question| {
		compiled = compile(vars, claim, |_| [])?
		wanted = match question {
			Find => Holding
			Prove => Failing
		}
		Engine.spend(compiled, wanted, default_budget)
	}
}

# -- Internals -------------------------------------------------------------

## What a description of unknowns reads and extends: the unknowns declared so
## far, and, when `concrete` is true, a solution to fill in instead.
Source : { decls : List(Engine.Decl), solved : List(U64), concrete : Bool }

symbolic : Source
symbolic = { decls: [], solved: [], concrete: Bool.False }

## The record of unknowns with a solution written into it.
fill : Solve.Vars(v), List(U64) -> v
fill = |Solve.Vars.(vars), values| vars({ decls: [], solved: values, concrete: Bool.True }).value

compile : Solve.Vars(v), (v -> Solve.Claim), (v -> List(Solve.Claim)) -> Try(Engine.Compiled, Solve.Problem)
compile = |Solve.Vars.(vars), claim, extras| {
	declared = vars(symbolic)
	Solve.Claim.(raw) = claim(declared.value)
	raw_extras = extras(declared.value).map(|Solve.Claim.(term)| term)
	Engine.compile_with(declared.source.decls, raw, raw_extras)
}

# The example at the top of this module, and its repair.
expect Solve.prove(
	{ lo: Solve.u8, hi: Solve.u8 }.Solve,
	|v| {
		mid = (v.lo + v.hi) // 2
		v.lo.lte(v.hi).implies(Solve.all([v.lo.lte(mid), mid.lte(v.hi)]))
	},
) == Ok(Crashes({ lo: 1, hi: 255 }))

expect Solve.prove(
	{ lo: Solve.u8, hi: Solve.u8 }.Solve,
	|v| {
		mid = v.lo + (v.hi - v.lo) // 2
		v.lo.lte(v.hi).implies(Solve.all([v.lo.lte(mid), mid.lte(v.hi)]))
	},
) == Ok(Proved)
