# Third-party software in roc-fuzz platform inputs

The prebuilt files under `platform/targets/x64musl` contain or link the
following third-party software. The platform bundle includes this notice.

| Component | Bundled inputs | License |
| --- | --- | --- |
| LLVM libFuzzer | `libfuzzer.a` | Apache-2.0 WITH LLVM-exception ([LLVM license](https://llvm.org/LICENSE.txt)) |
| LLVM libc++, libc++abi, libunwind, and compiler-rt | `libc++.a`, `libc++abi.a`, `libunwind.a`, `libcompiler_rt.a` | Apache-2.0 WITH LLVM-exception ([LLVM license](https://llvm.org/LICENSE.txt)) |
| musl libc | `crt1.o`, `libc.a` | MIT; Copyright © 2005-2020 Rich Felker and contributors ([musl copyright and license](https://git.musl-libc.org/cgit/musl/tree/COPYRIGHT)) |
| Zig runtime | `libzigc.a`, compiler runtime contributions, and the C malloc wrapper adapted into `src/c_malloc.zig` | MIT; Copyright © Zig contributors ([Zig license](https://github.com/ziglang/zig/blob/master/LICENSE)) |

`libfuzzer.a` is built from the checksum-pinned `libfuzzer-sys` source archive.
That crate's wrapper code is dual-licensed under MIT or Apache-2.0; the Roc
platform does not include the Rust wrapper code in its native runtime.
