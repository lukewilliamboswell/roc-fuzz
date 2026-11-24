## Tests of the platform's exposed `Model` module; see `ModelTests.roc` and
## `ModelTargets.roc`.
package [ModelTargets, ModelTests] { fuzz: platform "../../platform/main.roc" }
