app [target] { fuzz: platform "../platform/main.roc" }

# A first model: a queue kept in two lists, checked against one plain list.
#
#     roc test queueModel.roc
#     roc build --fuzz queueModel.roc --output=queue && ./queue run corpus --time=10

import fuzz.Model

## The code under test. `back` holds the newest item first, and `pop`
## turns it round when `front` runs out.
Queue : { front : List(U8), back : List(U8) }

push : Queue, U8 -> Queue
push = |queue, item| { ..queue, back: [item].concat(queue.back) }

pop : Queue -> (Try(U8, [Empty]), Queue)
pop = |queue| match queue.front {
	[first, .. as rest] => (Ok(first), { ..queue, front: rest })
	[] => if (queue.back.is_empty()) (Err(Empty), queue) else pop({ front: turned(queue.back), back: [] })
}

turned : List(U8) -> List(U8)
turned = |items| items.fold([], |out, item| [item].concat(out))

## The model: the real queue beside a list of what it should hold, and at
## most three items of two kinds, so that a search sees every case.
World : { queue : Queue, items : List(U8) }

machine : Model.Machine(World, [Push(U8), Pop])
machine = {
	init: { queue: { front: [], back: [] }, items: [] },
	actions: |world| if (world.items.len() < 3) [Push(1), Push(2), Pop] else [Pop],
	step: |world, action| match action {
		Push(item) => { queue: push(world.queue, item), items: world.items.append(item) }
		Pop => { queue: pop(world.queue).1, items: world.items.drop_first(1) }
	},
	rules: [
		Model.always_step("a pop returns the oldest item", |{ before, action, after: _ }| action != Pop or pop(before.queue).0 == before.items.first().map_err(|_| Empty)),
		Model.always("the queue holds its items in order", |world| world.queue.front.concat(turned(world.queue.back)) == world.items),
		Model.sometimes("the queue holds three items", |world| world.items.len() == 3),
		Model.sometimes_step("a pop turns the back list round", |{ before, action, after: _ }| action == Pop and before.queue.front.is_empty() and !before.queue.back.is_empty()),
		Model.sometimes_step("a pop finds the queue empty", |{ before, action, after: _ }| action == Pop and before.items.is_empty()),
	],
}

## Every sequence of pushes and pops, to the end.
expect Model.check(machine, { depth: 20 }) == { verdict: Holds(Exhausted), states: 41, depth: 5 }

## One path that reaches every goal, kept as a regression and as the fuzz
## target's example.
tour : List([Push(U8), Pop])
tour = [Push(1), Push(2), Push(1), Pop, Pop, Pop, Pop]

expect Model.replay(machine, tour) == { trace: tour, state: machine.init, reached: Model.goals(machine), verdict: Completed }

target = Model.walk_target({ name: "queue", machine, examples: [Model.walk_example(machine, { name: "every goal", revision: "1", trace: tour })] })
