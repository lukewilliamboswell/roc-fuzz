## Signed integers: a `Solve.Uint` is a row of bits, and the `_signed` forms
## read those bits the way `I8` to `I64` do.
import fuzz.Solve

Signed := [].{

	## The textbook absolute value. No annotation, so it could run on an `I32`
	## as well; on terms the comparison and the negation are the signed forms.
	absolute : Solve.Uint -> Solve.Uint
	absolute = |x| Solve.if_else(x.lt_signed(0), Solve.num(0).minus_signed(x), x)

	One : { x : Solve.Uint }

	## Is the absolute value of every `I32` at least zero?
	absolute_is_not_negative : {} -> Try([Proved, Refuted(One), Crashes(One)], Solve.Problem)
	absolute_is_not_negative = |{}| Solve.prove(
		Solve.map(Solve.u32, |x| { x: x }),
		|v| absolute(v.x).gte_signed(0),
	)

	Pair : { a : Solve.Uint, b : Solve.Uint }

	Verdict : Try([Proved, Refuted(Pair), Crashes(Pair)], Solve.Problem)

	pairs : U8 -> Solve.Vars(Pair)
	pairs = |width| { a: Solve.uint(width), b: Solve.uint(width) }.Solve

	## How far apart two `I32`s are, as a `U32`: what `I32.abs_diff` returns.
	## The subtraction wraps on purpose, and the result is read as unsigned.
	distance : Solve.Uint, Solve.Uint -> Solve.Uint
	distance = |a, b| Solve.if_else(b.lte_signed(a), a.minus_wrap(b), b.minus_wrap(a))

	## Is that the true distance? Worked out again in 64 bits, where nothing
	## can overflow, and compared.
	distance_is_exact : {} -> Verdict
	distance_is_exact = |{}| Solve.prove(
		pairs(32),
		|v| {
			wide_a = v.a.to_width_signed(64)
			wide_b = v.b.to_width_signed(64)
			exact = Solve.if_else(wide_b.lte_signed(wide_a), wide_a.minus_signed(wide_b), wide_b.minus_signed(wide_a))
			distance(v.a, v.b).to_width(64).eq(exact)
		},
	)

	## The same question about the tempting version, `(a - b).abs()` with a
	## signed subtraction.
	naive_distance_is_exact : {} -> Verdict
	naive_distance_is_exact = |{}| Solve.prove(
		pairs(32),
		|v| absolute(v.a.minus_signed(v.b)).to_width(64).eq(distance(v.a, v.b).to_width(64)),
	)

	# -- The signed forms against the same things spelled out by hand ---------
	#
	# Proofs written before the signed forms existed built these out of
	# unsigned terms. Each is checked against its signed form below.

	## `a <= b` on `I32`: flip the sign bits and compare as unsigned.
	lte_by_hand : Solve.Uint, Solve.Uint -> Solve.Claim
	lte_by_hand = |a, b| a.bitwise_xor(0x8000_0000).lte(b.bitwise_xor(0x8000_0000))

	## `a.to_i64()` as the 64 bits of the answer.
	widen_by_hand : Solve.Uint -> Solve.Uint
	widen_by_hand = |a| a.to_width(64).bitwise_xor(0x8000_0000).minus_wrap(0x8000_0000)

	## `a - b` on `I32`, crashing when Roc's `-` does.
	minus_by_hand : Solve.Uint, Solve.Uint -> Solve.Uint
	minus_by_hand = |a, b| widen_by_hand(a).minus_wrap(widen_by_hand(b)).plus_wrap(0x8000_0000).to_width(32).bitwise_xor(0x8000_0000)

	## Would `a + b` on `I64` crash?
	plus_overflows_by_hand : Solve.Uint, Solve.Uint -> Solve.Claim
	plus_overflows_by_hand = |a, b| {
		sum = a.plus_wrap(b)
		a.bitwise_xor(sum).bitwise_and(b.bitwise_xor(sum)).shr_wrap(63).eq(1)
	}

	by_hand_is_the_same : {} -> List(Verdict)
	by_hand_is_the_same = |{}| [
		Solve.prove(pairs(32), |v| v.a.lte_signed(v.b).iff(lte_by_hand(v.a, v.b))),
		Solve.prove(pairs(32), |v| v.a.to_width_signed(64).eq(widen_by_hand(v.a))),
		Solve.prove(pairs(32), |v| v.a.minus_overflows_signed(v.b).not().implies(v.a.minus_signed(v.b).eq(minus_by_hand(v.a, v.b)))),
		Solve.prove(pairs(64), |v| v.a.plus_overflows_signed(v.b).iff(plus_overflows_by_hand(v.a, v.b))),
	]
}

## It is not: negating `I32.lowest` overflows, and the solver finds exactly
## that number. `value_signed` reads the bits back as Roc would.
expect Signed.absolute_is_not_negative({}) == Ok(Crashes({ x: 2_147_483_648 }))

expect Solve.Uint.of_width(2_147_483_648, 32).value_signed() == I32.lowest.to_i64()

## The wrapping subtraction read as unsigned is the true distance, for every
## pair of `I32`s.
expect Signed.distance_is_exact({}) == Ok(Proved)

## The signed subtraction crashes before the absolute value is taken.
expect Signed.naive_distance_is_exact({}) == Ok(Crashes({ a: 0, b: 2_147_483_648 }))

## Each signed form is the thing the proofs exemplar spells out by hand.
expect Signed.by_hand_is_the_same({}) == [Ok(Proved), Ok(Proved), Ok(Proved), Ok(Proved)]

# The terms against Roc's own `I32`, on every pair of edge values.
expect {
	edges : List(I32)
	edges = [I32.lowest, I32.lowest + 1, -1_000_000, -2, -1, 0, 1, 2, 1_000_000, I32.highest - 1, I32.highest]
	edges.all(
		|a| edges.all(
			|b| {
				ta = Solve.Uint.from_i32(a)
				tb = Solve.Uint.from_i32(b)
				sum = match I32.plus_try(a, b) {
					Ok(n) => Ok(n.to_i64())
					Err(_) => Err(Overflow)
				}
				product = match I32.times_try(a, b) {
					Ok(n) => Ok(n.to_i64())
					Err(_) => Err(Overflow)
				}
				ta.lt_signed(tb).eval() == Ok(a < b)
					and ta.gte_signed(tb).eval() == Ok(a >= b)
					and ta.plus_signed(tb).eval_signed() == sum
					and ta.times_signed(tb).eval_signed() == product
					and ta.minus_overflows_signed(tb).eval() == Ok(I32.minus_try(a, b) == Err(Overflow))
					and ta.to_width_signed(64).eval_signed() == Ok(a.to_i64())
					and Signed.distance(ta, tb).eval() == Ok(I32.abs_diff(a, b).to_u64())
			},
		),
	)
}
