## Constraints with shapes that random numbers almost never have.
import fuzz.Solve

Shapes := [].{
	Window : { len : U64, start : U64, count : U64 }

	## A window into a buffer: it ends exactly at the end, is not empty, and
	## starts in the first half. About one random triple of bytes in 700 fits.
	window : List(U64) -> Try([Found(Window), None], Solve.Problem)
	window = |proposed| {
		found = Solve.find_near(
			{ len: Solve.u8, start: Solve.u8, count: Solve.u8 }.Solve,
			|v| Solve.all([(v.start + v.count).eq(v.len), v.count.gt(0), (v.start * 2).lt(v.len)]),
			proposed,
		)?
		match found {
			Found(v) => Ok(Found({ len: v.len.value(), start: v.start.value(), count: v.count.value() }))
			None => Ok(None)
		}
	}

	Sides : { a : Solve.Uint, b : Solve.Uint, c : Solve.Uint }

	sides : Solve.Vars(Sides)
	sides = { a: Solve.u16_in(1, 200), b: Solve.u16_in(1, 200), c: Solve.u16_in(1, 200) }.Solve

	## Whole-number right triangles with the short side first.
	right_angled : Sides -> Solve.Claim
	right_angled = |v| Solve.all([v.a.lt(v.b), (v.a * v.a + v.b * v.b).eq(v.c * v.c)])

	lengths : Sides -> (U64, U64, U64)
	lengths = |v| (v.a.value(), v.b.value(), v.c.value())
}

## Proposals in, windows out. `len` is declared first, so it keeps as much of
## its proposal as any window allows; then `start` does, beside that `len`;
## `count` gets what is left. (100, 90, 3) keeps its `len`, and `start` must
## come below 50: 26 is 90 with its top bit cleared.
expect [[], [200, 13, 77], [255, 255, 255], [100, 90, 3], [9, 200, 1]].map(Shapes.window) == [
	Ok(Found({ len: 1, start: 0, count: 1 })),
	Ok(Found({ len: 200, start: 13, count: 187 })),
	Ok(Found({ len: 255, start: 127, count: 128 })),
	Ok(Found({ len: 100, start: 26, count: 74 })),
	Ok(Found({ len: 9, start: 0, count: 9 })),
]

expect Solve.find(Shapes.sides, Shapes.right_angled) == Ok(Found({ a: 3, b: 4, c: 5 }))

## Steered: the first side is kept, and the second is the one nearest 150 in
## its leading bits among the triangles with a side of 60.
expect Solve.find_near(Shapes.sides, Shapes.right_angled, [60, 150, 170]) == Ok(Found({ a: 60, b: 144, c: 156 }))

## Six different triangles, each checked with ordinary arithmetic.
expect match Solve.enumerate(Shapes.sides, Shapes.right_angled, 6) {
	Ok(found) => found.map(Shapes.lengths) == [(3, 4, 5), (8, 15, 17), (24, 143, 145), (48, 189, 195), (117, 156, 195), (99, 132, 165)] and found.all(
		|v| {
			(a, b, c) = Shapes.lengths(v)
			a < b and a * a + b * b == c * c
		},
	)
	Err(_) => Bool.False
}
