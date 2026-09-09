Model :: {}.{
	# Raw bytes are representatives; only their low five bits determine equality.
	# This linear-list oracle never uses Set/Dict membership or insertion.
	Op : [Insert(U8), Remove(U8), Reserve(U64), Release, Clear, Keep(U8), Drop(U8), Union(List(U8)), Intersection(List(U8)), Difference(List(U8)), Map(U8), JoinMap(U8), FromIter(List(U8), U8)]
	Input : { initial : List(U8), capacity : U64, stop : U64, shared : Bool, ops : List(Op) }

	operation : U8, U8, U64, List(U8) -> Op
	operation = |kind, value, capacity, items| match kind {
		0 => Insert(value)
		1 => Remove(value)
		2 => Reserve(capacity)
		3 => Release
		4 => Clear
		5 => Keep(value % 33)
		6 => Drop(value % 33)
		7 => Union(items)
		8 => Intersection(items)
		9 => Difference(items)
		10 => Map(value)
		11 => JoinMap(value)
		_ => FromIter(items, value % 33)
	}

	contains : List(U8), U8 -> Bool
	contains = |xs, raw| List.any(xs, |x| x % 32 == raw % 32)

	insert : List(U8), U8 -> List(U8)
	insert = |xs, raw| if contains(xs, raw) xs else xs.append(raw)

	from_list : List(U8) -> List(U8)
	from_list = |xs| List.fold(xs, [], insert)

	remove : List(U8), U8 -> List(U8)
	remove = |xs, raw| {
		if !contains(xs, raw) {
			return xs
		}
		last = List.last(xs) ?? crash "model lost last element"
		prefix = List.take_first(xs, xs.len() - 1)
		List.map(prefix, |x| if x % 32 == raw % 32 last else x)
	}

	verify : Set(item), List(U8), (U8 -> item), (item -> U8), U64 -> {}
		where [item.is_eq : item, item -> Bool, item.to_hash : item, Hasher -> Hasher]
	verify = |set, model, make, token, stop| {
		expected = List.map(model, |raw| token(make(raw)))
		actual = List.map(set.to_list(), token)
		if actual != expected {
			crash "Set ordered representatives differ from list model"
		}
		if set.len() != model.len() or set.is_empty() != model.is_empty() {
			crash "Set length differs from model"
		}
		if set.capacity() < set.len() {
			crash "Set capacity below length"
		}
		for key in 0.U8..<32 {
			present = contains(model, key)
			if set.contains(make(key)) != present or set.subscript(make(key)) != present {
				crash "Set membership differs from model"
			}
		}
		if List.from_iter(set.iter().map(token)) != expected {
			crash "Set.iter changed order"
		}
		if List.from_iter(set.iter_rev().map(token)) != List.fold(expected, [], |acc, x| acc.prepend(x)) {
			crash "Set.iter_rev changed order"
		}
		if set.iter().size_hint() != Known(set.len()) {
			crash "Set iterator length hint is not exact"
		}
		if set.fold([], |acc, item| acc.append(token(item))) != expected {
			crash "Set.fold changed order"
		}
		if set.fold_until([], |acc, item| Continue(acc.append(token(item)))) != expected {
			crash "Set.fold_until Continue changed order"
		}
		limit = stop % 34
		folded = set.fold_until(
			[],
			|acc, item| {
				if acc.len() > limit {
					crash "Set.fold_until called step after Break"
				}
				next = acc.append(token(item))
				if acc.len() == limit Break(next) else Continue(next)
			},
		)
		if folded != expected.take_first(limit + 1) {
			crash "Set.fold_until Break returned wrong prefix"
		}
		rebuilt = Set.from_iter(set.iter())
		reversed = Set.from_iter(set.iter_rev())
		if set != rebuilt or set != reversed {
			crash "Set equality depends on order or capacity"
		}
		if !Set.single(set).contains(reversed) {
			crash "Equal sets have incompatible hashes"
		}
		{}
	}

	run : Input, (U8 -> item), (item -> U8) -> {}
		where [item.is_eq : item, item -> Bool, item.to_hash : item, Hasher -> Hasher]
	run = |input, make, token| {
		initial = Set.with_capacity(input.capacity)
		if initial.capacity() < input.capacity or !initial.is_empty() {
			crash "Set.with_capacity violated request"
		}
		var $set = List.fold(input.initial, initial, |s, raw| s.insert(make(raw)))
		var $model = from_list(input.initial)
		verify($set, $model, make, token, input.stop)
		for op in input.ops {
			# Generate both unique mutations and mutations with an older live alias.
			previous = if input.shared $set else Set.empty()
			previous_model = $model
			before_capacity = $set.capacity()
			match op {
				Insert(raw) => {
					$set = $set.insert(make(raw))
					$model = insert($model, raw)
				}
				Remove(raw) => {
					$set = $set.remove(make(raw))
					$model = remove($model, raw)
				}
				Reserve(extra) => {
					$set = $set.reserve(extra)
					if $set.capacity() < $model.len() + extra or $set.capacity() < before_capacity {
						crash "Set.reserve lost requested capacity"
					}
				}
				Release => {
					$set = $set.release_excess_capacity()
					if $set.capacity() > before_capacity {
						crash "Set.release_excess_capacity grew storage"
					}
					if $model.is_empty() and $set.capacity() != 0 {
						crash "Set.release_excess_capacity retained empty storage"
					}
				}
				Clear => {
					$set = $set.clear()
					$model = []
					if $set.capacity() != before_capacity {
						crash "Set.clear changed capacity"
					}
				}
				Keep(cutoff) => {
					$set = $set.keep_if(|item| token(item) % 32 >= cutoff)
					$model = $model.keep_if(|raw| raw % 32 >= cutoff)
				}
				Drop(cutoff) => {
					$set = $set.drop_if(|item| token(item) % 32 >= cutoff)
					$model = $model.drop_if(|raw| raw % 32 >= cutoff)
				}
				Union(raws) => {
					$set = $set.union(Set.from_list(raws.map(make)))
					$model = List.fold(raws, $model, insert)
				}
				Intersection(raws) => {
					$set = $set.intersection(Set.from_list(raws.map(make)))
					$model = $model.keep_if(|raw| contains(raws, raw))
				}
				Difference(raws) => {
					$set = $set.difference(Set.from_list(raws.map(make)))
					$model = $model.drop_if(|raw| contains(raws, raw))
				}
				Map(offset) => {
					$set = $set.map(|item| make((token(item) % 32 % (offset % 32 + 1)).plus_wrap(offset)))
					$model = from_list($model.map(|raw| (raw % 32 % (offset % 32 + 1)).plus_wrap(offset)))
				}
				JoinMap(offset) => {
					$set = $set.join_map(
						|item| {
							k = token(item) % 32
							if k % 3 == offset % 3 Set.empty() else Set.from_list([make(k), make(k.plus_wrap(offset))])
						},
					)
					$model = from_list($model.join_map(|raw| if raw % 32 % 3 == offset % 3 [] else [raw % 32, (raw % 32).plus_wrap(offset)]))
				}
				FromIter(raws, cutoff) => {
					# Filtering exercises leading/interleaved/all Skip steps.
					$set = Set.from_iter(raws.iter().keep_if(|raw| raw % 32 < cutoff).map(make))
					$model = from_list(raws.keep_if(|raw| raw % 32 < cutoff))
				}
			}
			verify($set, $model, make, token, input.stop)
			if input.shared {
				verify(previous, previous_model, make, token, input.stop)
			}
		}
		{}
	}
}
