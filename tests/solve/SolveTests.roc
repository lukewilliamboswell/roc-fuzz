## Tests of `Solve` that use only what the platform exposes: the promises of
## each query, in small examples. They live outside the platform, where no
## application's `roc test` runs them. `roc test tests/solve/main.roc` does.
import fuzz.Solve

SolveTests := [].{}

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
expect match Solve.prepare_with({ x: Solve.u8, y: Solve.u8 }.Solve, |v| v.x.lt(v.y), |v| [(v.x + v.y).eq(100)]) {
	Ok(prepared) => {
		ask = |near, assuming| Solve.ask(prepared, { near, assuming, within: 1000 })
		ask([10, 20], []) == Ok(Found({ x: 10, y: 20 }))
			and ask([20, 10], []) == Ok(Found({ x: 20, y: 26 }))
			and ask([10, 20], [0]) == Ok(Found({ x: 10, y: 90 }))
			and ask([60, 60], [0]) == Ok(Found({ x: 48, y: 52 }))
			and ask([10, 20], [1]) == Err(NoSuchExtra(1))
			and ask([10, 20], []) == Ok(Found({ x: 10, y: 20 }))
	}
	Err(_) => Bool.False
}

# What a question costs, for choosing a budget: the same counters every time,
# and a budget of that many conflicts is enough.
expect {
	pair = { a: Solve.uint(5), b: Solve.uint(5) }.Solve
	commutes = |v| v.a.times_wrap(v.b).eq(v.b.times_wrap(v.a))
	match Solve.effort(pair, commutes, Prove) {
		Ok(spent) => Solve.effort(pair, commutes, Prove) == Ok(spent) and Solve.prove_within(pair, commutes, spent.conflicts) == Ok(Proved)
		Err(_) => Bool.False
	}
}

expect Solve.effort({ x: Solve.u8, y: Solve.u8 }.Solve, |v| v.x.lt(v.y), Find) == Solve.effort({ x: Solve.u8, y: Solve.u8 }.Solve, |v| v.x.lt(v.y), Find)

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

# The examples in the API reference and the guide, as they are written there.
expect Solve.find(Solve.map(Solve.u8, |x| { x: x }), |v| (v.x * 3).eq(51)) == Ok(Found({ x: 17 }))

expect Solve.prove({ x: Solve.u8, y: Solve.u8 }.Solve, |v| v.y.neq(0).implies((v.x // v.y).lte(v.x))) == Ok(Proved)

expect Solve.prove({ x: Solve.u8, y: Solve.u8 }.Solve, |v| (v.x // v.y).lte(v.x)) == Ok(Crashes({ x: 0, y: 0 }))
