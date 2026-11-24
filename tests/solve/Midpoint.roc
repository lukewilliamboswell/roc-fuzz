## Overflow-freedom for an index computation, and one function that is both the
## real code and the term.
import fuzz.Solve

Midpoint := [].{

	## No annotation, on purpose: `+`, `-` and `//` are method calls, so this
	## one definition runs on `U32` and builds a term on `Solve.Uint`.
	careful = |lo, hi| lo + (hi - lo) // 2

	naive = |lo, hi| (lo + hi) // 2

	Bounds : { lo : Solve.Uint, hi : Solve.Uint }

	## For every ordered pair of `U32`s, does `middle` stay between them
	## without crashing?
	stays_between : (Solve.Uint, Solve.Uint -> Solve.Uint) -> Try([Proved, Refuted(Bounds), Crashes(Bounds)], Solve.Problem)
	stays_between = |middle| Solve.prove(
		{ lo: Solve.u32, hi: Solve.u32 }.Solve,
		|v| {
			mid = middle(v.lo, v.hi)
			v.lo.lte(v.hi).implies(Solve.all([v.lo.lte(mid), mid.lte(v.hi)]))
		},
	)

	## Is `careful` the true midpoint, computed with a bit to spare?
	is_the_midpoint : {} -> Try([Proved, Refuted(Bounds), Crashes(Bounds)], Solve.Problem)
	is_the_midpoint = |{}| Solve.prove(
		{ lo: Solve.u32, hi: Solve.u32 }.Solve,
		|v| {
			exact = (v.lo.to_width(33) + v.hi.to_width(33)) // 2
			v.lo.lte(v.hi).implies(careful(v.lo, v.hi).to_width(33).eq(exact))
		},
	)
}

## Proved for all 2^64 pairs: nothing overflows and the result is in range.
expect Midpoint.stays_between(Midpoint.careful) == Ok(Proved)

## The obvious version crashes, and the solver says where.
expect Midpoint.stays_between(Midpoint.naive) == Ok(Crashes({ lo: 1, hi: 4_294_967_295 }))

expect Midpoint.is_the_midpoint({}) == Ok(Proved)

# The term against the real code: the same function, on numbers and on terms.
expect {
	pairs = [(0, 0), (0, 1), (3, 10), (7, 4_000_000_000), (4_294_967_294, 4_294_967_295), (2_147_483_648, 2_147_483_648)]
	pairs.all(
		|(lo, hi)| {
			real : U32
			real = Midpoint.careful(lo, hi)
			Midpoint.careful(Solve.Uint.from_u32(lo), Solve.Uint.from_u32(hi)).eval() == Ok(real.to_u64())
		},
	)
}

# And where the real code crashes, the term says so instead of crashing.
expect Midpoint.naive(Solve.Uint.from_u32(4_000_000_000), Solve.Uint.from_u32(4_000_000_000)).eval() == Err(Overflow)
