import fuzz.Model
import IndexModel
import ReadyIndex
import SeededIndex

## The fuzzer's half of `IndexModel.roc`. Read that file first.
##
## Its search is exhaustive over six keys and silent about a seventh, and
## about a fork at any bit where those six never part. Here the same
## machine, with the same rules and the same goals, runs on paths made from
## a fuzzer's bytes, with keys of all 64 bits (1, 2). `roc test main.roc`
## runs the paths written out in section 3, and `main.roc` makes the fuzz
## target. Section 4 says what its campaigns found.
IndexPaths := [].{
	# -----------------------------------------------------------------------
	# 1. The same model, and a goal for every bit
	# -----------------------------------------------------------------------

	Action : IndexModel.Action

	## The goal that some insert forks at this bit.
	forks_at : U8 -> Model.Rule(IndexModel.World(index), Action)
	forks_at = |bit| IndexModel.goal("an insert forks at bit ${bit.to_str()}", |event| event.did == Inserted and event.sibling != Nothing and event.bit == bit)

	## A machine of `IndexModel.roc`, unchanged, and after its eleven goals
	## one for each of the 62 bits between the two that the six keys reach.
	widen : Model.Machine(IndexModel.World(index), Action) -> Model.Machine(IndexModel.World(index), Action)
	widen = |machine| {
		var $rules = machine.rules
		for bit in 1.U8..<63 {
			$rules = $rules.append(forks_at(bit))
		}
		{ ..machine, rules: $rules }
	}

	# -----------------------------------------------------------------------
	# 2. From a fuzzer's bytes to a path
	# -----------------------------------------------------------------------

	## Keys shaped so that they fork: three bytes are an action. The first
	## says insert or remove, the second picks a key that an earlier action
	## named (0 to begin with), and the third picks one bit of that key to
	## flip, unless the first byte says to leave the key as it is.
	##
	## Two keys drawn at random part at bit 63 half the time, and at bit 32
	## once in four thousand million pairs. A key one bit from an earlier key
	## parts from it at exactly that bit, whichever bit it is.
	##
	## What the shaping costs: a path spends an action for each bit by which
	## two keys differ, and an action means what it means only after the ones
	## before it: change one early byte and every key after it is another key.
	shaped : List(U8) -> List(Action)
	shaped = |bytes| {
		var $named = [0.U64]
		var $actions = []
		var $at = 0
		while $at + 3 <= bytes.len() {
			how = bytes.get($at) ?? 0
			from = $named.get((bytes.get($at + 1) ?? 0).to_u64() % $named.len()) ?? 0
			bit = (bytes.get($at + 2) ?? 0) % 64
			key = if (how % 4 < 2) from.bitwise_xor((1.U64).shl_wrap(bit)) else from
			$actions = $actions.append(act(how, key, $actions.len()))
			if !$named.contains(key) {
				$named = $named.append(key)
			}
			$at = $at + 3
		}
		$actions
	}

	## Keys read straight from the input, each put through a function that
	## spreads its bits over all 64: nine bytes are an action, one to say
	## insert or remove and eight for the key. These are the keys a test
	## would draw at random, and section 4 shows what they miss.
	uniform : List(U8) -> List(Action)
	uniform = |bytes| {
		var $actions = []
		var $at = 0
		while $at + 9 <= bytes.len() {
			var $key = 0.U64
			for byte in bytes.sublist({ start: $at + 1, len: 8 }) {
				$key = $key.shl_wrap(8).bitwise_or(byte.to_u64())
			}
			$actions = $actions.append(act(bytes.get($at) ?? 0, mixed($key), $actions.len()))
			$at = $at + 9
		}
		$actions
	}

	## One path that reaches every goal, which `main.roc` declares as its
	## example: 0, each power of two from the bottom up, an overwrite, the
	## removal of a key that was never there, every key out again from the
	## top down, and one removal from the empty index.
	tour : List(U8)
	tour = {
		var $bytes = [2, 0, 0]
		for bit in 0.U8..<64 {
			$bytes = $bytes.concat([0, 0, bit])
		}
		$bytes = $bytes.concat([2, 0, 0, 1, 1, 1])
		for back in 0.U8..<65 {
			$bytes = $bytes.concat([3, 64 - back, 0])
		}
		$bytes.concat([3, 0, 0])
	}
}

## An even byte inserts, with the action's place in the path as the value,
## so that no two inserts carry the same one. An odd byte removes.
act : U8, U64, U64 -> IndexPaths.Action
act = |how, key, place| if (how % 2 == 0) Insert(key, place) else Remove(key)

## The last step of SplitMix64: a one-to-one scramble of the 64 bits.
mixed : U64 -> U64
mixed = |key| {
	once = key.bitwise_xor(key.shr_zf_wrap(30)).times_wrap(0xbf58476d1ce4e5b9)
	twice = once.bitwise_xor(once.shr_zf_wrap(27)).times_wrap(0x94d049bb133111eb)
	twice.bitwise_xor(twice.shr_zf_wrap(31))
}

# ---------------------------------------------------------------------------
# 3. Paths written out: what `roc test` checks
# ---------------------------------------------------------------------------

wide = IndexPaths.widen(IndexModel.machine(ReadyIndex.empty()))

## What the search could not reach, in six bytes: a fork at bit 32.
expect IndexPaths.shaped([2, 0, 0, 0, 0, 32]) == [Insert(0, 0), Insert(0x100000000, 1)]
expect Model.apply(wide, IndexPaths.shaped([2, 0, 0, 0, 0, 32])).reached == ["an insert fills an empty index", "an insert forks beside a single leaf", "an insert forks at bit 32"]

## The tour breaks no rule and reaches all 73 goals.
expect {
	run = Model.apply(wide, IndexPaths.shaped(IndexPaths.tour))
	run.verdict == Completed and run.trace.len() == 133 and run.reached.len() == 73 and run.unreached == []
}

## The seeded bug of `SeededIndex.roc` breaks a rule on the second action of
## a shaped path: insert 0, then remove 32, which was never there.
expect Model.apply(IndexPaths.widen(IndexModel.machine(SeededIndex.empty())), IndexPaths.shaped([2, 0, 0, 1, 0, 5])).verdict == Violated({ rule: "the length is the number of live keys" })

# ---------------------------------------------------------------------------
# 4. What the campaigns found
# ---------------------------------------------------------------------------

## Campaigns of 60 seconds from an empty corpus, three seeds each, on the
## target that `main.roc` makes, without its example. The real index broke
## no rule in any of them.
##
## Goals. With `shaped` keys every campaign reached all 73. With `uniform`
## keys every campaign passed every rule and reached 28 to 31 of the 73, and
## none a fork at bit 39 or below: by its rules alone that campaign looks as
## good as the others, and only its goals say it never tested a deep fork.
## Its report says `inconclusive` and names each goal it missed.
##
## Seeded bugs. `SeededIndex` under this target was a finding in every
## campaign, within the first thousand paths. Of 26 one-line bugs seeded
## in turn, one is a fork at bit 32 gone wrong: the six-key search passes
## it, because none of the six part at bit 32. Every campaign with `shaped`
## keys, or with keys read straight from the input, found it, in 912 to
## 7,993 paths, and all three with `uniform` keys missed it. Every finding
## replayed, and was minimised to three actions or fewer.
