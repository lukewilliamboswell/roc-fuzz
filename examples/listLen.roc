app [main] { pf: platform "../platform/main.roc" }

import pf.Arbitrary

main : List(U8) -> U8
main = |data| Arbitrary.new(data).arbitrary_list_u8().value.len().to_u8_wrap()
