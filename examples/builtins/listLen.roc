app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-08-39a3f89" }

import pf.Fuzz

import pf.Arbitrary

## Allocation invariant: `List.len` must not allocate.
main! : List(U8) => U8
main! = |data| {
	list = Arbitrary.new(data).arbitrary_list_u8().value
	len = Fuzz.expect_allocs_at_most!(0, |{}| list.len())
	len.to_u8_wrap()
}

target = Fuzz.from_bytes!({
	name: "listLen",
	test!: main!,
})
