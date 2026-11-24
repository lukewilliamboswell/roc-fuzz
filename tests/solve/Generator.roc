## A generator that asks one claim again and again: the claim is built and
## loaded once, and each call only steers and solves.
import fuzz.Solve

Generator := [].{
	Progress(n) : { acked : n, got : n, sent : n }

	unknowns : Solve.Vars(Progress(Solve.Uint))
	unknowns = { acked: Solve.u64_in(0, 999_999), got: Solve.u64_in(0, 999_999), sent: Solve.u64_in(0, 999_999) }.Solve

	## What every world must satisfy: at most eight messages are sent and
	## not yet acknowledged, and what was received lies between the two.
	in_flight : Progress(Solve.Uint) -> Solve.Claim
	in_flight = |v| Solve.all([v.acked.lte(v.got), v.got.lte(v.sent), v.sent.lte(v.acked + 8)])

	## What a caller may ask for on top, by position: the open window crosses
	## a wrap of the 16-bit sequence numbers, everything sent was received,
	## something received is still to be acknowledged, and nothing at all is
	## outstanding.
	extras : Progress(Solve.Uint) -> List(Solve.Claim)
	extras = |v| [
		(v.sent % 65_536).lt(v.acked % 65_536),
		v.got.eq(v.sent),
		v.acked.lt(v.got),
		v.acked.eq(v.sent),
	]

	crossing : U64
	crossing = 0

	all_received : U64
	all_received = 1

	ack_pending : U64
	ack_pending = 2

	idle : U64
	idle = 3

	## The claim in the solver, worked out once, when this module is compiled.
	## A fuzz target is a pure function, so a constant is where it can keep
	## work between calls. This claim is small; one of 38,000 clauses costs
	## the compiler about a tenth of a second.
	ready : Try(Solve.Prepared(Progress(Solve.Uint)), Solve.Problem)
	ready = Solve.prepare_with(unknowns, in_flight, extras)

	## A world near the proposed numbers in which the chosen extras hold too.
	world : List(U64), List(U64) -> Try([World(Progress(U64)), Impossible, GaveUp(Solve.Effort)], Solve.Problem)
	world = |proposed, assuming| {
		formula = ready?
		match Solve.ask(formula, { near: proposed, assuming, within: 10_000 })? {
			Found(v) => Ok(World({ acked: v.acked.value(), got: v.got.value(), sent: v.sent.value() }))
			None => Ok(Impossible)
			GaveUp(spent) => Ok(GaveUp(spent))
		}
	}

	## The same rules as ordinary Roc, to check what comes back.
	fits : Progress(U64), List(U64) -> Bool
	fits = |{ acked, got, sent }, assuming| {
		acked <= got and got <= sent and sent <= acked + 8 and assuming.all(
			|extra| match extra {
				0 => sent % 65_536 < acked % 65_536
				1 => got == sent
				2 => acked < got
				_ => acked == sent
			},
		)
	}
}

## The proposal already fits the claim, so it comes back as it is.
expect Generator.world([70_000, 70_003, 70_005], []) == Ok(World({ acked: 70_000, got: 70_003, sent: 70_005 }))

## The same proposal with extras switched on, from the same prepared claim:
## moved to a wrap, then with everything received as well.
expect Generator.world([70_000, 70_003, 70_005], [Generator.crossing]) == Ok(World({ acked: 131_064, got: 131_067, sent: 131_072 }))

expect Generator.world([70_000, 70_003, 70_005], [Generator.crossing, Generator.all_received]) == Ok(World({ acked: 131_064, got: 131_072, sent: 131_072 }))

expect Generator.world([70_000, 70_003, 70_005], [Generator.all_received, Generator.ack_pending]) == Ok(World({ acked: 70_000, got: 70_003, sent: 70_003 }))

## Proposing zeros asks for the smallest world, number by number.
expect Generator.world([0, 0, 0], [Generator.crossing]) == Ok(World({ acked: 65_528, got: 65_528, sent: 65_536 }))

expect Generator.world([0, 0, 0], [Generator.all_received, Generator.ack_pending]) == Ok(World({ acked: 0, got: 1, sent: 1 }))

## Extras that cannot hold together: a window that crosses a wrap is not
## empty. The answer is that there is no such world, not a wrong one.
expect Generator.world([70_000, 70_003, 70_005], [Generator.crossing, Generator.idle]) == Ok(Impossible)

## An extra the prepared claim does not have is a mistake in the query.
expect Generator.world([1, 2, 3], [7]) == Err(NoSuchExtra(7))

## Every world, whatever was assumed, passes the same rules as ordinary Roc,
## and asking again gives the same world.
expect {
	queries = [
		([], []),
		([5, 5, 5], [Generator.ack_pending]),
		([999_999, 0, 500_000], [Generator.crossing]),
		([123_456, 654_321, 111_111], [Generator.crossing, Generator.all_received, Generator.ack_pending]),
		([65_536, 65_536, 65_536], [Generator.crossing, Generator.all_received]),
		([65_536, 65_536, 65_536], [Generator.idle]),
	]
	queries.all(
		|(proposed, assuming)| match Generator.world(proposed, assuming) {
			Ok(World(progress)) => Generator.fits(progress, assuming) and Generator.world(proposed, assuming) == Ok(World(progress))
			_ => Bool.False
		},
	)
}
