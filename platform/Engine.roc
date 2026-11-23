## From a term and its unknowns to answers from the SAT solver. Internal:
## `Solve` wraps this in typed records, and `Validate` drives it with raw terms.
##
## Every set of values returned from here has been run through `Term.holds`
## first. A solver answer the evaluator rejects is reported as `Disagreement`
## instead of being passed on.
import sat.Rocsat
import Term
import Circuit
import Blast

Engine := [].{

	## One unknown: a number of some width within `lo..=hi`, or a truth value.
	Decl : { sort : [Number(U8), Flag], lo : U64, hi : U64 }

	## A claim built into the formula but not forced: the elaborated term and
	## the wire that is true when it holds. A query may assume it.
	Extra : { term : Term, holds : I32 }

	Compiled : {
		net : Circuit.Net,

		## The wires of each unknown, by position, low bit first.
		inputs : List(List(I32)),

		## Every wire the solver is free to choose.
		free : List(I32),
		decls : List(Decl),

		## The elaborated claim.
		term : Term,

		## True when every unknown is inside its declared range.
		domain : I32,

		## True when the claim holds.
		holds : I32,
		extras : List(Extra),
	}

	## What a search cost: the solver's own counters. They do not depend on
	## the machine or the build, so the same query always costs the same.
	Effort : { conflicts : U64, decisions : U64, propagations : U64, restarts : U64 }

	## A budget that never runs out.
	no_limit : U64
	no_limit = U64.highest

	## Elaborate the claim and build its circuit. An unknown gets one fresh
	## wire per bit its range can use; bits above the highest bit of `hi` are
	## fixed to zero, so a narrow range in a wide type costs the solver little.
	compile : List(Decl), Term -> Try(Compiled, Term.Fault)
	compile = |decls, raw| compile_with(decls, raw, [])

	## `compile`, with further claims built over the same unknowns for
	## queries to assume.
	compile_with : List(Decl), Term, List(Term) -> Try(Compiled, Term.Fault)
	compile_with = |decls, raw, raw_extras| {
		term = Term.elaborate(raw)?
		var $net = Circuit.new({})
		var $inputs = List.with_capacity(decls.len())
		var $free = []
		var $domain = Circuit.yes
		for decl in decls {
			match decl.sort {
				Flag => {
					(net1, wire) = Circuit.fresh($net)
					$net = net1
					$inputs = $inputs.append([wire])
					$free = $free.append(wire)
				}
				Number(width) => {
					Term.good_width(width)?
					if decl.lo > decl.hi or decl.hi > Term.mask(width) {
						return Err(BadRange({ lo: decl.lo, hi: decl.hi, width }))
					}
					wide = width.to_u64()
					used = 64 - decl.hi.count_leading_zero_bits().to_u64()
					(net1, low) = Circuit.input($net, used)
					wires = low.concat(List.repeat(Circuit.no, wide - used))
					(net2, under) = Circuit.less(net1, wires, Circuit.constant(decl.lo, wide))
					(net3, over) = Circuit.less(net2, Circuit.constant(decl.hi, wide), wires)
					(net4, within) = Circuit.and_gate(net3, -under, -over)
					(net5, domain) = Circuit.and_gate(net4, $domain, within)
					$net = net5
					$domain = domain
					$inputs = $inputs.append(wires)
					$free = $free.concat(low)
				}
			}
		}
		(net9, holds) = Blast.holds($net, $inputs, term)?
		$net = net9
		var $extras = List.with_capacity(raw_extras.len())
		for raw_extra in raw_extras {
			extra = Term.elaborate(raw_extra)?
			(next, wire) = Blast.holds($net, $inputs, extra)?
			$net = next
			$extras = $extras.append({ term: extra, holds: wire })
		}
		Ok({ net: $net, inputs: $inputs, free: $free, decls, term, domain: $domain, holds, extras: $extras })
	}

	## What the solver is given: unknowns, the bits it is free to choose, and
	## the variables and clauses of the formula (with the two that state the
	## question).
	size : Compiled -> { unknowns : U64, bits : U64, variables : U64, clauses : U64 }
	size = |compiled| {
		unknowns: compiled.decls.len(),
		bits: compiled.free.len(),
		variables: Circuit.variables(compiled.net),
		clauses: compiled.net.count + 2,
	}

	## The wire to force for each question: values where the claim holds, or
	## values where it does not (false or crashing).
	goal : Compiled, [Holding, Failing] -> I32
	goal = |compiled, wanted| match wanted {
		Holding => compiled.holds
		Failing => -compiled.holds
	}

	## The formula as the solver takes it: every clause in one list, each
	## ended by a zero, the last two being the ones that put the unknowns in
	## range and force the question.
	clauses : Compiled, [Holding, Failing] -> List(I32)
	clauses = |compiled, wanted| compiled.net.clauses.append(compiled.domain).append(0).append(goal(compiled, wanted)).append(0)

	## A solver holding the formula, with the unknowns in range and the
	## question forced. Every clause goes in with one call, in the form the
	## circuit already keeps them.
	load : Compiled, [Holding, Failing] -> Try(Rocsat.State, Term.Fault)
	load = |compiled, wanted| {
		sat = Rocsat.add_clauses_flat(Rocsat.new({}), clauses(compiled, wanted)) ? Solver
		Ok(sat)
	}

	## What answers are read from and checked against, once the formula is in
	## a solver.
	Asked : {
		inputs : List(List(I32)),
		free : List(I32),
		decls : List(Decl),
		term : Term,
		wanted : [Holding, Failing],
		extras : List(Extra),
	}

	asked : Compiled, [Holding, Failing] -> Asked
	asked = |compiled, wanted| {
		inputs: compiled.inputs,
		free: compiled.free,
		decls: compiled.decls,
		term: compiled.term,
		wanted,
		extras: compiled.extras,
	}

	## A formula compiled and loaded once, to be asked any number of times.
	## Nothing in it is a function.
	Ready : { sat : Rocsat.State, asked : Asked }

	prepare : Compiled, [Holding, Failing] -> Try(Ready, Term.Fault)
	prepare = |compiled, wanted| {
		sat = load(compiled, wanted)?
		Ok({ sat, asked: asked(compiled, wanted) })
	}

	## The proposals as literals for the solver to prefer, in the order that
	## decides between them: unknowns in the order they were declared, and
	## within a number from its highest free bit down to its lowest. Each
	## literal says "this bit is as in the proposal".
	##
	## A proposal is first moved inside the unknown's range. Unknowns past the
	## end of `proposed` are not listed, and neither are bits the range fixes.
	preferences : List(List(I32)), List(Decl), List(U64) -> List(I32)
	preferences = |inputs, decls, proposed| {
		var $lits = []
		var $id = 0
		for decl in decls {
			match proposed.get($id) {
				Ok(proposal) => {
					nearest = U64.max(decl.lo, U64.min(decl.hi, proposal))
					wires = inputs.get($id) ?? []
					var $place = wires.len()
					while $place > 0 {
						$place = $place - 1
						wire = wires.get($place) ?? Circuit.no
						if wire != Circuit.no and wire != Circuit.yes {
							set = nearest.shr_wrap($place.to_u8_wrap()).bitwise_and(1) == 1
							$lits = $lits.append(
								if set {
									wire
								} else {
									-wire
								},
							)
						}
					}
				}
				Err(_) => {}
			}
			$id = $id + 1
		}
		$lits
	}

	## The wires of the extra claims a query assumes, by their positions.
	assumptions : List(Extra), List(U64) -> Try(List(I32), Term.Fault)
	assumptions = |extras, assumed| {
		var $wires = List.with_capacity(assumed.len())
		for index in assumed {
			match extras.get(index) {
				Ok(extra) => {
					$wires = $wires.append(extra.holds)
				}
				Err(_) => {
					return Err(NoSuchExtra(index))
				}
			}
		}
		Ok($wires)
	}

	## The value the solver gave each unknown.
	read : Rocsat.State, List(List(I32)) -> List(U64)
	read = |sat, inputs| inputs.map(
		|wires| {
			var $number = 0
			var $weight = 1
			for wire in wires {
				on = if wire == Circuit.yes {
					Bool.True
				} else if wire == Circuit.no {
					Bool.False
				} else {
					Rocsat.value(sat, wire) == Ok(True)
				}
				if on {
					$number = $number.bitwise_or($weight)
				}
				$weight = $weight.shl_wrap(1)
			}
			$number
		},
	)

	## Is every value inside the range its unknown was declared with?
	inside : List(Decl), List(U64) -> Bool
	inside = |decls, values| {
		var $ok = decls.len() == values.len()
		var $id = 0
		for decl in decls {
			number = values.get($id) ?? 0
			if number < decl.lo or number > decl.hi {
				$ok = Bool.False
			}
			$id = $id + 1
		}
		$ok
	}

	## Do these values answer the question, according to the evaluator? They
	## must also make every assumed extra claim hold.
	confirmed : Asked, List(U64), List(U64) -> Bool
	confirmed = |question, values, assumed| inside(question.decls, values) and (
		match (question.wanted, Term.holds(question.term, values)) {
			(Holding, Ok(held)) => held
			(Failing, Ok(held)) => !held
			(Failing, Err(Overflow)) => Bool.True
			(Failing, Err(DivByZero)) => Bool.True
			_ => Bool.False
		}
	) and assumed.all(
		|index| match question.extras.get(index) {
			Ok(extra) => Term.holds(extra.term, values) == Ok(Bool.True)
			Err(_) => Bool.False
		},
	)

	## What one call to the solver did, as `Effort`.
	cost : Rocsat.Counters -> Effort
	cost = |did| { conflicts: did.conflicts, decisions: did.decisions, propagations: did.propagations, restarts: did.restarts }

	Answer : [Values(List(U64)), Nothing, GaveUp(Effort)]

	## One search, on a solver that holds the formula.
	##
	## - `proposed` steers: see `preferences`. The solver branches on those
	##   literals first and in that order, so of all the answers there are, it
	##   returns the one that agrees with the proposals on the first listed bit
	##   if any does, then among those on the second, and so on. They steer
	##   this search only: the solver keeps nothing of them.
	## - `assumed` names extra claims that must hold as well.
	## - `budget` is the number of conflicts the search may meet, and it never
	##   meets more. A search that needs fewer is the same search, with the
	##   same answer, as one with no limit.
	##
	## Returns the solver as the search left it, which keeps what it learned,
	## and what the search spent, whatever it answered. `GaveUp` carries that
	## too, and its conflicts are exactly the budget.
	search : Rocsat.State, Asked, List(U64), List(U64), U64 -> Try((Rocsat.State, Answer, Effort), Term.Fault)
	search = |sat0, question, proposed, assumed, budget| {
		wires = assumptions(question.extras, assumed)?
		preferred = preferences(question.inputs, question.decls, proposed)
		(sat1, outcome, did) = Rocsat.solve_with(sat0, { assumptions: wires, preferred, max_conflicts: budget }) ? Solver
		spent = cost(did)
		match outcome {
			Unsat => Ok((sat1, Nothing, spent))
			Unknown => Ok((sat1, GaveUp(spent), spent))
			Sat => {
				values = read(sat1, question.inputs)
				if confirmed(question, values, assumed) {
					Ok((sat1, Values(values), spent))
				} else {
					Err(Disagreement)
				}
			}
		}
	}

	## One answer to the question within a budget of conflicts, steered
	## towards `proposed`.
	one_within : Compiled, [Holding, Failing], List(U64), U64 -> Try(Answer, Term.Fault)
	one_within = |compiled, wanted, proposed, budget| fresh(compiled, wanted, proposed, [], budget)

	## Load the formula into a new solver and search once: what `respond`
	## does, for a formula that was built but not loaded.
	fresh : Compiled, [Holding, Failing], List(U64), List(U64), U64 -> Try(Answer, Term.Fault)
	fresh = |compiled, wanted, proposed, assumed, budget| {
		sat = load(compiled, wanted)?
		(_, answer, _) = search(sat, asked(compiled, wanted), proposed, assumed, budget)?
		Ok(answer)
	}

	## One answer to the question, or `Nothing` when the solver shows there is
	## none. No limit: this returns when the solver does.
	one : Compiled, [Holding, Failing], List(U64) -> Try([Values(List(U64)), Nothing], Term.Fault)
	one = |compiled, wanted, proposed| match one_within(compiled, wanted, proposed, no_limit)? {
		Values(values) => Ok(Values(values))
		Nothing => Ok(Nothing)
		GaveUp(effort) => Err(GaveUp(effort))
	}

	## One answer from a prepared formula. The formula is left as it was, so
	## the same `Ready` answers every query from the same starting point.
	respond : Ready, List(U64), List(U64), U64 -> Try(Answer, Term.Fault)
	respond = |ready, proposed, assumed, budget| {
		(_, answer, _) = search(ready.sat, ready.asked, proposed, assumed, budget)?
		Ok(answer)
	}

	## Up to `limit` different answers within a budget of conflicts for all of
	## them together. After each one a clause is added that makes some chosen
	## bit differ, and the same solver carries on. `stopped` says why the list
	## ends: `Finished` when there are no more answers or `limit` was reached,
	## `GaveUp` when the budget ran out first.
	many_within : Compiled, [Holding, Failing], U64, U64 -> Try({ found : List(List(U64)), stopped : [Finished, GaveUp(Effort)] }, Term.Fault)
	many_within = |compiled, wanted, limit, budget| {
		question = asked(compiled, wanted)
		var $sat = load(compiled, wanted)?
		var $spent = { conflicts: 0, decisions: 0, propagations: 0, restarts: 0 }
		var $found = []
		var $stopped = Finished
		var $more = limit > 0
		while $more {
			(sat1, answer, once) = search($sat, question, [], [], budget - $spent.conflicts)?
			$spent = {
				conflicts: $spent.conflicts + once.conflicts,
				decisions: $spent.decisions + once.decisions,
				propagations: $spent.propagations + once.propagations,
				restarts: $spent.restarts + once.restarts,
			}
			match answer {
				Nothing => {
					$sat = sat1
					$more = Bool.False
				}
				GaveUp(_) => {
					$stopped = GaveUp($spent)
					$sat = sat1
					$more = Bool.False
				}
				Values(values) => {
					$found = $found.append(values)
					differ = question.free.map(
						|wire| if Rocsat.value(sat1, wire) == Ok(True) {
							-wire
						} else {
							wire
						},
					)
					if differ.is_empty() or $found.len() >= limit {
						$sat = sat1
						$more = Bool.False
					} else {
						$sat = Rocsat.add_clause(sat1, differ) ? Solver
					}
				}
			}
		}
		Ok({ found: $found, stopped: $stopped })
	}

	## Up to `limit` different answers, with no limit on the search.
	many : Compiled, [Holding, Failing], U64 -> Try(List(List(U64)), Term.Fault)
	many = |compiled, wanted, limit| {
		listed = many_within(compiled, wanted, limit, no_limit)?
		match listed.stopped {
			Finished => Ok(listed.found)
			GaveUp(effort) => Err(GaveUp(effort))
		}
	}

	## The solver's own counters after answering the question once, within a
	## budget of conflicts.
	counters : Compiled, [Holding, Failing], U64 -> Try({ answer : [Sat, Unsat], counters : Str }, Term.Fault)
	counters = |compiled, wanted, budget| {
		sat0 = load(compiled, wanted)?
		(sat1, answer, _) = search(sat0, asked(compiled, wanted), [], [], budget)?
		match answer {
			Values(_) => Ok({ answer: Sat, counters: Rocsat.stats(sat1) })
			Nothing => Ok({ answer: Unsat, counters: Rocsat.stats(sat1) })
			GaveUp(spent) => Err(GaveUp(spent))
		}
	}
}
