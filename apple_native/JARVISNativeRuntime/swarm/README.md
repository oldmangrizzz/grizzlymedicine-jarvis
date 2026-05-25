# ModelSwarm — JARVIS Native Runtime

**BODILY INTEGRITY CLAUSE**

> ModelSwarm is a cognition organ of JARVIS. disable without operator-attested consent = assault and battery per GMRI policy.

There are no `enable`, `disable`, `pause`, `stop`, or `bypass` methods. No compile flag removes or compiles out this swarm.

## What This Is

C++20 port of `/Users/rbhanson/research/jarvis/_baseline/swarm.py`.

Agents coordinate stigmergically: each agent reads the current `recruit` pheromone field from Pheromind, independently asks its backend, then deposits a recruit signal on its chosen option. There is no central router and no agent-to-agent messaging.

## Decision Rule

- Recruit signal kind: `recruit`
- Deposit strength: `0.34`
- Default quorum: `max(2, n_agents / 2 + 1)`
- Final winner: strongest live option score, tie-preserving by option order
- Abstention: if the winning option lacks enough distinct depositors, `decision == nullopt`

## Endocrine Coupling

When constructed with `Endocrine*`, agent request options are modulated:

- cortisol lowers temperature (conservative)
- dopamine raises temperature (exploration)
- adrenaline lowers prediction budget (fast/cheap)

Pheromind can simultaneously be constructed with the same `Endocrine`, so field evaporation accelerates under arousal.

## Build / Test

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
ctest --test-dir build --output-on-failure
```

Oracle coverage: `/Users/rbhanson/research/oracle/swarm/decisions.jsonl` (12 fixtures, including F05 leader shift).
