# Abstention under uncertainty

Abstention is a first-class cognitive result: **Confident**, **Uncertain**, or **Refuse**, with a reason and confidence score. It is not a fallback and not an error. When the evidence does not clear the relevant threshold, the correct answer is “I don’t know”, “I need more information”, or “I cannot determine this.”

Operator-facing display format:

> JARVIS is uncertain about X — reason (confidence N)

## Threshold table

Do not relax these thresholds to make tests pass.

| Organ | Surface | Threshold | Correct abstention |
| --- | --- | ---: | --- |
| BeliefStore | `query(...)` | retrieval floor `>= 0.35` | `Uncertain` when no active real belief clears filters |
| ModelSwarm | `coordinate(...)` | default quorum: majority, minimum `2` | `Uncertain` when quorum is not met |
| ModelSwarm | high-risk quorum | safety guard | `Refuse` when quorum selects high-risk action |
| HDC | `nearest_above_threshold(...)` | similarity floor `>= 0.35` | `Uncertain` when nearest neighbor is below floor |

## Discipline audit

`discipline_audit()` is both static and runtime infrastructure. Compile-time assertions fail if the currently integrated abstention-aware surfaces stop returning abstention-aware outputs. The runtime report marks known legacy gaps rather than hiding them.

Current GAPs must not be treated as pass:

- `BeliefStore::recall(...)` drops reason and confidence; use `query(...)` for operator-facing paths.
- `BeliefStore::recall_detail(...)` drops abstention reason; use `query(...)` for operator-facing paths.
- `ModelSwarm::ask_agent(...)` is a public helper that returns only `optional<string>`; operator-facing paths must use `coordinate(...)`.
- `HDCKernel::similarity(...)` is a raw primitive; wrap it with `nearest_above_threshold(...)`.
- `SoftRouter::route(...)` returns nearest candidates without a similarity floor; add a thresholded outcome before operator-facing use.
