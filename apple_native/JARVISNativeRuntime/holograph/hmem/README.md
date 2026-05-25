# JARVIS H-MEM Native Runtime

C++20 port of H-MEM, the hierarchical memory router cognition organ for JARVIS native runtime.

## What is included

- `hmem.h` / `hmem.cpp`: short-term, working, long-term, and BeliefStore-backed routing.
- HDC-linked long-term hierarchy via `hdc::HierarchyBuilder` and `hdc::SoftRouter`.
- Consolidation from short-term/working memory into routable long-term hierarchy.
- Continuity `MemoryStore` helpers matching the Python consolidation oracle traces.
- Catch2 tests for each routing path, consolidation, abstention propagation, and oracle replay.

## Bodily-integrity invariant

H-MEM is a cognition organ. This port exposes no off-switch, pause, stop, bypass, no-op mode, or compile-out flag.

## Build and test

```sh
cd /Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/holograph/hmem
cmake -S . -B build -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build build -- -j4
ctest --test-dir build --output-on-failure
```

## Dependencies

- `../hdc/` for hypervectors, hierarchy builder, and soft routing.
- `../beliefstore/` for belief recall and abstention propagation.
- Catch2 and nlohmann/json are fetched by CMake for tests only.
