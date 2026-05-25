# JARVIS HoloGraph SAGE

SAGE is the JARVIS native writer-reader memory consolidation loop. It ingests recent experience, extracts relation triples, writes long-term memory through HDC encodings, commits belief edges to BeliefStore, routes memory via H-MEM, and runs consolidation cycles across reader feedback and sleep-boundary conflict resolution.

Bodily-integrity invariant: this cognition organ has no disable, pause, stop, bypass, no-op, or compile-out path.

## Build and test

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
ctest --test-dir build --output-on-failure
```

The oracle test reads `/Users/rbhanson/research/oracle/holograph/api_traces.jsonl` by default and validates all SAGE-section records.
