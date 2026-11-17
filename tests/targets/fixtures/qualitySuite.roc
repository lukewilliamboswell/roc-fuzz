app [target] { fuzz: platform "../../../platform/main.roc" }
import fuzz.Fuzz

numbers = Fuzz.target_with({ name: "numbers", generator: Fuzz.u8, test: |_value| Fuzz.keep, show: Str.inspect, examples: [Fuzz.example({ name: "number-example", revision: "1", make: || 7.U8 })] })

text = Fuzz.target_with({ name: "text", generator: Fuzz.str, test: |_value| Fuzz.keep, show: Str.inspect, examples: [Fuzz.example({ name: "text-example", revision: "1", make: || "independent" })] })

failures = Fuzz.target_with({ name: "failures", generator: Fuzz.raw_bytes, test: |_value| crash "selected failure property", show: Str.inspect, examples: [Fuzz.example({ name: "failure-example", revision: "1", make: || [] })] })

target = Fuzz.suite([numbers, Fuzz.suite([text, failures])])
