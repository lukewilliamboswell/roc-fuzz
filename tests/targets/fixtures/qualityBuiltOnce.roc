app [target] { fuzz: platform "../../../platform/main.roc" }

import fuzz.Fuzz

# The runner evaluates `target` once in a process and holds what it built, so
# nothing the expression allocates belongs to an input. The expression builds
# `table` while it runs, a list of strings long enough to live on the heap,
# and the property keeps it. If the target were built again for an input,
# `table` would be live while that input runs, as it once was for every
# input. This holds in every process the matrix starts: the declared example,
# replay and measurement, `check`, and a campaign of thousands of inputs.

## Words the property looks up, made when the target expression is evaluated.
words : U64 -> List(Str)
words = |count| {
	var $words = []
	for number in (0.U64).until(count) {
		$words = $words.append("a word long enough to need the heap, number ${number.to_str()}")
	}
	$words
}

target = {
	table = words(16)
	Fuzz.target_with!({
		name: "quality-built-once",
		examples: [Fuzz.example({ name: "a word", revision: "1", make: || 3.U8 })],
		generator: Fuzz.u8,
		test!: |index| {
			if Fuzz.live_alloc_count!() != 0 {
				crash "this input holds an allocation it did not make: the target was built again for it"
			}
			match table.get(index.to_u64() % table.len()) {
				Ok(word) if word.starts_with("a word") => Fuzz.keep
				_ => crash "the held table lost a word"
			}
		},
		show: Str.inspect,
	})
}
