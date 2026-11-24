## A rule stated the way the code checks it: one pass that keeps a running
## maximum. Each step uses the maximum so far three times, so the step is
## marked `shared` and the term stays as long as the code is.
import fuzz.Solve

RunningMaximum := [].{

	## The real check: no item is `window` or more below an earlier one.
	in_order : List(U64), U64 -> Bool
	in_order = |items, window| {
		var $highest = 0
		var $ok = Bool.True
		for item in items {
			if $highest >= item + window {
				$ok = Bool.False
			}
			if item > $highest {
				$highest = item
			}
		}
		$ok
	}

	## The same pass over terms. Without `.shared()` the term for `$highest`
	## holds the previous one twice, and twenty items make a term of a million
	## parts; with it, twenty items are twenty definitions.
	in_order_claim : List(Solve.Uint), U64 -> Solve.Claim
	in_order_claim = |items, window| {
		var $highest = Solve.num(0)
		var $claims = []
		for item in items {
			$claims = $claims.append($highest.lt(item + Solve.num(window)))
			$highest = Solve.if_else(item.gt($highest), item, $highest).shared()
		}
		Solve.all($claims)
	}

	## The rule with no running value: every pair of items, the later one not
	## `window` or more below the earlier.
	pairwise_claim : List(Solve.Uint), U64 -> Solve.Claim
	pairwise_claim = |items, window| {
		var $claims = []
		var $later = 0
		for item in items {
			for before in items.take_first($later) {
				$claims = $claims.append(before.lt(item + Solve.num(window)))
			}
			$later = $later + 1
		}
		Solve.all($claims)
	}

	## `count` bytes that leave room to add the window.
	unknowns : U64 -> Solve.Vars(List(Solve.Uint))
	unknowns = |count| Solve.several(Solve.u8_in(0, 240), count)

	## Are the two ways of stating the rule the same rule, for every list of
	## `count` items?
	same_rule : U64, U64 -> Try([Proved, Refuted(List(Solve.Uint)), Crashes(List(Solve.Uint))], Solve.Problem)
	same_rule = |count, window| Solve.prove(unknowns(count), |list| in_order_claim(list, window).iff(pairwise_claim(list, window)))

	## A list in order near the proposed numbers.
	near : List(U64), U64 -> Try([Found(List(U64)), None], Solve.Problem)
	near = |proposed, window| match Solve.find_near(unknowns(proposed.len()), |list| in_order_claim(list, window), proposed)? {
		Found(list) => Ok(Found(list.map(|item| item.value())))
		None => Ok(None)
	}
}

## One pass with a running maximum states the same rule as all the pairs,
## for every list of four bytes.
expect RunningMaximum.same_rule(4, 8) == Ok(Proved)

## Steered: each item keeps what it can of its proposal, earlier items first.
## 150 comes too far below the 200 before it and becomes 214, which is 150
## with one bit changed.
expect RunningMaximum.near([50, 200, 150, 12, 199, 240, 3, 230], 8) == Ok(Found([50, 200, 214, 207, 207, 240, 235, 238]))

## Forty items are forty steps and 11,748 clauses, where the term written
## out would have 2^40 parts.
expect Solve.measure(RunningMaximum.unknowns(40), |list| RunningMaximum.in_order_claim(list, 8)) == Ok({ bits: 320, clauses: 11_748, unknowns: 40, variables: 4028 })

# The term against the real code: the same answer on lists in and out of order.
expect {
	lists = [[], [5], [5, 5], [10, 3], [10, 2], [1, 2, 3, 4], [100, 93, 200, 193, 192], [100, 93, 200, 192], [240, 233, 0]]
	lists.all(|list| RunningMaximum.in_order_claim(list.map(|item| Solve.Uint.of_width(item, 8)), 8).eval() == Ok(RunningMaximum.in_order(list, 8)))
}
