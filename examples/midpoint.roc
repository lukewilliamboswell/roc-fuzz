app [target] { fuzz: platform "../platform/main.roc" }

import fuzz.Fuzz
import fuzz.Solve

## The midpoint of a binary search, two ways. Neither has a type annotation:
## `+`, `-` and `//` are method calls, so the same definition runs on `U32`s
## and builds a term on `Solve.Uint`s. The function that is fuzzed below is
## the function that is proved.
naive = |lo, hi| (lo + hi) // 2

careful = |lo, hi| lo + (hi - lo) // 2

Bounds : { lo : Solve.Uint, hi : Solve.Uint }

Verdict : Try([Proved, Refuted(Bounds), Crashes(Bounds)], Solve.Problem)

## For every pair of `U32`s with `lo <= hi`, does `middle` stay between them
## without crashing?
stays_between : (Solve.Uint, Solve.Uint -> Solve.Uint) -> Verdict
stays_between = |middle| Solve.prove(
	{ lo: Solve.u32, hi: Solve.u32 }.Solve,
	|v| {
		mid = middle(v.lo, v.hi)
		v.lo.lte(v.hi).implies(Solve.all([v.lo.lte(mid), mid.lte(v.hi)]))
	},
)

## The obvious version crashes, and the answer says where: the sum of 1 and
## the largest `U32` does not fit.
expect stays_between(naive) == Ok(Crashes({ lo: 1, hi: 4_294_967_295 }))

## The careful version is proved for all 2^64 pairs: nothing overflows and the
## result is in range.
expect stays_between(careful) == Ok(Proved)

## The proof is about the term. This target checks that the term means what
## the compiled code does: on every pair the fuzzer tries, `careful` on `U32`s
## and the plain evaluator on the same term give the same number.
test : { lo : U32, hi : U32 } -> Fuzz.Outcome
test = |{ lo, hi }| {
	if lo > hi {
		return Fuzz.reject
	}
	real : U32
	real = careful(lo, hi)
	if careful(Solve.Uint.from_u32(lo), Solve.Uint.from_u32(hi)).eval() != Ok(real.to_u64()) {
		crash "the term and the code disagree about the midpoint"
	}
	Fuzz.keep
}

u32 : Fuzz.Generator(U32)
u32 = Fuzz.map(Fuzz.u64_in(0, U32.highest.to_u64()), |n| n.to_u32_wrap())

target = Fuzz.target_with({
	name: "midpoint",
	examples: [
		Fuzz.example({ name: "equal", revision: "1", make: || { lo: 7, hi: 7 } }),
		Fuzz.example({ name: "top-of-range", revision: "1", make: || { lo: 1, hi: U32.highest } }),
	],
	generator: { lo: u32, hi: u32 }.Fuzz,
	test,
	show: Str.inspect,
})
