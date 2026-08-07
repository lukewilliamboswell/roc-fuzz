Bugs found in Roc via fuzzing:

 - Memory leak in Str.concat [roc#4846](https://github.com/roc-lang/roc/issues/4856)
 - Bug in borrow analysis leading to use-after-free or memory leak when host calls into Roc
 - Memory leak in List.concat [roc#4870](https://github.com/roc-lang/roc/issues/4870)
 - Second memory leak in List.concat [roc#4899](https://github.com/roc-lang/roc/issues/4899)
 - Memory leak in Str.trimLeft and Str.trimRight [roc#4900](https://github.com/roc-lang/roc/issues/4900)
 - Inconsistentcy with (Str.trimLeft |> Str.trimRight) from Str.trim [roc#4951](https://github.com/roc-lang/roc/issues/4951)
 - Third memory leak in List.concat [roc#4952](https://github.com/roc-lang/roc/issues/4952)
 - Bad results from Str.split with overlapping strings [roc#4953](https://github.com/roc-lang/roc/issues/4953)
 - Stack overflow when passing empty string to Str.toI128 and Str.toU128 [roc#4954](https://github.com/roc-lang/roc/issues/4954)
 - Memory leak in Str.trim [roc#5075](https://github.com/roc-lang/roc/issues/5075)
 - Failure to decrement refcount when in Str/List.releaseExcessCapacity
 - Accessing past the end of the array in isValidUtf8
 - JSON string decoding doesn't handle missing quotation [roc#5168](https://github.com/roc-lang/roc/issues/5168) 
 - F64.from_str hangs for 30+ minutes on adversarial underscore-heavy decimal literal [roc#10660](https://github.com/roc-lang/roc/issues/10660)
