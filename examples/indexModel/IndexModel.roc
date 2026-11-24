import fuzz.Model
import ReadyIndex
import SeededIndex

## `Model` on real code, read top to bottom. Run it with `roc test main.roc`.
##
## The code under test is `ReadyIndex.roc` beside this file: the compressed
## binary radix tree that roc-signals keeps its ready owners in, copied
## unedited from that project (its header names the commit).
##
## A model is a machine that drives the real code (1), rules that must
## always hold (1) and goals that some step must reach (2). An engine then
## runs it: a search of every path (3), one given path (4), the same search
## on a copy of the code with a bug in it (5), and a fuzzer (`IndexPaths.roc`).
IndexModel := [].{
	# -----------------------------------------------------------------------
	# 1. The machine: the real index, and beside it a reference
	# -----------------------------------------------------------------------

	Entry : { key : U64, value : U64 }

	## The state: the real index, and the live entries in key order, a list
	## too plain to get wrong. Every action is applied to both.
	World(index) : { index : index, reference : List(Entry) }

	Action : [Insert(U64, U64), Remove(U64)]

	## Six keys, which part from one another at bits 0, 1, 62 and 63. Each
	## can be inserted with either of two values, so that an overwrite shows.
	keys : List(U64)
	keys = [0, 1, 2, 0x4000000000000000, 0x8000000000000000, 0x8000000000000001]

	possible : List(Action)
	possible = keys.join_map(|key| [Insert(key, 10), Insert(key, 20), Remove(key)])

	key_of : Action -> U64
	key_of = |action| match action {
		Insert(key, _) => key
		Remove(key) => key
	}

	## Looked up after a step: its own key, two never inserted, the six, the live.
	probes : List(Entry), Action -> List(U64)
	probes = |live, action| [key_of(action), 3, 0xffffffffffffffff].concat(keys).concat(live.map(|entry| entry.key))

	put : List(Entry), Entry -> List(Entry)
	put = |entries, new| entries.keep_if(|old| old.key < new.key).append(new).concat(entries.keep_if(|old| old.key > new.key))

	held : List(Entry), U64 -> Try(U64, [Missing])
	held = |entries, key| entries.find_first(|entry| entry.key == key).map_ok(|entry| entry.value).map_err(|_| Missing)

	## The machine drives any type that has these six operations, so that
	## section 5 can aim it at a copy of the module with a bug in it. The
	## first four `rules` must always hold, three of every state and the
	## lookups of every step. The fourth is the promise in the comment on
	## `ReadyIndex.insert`, "The tree shape is canonical for its key set", and
	## it trusts the module's own `==`. The rest are the goals of section 2.
	machine : index -> Model.Machine(World(index), Action)
		where [
			index.insert : index, Entry -> index,
			index.remove : index, U64 -> index,
			index.get : index, U64 -> Try(U64, [Missing]),
			index.len : index -> U64,
			index.is_valid : index -> Bool,
			index.is_eq : index, index -> Bool,
		]
	machine = |empty| {
		init: { index: empty, reference: [] },
		actions: |_| possible,
		step: |world, action| match action {
			Insert(key, value) => { index: world.index.insert({ key, value }), reference: put(world.reference, { key, value }) }
			Remove(key) => { index: world.index.remove(key), reference: world.reference.drop_if(|entry| entry.key == key) }
		},
		rules: [
			Model.always("the length is the number of live keys", |world| world.index.len() == world.reference.len()),
			Model.always_step("a lookup returns what the reference holds", |{ before: _, action, after }| probes(after.reference, action).all(|key| after.index.get(key) == held(after.reference, key))),
			Model.always("the index calls itself valid", |world| world.index.is_valid()),
			Model.always("the shape is that of a fresh build from the same entries", |world| world.index == world.reference.fold(empty, |index, entry| index.insert(entry))),
		].concat(goals({})),
	}

	# -----------------------------------------------------------------------
	# 2. Goals: one for each structural event, each a rule about one step
	# -----------------------------------------------------------------------

	## What a step does to the tree: whether the key was live, the bit of the
	## fork above it, and whether one leaf or a subtree hangs on that fork's
	## other side. The nodes are private, so this is worked out from the keys
	## live before the step: those that part from `key` at the lowest bit are
	## its fork's other child. The state remembers no step, hence 729 states.
	Event : { did : [Inserted, Overwrote, Removed, Missed], sibling : [Nothing, Leaf, Subtree], bit : U8 }

	event_of : List(Entry), Action -> Event
	event_of = |entries, action| {
		key = key_of(action)
		others = entries.map(|entry| entry.key).drop_if(|other| other == key)
		parts_at = |other| 63 - key.bitwise_xor(other).count_leading_zero_bits()
		bit = others.fold(63, |lowest, other| U8.min(lowest, parts_at(other)))
		beside = others.count_if(|other| parts_at(other) == bit)
		live = others.len() < entries.len()
		{
			did: match action {
				Insert(_, _) => if (live) Overwrote else Inserted
				Remove(_) => if (live) Removed else Missed
			},
			sibling: if (beside == 0) Nothing else if (beside == 1) Leaf else Subtree,
			bit,
		}
	}

	## A goal is a `sometimes` rule about a step: some step taken must do this.
	## Such a rule is handed the state before, the action and the state after.
	goal : Str, (Event -> Bool) -> Model.Rule(World(index), Action)
	goal = |name, wanted| Model.sometimes_step(name, |{ before, action, after: _ }| wanted(event_of(before.reference, action)))

	## One goal for each arm of `insert` and `remove`. (A function of nothing,
	## because a Roc value has one type and these serve two kinds of index.)
	goals : {} -> List(Model.Rule(World(index), Action))
	goals = |{}| [
		goal("an insert fills an empty index", |event| event.did == Inserted and event.sibling == Nothing),
		goal("an insert overwrites a live key", |event| event.did == Overwrote),
		goal("an insert forks beside a single leaf", |event| event.did == Inserted and event.sibling == Leaf),
		goal("an insert forks above a whole subtree", |event| event.did == Inserted and event.sibling == Subtree),
		goal("an insert forks at bit 63", |event| event.did == Inserted and event.sibling != Nothing and event.bit == 63),
		goal("an insert forks at bit 0", |event| event.did == Inserted and event.sibling != Nothing and event.bit == 0),
		goal("removing a missing key leaves an empty index alone", |event| event.did == Missed and event.sibling == Nothing),
		goal("removing a missing key leaves a populated index alone", |event| event.did == Missed and event.sibling != Nothing),
		goal("removing the last key empties the index", |event| event.did == Removed and event.sibling == Nothing),
		goal("a removal collapses a fork onto its other leaf", |event| event.did == Removed and event.sibling == Leaf),
		goal("a removal collapses a fork onto its other subtree", |event| event.did == Removed and event.sibling == Subtree),
	]

	## For section 4, the schedule of the third expect in `ReadyIndex.roc`: 96
	## turns over twelve keys, some removing and the others inserting the turn.
	schedule : List(Action)
	schedule = {
		twelve = [0, 1, 2, 3, 255, 256, 257, 0x7fffffffffffffff, 0x8000000000000000, 0x8000000000000001, 0xfffffffffffffffe, 0xffffffffffffffff]
		var $actions = []
		for turn in 0.U64..<96 {
			key = twelve.get((turn * 7) % 12) ?? 0
			$actions = $actions.append(if ((turn // 12) % 3 == 0) Remove(key) else Insert(key, turn))
		}
		$actions
	}
}

# ---------------------------------------------------------------------------
# 3. The search: every sequence of actions
# ---------------------------------------------------------------------------

real = IndexModel.machine(ReadyIndex.empty())

## `ReadyIndex` has `==` and no hash, so `key` tells the search to remember a
## world by its reference. Two worlds with one reference and two trees would
## then pass for one, so `verify: EveryStep` checks every world a step makes.
search : Model.Machine(IndexModel.World(index), IndexModel.Action) -> Model.Report(IndexModel.Action)
search = |subject| Model.explore(subject, { depth: 100, key: |world| world.reference, verify: EveryStep, blame: EveryRule })

## What this establishes: over these six keys and two values, no sequence of
## inserts and removals of any length breaks a rule, and every goal can be
## reached. What it does not: anything about a seventh key, or about a fork
## at any of the sixty bits where these six never part. `IndexPaths.roc` does.
expect Model.explain(search(real)) == "Holds for every reachable state. The search ran out of new states: 729 visited, the farthest 6 actions from the start, and every step from each of them checked (13122 steps). Goals reached: 11 of 11."

## Every goal comes back with a shortest trace that reaches it.
expect Model.witness(search(real), "a removal collapses a fork onto its other subtree") == Ok([Insert(0, 10), Insert(1, 10), Insert(2, 10), Remove(2)])

# ---------------------------------------------------------------------------
# 4. A finding: the module's own test, graded by the same goals
# ---------------------------------------------------------------------------

## `Model.apply` takes a path as it comes. 80 of the 96 actions of `schedule`
## use a key or a value that `possible` does not list, and are applied all
## the same. The test breaks no rule and misses one goal: it only ever
## removes a missing key while the index is empty.
expect {
	run = Model.apply(real, IndexModel.schedule)
	run.verdict == Completed and run.outside.len() == 80 and run.unreached == ["removing a missing key leaves a populated index alone"]
}

## The search reaches that goal in two actions.
expect Model.witness(search(real), "removing a missing key leaves a populated index alone") == Ok([Insert(0, 10), Remove(1)])

# ---------------------------------------------------------------------------
# 5. A seeded bug in the arm the test never enters
# ---------------------------------------------------------------------------

## `SeededIndex.roc` is `ReadyIndex.roc` with one line of `remove` changed:
## removing a missing key from a populated index takes one off the count.
## The module's three expects are in that copy too, and pass. The search fails
## on the two-action trace above, and `blame: EveryRule` names every rule
## broken there, so the order they are written in decides nothing.
expect {
	report = search(IndexModel.machine(SeededIndex.empty()))
	report.verdict == Violated({ rule: "the length is the number of live keys", trace: [Insert(0, 10), Remove(1)] }) and report.broken == [
		"the length is the number of live keys",
		"the index calls itself valid",
		"the shape is that of a fresh build from the same entries",
	]
}
