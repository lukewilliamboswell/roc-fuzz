app [target] { pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", roc: "nightly-2026-09-05-b195f5b" }

import pf.Fuzz

## Allocation invariant: doing nothing must allocate nothing.
main! : List(U8) => U8
main! = |_data| {
	Fuzz.expect_allocs_at_most!(0, |{}| {})
	0
}

target = Fuzz.from_bytes!({
	name: "noop",
	test!: main!,
})
