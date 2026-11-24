## A bit trick against its obvious definition.
import fuzz.Solve

BitTricks := [].{

	## The average of two numbers without a wider type: the bits they share,
	## plus half the bits they do not. Runs on `U32` and on `Solve.Uint`.
	average = |a, b| a.bitwise_and(b) + a.bitwise_xor(b).shr_wrap(1)

	Pair : { a : Solve.Uint, b : Solve.Uint }

	## The trick equals `(a + b) // 2` done with a bit to spare, for all 2^64
	## pairs, and never overflows.
	average_is_exact : {} -> Try([Proved, Refuted(Pair), Crashes(Pair)], Solve.Problem)
	average_is_exact = |{}| Solve.prove(
		{ a: Solve.u32, b: Solve.u32 }.Solve,
		|v| average(v.a, v.b).to_width(33).eq((v.a.to_width(33) + v.b.to_width(33)) // 2),
	)

	## `x & (x - 1) == 0` picks out the powers of two, once zero is excluded.
	## The guard comes first, so `x - 1` is never evaluated at zero.
	power_of_two_trick : Solve.Uint -> Solve.Claim
	power_of_two_trick = |x| Solve.all([x.neq(0), x.bitwise_and(x - 1).eq(0)])

	## The definition: `x` is one of 1, 2, 4, ..., 32768.
	power_of_two : Solve.Uint -> Solve.Claim
	power_of_two = |x| {
		var $powers = []
		var $power = 1
		while $power < 65_536 {
			$powers = $powers.append(x.eq(Solve.num($power)))
			$power = $power * 2
		}
		Solve.any($powers)
	}

	trick_is_right : {} -> Try([Proved, Refuted({ x : Solve.Uint }), Crashes({ x : Solve.Uint })], Solve.Problem)
	trick_is_right = |{}| Solve.prove(
		Solve.map(Solve.u16, |x| { x: x }),
		|v| power_of_two_trick(v.x).iff(power_of_two(v.x)),
	)

	## Forgetting the guard is caught as a crash at zero, not as a wrong answer.
	unguarded : {} -> Try([Proved, Refuted({ x : Solve.Uint }), Crashes({ x : Solve.Uint })], Solve.Problem)
	unguarded = |{}| Solve.prove(
		Solve.map(Solve.u16, |x| { x: x }),
		|v| v.x.bitwise_and(v.x - 1).eq(0).iff(power_of_two(v.x)),
	)
}

expect BitTricks.average_is_exact({}) == Ok(Proved)
expect BitTricks.trick_is_right({}) == Ok(Proved)
expect BitTricks.unguarded({}) == Ok(Crashes({ x: 0 }))

# The trick on real numbers.
expect {
	BitTricks.average(4_000_000_000.U32, 4_000_000_002.U32) == 4_000_000_001
}
