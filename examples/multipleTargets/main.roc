app [target] { fuzz: platform "../../platform/main.roc" }
import fuzz.Fuzz
import Collections
import Text

## One build, three independently selectable properties and input types.
target = Fuzz.suite([Collections.split_roundtrip, Collections.concatenate, Text.roundtrip])
