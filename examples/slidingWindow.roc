app [target] { fuzz: platform "../platform/main.roc" }

import fuzz.Fuzz
import fuzz.Solve

## A sliding-window link counts messages in `U64`s but puts only the low 16
## bits of each count on the wire. The receiver works out from two wire
## numbers how many messages are still unacknowledged. That is easy to get
## right until the window crosses 65,536, where the wire numbers start again
## from zero.
outstanding : U16, U16 -> U16
outstanding = |acked, sent| sent.minus_wrap(acked)

## The rules every state of the link satisfies: acknowledged, then received,
## then sent, with at most eight messages in flight. Counts stay below a
## million, so the solver chooses 20 bits per count, not 64.
Progress(n) : { acked : n, got : n, sent : n }

unknowns : Solve.Vars(Progress(Solve.Uint))
unknowns = { acked: Solve.u64_in(0, 999_999), got: Solve.u64_in(0, 999_999), sent: Solve.u64_in(0, 999_999) }.Solve

in_flight : Progress(Solve.Uint) -> Solve.Claim
in_flight = |v| Solve.all([v.acked.lte(v.got), v.got.lte(v.sent), v.sent.lte(v.acked + 8)])

## An extra rule an input may switch on: the window crosses a wrap of the
## wire numbers. About one valid state in 12,000 does, and almost no random
## triple of numbers is a state at all.
crossing : Progress(Solve.Uint) -> Solve.Claim
crossing = |v| (v.sent % 65_536).lt(v.acked % 65_536)

## The rules, built into a formula and loaded into the solver once, when this
## file is compiled. A claim prepared inside `test` would be prepared again
## for every input.
ready : Try(Solve.Prepared(Progress(Solve.Uint)), Solve.Problem)
ready = Solve.prepare_with(unknowns, in_flight, |v| [crossing(v)])

## What the fuzzer chooses: three numbers the solver steers towards, and
## whether to ask for a state that crosses the wrap.
Proposal : { acked : U64, got : U64, sent : U64, wrap : U8 }

## The state of the link nearest the proposal. The solver keeps as many
## leading bits of each number as the rules allow, so the fuzzer's mutations
## still move the state around.
state : Proposal -> Try([Found(Progress(U64)), None, GaveUp(Solve.Effort)], Solve.Problem)
state = |proposal| {
	assuming = if (proposal.wrap % 2 == 1) [0] else []
	query = { near: [proposal.acked, proposal.got, proposal.sent], assuming, within: 10_000 }
	match Solve.ask(ready?, query)? {
		Found(v) => Ok(Found({ acked: v.acked.value(), got: v.got.value(), sent: v.sent.value() }))
		None => Ok(None)
		GaveUp(spent) => Ok(GaveUp(spent))
	}
}

## Every state the solver hands back satisfies the rules, checked again in
## plain Roc, and the receiver's 16-bit answer is the true count. Written with
## `sent - acked` on the `U16`s, `outstanding` crashes on the first state that
## crosses the wrap.
##
## Each input costs a solver query. On an Apple Silicon Mac this target runs
## about 200 inputs a second, where a target with a generator written by hand
## runs thousands. That is the price of stating the rules once, as a claim.
test! : Proposal => Fuzz.Outcome
test! = |proposal| match state(proposal) {
	Ok(Found({ acked, got, sent })) => {
		if !(acked <= got and got <= sent and sent <= acked + 8) {
			crash "the solver returned a state that breaks the rules"
		}
		if sent % 65_536 < acked % 65_536 {
			Fuzz.mark!("window crosses the wrap")
		}
		if outstanding(acked.to_u16_wrap(), sent.to_u16_wrap()).to_u64() != sent - acked {
			crash "the receiver miscounted the messages in flight"
		}
		Fuzz.keep
	}
	_ => Fuzz.reject
}

target = Fuzz.target_with!({
	name: "sliding-window",
	examples: [
		Fuzz.example({ name: "idle", revision: "1", make: || { acked: 0, got: 0, sent: 0, wrap: 0 } }),
		Fuzz.example({ name: "across-the-wrap", revision: "1", make: || { acked: 70_000, got: 70_003, sent: 70_005, wrap: 1 } }),
	],
	generator: { acked: Fuzz.u64, got: Fuzz.u64, sent: Fuzz.u64, wrap: Fuzz.u8 }.Fuzz,
	test!,
	show: Str.inspect,
}).with_goals(["window crosses the wrap"])

## The proposal fits the rules, so it comes back as it is.
expect state({ acked: 70_000, got: 70_003, sent: 70_005, wrap: 0 }) == Ok(Found({ acked: 70_000, got: 70_003, sent: 70_005 }))

## The same proposal with the wrap asked for is moved to the nearest wrap
## that keeps most of its leading bits.
expect state({ acked: 70_000, got: 70_003, sent: 70_005, wrap: 1 }) == Ok(Found({ acked: 131_064, got: 131_067, sent: 131_072 }))
