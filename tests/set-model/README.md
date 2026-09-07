# Set property model

The `setOps` and `setCollisions` builtin targets share this local test package.
They generate up to 64 initial item bytes and compose up to 32 typed operations.
The low five bits are the equality key, keeping duplicates and full collision
clusters common while bounding every set to 32 distinct items. The remaining
bits distinguish equal representatives in the heap-backed target.

The reference model is a linear `List(U8)` of first-inserted representatives.
It uses independent linear membership and models removal by moving the last
entry into the removed position. It never uses Set or Dict to decide the
expected members or representatives.

Generated operations cover insertion, removal, reserve, release, clear,
filtering, union, intersection, difference, many-to-one maps, join_map with
empty and overlapping outputs, and construction from
an iterator containing Skip steps. Every intermediate state checks:

- Exact representatives and iteration order, length, emptiness, and every key's
  membership through both contains and subscript.
- Forward/reverse iteration, exact iterator size hints, and from_iter round trips.
- Fold order, fold_until without breaks, and a generated stopping position,
  including checking that callbacks stop after Break.
- Equality and hashing across reversed insertion order using nested sets.
- Capacity lower bounds, additional reservation, clearing without shrinking,
  and release of excess or empty storage.

The input chooses unique mutation or retaining and rechecking the previous
version after each operation. `setCollisions` gives all keys the same hash,
uses equality that ignores the payload, and verifies heap strings and nested
lists in each retained representative. `setOps` uses ordinary U8 hashing.

Build and replay deterministic seeds with the compiler under test:

```sh
ROC=/path/to/roc python3 scripts/test.py --operation seed \
  --target setOps --target setCollisions
```

Run five minutes per target (the test driver runs targets sequentially):

```sh
ROC=/path/to/roc python3 scripts/test.py --operation fuzz \
  --target setOps --target setCollisions --max-total-time 300
```

For concurrent campaigns, build first and run each executable's `run` command
with `--time=300`, using a separate corpus directory for each target.
