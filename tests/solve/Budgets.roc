## A question that is too hard gets "gave up" for an answer, with the bill.
import fuzz.Solve

Budgets := [].{
	Pair : { a : Solve.Uint, b : Solve.Uint }

	Verdict : Try([Proved, Refuted(Pair), Crashes(Pair), GaveUp(Solve.Effort)], Solve.Problem)

	## Multiplication does not care about the order of its operands. True at
	## every width, and a question SAT solvers are bad at: each bit more makes
	## it several times harder.
	times_commutes : U8, U64 -> Verdict
	times_commutes = |width, budget| Solve.prove_within(
		{ a: Solve.uint(width), b: Solve.uint(width) }.Solve,
		|v| v.a.times_wrap(v.b).eq(v.b.times_wrap(v.a)),
		budget,
	)

	## The same claim through `prove`, which has no budget to set.
	times_commutes_unbounded : U8 -> Try([Proved, Refuted(Pair), Crashes(Pair)], Solve.Problem)
	times_commutes_unbounded = |width| Solve.prove(
		{ a: Solve.uint(width), b: Solve.uint(width) }.Solve,
		|v| v.a.times_wrap(v.b).eq(v.b.times_wrap(v.a)),
	)
}

## At 5 bits a thousand conflicts are enough.
expect Budgets.times_commutes(5, 1_000) == Ok(Proved)

## At 10 bits they are not, and the answer says so instead of not coming
## back: nothing is known about the claim, and this is what was spent. The
## counters are the solver's own and depend only on the question, so the
## same budget always buys exactly this. The budget is exact: the solver
## stops at the conflict that uses it up. (The whole proof takes 913,801
## conflicts, forty seconds of an optimised build.)
expect Budgets.times_commutes(10, 1_000) == Ok(GaveUp({ conflicts: 1000, decisions: 1319, propagations: 82_304, restarts: 0 }))

## A budget of nothing buys no search. Only a claim that is settled by the
## time its formula is loaded gets an answer, and this is not one.
expect Budgets.times_commutes(10, 0) == Ok(GaveUp({ conflicts: 0, decisions: 0, propagations: 0, restarts: 0 }))

## `prove` has a budget too, `Solve.default_budget`, and reports running out
## of it as a problem. Not asked here, because it takes a minute of an
## optimised build to find out:
##
##     Budgets.times_commutes_unbounded(16) == Err(GaveUp({ conflicts: 1_000_000, .. }))
expect Budgets.times_commutes_unbounded(5) == Ok(Proved)
