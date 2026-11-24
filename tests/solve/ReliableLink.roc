## A sliding-window link with 16-bit sequence numbers: a proof that a frame
## accepted inside the window is the awaited one, and worlds steered to the
## wrap of the sequence space.
import fuzz.Solve

ReliableLink := [].{
	Config : { space : U64, window : U64 }

	Position : { awaited : Solve.Uint, frame : Solve.Uint }

	## If the frame that arrives is within one window of the awaited one, and
	## it carries the awaited sequence number, then it is the awaited message.
	## Asked for every position up to a billion messages.
	acceptance_is_safe : Config -> Try([Proved, Refuted(Position), Crashes(Position)], Solve.Problem)
	acceptance_is_safe = |config| Solve.prove(
		{ awaited: Solve.u64_in(0, 999_999_999), frame: Solve.u64_in(0, 999_999_999) }.Solve,
		|v| {
			space = Solve.num(config.space)
			window = Solve.num(config.window)
			within_a_window = Solve.all([v.awaited.lte(v.frame + window), v.frame.lt(v.awaited + window)])
			accepted = (v.frame % space).eq(v.awaited % space)
			Solve.all([within_a_window, accepted]).implies(v.frame.eq(v.awaited))
		},
	)

	Progress : { acked : U64, got : U64, sent : U64 }

	## A world whose open window reaches or crosses the wrap, steered towards
	## three proposed numbers: what a generator would do with three numbers
	## drawn from a fuzzer's bytes.
	near_the_wrap : Config, List(U64) -> Try([World(Progress), Impossible], Solve.Problem)
	near_the_wrap = |config, proposed| {
		found = Solve.find_near(
			{ acked: Solve.u64_in(0, 999_999), got: Solve.u64_in(0, 999_999), sent: Solve.u64_in(0, 999_999) }.Solve,
			|v| {
				space = Solve.num(config.space)
				window = Solve.num(config.window)
				Solve.all([
					v.acked.lte(v.got),
					v.got.lte(v.sent),
					v.sent.lte(v.acked + window),
					(v.sent % space).lt(v.acked % space),
				])
			},
			proposed,
		)?
		match found {
			Found(v) => Ok(World({ acked: v.acked.value(), got: v.got.value(), sent: v.sent.value() }))
			None => Ok(Impossible)
		}
	}

	## The same four conditions as ordinary Roc, to check what comes back.
	crosses_the_wrap : Config, Progress -> Bool
	crosses_the_wrap = |config, { acked, got, sent }|
		acked <= got and got <= sent and sent <= acked + config.window and sent % config.space < acked % config.space
}

production : ReliableLink.Config
production = { space: 65_536, window: 8 }

expect ReliableLink.acceptance_is_safe(production) == Ok(Proved)

## The widest safe window is one less than the sequence space.
expect ReliableLink.acceptance_is_safe({ space: 65_536, window: 65_535 }) == Ok(Proved)

## One wider and the solver answers with the collision the search found at
## size two: frame 0 arriving while message 65,536 is awaited.
expect ReliableLink.acceptance_is_safe({ space: 65_536, window: 65_536 }) == Ok(Refuted({ awaited: 65_536, frame: 0 }))

## What eight different proposals become. Each world is valid and the same
## proposal always gives the same world. Which world is not left to the
## solver: `acked` gets the value that keeps the most leading bits of its
## proposal, then `got` beside it, then `sent`.
##
## - (65530, 65533, 65535) keeps its first two numbers. `sent` must pass the
##   wrap at 65,536 and may not pass `acked + 8`, which leaves 65,536 to
##   65,538, and 65,538 is the one whose bits differ least from 65,535's.
## - (0, 0, 0) is the smallest world there is, number by number.
## - (200000, 200004, 200008) goes to the wrap at 262,144 and not to the
##   nearer one at 196,608: the numbers just below 262,144 share four leading
##   bits with 200,000, and the ones below 196,608 only three.
## - No proposals at all leaves the choice to the solver, as `find` does.
proposals : List(List(U64))
proposals = [[], [0, 0, 0], [999_999, 999_999, 999_999], [65_530, 65_533, 65_535], [500_000, 123, 77], [131_071, 0, 131_073], [200_000, 200_004, 200_008], [7, 900_000, 3]]

expect proposals.map(|proposed| ReliableLink.near_the_wrap(production, proposed)) == [
	Ok(World({ acked: 65_529, got: 65_529, sent: 65_536 })),
	Ok(World({ acked: 65_528, got: 65_528, sent: 65_536 })),
	Ok(World({ acked: 983_039, got: 983_047, sent: 983_047 })),
	Ok(World({ acked: 65_530, got: 65_533, sent: 65_538 })),
	Ok(World({ acked: 524_280, got: 524_283, sent: 524_288 })),
	Ok(World({ acked: 131_071, got: 131_071, sent: 131_073 })),
	Ok(World({ acked: 262_136, got: 262_140, sent: 262_144 })),
	Ok(World({ acked: 65_535, got: 65_536, sent: 65_539 })),
]

## Every world satisfies the ordinary Roc version of the four conditions.
expect proposals.all(
	|proposed| match ReliableLink.near_the_wrap(production, proposed) {
		Ok(World(progress)) => ReliableLink.crosses_the_wrap(production, progress)
		_ => Bool.False
	},
)

## With a window of zero nothing is ever outstanding, so no world crosses the
## wrap: the solver shows there is none.
expect ReliableLink.near_the_wrap({ space: 65_536, window: 0 }, []) == Ok(Impossible)
