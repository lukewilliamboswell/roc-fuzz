# roc-fuzz

`roc-fuzz` is a coverage-guided software-quality platform for Roc. You write a small Roc function whose input is arbitrary bytes and whose assertions describe the behavior that must always hold; `cargo-fuzz` then explores that function and saves any reproducible crash or failed invariant.

The released workflow supports Linux x86-64 with glibc.

## Use the released platform

Install the Roc nightly named in [`.roc-version`](.roc-version) and `cargo-fuzz`:

```sh
cargo install cargo-fuzz
roc version
```

Each release publishes a content-addressed Roc platform bundle (`.tar.zst`). Reference that bundle from a quality target in your own project. Replace `<released-bundle-url>` with the URL copied from the release:

```roc
app [main] { pf: platform "<released-bundle-url>" }

import pf.Arbitrary

main : List(U8) -> U8
main = |data| {
	input = Arbitrary.new(data).arbitrary_str().value
	parsed : Try(U64, _)
	parsed = Json.parse(input)

	match parsed {
		Ok(value) => {
			round_tripped : Try(U64, _)
			round_tripped = Json.parse(Json.to_str(value))
			if round_tripped != Ok(value) {
				crash "JSON U64 changed during a round trip"
			}
			0
		}
		Err(_) => 1
	}
}
```

The required boundary is `main : List(U8) -> U8`. Importing `pf.Arbitrary` is optional, but it is useful for deterministically deriving strings, byte lists, sizes, ratios, and varied allocation shapes from the fuzzer input.

Build the Roc app as an instrumented archive. The output name is intentional: the Rust host links it as `roc_fuzz`.

```sh
mkdir -p target/roc-fuzz
roc build --fuzz --target=x64glibc --opt=speed \
  quality/json_u64.roc \
  --output=target/roc-fuzz/libroc_fuzz.a
```

Create a normal cargo-fuzz target in your Rust project and add the published ABI host crate:

```sh
cargo fuzz init
cargo fuzz add json_u64
cargo add --manifest-path fuzz/Cargo.toml roc-fuzz@0.1.0
```

Use this as `fuzz/fuzz_targets/json_u64.rs`:

```rust
#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    roc_fuzz::call_roc(data);
});
```

Then point the host crate at the archive and run cargo-fuzz independently:

```sh
ROC_FUZZ_ARCHIVE="$PWD/target/roc-fuzz/libroc_fuzz.a" \
cargo fuzz run --sanitizer=none json_u64
```

The absolute `ROC_FUZZ_ARCHIVE` path makes Cargo rerun the host build when the archive changes. `--sanitizer=none` disables additional Rust runtime checking while cargo-fuzz still instruments the Rust harness for coverage; `roc build --fuzz` separately instruments the Roc app and builtins. Pass ordinary libFuzzer options after `--`, for example `-- -max_total_time=60`, and pass a corpus directory before it if you want discoveries retained across runs.

## What is `fuzz/`?

[`fuzz/`](fuzz) is this repository’s conventional cargo-fuzz companion crate and a working example of the setup above. Cargo-fuzz keeps its `#![no_main]` executable separate from the reusable root library, so `fuzz/Cargo.toml` depends on both `libfuzzer-sys` and `roc-fuzz`, while [`fuzz/fuzz_targets/roc-fuzz.rs`](fuzz/fuzz_targets/roc-fuzz.rs) only forwards each input byte slice to `roc_fuzz::call_roc`.

It is not part of the Roc `.tar.zst` bundle or the published Rust host crate. Consumers create the equivalent directory in their own project with `cargo fuzz init`. Its `corpus/` and `artifacts/` subdirectories are cargo-fuzz runtime state and are ignored by Git.

## Included examples

[`examples/`](examples) contains 31 quality targets for modern Roc builtins. They serve as executable examples and as the platform’s regression matrix. Their deterministic seeds and enabled stages live in [`scripts/test_spec.json`](scripts/test_spec.json); four targets for removed legacy APIs remain recorded there with their retirement reasons.

Platform implementation, release bundling, compiler development, the spec driver, and the LLVM coverage change are documented in [CONTRIBUTING.md](CONTRIBUTING.md).
