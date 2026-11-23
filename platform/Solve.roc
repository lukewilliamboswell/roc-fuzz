## A small constraint toolbox: state a fact about integers of a fixed width,
## then ask for values that make it true, or for a proof that no values make
## it false.
##
## ```roc
## import solve.Solve
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
## The answer covers every pair of bytes, and here it says the addition
## overflows. Written as `v.lo + (v.hi - v.lo) // 2` the same claim is `Proved`.
##
## ## Terms
##
## The solver works on terms, not on Roc code. A `Uint` is a number not yet
## chosen and a `Claim` is a fact about such numbers. `+ - * // %` and number
## literals work on `Uint`. Comparisons are methods (`lt`, `lte`, `eq`, ...)
## because Roc's `<` must return a `Bool`, and `Solve.all`, `Solve.any`,
## `implies` and `Solve.if_else` stand in for `and`, `or` and `if`.
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
##   around instead and the `_overflows` forms ask whether the crash would
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
## (`Crashes`). So a proof is also a proof that nothing overflowed.
##
## ## Sharing
##
## A Roc name is not a name inside a term. After `m = a + b`, every use of
## `m` puts the whole of `a + b` into the term again. That is usually
## harmless, but a value worked out step by step from the step before, like a
## running maximum, then doubles at every step: twenty steps make a term of a
## million parts. `x.shared()` is the fix. It means exactly what `x` means,
## guards and crashes included, and is worked out once wherever it appears:
## in the formula, in the plain evaluator, and in every check.
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
##   nothing about the claim. It says what was spent.
## - `find`, `find_near`, `prove` and `enumerate` use `default_budget`, a
##   million conflicts, and report running out as `Err(GaveUp(effort))`. A
##   question they used to answer they still answer, with the same values.
##   One they could not answer now fails after about a minute of an optimised
##   build instead of never returning.
## - A search that ends inside its budget is the same search whatever the
##   budget was. A larger budget never changes an answer.
## - `Solve.no_limit` is a budget that never runs out.
##
## The default backend of `roc test` runs the solver thirty to a hundred and
## fifty times slower than `--opt=speed`. Loading is not the cost there: a
## formula of a few thousand clauses (`measure` counts them) loads in
## milliseconds. Claims that need a few thousand conflicts are comfortable.
## For anything larger use `--opt=speed`, or give the test a small budget of
## its own: a million conflicts on the default backend is tens of minutes.
##
## ## What to trust
##
## Every set of values this module returns has been run through the plain
## evaluator (`Term.eval`) before it is returned, so `Found`, `Refuted` and
## `Crashes` never depend on the solver being right. `Proved` and `None` do:
## they say the solver found nothing. `GaveUp` claims nothing. `Validate.roc`
## compares all of it with brute-force enumeration at small widths: the
## verdicts, the order `find_near` promises, the answers under a budget, and
## shared terms against the same terms written out.
import Term
import Engine

Solve := [].{

	## A symbolic integer of a fixed width: a row of bits, read as an
	## unsigned number except by the `_signed` forms.
	Uint := [U(Term)].{
		from_numeral : Numeral -> Try(Uint, [InvalidNumeral(Str)])
		from_numeral = |numeral| match U64.from_numeral(numeral) {
			Ok(number) => Ok(U(Lit(number)))
			Err(problem) => Err(problem)
		}

		## A `U8` as a term 8 bits wide. Likewise the other three.
		from_u8 : U8 -> Uint
		from_u8 = |number| U(Const(number.to_u64(), 8))

		from_u16 : U16 -> Uint
		from_u16 = |number| U(Const(number.to_u64(), 16))

		from_u32 : U32 -> Uint
		from_u32 = |number| U(Const(number.to_u64(), 32))

		from_u64 : U64 -> Uint
		from_u64 = |number| U(Const(number, 64))

		## A number as a term of the given width in bits.
		of_width : U64, U8 -> Uint
		of_width = |number, width| U(Const(number, width))

		## `a + b`. Crashes when the sum does not fit the width.
		plus : Uint, Uint -> Uint
		plus = |U(a), U(b)| U(Arith(Plus, a, b))

		## `a - b`. Crashes when `b` is larger than `a`.
		minus : Uint, Uint -> Uint
		minus = |U(a), U(b)| U(Arith(Minus, a, b))

		## `a * b`. Crashes when the product does not fit the width.
		times : Uint, Uint -> Uint
		times = |U(a), U(b)| U(Arith(Times, a, b))

		## `a // b`. Crashes when `b` is zero. A divisor that is a constant
		## power of two costs nothing; any other divisor costs a multiplier.
		div_trunc_by : Uint, Uint -> Uint
		div_trunc_by = |U(a), U(b)| U(Arith(Div, a, b))

		## `a % b`. Crashes when `b` is zero.
		rem_by : Uint, Uint -> Uint
		rem_by = |U(a), U(b)| U(Arith(Rem, a, b))

		plus_wrap : Uint, Uint -> Uint
		plus_wrap = |U(a), U(b)| U(Arith(PlusWrap, a, b))

		minus_wrap : Uint, Uint -> Uint
		minus_wrap = |U(a), U(b)| U(Arith(MinusWrap, a, b))

		times_wrap : Uint, Uint -> Uint
		times_wrap = |U(a), U(b)| U(Arith(TimesWrap, a, b))

		## Would `a + b` crash?
		plus_overflows : Uint, Uint -> Claim
		plus_overflows = |U(a), U(b)| C(Overflows(Plus, a, b))

		minus_overflows : Uint, Uint -> Claim
		minus_overflows = |U(a), U(b)| C(Overflows(Minus, a, b))

		times_overflows : Uint, Uint -> Claim
		times_overflows = |U(a), U(b)| C(Overflows(Times, a, b))

		bitwise_and : Uint, Uint -> Uint
		bitwise_and = |U(a), U(b)| U(Arith(BitAnd, a, b))

		bitwise_or : Uint, Uint -> Uint
		bitwise_or = |U(a), U(b)| U(Arith(BitOr, a, b))

		bitwise_xor : Uint, Uint -> Uint
		bitwise_xor = |U(a), U(b)| U(Arith(BitXor, a, b))

		bitwise_not : Uint -> Uint
		bitwise_not = |U(a)| U(BitNot(a))

		## Shift left by a fixed count, taken modulo the width as in Roc.
		shl_wrap : Uint, U8 -> Uint
		shl_wrap = |U(a), count| U(Shift(Left, a, count))

		## Shift right by a fixed count, taken modulo the width as in Roc.
		shr_wrap : Uint, U8 -> Uint
		shr_wrap = |U(a), count| U(Shift(Right, a, count))

		## The same number at another width. Crashes when it does not fit.
		to_width : Uint, U8 -> Uint
		to_width = |U(a), width| U(Resize(Checked, a, width))

		## The low bits of the number at another width.
		to_width_wrap : Uint, U8 -> Uint
		to_width_wrap = |U(a), width| U(Resize(Wrap, a, width))

		## The same number, to be worked out once however often it is used.
		## See "Sharing" at the top of this file.
		shared : Uint -> Uint
		shared = |U(a)| U(Term.shared(a))

		## An `I8` as its 8 bits. Likewise the other three.
		from_i8 : I8 -> Uint
		from_i8 = |number| U(Const(number.to_u8_wrap().to_u64(), 8))

		from_i16 : I16 -> Uint
		from_i16 = |number| U(Const(number.to_u16_wrap().to_u64(), 16))

		from_i32 : I32 -> Uint
		from_i32 = |number| U(Const(number.to_u32_wrap().to_u64(), 32))

		from_i64 : I64 -> Uint
		from_i64 = |number| U(Const(number.to_u64_wrap(), 64))

		## `a + b` on signed integers. Crashes when the sum does not fit the
		## width as a signed number, as `I32`'s `+` does.
		plus_signed : Uint, Uint -> Uint
		plus_signed = |U(a), U(b)| U(Signed(Plus, a, b))

		## `a - b` on signed integers. Crashes when the difference does not fit.
		minus_signed : Uint, Uint -> Uint
		minus_signed = |U(a), U(b)| U(Signed(Minus, a, b))

		## `a * b` on signed integers. Crashes when the product does not fit.
		## Built from a multiplier of twice the width, so it costs several
		## times what `times` costs.
		times_signed : Uint, Uint -> Uint
		times_signed = |U(a), U(b)| U(Signed(Times, a, b))

		## Would `a + b` on signed integers crash?
		plus_overflows_signed : Uint, Uint -> Claim
		plus_overflows_signed = |U(a), U(b)| C(SignedOverflows(Plus, a, b))

		minus_overflows_signed : Uint, Uint -> Claim
		minus_overflows_signed = |U(a), U(b)| C(SignedOverflows(Minus, a, b))

		times_overflows_signed : Uint, Uint -> Claim
		times_overflows_signed = |U(a), U(b)| C(SignedOverflows(Times, a, b))

		## The same signed number at another width. Widening copies the sign
		## bit, as `I32.to_i64` does. Narrowing crashes when it does not fit;
		## `to_width_wrap` keeps the low bits instead, as `to_i8_wrap` does.
		to_width_signed : Uint, U8 -> Uint
		to_width_signed = |U(a), width| U(SignedResize(a, width))

		## `a < b` on signed integers.
		lt_signed : Uint, Uint -> Claim
		lt_signed = |U(a), U(b)| C(SignedCompare(Lt, a, b))

		lte_signed : Uint, Uint -> Claim
		lte_signed = |U(a), U(b)| C(SignedCompare(Lte, a, b))

		gt_signed : Uint, Uint -> Claim
		gt_signed = |U(a), U(b)| C(SignedCompare(Lt, b, a))

		gte_signed : Uint, Uint -> Claim
		gte_signed = |U(a), U(b)| C(SignedCompare(Lte, b, a))

		eq : Uint, Uint -> Claim
		eq = |U(a), U(b)| C(Compare(Eq, a, b))

		neq : Uint, Uint -> Claim
		neq = |U(a), U(b)| C(Not(Compare(Eq, a, b)))

		lt : Uint, Uint -> Claim
		lt = |U(a), U(b)| C(Compare(Lt, a, b))

		lte : Uint, Uint -> Claim
		lte = |U(a), U(b)| C(Compare(Lte, a, b))

		gt : Uint, Uint -> Claim
		gt = |U(a), U(b)| C(Compare(Lt, b, a))

		gte : Uint, Uint -> Claim
		gte = |U(a), U(b)| C(Compare(Lte, b, a))

		## Run a term that has no unknowns left in it.
		eval : Uint -> Try(U64, Problem)
		eval = |U(raw)| {
			term = Term.elaborate(raw)?
			match Term.eval(term, [])? {
				Word(number, _) => Ok(number)
				Bit(_) => Err(Malformed)
			}
		}

		## The number a solved unknown stands for. The records inside `Found`,
		## `Refuted` and `Crashes` hold nothing but such numbers.
		##
		## Crashes on a term that still has unknowns in it or that overflows;
		## use `eval` when that can happen.
		value : Uint -> U64
		value = |U(term)| match term {
			Const(number, _) => number
			Lit(number) => number
			_ => match eval(U(term)) {
				Ok(number) => number
				Err(_) => {
					crash "Solve.Uint.value: the term has no value; use Uint.eval"
				}
			}
		}

		## `eval`, with the number read as a signed integer of its width.
		eval_signed : Uint -> Try(I64, Problem)
		eval_signed = |U(raw)| {
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
		## written `Refuted({ awaited: 65_536, frame: 0 })`.
		is_eq : Uint, Uint -> Bool
		is_eq = |U(a), U(b)| match (a, b) {
			(Const(x, _), Lit(y)) => x == y
			(Lit(x), Const(y, _)) => x == y
			_ => a == b
		}

		to_inspect : Uint -> Str
		to_inspect = |U(term)| match term {
			Const(number, _) => number.to_str()
			Lit(number) => number.to_str()
			_ => Str.inspect(term)
		}
	}

	## A symbolic truth value: a fact about numbers not yet chosen.
	Claim := [C(Term)].{
		is_eq : _

		not : Claim -> Claim
		not = |C(a)| C(Not(a))

		## `!a or b`: whenever `a` is true, `b` is too. `b` is only evaluated
		## when `a` is true.
		implies : Claim, Claim -> Claim
		implies = |C(a), C(b)| C(Implies(a, b))

		## Both are true or both are false.
		iff : Claim, Claim -> Claim
		iff = |C(a), C(b)| C(Same(a, b))

		## `a and b`. `Solve.all` takes any number of claims.
		both : Claim, Claim -> Claim
		both = |C(a), C(b)| C(All([a, b]))

		## `a or b`. `Solve.any` takes any number of claims.
		either : Claim, Claim -> Claim
		either = |C(a), C(b)| C(Any([a, b]))

		## The same claim, to be worked out once however often it is used.
		shared : Claim -> Claim
		shared = |C(a)| C(Term.shared(a))

		## Run a claim that has no unknowns left in it.
		eval : Claim -> Try(Bool, Problem)
		eval = |C(raw)| {
			term = Term.elaborate(raw)?
			Term.holds(term, [])
		}

		## The answer a solved truth value stands for. Crashes like `Uint.value`.
		value : Claim -> Bool
		value = |C(term)| match term {
			Truth(answer) => answer
			_ => match eval(C(term)) {
				Ok(answer) => answer
				Err(_) => {
					crash "Solve.Claim.value: the term has no value; use Claim.eval"
				}
			}
		}

		to_inspect : Claim -> Str
		to_inspect = |C(term)| match term {
			Truth(answer) => if answer {
				"True"
			} else {
				"False"
			}
			_ => Str.inspect(term)
		}
	}

	## Why a query could not be answered. `Overflow` and `DivByZero` come only
	## from running a term on values (`check`, `eval`). `Solver` and
	## `Disagreement` are bugs in this package or the one beneath it. The rest
	## say the terms themselves are ill-formed.
	Problem : Term.Fault

	# -- Building terms ------------------------------------------------------

	## A number known only when the program runs, as a literal: it takes the
	## width of what it meets, like `1` in `x + 1`.
	num : U64 -> Uint
	num = |value| U(Lit(value))

	## A `Bool` as a claim.
	truth : Bool -> Claim
	truth = |value| C(Truth(value))

	## Every claim is true. Later claims are only evaluated while the earlier
	## ones are true, as with `and`.
	all : List(Claim) -> Claim
	all = |claims| C(All(claims.map(|C(term)| term)))

	## At least one claim is true. Later claims are only evaluated while the
	## earlier ones are false, as with `or`.
	any : List(Claim) -> Claim
	any = |claims| C(Any(claims.map(|C(term)| term)))

	## `if condition { then } else { otherwise }` on numbers. Only the chosen
	## side is evaluated.
	if_else : Claim, Uint, Uint -> Uint
	if_else = |C(condition), U(then), U(otherwise)| U(Choose(condition, then, otherwise))

	## `if condition { then } else { otherwise }` on claims.
	if_else_claim : Claim, Claim, Claim -> Claim
	if_else_claim = |C(condition), C(then), C(otherwise)| C(Choose(condition, then, otherwise))

	# -- Declaring unknowns --------------------------------------------------

	## A description of the unknowns of a problem, giving a value of type `v`
	## to state claims about. Combine several with the record builder:
	##
	## ```roc
	## { start: Solve.u16, count: Solve.u16_in(1, 512), urgent: Solve.bool }.Solve
	## ```
	##
	## The same description is read twice: once to hand out unknowns, and once
	## more with a solution, to hand the same record back with its numbers
	## filled in. Unknowns are numbered in the order the fields are written.
	Vars(v) : Source -> { value : v, source : Source }

	Source : { decls : List(Engine.Decl), solved : List(U64), concrete : Bool }

	## What the record builder calls to combine two fields.
	map2 : Vars(a), Vars(b), (a, b -> c) -> Vars(c)
	map2 = |first, second, combine| |source| {
		left = first(source)
		right = second(left.source)
		{ value: combine(left.value, right.value), source: right.source }
	}

	## Change the value a description gives, for example to a tuple or to a
	## nominal type.
	map : Vars(a), (a -> b) -> Vars(b)
	map = |vars, change| |source| {
		made = vars(source)
		{ value: change(made.value), source: made.source }
	}

	## An unknown of `width` bits, anywhere from `lo` to `hi` inclusive.
	##
	## A narrow range in a wide type is cheap: `Solve.u64_in(0, 999)` behaves
	## like a `U64` in arithmetic but gives the solver only ten bits to choose.
	uint_in : U8, U64, U64 -> Vars(Uint)
	uint_in = |width, lo, hi| |source| {
		id = source.decls.len()
		value = if source.concrete {
			U(Const(source.solved.get(id) ?? 0, width))
		} else {
			U(Var(id, width))
		}
		{ value, source: { ..source, decls: source.decls.append({ sort: Number(width), lo, hi }) } }
	}

	## An unknown of `width` bits.
	uint : U8 -> Vars(Uint)
	uint = |width| uint_in(width, 0, Term.mask(width))

	u8 : Vars(Uint)
	u8 = uint(8)

	u16 : Vars(Uint)
	u16 = uint(16)

	u32 : Vars(Uint)
	u32 = uint(32)

	u64 : Vars(Uint)
	u64 = uint(64)

	u8_in : U64, U64 -> Vars(Uint)
	u8_in = |lo, hi| uint_in(8, lo, hi)

	u16_in : U64, U64 -> Vars(Uint)
	u16_in = |lo, hi| uint_in(16, lo, hi)

	u32_in : U64, U64 -> Vars(Uint)
	u32_in = |lo, hi| uint_in(32, lo, hi)

	u64_in : U64, U64 -> Vars(Uint)
	u64_in = |lo, hi| uint_in(64, lo, hi)

	## `count` unknowns of the same kind, declared one after another, as a
	## list.
	several : Vars(item), U64 -> Vars(List(item))
	several = |one, count| |source| {
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
	}

	## An unknown truth value.
	bool : Vars(Claim)
	bool = |source| {
		id = source.decls.len()
		value = if source.concrete {
			C(Truth((source.solved.get(id) ?? 0) != 0))
		} else {
			C(Flag(id))
		}
		{ value, source: { ..source, decls: source.decls.append({ sort: Flag, lo: 0, hi: 1 }) } }
	}

	# -- Queries -------------------------------------------------------------

	## What a search cost, in the solver's own counters. The counters depend
	## only on the question, never on the machine or the build, so a budget
	## that is enough once is enough every time.
	Effort : Engine.Effort

	## The budget of the queries that do not take one: a million conflicts,
	## which an optimised build spends in about a minute. When the number was
	## chosen, the hardest proof among the tests that use this package needed
	## 22,562.
	default_budget : U64
	default_budget = 1_000_000

	## A budget that never runs out, for `prove_within` and the other
	## `_within` queries: the query returns when the solver does.
	no_limit : U64
	no_limit = Engine.no_limit

	## Values that make the claim hold, or `None` when there are none. Which
	## values, when there are several, is the solver's choice: the same every
	## time, but nothing more is promised. `find_near` promises more.
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
		compiled = compile(vars, claim)?
		match Engine.one_within(compiled, Holding, proposed, budget)? {
			Values(values) => Ok(Found(fill(vars, values)))
			Nothing => Ok(None)
			GaveUp(spent) => Ok(GaveUp(spent))
		}
	}

	## Does the claim hold for every value of its unknowns?
	##
	## `Refuted` carries values that make it false, and `Crashes` values on
	## which evaluating it overflows or divides by zero.
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
	## it up, so `effort.conflicts` is the budget. A search that needs fewer
	## conflicts than the budget is the same search whatever the budget, so a
	## larger budget never changes an answer that was already given.
	prove_within : Vars(v), (v -> Claim), U64 -> Try([Proved, Refuted(v), Crashes(v), GaveUp(Effort)], Problem)
	prove_within = |vars, claim, budget| {
		compiled = compile(vars, claim)?
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
	## Gives up after `default_budget` conflicts in all with
	## `Err(GaveUp(effort))`.
	enumerate : Vars(v), (v -> Claim), U64 -> Try(List(v), Problem)
	enumerate = |vars, claim, limit| match enumerate_within(vars, claim, limit, default_budget)? {
		Listed(found) => Ok(found)
		GaveUp(_, spent) => Err(GaveUp(spent))
	}

	## `enumerate` within a budget of conflicts for the whole list. `GaveUp`
	## carries the sets found before the budget ran out, which may not be all.
	enumerate_within : Vars(v), (v -> Claim), U64, U64 -> Try([Listed(List(v)), GaveUp(List(v), Effort)], Problem)
	enumerate_within = |vars, claim, limit, budget| {
		compiled = compile(vars, claim)?
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
	## hold one of these.
	Prepared(v) : { vars : Vars(v), held : [Loaded(Engine.Ready), Built(Engine.Compiled)] }

	## Build the claim's formula and load it into a solver. Every answer `ask`
	## gives from it makes the claim hold.
	prepare : Vars(v), (v -> Claim) -> Try(Prepared(v), Problem)
	prepare = |vars, claim| prepare_with(vars, claim, |_| [])

	## `prepare`, with further claims over the same unknowns that each query
	## may switch on. They are built into the formula once and cost a query
	## nothing until it assumes them.
	prepare_with : Vars(v), (v -> Claim), (v -> List(Claim)) -> Try(Prepared(v), Problem)
	prepare_with = |vars, claim, extras| {
		compiled = compile_with(vars, claim, extras)?
		ready = Engine.prepare(compiled, Holding)?
		Ok({ vars, held: Loaded(ready) })
	}

	## `prepare_with` that stops before the solver: the formula is built and
	## kept, and each `ask` loads it into a fresh solver. Answers are the same.
	## A query costs more this way and holding it costs a little less. That
	## used to matter in a top-level constant, which the compiler works out:
	## loading a large formula there took minutes. It now takes a tenth of a
	## second for 38,000 clauses (`bench/held.roc`), so `prepare_with` is the
	## form to hold.
	prepare_unloaded : Vars(v), (v -> Claim), (v -> List(Claim)) -> Try(Prepared(v), Problem)
	prepare_unloaded = |vars, claim, extras| {
		compiled = compile_with(vars, claim, extras)?
		Ok({ vars, held: Built(compiled) })
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
	## Every query starts from the claim as it was prepared: no query sees
	## what another one did, so the same query always gives the same answer.
	ask : Prepared(v), Query -> Try([Found(v), None, GaveUp(Effort)], Problem)
	ask = |prepared, query| {
		answer = match prepared.held {
			Loaded(ready) => Engine.respond(ready, query.near, query.assuming, query.within)?
			Built(compiled) => Engine.fresh(compiled, Holding, query.near, query.assuming, query.within)?
		}
		match answer {
			Values(values) => Ok(Found(fill(prepared.vars, values)))
			Nothing => Ok(None)
			GaveUp(spent) => Ok(GaveUp(spent))
		}
	}

	## Run the claim on ordinary values, one per unknown in declaration order
	## (0 or 1 for a truth value). This is the plain evaluator: no solver is
	## involved, so it is the way to test a term against real Roc code.
	##
	## `Err(Overflow)` and `Err(DivByZero)` mean the claim crashes on these
	## values. Declared ranges are not enforced here.
	check : Vars(v), (v -> Claim), List(U64) -> Try(Bool, Problem)
	check = |vars, claim, values| {
		declared = vars(symbolic)
		C(raw) = claim(declared.value)
		term = Term.elaborate(raw)?
		Term.holds(term, values)
	}

	## How large the problem handed to the solver is: the unknowns declared,
	## the bits the solver is free to choose, and the variables and clauses of
	## the formula.
	measure : Vars(v), (v -> Claim) -> Try({ unknowns : U64, bits : U64, variables : U64, clauses : U64 }, Problem)
	measure = |vars, claim| {
		compiled = compile(vars, claim)?
		Ok(Engine.size(compiled))
	}

	## The solver's own counters after a `find` (`Holding`) or a `prove`
	## (`Failing`), for judging how hard a problem was and what budget it
	## needs. Gives up after `default_budget` conflicts like the queries.
	effort : Vars(v), (v -> Claim), [Holding, Failing] -> Try({ answer : [Sat, Unsat], counters : Str }, Problem)
	effort = |vars, claim, wanted| {
		compiled = compile(vars, claim)?
		Engine.counters(compiled, wanted, default_budget)
	}

	# -- Internals -----------------------------------------------------------

	symbolic : Source
	symbolic = { decls: [], solved: [], concrete: Bool.False }

	## The record of unknowns with a solution written into it.
	fill : Vars(v), List(U64) -> v
	fill = |vars, values| vars({ decls: [], solved: values, concrete: Bool.True }).value

	compile : Vars(v), (v -> Claim) -> Try(Engine.Compiled, Problem)
	compile = |vars, claim| {
		declared = vars(symbolic)
		C(raw) = claim(declared.value)
		Engine.compile(declared.source.decls, raw)
	}

	compile_with : Vars(v), (v -> Claim), (v -> List(Claim)) -> Try(Engine.Compiled, Problem)
	compile_with = |vars, claim, extras| {
		declared = vars(symbolic)
		C(raw) = claim(declared.value)
		raw_extras = extras(declared.value).map(|C(term)| term)
		Engine.compile_with(declared.source.decls, raw, raw_extras)
	}
}

# The example at the top of this file, and its repair.
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

# Unknowns of every kind in one record, and ordinary values back out.
expect {
	answer = Solve.find(
		{ small: Solve.u8_in(10, 20), wide: Solve.u64, on: Solve.bool }.Solve,
		|v| Solve.all([v.on, v.small.gt(18), v.wide.eq(v.small.to_width(64) * 1_000_000_000_000)]),
	)
	match answer {
		Ok(Found(v)) => v.on.value() and v.small.value() > 18 and v.small.value() <= 20 and v.wide.value() == v.small.value() * 1_000_000_000_000
		_ => Bool.False
	}
}

# No values at all is an answer too.
expect Solve.find({ x: Solve.u8, y: Solve.u8 }.Solve, |v| Solve.all([v.x.lt(v.y), v.y.lt(v.x)])) == Ok(None)

# A proposal that already fits comes back as it is.
expect Solve.find_near({ x: Solve.u16, y: Solve.u16 }.Solve, |v| v.x.lt(v.y), [1000, 2000]) == Ok(Found({ x: 1000, y: 2000 }))

# All the answers, when there are few: 12 as a product of two 4-bit numbers.
expect {
	pairs = Solve.enumerate({ x: Solve.uint(4), y: Solve.uint(4) }.Solve, |v| (v.x * v.y).eq(12), 100)
	match pairs {
		Ok(found) => found.len() == 6 and found.all(|v| v.x.value() * v.y.value() == 12)
		Err(_) => Bool.False
	}
}

# The plain evaluator on ordinary values: no solver involved.
expect Solve.check({ x: Solve.u8, y: Solve.u8 }.Solve, |v| (v.x + v.y).eq(44), [40, 4]) == Ok(Bool.True)
expect Solve.check({ x: Solve.u8, y: Solve.u8 }.Solve, |v| (v.x + v.y).eq(44), [200, 100]) == Err(Overflow)
expect Solve.check({ x: Solve.u8, y: Solve.u8 }.Solve, |v| v.x.plus_wrap(v.y).eq(44), [200, 100]) == Ok(Bool.True)
expect (Solve.Uint.from_u8(250) + 5).eval() == Ok(255)
expect (Solve.Uint.from_u8(250) + 6).eval() == Err(Overflow)
expect Solve.if_else(Solve.Uint.from_u8(3).lt(4), 10, 20).value() == 10

# Ill-formed terms are reported, whatever the question.
expect Solve.prove({ x: Solve.u8, y: Solve.u16 }.Solve, |v| v.x.lt(v.y)) == Err(WidthMismatch({ left: 8, right: 16 }))
expect Solve.prove({ x: Solve.u8, y: Solve.u16 }.Solve, |v| v.x.to_width(16).lte(v.y.plus_wrap(v.x.to_width(16)))) == Ok(Refuted({ x: 1, y: 65535 }))
expect Solve.find(Solve.map(Solve.u8, |x| { x: x }), |v| v.x.gt(300)) == Err(LiteralTooLarge({ literal: 300, width: 8 }))
expect Solve.find(Solve.map(Solve.u8_in(9, 3), |x| { x: x }), |v| v.x.gt(1)) == Err(BadRange({ lo: 9, hi: 3, width: 8 }))

# Steering follows the rule, not the distance: with only 7 and 12 possible,
# a proposal of 8 gives 12, which keeps its top bit, though 7 is one away.
expect Solve.find_near(Solve.map(Solve.uint(4), |x| { x: x }), |v| Solve.any([v.x.eq(7), v.x.eq(12)]), [8]) == Ok(Found({ x: 12 }))
expect Solve.find_near(Solve.map(Solve.uint(4), |x| { x: x }), |v| Solve.any([v.x.eq(7), v.x.eq(12)]), [3]) == Ok(Found({ x: 7 }))

# A proposal outside the range counts as the nearest end of the range, and
# proposing 0 for an unknown that can be 0 asks for its smallest value.
expect Solve.find_near({ x: Solve.u8_in(3, 200), y: Solve.u8 }.Solve, |v| (v.x + v.y).gt(250), [0, 0]) == Ok(Found({ x: 3, y: 248 }))
expect match Solve.find_near({ x: Solve.u8_in(3, 200), y: Solve.u8 }.Solve, |v| (v.x + v.y).gt(250), [999]) {
	Ok(Found(v)) => v.x.value() == 200 and v.y.value() > 50 and v.y.value() < 56
	_ => Bool.False
}

# A budget too small for the question is answered with what was spent. No
# budget is needed to see that a claim with no unknowns left is true.
expect {
	hard = |budget| Solve.prove_within({ a: Solve.u8, b: Solve.u8 }.Solve, |v| v.a.times_wrap(v.b).eq(v.b.times_wrap(v.a)), budget)
	hard(50) == Ok(GaveUp({ conflicts: 50, decisions: 98, propagations: 2631, restarts: 0 }))
		and Solve.prove_within({ a: Solve.u8, b: Solve.u8 }.Solve, |v| v.a.lte(v.a), 0) == Ok(Proved)
}

# A prepared claim answers many queries: each one steered on its own, and
# with or without the extra claim the claim was prepared with.
expect {
	prepared = Solve.prepare_with({ x: Solve.u8, y: Solve.u8 }.Solve, |v| v.x.lt(v.y), |v| [(v.x + v.y).eq(100)])
	kept = Solve.prepare_unloaded({ x: Solve.u8, y: Solve.u8 }.Solve, |v| v.x.lt(v.y), |v| [(v.x + v.y).eq(100)])
	[prepared, kept].all(
		|held| match held {
			Ok(formula) => {
				ask = |near, assuming| Solve.ask(formula, { near, assuming, within: 1000 })
				ask([10, 20], []) == Ok(Found({ x: 10, y: 20 }))
					and ask([20, 10], []) == Ok(Found({ x: 20, y: 26 }))
					and ask([10, 20], [0]) == Ok(Found({ x: 10, y: 90 }))
					and ask([60, 60], [0]) == Ok(Found({ x: 48, y: 52 }))
					and ask([10, 20], [1]) == Err(NoSuchExtra(1))
					and ask([10, 20], []) == Ok(Found({ x: 10, y: 20 }))
			}
			Err(_) => Bool.False
		},
	)
}

# A shared term means what the term means: the same proof, the same crash at
# the same place, and a guard still protects it.
expect {
	pair = { x: Solve.u8, y: Solve.u8 }.Solve
	quotient = |v| (v.x // v.y).shared()
	Solve.prove(pair, |v| v.y.neq(0).implies(Solve.all([quotient(v).lte(v.x), (quotient(v) * v.y).lte(v.x)]))) == Ok(Proved)
		and Solve.prove(pair, |v| Solve.all([quotient(v).lte(v.x), (quotient(v) * v.y).lte(v.x)])) == Ok(Crashes({ x: 0, y: 0 }))
		and Solve.check(pair, |v| quotient(v).eq(quotient(v)), [7, 0]) == Err(DivByZero)
		and (Solve.Uint.from_u8(200).shared() + Solve.Uint.from_u8(55).shared()).eval() == Ok(255)
}

# Signed forms read the same bits as `I8` does: 200 is -56.
expect Solve.Uint.from_u8(200).lt_signed(Solve.Uint.from_u8(3)).eval() == Ok(Bool.True)
expect Solve.Uint.from_u8(200).lt(Solve.Uint.from_u8(3)).eval() == Ok(Bool.False)
expect Solve.Uint.from_i8(-56).value() == 200 and Solve.Uint.from_u8(200).value_signed() == -56
expect Solve.Uint.from_i8(100).plus_signed(Solve.Uint.from_i8(27)).eval_signed() == Ok(127)
expect Solve.Uint.from_i8(100).plus_signed(Solve.Uint.from_i8(28)).eval_signed() == Err(Overflow)
expect Solve.Uint.from_i8(-56).to_width_signed(16).eval() == Ok(65_480)
expect Solve.Uint.from_i16(-200).to_width_signed(8).eval() == Err(Overflow)

# For every `I8`, negating twice gives the number back unless negating
# crashes, and it crashes only at -128.
expect Solve.prove(
	Solve.map(Solve.u8, |x| { x: x }),
	|v| {
		zero = Solve.Uint.from_i8(0)
		zero.minus_overflows_signed(v.x).iff(v.x.eq(128)).both(v.x.neq(128).implies(zero.minus_signed(zero.minus_signed(v.x)).eq(v.x)))
	},
) == Ok(Proved)
