Stack := [].{
	push : List(a), a -> List(a)
	push = |items, item| List.prepend(items, item)

	pop : List(a) -> Try({ value : a, rest : List(a) }, [Empty])
	pop = |items|
		match items {
			[first, .. as rest] => Ok({ value: first, rest })
			[] => Err(Empty)
		}
}
