# The solver's internal modules as a package, for the brute-force validation
# in tests/solve/validate, which needs the raw terms that `Solve` hides. No
# application can import it: a platform dependency resolves to main.roc. It is
# test-only and does not belong in the released bundle.
package [Engine, Term] { sat: "https://github.com/lukewilliamboswell/rocsat/releases/download/0.0.2/3vAUWAXKSUvBxELd63BG4FjmGjgrJoHscu2GVFQTHhu.tar.zst" }
