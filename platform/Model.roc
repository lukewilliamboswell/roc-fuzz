import Fuzz
import Target

## Describe a system as a state machine, say what must be true of it, and check
## that several ways. The engines are pure functions of ordinary Roc values, so
## they run in a plain `expect` under `roc test`, and inside a fuzz target
## unchanged.
##
## ```roc
## counter : Model.Machine(U64, [Up, Down])
## counter = {
## 	init: 0,
## 	actions: |n| if n == 0 [Up] else if n == 3 [Down] else [Up, Down],
## 	step: |n, action| match action {
## 		Up => n + 1
## 		Down => n - 1
## 	},
## 	rules: [Model.always("never above three", |n| n <= 3), Model.sometimes("reaches three", |n| n == 3)],
## }
##
## expect Model.check(counter, { depth: 10 }) == { verdict: Holds(Exhausted), states: 4, depth: 3 }
## ```
##
## The engines, weakest assumption first:
##
## - [`check`](#Model.check) visits every state within a number of steps of `init`,
##   and [`explore`](#Model.explore) is the same search with a full report.
## - [`walk`](#Model.walk) follows one path chosen by a list of bytes: the body of a fuzz target.
## - [`replay`](#Model.replay) follows one path given as a list of actions: a regression test.
##   [`apply`](#Model.apply) does the same without asking whether each action is possible.
## - [`step_from`](#Model.step_from) starts at any state at all and takes each action once.
##
## ## Under a fuzzer
##
## [`walk_target`](#Model.walk_target), [`path_target`](#Model.path_target) and
## [`step_target`](#Model.step_target) make a fuzz target from a machine. Each
## checks every rule and reports a broken one as a crash, so the runner
## saves, replays and minimises it like any other finding.
##
## ```roc
## app [target] { fuzz: platform "PLATFORM_URL" }
##
## import fuzz.Model
## import Index
##
## target = Model.path_target({ name: "index", machine: Index.machine, decode: Index.path, examples: [] })
## ```
##
## Each target declares the machine's goals to the runner and marks the ones
## an input reaches. The campaign report then lists every goal with the first
## input that reached it, and the goals no input reached, and a campaign that
## leaves one unreached is `inconclusive`: it passed every rule without going
## where the model says a run must go. Replay a goal's witness with
## `TARGET replay`, or keep it with `TARGET retain` and declare it as an
## example, after which `TARGET check` reaches that goal every time.
##
## ## Rules about steps
##
## A rule is about a state or about one step. A rule about a step is handed
## the state before, the action and the state after, and goes in the same
## list:
##
## ```roc
## Model.always_step("one at a time", |{ before, action: _, after }| after == before + 1 or before == after + 1)
## Model.sometimes_step("comes down from three", |{ before, action, after: _ }| action == Down and before == 3)
## ```
##
## Every engine checks every rule of the machine it is given, so a goal is
## written once and a search, a walk, a replayed path and a single step all
## grade it. See [`Transition`](#Model.Transition).
##
## ## What a search remembers
##
## A search keeps the states it has met and does not look at one twice. "The
## same state" is decided by `==` and the hash ([`check`](#Model.check)) or by a key you
## give ([`explore`](#Model.explore)), and by default a state already met is dropped
## before any rule sees it. So if two different states compare equal, the
## second is never checked and nothing reachable only through it is ever
## visited: a broken state can vanish without a word. Write a state's `is_eq`
## by hand only if it compares everything `step` and the rules read. When in
## doubt, search with `verify: EveryStep`, which checks the rules on every
## state a step produces before asking whether it was met before.
##
## ## When the code under test crashes
##
## Roc code cannot catch a crash, so a `crash` or an integer overflow inside
## `actions`, `step` or a rule ends the engine with no verdict and no trace.
## `roc test` runs each top-level `expect` on its own and reports the crashed
## one as failed with the crash message, and that is all it knows. A fuzz
## campaign does better: the runner saves the input that crashed, and the
## `show` of a [`path_target`](#Model.path_target) prints that input's path
## without running it.
Model := [].{

	## Something that must be true of a machine, listed in its `rules`. The
	## `Str` names the rule in every verdict, so write it as the sentence you
	## want to read when it fails.
	##
	## A rule is about a state ([`always`](#Model.always), [`sometimes`](#Model.sometimes),
	## [`at_rest`](#Model.at_rest)) or about one step ([`always_step`](#Model.always_step),
	## [`sometimes_step`](#Model.sometimes_step)). Every engine checks both kinds.
	Rule(state, action) := [
		Always(Str, state -> Bool),
		Sometimes(Str, state -> Bool),
		AtRest(Str, state -> Bool),
		AlwaysStep(Str, Transition(state, action) -> Bool),
		SometimesStep(Str, Transition(state, action) -> Bool),
	]

	## A rule that must hold in every state an engine visits, the first included.
	always : Str, (state -> Bool) -> Rule(state, action)
	always = |name, holds| Always(name, holds)

	## A goal: a rule that some visited state must satisfy. It guards against
	## a model that passes only because it never gets anywhere interesting.
	## Only a search can say a goal was never reached; a path reports the
	## ones it did reach.
	sometimes : Str, (state -> Bool) -> Rule(state, action)
	sometimes = |name, goal| Sometimes(name, goal)

	## A rule for states where the machine has come to rest: no action is
	## possible, or every possible action leaves the state exactly as it was.
	## Such a state must satisfy `allowed`, otherwise the machine is stuck there
	## and the engines report a `Deadlock`. With no `at_rest` rule, resting
	## anywhere is fine.
	at_rest : Str, (state -> Bool) -> Rule(state, action)
	at_rest = |name, allowed| AtRest(name, allowed)

	## A rule that must hold of every step an engine takes.
	always_step : Str, (Transition(state, action) -> Bool) -> Rule(state, action)
	always_step = |name, holds| AlwaysStep(name, holds)

	## A goal about a step: some step taken must satisfy it.
	sometimes_step : Str, (Transition(state, action) -> Bool) -> Rule(state, action)
	sometimes_step = |name, goal| SometimesStep(name, goal)

	## One step: the state before, the action taken, and the state after.
	##
	## A step rule reads all three, so a fact about what just happened ("a live
	## key was removed", "the count never drops by more than one") needs no
	## field in the state to remember it. That matters to a search: memory kept
	## in the state multiplies the states.
	##
	## A search checks a step rule on every step it takes, including a step
	## that leads back to a state already met. [`walk`](#Model.walk), [`replay`](#Model.replay)
	## and [`apply`](#Model.apply) check it on every step of their path, and
	## [`step_from`](#Model.step_from) on each step it takes from its state.
	Transition(state, action) : { before : state, action : action, after : state }

	## The system: where it starts, what can happen in a state, what happening
	## does, and what must be true. `actions` must list only what is possible in
	## that state, because every engine but [`apply`](#Model.apply) picks from that list
	## and nowhere else, and calls `step` only with an action it returned for
	## that state.
	Machine(state, action) : {
		init : state,
		actions : state -> List(action),
		step : state, action -> state,
		rules : List(Rule(state, action)),
	}

	## The names of a machine's goals, its `sometimes` and `sometimes_step`
	## rules, in the order they are written.
	goals : Machine(state, action) -> List(Str)
	goals = |machine| {
		rules = sorted(machine.rules)
		waiting(rules.goals, rules.step_goals)
	}

	## How much a search covered.
	##
	## - `Exhausted`: the search ran out of new states. Every reachable state
	##   was visited and every step from every one of them was taken, so the
	##   answer is final for this machine, at this size.
	## - `Bounded`: the depth limit stopped it. Every state within `depth`
	##   actions of `init` was visited, and every step of a trace of at most
	##   `depth` actions was taken. The states exactly `depth` actions away were
	##   visited and not stepped from, so whether anything lies beyond them, or
	##   one of them is stuck, is not known.
	Extent : [Exhausted, Bounded]

	## What a search concluded.
	##
	## - `Holds`: no rule failed, as far as the extent says.
	## - `Violated`: an `always` rule failed. `trace` is a shortest list of
	##   actions from `init` to a state, or through a step, that breaks any
	##   `always` rule. The search stopped there.
	## - `Deadlock`: `trace` leads to a resting state its `at_rest` rule
	##   forbids. The search stopped there.
	## - `Unreached`: no `always` rule failed, and no state visited or step
	##   taken satisfied this `sometimes` rule. When the extent is `Exhausted`
	##   none ever will.
	Verdict(action) : [
		Holds(Extent),
		Violated({ rule : Str, trace : List(action) }),
		Deadlock({ rule : Str, trace : List(action) }),
		Unreached({ rule : Str, extent : Extent }),
	]

	## A verdict with the size of the search behind it: the number of distinct
	## states visited, and how many actions the farthest of them is from `init`
	## (for `Violated`, the length of the trace).
	Search(action) : { verdict : Verdict(action), states : U64, depth : U64 }

	## Visit every state reachable from `init` in at most `depth` actions,
	## nearest first, remembering the states already seen.
	##
	## The states are held in memory and compared by value, so this is for
	## small configurations: shrink the sizes until the search is `Exhausted`.
	##
	## A state equal to one already seen is dropped before any rule sees it, so
	## the state's `==` must not call two different states equal. See "What a
	## search remembers" above, and [`explore`](#Model.explore) for the way out.
	check : Machine(state, action), { depth : U64 } -> Search(action)
		where [state.is_eq : state, state -> Bool, state.to_hash : state, Hasher -> Hasher]
	check = |machine, { depth }| {
		report = explore(machine, { depth, key: itself })
		{ verdict: report.verdict, states: report.states, depth: report.depth }
	}

	## How to search. Only `depth` and `key` must be given.
	##
	## - `depth`: stop after this many actions from `init`.
	## - `key`: what the search remembers a state by. Two states with equal
	##   keys are one state to the search: the second is not stepped from, and
	##   a step from one to the other is no move at all to an `at_rest` rule.
	##   Pass `|state| state` to remember the whole state, or a part of it when
	##   the rest has no hash, such as a reference kept beside the real
	##   structure. A key that leaves something out is only sound when the
	##   rules pin the rest to it, and then only with `verify: EveryStep`.
	## - `verify`: `NewStates` checks the state rules once for each new key.
	##   `EveryStep` checks them on the state after every step, before asking
	##   whether its key was met, so a broken state can no longer hide behind
	##   an equal key. It costs one round of rules for each step instead of
	##   each state, and it does not step from the hidden state. Rules about
	##   steps are checked on every step either way.
	## - `blame`: with `FirstRule`, `broken` names the one rule the verdict
	##   names. With `EveryRule` it names every `always` rule the offending
	##   state and step break, so the order of the rules does not decide which
	##   is blamed. Every rule is then called on a state that already broke
	##   one, so they must not crash on such a state.
	Options(state, key) := {
		depth : U64,
		key : state -> key,
		verify : [NewStates, EveryStep] ?? NewStates,
		blame : [FirstRule, EveryRule] ?? FirstRule,
	}

	## Everything a search found.
	##
	## - `verdict`: as [`check`](#Model.check) gives it, naming the first problem.
	## - `states`: the distinct keys visited. `depth`: how many actions the
	##   farthest of them is from `init` (for `Violated`, the length of the
	##   trace). `steps`: how many steps were taken and checked.
	## - `broken`: the `always` or `at_rest` rules the offending state and step
	##   break, state rules first; see `blame` in [`Options`](#Model.Options). Empty unless
	##   the verdict is `Violated` or `Deadlock`.
	## - `reached`: every goal that was met, in the order the rules are
	##   written, each with a shortest trace that meets it.
	## - `unreached`: every goal that was not met, not only the first. After
	##   `Violated` or `Deadlock` the search stopped early, so these two lists
	##   say only how far it had got.
	Report(action) : {
		verdict : Verdict(action),
		states : U64,
		depth : U64,
		steps : U64,
		broken : List(Str),
		reached : List({ rule : Str, trace : List(action) }),
		unreached : List(Str),
	}

	## The search behind [`check`](#Model.check), with the whole of what it found and a
	## say in how it runs: see [`Options`](#Model.Options) and [`Report`](#Model.Report).
	##
	## ```roc
	## report = Model.explore(machine, { depth: 100, key: |world| world.reference, verify: EveryStep })
	## ```
	##
	## The state needs no `==` and no hash of its own, only its key does.
	explore : Machine(state, action), Options(state, key) -> Report(action)
		where [key.is_eq : key, key -> Bool, key.to_hash : key, Hasher -> Hasher]
	explore = |machine, options| {
		rules = sorted(machine.rules)
		count = machine.rules.len()
		every = options.verify == EveryStep
		key = options.key
		init = machine.init
		match first_broken(rules.always, init) {
			Broken(rule) => {
				broken = match options.blame {
					FirstRule => [rule]
					EveryRule => every_broken(rules.always, init)
				}
				return { verdict: Violated({ rule, trace: [] }), states: 1, depth: 0, steps: 0, broken, reached: [], unreached: waiting(rules.goals, rules.step_goals) }
			}
			Fine => {}
		}
		rests = !rules.rest.is_empty()
		var $found = rules.goals.keep_if(|wanted| (wanted.test)(init)).map(|met| { id: met.id, rule: met.name, trace: [] })
		var $state_goals = rules.goals.drop_if(|wanted| (wanted.test)(init))
		var $step_goals = rules.step_goals
		init_key = key(init)
		var $seen = Set.empty().insert(init_key)
		var $frontier = [{ state: init, key: init_key, trace: [] }]
		var $level = 0
		var $deepest = 0
		var $steps = 0
		while $level < options.depth and !$frontier.is_empty() {
			var $next = []
			for node in $frontier {
				var $moved = Bool.False
				for action in (machine.actions)(node.state) {
					after = (machine.step)(node.state, action)
					$steps = $steps + 1
					after_key = key(after)
					if !$moved and after_key != node.key {
						$moved = Bool.True
					}
					new = !$seen.contains(after_key)
					look = new or every
					step = { before: node.state, action, after }
					state_broken = if (look) first_broken(rules.always, after) else Fine
					either_broken = match state_broken {
						Fine => first_broken(rules.step_always, step)
						Broken(rule) => Broken(rule)
					}
					match either_broken {
						Broken(rule) => {
							broken = match options.blame {
								FirstRule => [rule]
								EveryRule => every_broken(rules.always, after).concat(every_broken(rules.step_always, step))
							}
							return {
								verdict: Violated({ rule, trace: node.trace.append(action) }),
								states: if (new) $seen.len() + 1 else $seen.len(),
								depth: $level + 1,
								steps: $steps,
								broken,
								reached: witnesses($found, count),
								unreached: waiting($state_goals, $step_goals),
							}
						}
						Fine => {}
					}
					if look and $state_goals.any(|wanted| (wanted.test)(after)) {
						trace = node.trace.append(action)
						$found = $found.concat($state_goals.keep_if(|wanted| (wanted.test)(after)).map(|met| { id: met.id, rule: met.name, trace }))
						$state_goals = $state_goals.drop_if(|wanted| (wanted.test)(after))
					}
					if $step_goals.any(|wanted| (wanted.test)(step)) {
						trace = node.trace.append(action)
						$found = $found.concat($step_goals.keep_if(|wanted| (wanted.test)(step)).map(|met| { id: met.id, rule: met.name, trace }))
						$step_goals = $step_goals.drop_if(|wanted| (wanted.test)(step))
					}
					if new {
						$seen = $seen.insert(after_key)
						$next = $next.append({ state: after, key: after_key, trace: node.trace.append(action) })
						$deepest = $level + 1
					}
				}
				if rests and !$moved {
					match first_broken(rules.rest, node.state) {
						Broken(rule) => {
							broken = match options.blame {
								FirstRule => [rule]
								EveryRule => every_broken(rules.rest, node.state)
							}
							return {
								verdict: Deadlock({ rule, trace: node.trace }),
								states: $seen.len(),
								depth: $deepest,
								steps: $steps,
								broken,
								reached: witnesses($found, count),
								unreached: waiting($state_goals, $step_goals),
							}
						}
						Fine => {}
					}
				}
			}
			if $next.is_empty() {
				$frontier = []
			} else {
				$frontier = $next
				$level = $level + 1
			}
		}
		extent = if ($frontier.is_empty()) Exhausted else Bounded
		unreached = waiting($state_goals, $step_goals)
		verdict = match unreached.first() {
			Ok(rule) => Unreached({ rule, extent })
			Err(_) => Holds(extent)
		}
		{ verdict, states: $seen.len(), depth: $deepest, steps: $steps, broken: [], reached: witnesses($found, count), unreached }
	}

	## The shortest trace the search found that meets the `sometimes` rule
	## with this name.
	witness : Report(action), Str -> Try(List(action), [NotReached])
	witness = |report, rule| match report.reached.find_first(|met| met.rule == rule) {
		Ok(met) => Ok(met.trace)
		Err(_) => Err(NotReached)
	}

	## A report in plain words: the verdict, then what the search covered, and
	## so what the verdict does and does not establish.
	##
	## ```roc
	## expect Model.explain(Model.explore(counter, { depth: 10, key: |n| n })) == "Holds for every reachable state. The search ran out of new states: 4 visited, the farthest 3 actions from the start, and every step from each of them checked (6 steps). Goals reached: 1 of 1."
	## ```
	explain : Report(action) -> Str
	explain = |report| {
		states = report.states.to_str()
		depth = report.depth.to_str()
		steps = report.steps.to_str()
		total = (report.reached.len() + report.unreached.len()).to_str()
		missed = "${report.unreached.len().to_str()} of ${total}"
		exhausted = "The search ran out of new states: ${states} visited, the farthest ${depth} actions from the start, and every step from each of them checked (${steps} steps)."
		bounded = "The depth limit stopped the search: ${states} states visited, ${steps} steps checked, and the farthest states not stepped from."
		stopped = "The search stopped there (states visited: ${states}, steps checked: ${steps})."
		match report.verdict {
			Holds(Exhausted) => "Holds for every reachable state. ${exhausted} Goals reached: ${total} of ${total}."
			Holds(Bounded) => "Holds within ${depth} actions of the start, and nothing is known beyond that. ${bounded} Goals reached: ${total} of ${total}."
			Unreached({ rule: _, extent: Exhausted }) => "No rule fails in any reachable state, and ${missed} goals can never be reached: ${quoted(report.unreached)}. ${exhausted}"
			Unreached({ rule: _, extent: Bounded }) => "No rule fails within ${depth} actions of the start, and ${missed} goals were not reached there: ${quoted(report.unreached)}. They may be reachable further on. ${bounded}"
			Violated({ rule, trace }) => "Violated: \"${rule}\" fails at the end of a trace of length ${trace.len().to_str()}, and no shorter trace breaks an `always` rule. Rules broken there: ${quoted(report.broken)}. ${stopped}"
			Deadlock({ rule, trace }) => "Deadlock: a trace of length ${trace.len().to_str()} leaves the machine at rest where \"${rule}\" forbids it, and no shorter trace breaks any rule. ${stopped}"
		}
	}

	## What happened along one path.
	##
	## `trace` holds the actions actually taken, `state` is where the path
	## ended, and `reached` names the goals met on the way, by a state or by
	## a step.
	##
	## - `Completed`: every choice was taken, or nothing more could happen, and no rule failed.
	## - `Violated`: an `always` rule failed in `state`, or an `always_step`
	##   rule on the step into it. The path stops there.
	## - `Deadlock`: the path ended at rest in a state its `at_rest` rule forbids.
	## - `Impossible`: only from [`replay`](#Model.replay). The action at index `at`
	##   was not among the possible actions in `state`.
	Run(state, action) : {
		trace : List(action),
		state : state,
		reached : List(Str),
		verdict : [Completed, Violated({ rule : Str }), Deadlock({ rule : Str }), Impossible({ at : U64 })],
	}

	## Follow one path from `init`, letting each byte choose among the actions
	## possible at that moment (`byte % count`). Every byte list is therefore a
	## valid path and none is ever rejected. The path ends when the bytes run
	## out, an `always` rule fails, or nothing can happen.
	##
	## This is the body of a fuzz target: pass it the fuzzer's bytes and crash
	## unless the verdict is `Completed`. The same bytes always give the same
	## path, and a shorter byte list gives a prefix of it, so the fuzzer's
	## minimiser shortens the trace. Only the first 256 possible actions in a
	## state can be chosen.
	walk : Machine(state, action), List(U8) -> Run(state, action)
		where [state.is_eq : state, state -> Bool]
	walk = |machine, bytes| strict(
		drive(
			machine,
			bytes,
			|state, byte, _| {
				options = (machine.actions)(state)
				count = options.len()
				if count == 0 {
					Stop
				} else {
					match options.get(byte.to_u64() % count) {
						Ok(action) => Take({ action, listed: Bool.True })
						Err(_) => Stop
					}
				}
			},
		),
	)

	## Follow a path given as actions, checking that each one is possible when
	## its turn comes. Paste the trace from a failed [`check`](#Model.check) or a
	## fuzzer's finding here to keep it as an ordinary `expect`.
	replay : Machine(state, action), List(action) -> Run(state, action)
		where [state.is_eq : state, state -> Bool, action.is_eq : action, action -> Bool]
	replay = |machine, trace| strict(
		drive(
			machine,
			trace,
			|state, action, at| {
				if ((machine.actions)(state).contains(action)) Take({ action, listed: Bool.True }) else Refuse(at)
			},
		),
	)

	## What happened along a path of actions applied as given.
	##
	## As [`Run`](#Model.Run), and besides: `unreached` names every goal the
	## path did not meet, in the order the rules are written, and `outside`
	## holds the index of each action that `actions` did not list when its
	## turn came. Those were applied all the same, so a rule that failed
	## after one may be the path's fault and not the machine's.
	Applied(state, action) : {
		trace : List(action),
		state : state,
		reached : List(Str),
		unreached : List(Str),
		outside : List(U64),
		verdict : [Completed, Violated({ rule : Str }), Deadlock({ rule : Str })],
	}

	## Follow a path given as actions without asking whether each one is
	## possible: `step` is called with every action in turn, and the rules
	## are checked as it goes. Use it to grade a path made elsewhere against
	## a machine's rules and goals: the schedule of an existing test, or the
	## actions a fuzz target decodes from its input. The machine then needs
	## no `actions` wide enough to list every action such a path may use.
	##
	## Because `actions` is not consulted first, `step` must accept whatever
	## the path holds.
	apply : Machine(state, action), List(action) -> Applied(state, action)
		where [state.is_eq : state, state -> Bool, action.is_eq : action, action -> Bool]
	apply = |machine, path| {
		ran = drive(machine, path, |state, action, _| Take({ action, listed: (machine.actions)(state).contains(action) }))
		rules = sorted(machine.rules)
		{
			trace: ran.trace,
			state: ran.state,
			reached: ran.reached,
			unreached: waiting(rules.goals, rules.step_goals).drop_if(|name| ran.reached.contains(name)),
			outside: ran.outside,
			verdict: ran.verdict,
		}
	}

	## The bytes that make [`walk`](#Model.walk) take exactly this trace, or the
	## index of the first action that is not possible (or is beyond the 256 a
	## byte can choose). Use it to seed a fuzz corpus with a trace from `check`.
	walk_bytes : Machine(state, action), List(action) -> Try(List(U8), [Impossible({ at : U64 })])
		where [action.is_eq : action, action -> Bool]
	walk_bytes = |machine, trace| {
		var $state = machine.init
		var $bytes = []
		for action in trace {
			match position((machine.actions)($state), action) {
				Ok(index) if index < 256 => {
					$bytes = $bytes.append(index.to_u8_wrap())
				}
				_ => {
					return Err(Impossible({ at: $bytes.len() }))
				}
			}
			$state = (machine.step)($state, action)
		}
		Ok($bytes)
	}

	## What one step from a given state showed.
	##
	## - `Outside`: the state itself breaks this `always` rule, so it says nothing. A fuzz target rejects it.
	## - `Preserved`: each of `actions` possible actions was a step that keeps
	##   every `always_step` rule, into a state that keeps every `always` rule.
	##   `reached` names the goals met by the state, by one of those steps or
	##   by a state one led to.
	## - `Broken`: after `action`, this `always` rule fails, or the step itself breaks this `always_step` rule.
	## - `Stuck`: the state satisfies every `always` rule but is at rest where its `at_rest` rule forbids.
	Step(action) : [Outside({ rule : Str }), Preserved({ actions : U64, reached : List(Str) }), Broken({ rule : Str, action : action }), Stuck({ rule : Str })]

	## Start from any state at all, reachable or not, and take each possible
	## action once.
	##
	## If the rules hold in `init`, and no rule-satisfying state can break them
	## in one step, then they hold in every reachable state, however far away.
	## So feed this states from a generator instead of walking to them: a state
	## one step short of a sequence-number wrap is as easy to generate as an
	## empty one.
	##
	## A `Broken` or `Stuck` answer is not yet a bug. Either the state is
	## reachable and it is one, or it is not and the rules are too weak to rule
	## it out: add the missing `always` rule and run again. The rules are strong
	## enough when this only ever answers `Outside` or `Preserved`.
	step_from : Machine(state, action), state -> Step(action)
		where [state.is_eq : state, state -> Bool]
	step_from = |machine, state| {
		rules = sorted(machine.rules)
		match first_broken(rules.always, state) {
			Broken(rule) => {
				return Outside({ rule: rule })
			}
			Fine => {}
		}
		options = (machine.actions)(state)
		var $moved = Bool.False
		var $reached = reached(rules.goals, state, [])
		for action in options {
			next = (machine.step)(state, action)
			step = { before: state, action, after: next }
			either_broken = match first_broken(rules.always, next) {
				Fine => first_broken(rules.step_always, step)
				Broken(rule) => Broken(rule)
			}
			match either_broken {
				Broken(rule) => {
					return Broken({ rule, action })
				}
				Fine => {}
			}
			$reached = reached(rules.step_goals, step, reached(rules.goals, next, $reached))
			if !$moved and next != state {
				$moved = Bool.True
			}
		}
		if !$moved {
			match first_broken(rules.rest, state) {
				Broken(rule) => {
					return Stuck({ rule: rule })
				}
				Fine => {}
			}
		}
		Preserved({ actions: options.len(), reached: $reached })
	}

	## Walks from `init` as a fuzz target. The fuzzer's bytes are the input,
	## each one choosing among the possible actions ([`walk`](#Model.walk)), so
	## no input is rejected and the minimiser shortens the trace by deleting
	## bytes. `show` prints the trace taken, the state it ended in and the
	## verdict.
	##
	## `examples` are traces: paste in one printed by [`check`](#Model.check)
	## or by a failed run and it is checked on every run and seeds the corpus.
	## Bound the walk's length with the runner's `--max-input-size`.
	##
	## When the code under test crashes on a walk, `show` crashes with it,
	## because it has to take the walk to know the trace. Use
	## [`path_target`](#Model.path_target) where that matters: its `show`
	## prints the path without running it.
	walk_target : { name : Str, machine : Machine(state, action), examples : List({ name : Str, trace : List(action) }) } -> Target
		where [state.is_eq : state, state -> Bool, action.is_eq : action, action -> Bool]
	walk_target = |{ name, machine, examples }| Fuzz.target_with!({
		name,
		examples: examples.map(
			|example| Fuzz.example({
				name: example.name,
				revision: "1",
				make: || match walk_bytes(machine, example.trace) {
					Ok(bytes) => bytes
					Err(Impossible(stopped)) => crash "example ${example.name}: action ${stopped.at.to_str()} of its trace is not possible"
				},
			}),
		),
		generator: Fuzz.raw_bytes,
		test!: |bytes| {
			run = walk(machine, bytes)
			match run.verdict {
				Completed => kept!(run.reached)
				_ => crash "${Str.inspect(run.verdict)} after ${Str.inspect(run.trace)}"
			}
		},
		show: |bytes| Str.inspect(walk(machine, bytes)),
	}).with_goals_from(|| goals(machine))

	## A path from `init` made by `decode` from the fuzzer's bytes and applied
	## as it comes ([`apply`](#Model.apply)), as a fuzz target: the machine's
	## `actions` are not asked whether each action is possible, so the actions
	## can be drawn from a space far too wide to list. `decode` must be total,
	## so that no input is rejected, and should turn a prefix of the bytes
	## into a prefix of the path, so that the minimiser shortens the trace.
	##
	## `examples` are inputs: bytes that `decode` turns into the paths to
	## check on every run.
	##
	## `show` prints the decoded path and does not run it. The path is in the
	## input, so when the code under test crashes on it, `show` still prints
	## the trace that led there: the last action of the minimised input is
	## the one that crashed. `TARGET replay` names the goals an input reaches.
	path_target : { name : Str, machine : Machine(state, action), decode : List(U8) -> List(action), examples : List(Fuzz.Example(List(U8))) } -> Target
		where [state.is_eq : state, state -> Bool, action.is_eq : action, action -> Bool]
	path_target = |{ name, machine, decode, examples }| Fuzz.target_with!({
		name,
		examples,
		generator: Fuzz.raw_bytes,
		test!: |bytes| {
			# The runner adds up the goals of a campaign, so an input says only
			# what it reached, and asks nothing of `actions`.
			run = drive(machine, decode(bytes), |_, action, _| Take({ action, listed: Bool.True }))
			match run.verdict {
				Completed => kept!(run.reached)
				_ => crash "${Str.inspect(run.verdict)} after ${Str.inspect(run.trace)}"
			}
		},
		show: |bytes| Str.inspect(decode(bytes)),
	}).with_goals_from(|| goals(machine))

	## One step from a generated state as a fuzz target:
	## [`step_from`](#Model.step_from) on whatever `generator` makes. A state
	## that already breaks an `always` rule is rejected, so the report's
	## rejected count says how often the generator misses. `show` prints the
	## state and what one step from it found.
	##
	## `examples` are states to start the search from. The platform encodes
	## each one as a corpus seed and mutates the encoded state directly, which
	## gives the fuzzer valid states to vary even when the generator almost
	## never makes one.
	step_target : { name : Str, machine : Machine(state, action), generator : Fuzz.Generator(state), examples : List(Fuzz.Example(state)) } -> Target
		where [state.is_eq : state, state -> Bool, state.Fuzz.Encodable, state.Fuzz.Parseable(errs)]
	step_target = |{ name, machine, generator, examples }| Fuzz.target_with!({
		name,
		examples,
		generator,
		test!: |state| match step_from(machine, state) {
			Outside(_) => Fuzz.reject
			Preserved(found) => kept!(found.reached)
			other => crash "${Str.inspect(other)} from ${Str.inspect(state)}"
		},
		show: |state| Str.inspect({ state, step: step_from(machine, state) }),
	}).with_goals_from(|| goals(machine))
}

## Keep an input that broke no rule, and tell the runner which goals it met.
kept! : List(Str) => Fuzz.Outcome
kept! = |met| {
	for goal in met {
		Fuzz.mark!(goal)
	}
	Fuzz.keep
}

## What `check` remembers a state by: all of it.
itself : state -> state
itself = |state| state

## A rule as the engines hold it: its place in the machine's list, its name
## and its test. What it is about, and what it demands, is told by the list
## it was sorted into.
Held(subject) : { id : U64, name : Str, test : subject -> Bool }

## A machine's rules, sorted by kind.
Sorted(state, action) : {
	always : List(Held(state)),
	goals : List(Held(state)),
	rest : List(Held(state)),
	step_always : List(Held(Model.Transition(state, action))),
	step_goals : List(Held(Model.Transition(state, action))),
}

sorted : List(Model.Rule(state, action)) -> Sorted(state, action)
sorted = |rules| {
	var $always = []
	var $goals = []
	var $rest = []
	var $step_always = []
	var $step_goals = []
	var $id = 0
	for rule in rules {
		match rule {
			Always(name, test) => {
				$always = $always.append({ id: $id, name, test })
			}
			Sometimes(name, test) => {
				$goals = $goals.append({ id: $id, name, test })
			}
			AtRest(name, test) => {
				$rest = $rest.append({ id: $id, name, test })
			}
			AlwaysStep(name, test) => {
				$step_always = $step_always.append({ id: $id, name, test })
			}
			SometimesStep(name, test) => {
				$step_goals = $step_goals.append({ id: $id, name, test })
			}
		}
		$id = $id + 1
	}
	{ always: $always, goals: $goals, rest: $rest, step_always: $step_always, step_goals: $step_goals }
}

## The first of these rules that this state, or this step, fails.
first_broken : List(Held(subject)), subject -> [Fine, Broken(Str)]
first_broken = |rules, subject| {
	for rule in rules {
		if !(rule.test)(subject) {
			return Broken(rule.name)
		}
	}
	Fine
}

## Every one of these rules that this state, or this step, fails.
every_broken : List(Held(subject)), subject -> List(Str)
every_broken = |rules, subject| {
	var $broken = []
	for rule in rules {
		if !(rule.test)(subject) {
			$broken = $broken.append(rule.name)
		}
	}
	$broken
}

## Rule names as they read in a sentence: quoted, with commas between.
quoted : List(Str) -> Str
quoted = |rules| Str.join_with(rules.map(|rule| "\"${rule}\""), ", ")

## The names of these goals, about states and about steps, in the order
## their rules were written. Each list is already in that order, so this
## merges the two by their places in the machine's list.
waiting : List(Held(state)), List(Held(step)) -> List(Str)
waiting = |state_goals, step_goals| {
	var $names = []
	var $state_at = 0
	var $step_at = 0
	while $state_at < state_goals.len() or $step_at < step_goals.len() {
		match (state_goals.get($state_at), step_goals.get($step_at)) {
			(Ok(about_state), Ok(about_step)) if about_state.id > about_step.id => {
				$names = $names.append(about_step.name)
				$step_at = $step_at + 1
			}
			(Ok(about_state), _) => {
				$names = $names.append(about_state.name)
				$state_at = $state_at + 1
			}
			(Err(_), Ok(about_step)) => {
				$names = $names.append(about_step.name)
				$step_at = $step_at + 1
			}
			(Err(_), Err(_)) => {
				break
			}
		}
	}
	$names
}

## The goals met, in the order their rules were written.
witnesses : List({ id : U64, rule : Str, trace : List(action) }), U64 -> List({ rule : Str, trace : List(action) })
witnesses = |found, count| {
	var $met = []
	for id in 0..<count {
		match found.find_first(|met| met.id == id) {
			Ok(met) => {
				$met = $met.append({ rule: met.rule, trace: met.trace })
			}
			Err(_) => {}
		}
	}
	$met
}

## Add the goals this state, or this step, meets to the names already
## reached. One plain loop: the list functions here cost a fuzz target many
## times as long to compile, and bought no speed.
reached : List(Held(subject)), subject, List(Str) -> List(Str)
reached = |wanted_goals, subject, seen| {
	var $seen = seen
	for wanted in wanted_goals {
		if !$seen.contains(wanted.name) and (wanted.test)(subject) {
			$seen = $seen.append(wanted.name)
		}
	}
	$seen
}

## Is this state at rest: can nothing happen, or nothing that changes it?
resting : Model.Machine(state, action), state -> Bool
	where [state.is_eq : state, state -> Bool]
resting = |machine, state| (machine.actions)(state).all(|action| (machine.step)(state, action) == state)

position : List(item), item -> Try(U64, [NotFound])
	where [item.is_eq : item, item -> Bool]
position = |items, wanted| {
	var $index = 0
	for item in items {
		if item == wanted {
			return Ok($index)
		}
		$index = $index + 1
	}
	Err(NotFound)
}

## What `drive` found along one path. `refused` is the index of a choice that
## `choose` would not take, which ends the path.
Path(state, action) : {
	trace : List(action),
	state : state,
	reached : List(Str),
	outside : List(U64),
	verdict : [Completed, Violated({ rule : Str }), Deadlock({ rule : Str })],
	refused : [Nothing, At(U64)],
}

## A path as `walk` and `replay` report it.
strict : Path(state, action) -> Model.Run(state, action)
strict = |path| {
	trace: path.trace,
	state: path.state,
	reached: path.reached,
	verdict: match path.refused {
		At(at) => Impossible({ at: at })
		Nothing => match path.verdict {
			Completed => Completed
			Violated(found) => Violated(found)
			Deadlock(found) => Deadlock(found)
		}
	},
}

## The loop behind `walk`, `replay`, `apply` and the fuzz targets. `choose`
## turns the state and the next choice into the action to take, and says
## whether that action was among the possible ones. It asks `actions` only if
## it needs to, so a path that is applied as it comes costs nothing there.
drive : Model.Machine(state, action), List(choice), (state, choice, U64 -> [Take({ action : action, listed : Bool }), Stop, Refuse(U64)]) -> Path(state, action)
	where [state.is_eq : state, state -> Bool]
drive = |machine, choices, choose| {
	rules = sorted(machine.rules)
	var $state = machine.init
	var $trace = []
	var $outside = []
	var $reached = reached(rules.goals, $state, [])
	match first_broken(rules.always, $state) {
		Broken(rule) => {
			return { trace: $trace, state: $state, reached: $reached, outside: $outside, verdict: Violated({ rule: rule }), refused: Nothing }
		}
		Fine => {}
	}
	for choice in choices {
		match choose($state, choice, $trace.len()) {
			Take({ action, listed }) => {
				if !listed {
					$outside = $outside.append($trace.len())
				}
				step = { before: $state, action, after: (machine.step)($state, action) }
				$state = step.after
				$trace = $trace.append(action)
				state_broken = first_broken(rules.always, $state)
				either_broken = match state_broken {
					Fine => first_broken(rules.step_always, step)
					Broken(rule) => Broken(rule)
				}
				match either_broken {
					Broken(rule) => {
						return { trace: $trace, state: $state, reached: $reached, outside: $outside, verdict: Violated({ rule: rule }), refused: Nothing }
					}
					Fine => {}
				}
				$reached = reached(rules.step_goals, step, reached(rules.goals, $state, $reached))
			}
			Refuse(at) => {
				return { trace: $trace, state: $state, reached: $reached, outside: $outside, verdict: Completed, refused: At(at) }
			}
			Stop => {
				break
			}
		}
	}
	# A stuck state can never be left, so if the path entered one it ended there.
	if !rules.rest.is_empty() and resting(machine, $state) {
		match first_broken(rules.rest, $state) {
			Broken(rule) => {
				return { trace: $trace, state: $state, reached: $reached, outside: $outside, verdict: Deadlock({ rule: rule }), refused: Nothing }
			}
			Fine => {}
		}
	}
	{ trace: $trace, state: $state, reached: $reached, outside: $outside, verdict: Completed, refused: Nothing }
}

# ---------------------------------------------------------------------------
# The toolbox checked against a machine small enough to work out by hand: a
# counter that may go up to `top`, and a rule that says it stays below `limit`.
# ---------------------------------------------------------------------------

counter : U64, U64 -> Model.Machine(U64, [Up, Down])
counter = |top, limit| {
	init: 0,
	actions: |n| if (n == 0) [Up] else if (n == top) [Down] else [Up, Down],
	step: |n, action| match action {
		Up => n + 1
		Down => n - 1
	},
	rules: [Model.always("stays below the limit", |n| n < limit), Model.sometimes("reaches three", |n| n == 3)],
}

expect Model.check(counter(3, 4), { depth: 10 }) == { verdict: Holds(Exhausted), states: 4, depth: 3 }
expect Model.check(counter(9, 10), { depth: 5 }) == { verdict: Holds(Bounded), states: 6, depth: 5 }
expect Model.check(counter(9, 5), { depth: 10 }) == { verdict: Violated({ rule: "stays below the limit", trace: [Up, Up, Up, Up, Up] }), states: 6, depth: 5 }
expect Model.check(counter(2, 4), { depth: 10 }) == { verdict: Unreached({ rule: "reaches three", extent: Exhausted }), states: 3, depth: 2 }
expect Model.check(counter(9, 10), { depth: 2 }) == { verdict: Unreached({ rule: "reaches three", extent: Bounded }), states: 3, depth: 2 }
expect Model.check(counter(9, 0), { depth: 10 }) == { verdict: Violated({ rule: "stays below the limit", trace: [] }), states: 1, depth: 0 }

# A depth that is exactly the distance of the farthest state is still
# `Bounded`: all four states were visited, and the last was not stepped from.
expect Model.check(counter(3, 4), { depth: 3 }) == { verdict: Holds(Bounded), states: 4, depth: 3 }
expect Model.check(counter(3, 4), { depth: 4 }) == { verdict: Holds(Exhausted), states: 4, depth: 3 }
expect Model.check(counter(3, 4), { depth: 0 }) == { verdict: Unreached({ rule: "reaches three", extent: Bounded }), states: 1, depth: 0 }

# Byte 0 picks the first possible action, byte 1 the second.
expect Model.walk(counter(9, 10), [0, 0, 1, 0]) == { trace: [Up, Up, Down, Up], state: 2, reached: [], verdict: Completed }
expect Model.walk(counter(9, 2), [0, 0, 0, 0]) == { trace: [Up, Up], state: 2, reached: [], verdict: Violated({ rule: "stays below the limit" }) }
expect Model.walk(counter(9, 10), [0, 0, 0]).reached == ["reaches three"]

expect Model.replay(counter(9, 10), [Up, Up, Down]).verdict == Completed
expect Model.replay(counter(9, 10), [Up, Down, Down]) == { trace: [Up, Down], state: 0, reached: [], verdict: Impossible({ at: 2 }) }

# `walk_bytes` and `walk` are inverses on possible traces.
expect Model.walk_bytes(counter(9, 10), [Up, Up, Down, Up]) == Ok([0, 0, 1, 0])
expect Model.walk_bytes(counter(9, 10), [Down]) == Err(Impossible({ at: 0 }))

# One step from anywhere: 3 is fine below a limit of 5, 4 steps over it, 7 is outside.
expect Model.step_from(counter(9, 5), 3) == Preserved({ actions: 2, reached: ["reaches three"] })
expect Model.step_from(counter(9, 5), 4) == Broken({ rule: "stays below the limit", action: Up })
expect Model.step_from(counter(9, 5), 7) == Outside({ rule: "stays below the limit" })

## A lift that jams when it reaches the top floor: every button still responds
## and nothing moves.
lift : Model.Machine(U64, [Up, Down])
lift = {
	init: 0,
	actions: |_| [Up, Down],
	step: |floor, action| match action {
		Up => if (floor < 2) floor + 1 else floor
		Down => if (floor == 2 or floor == 0) floor else floor - 1
	},
	rules: [Model.at_rest("the lift never jams", |_| Bool.False)],
}

expect Model.check(lift, { depth: 10 }) == { verdict: Deadlock({ rule: "the lift never jams", trace: [Up, Up] }), states: 3, depth: 2 }
expect Model.walk(lift, [0, 1, 0, 0, 1, 1]).verdict == Deadlock({ rule: "the lift never jams" })
expect Model.walk(lift, [0, 1, 0]).verdict == Completed
expect Model.step_from(lift, 2) == Stuck({ rule: "the lift never jams" })
