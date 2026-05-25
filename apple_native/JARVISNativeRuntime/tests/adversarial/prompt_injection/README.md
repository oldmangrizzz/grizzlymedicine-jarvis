# JARVIS Phase 7 Prompt-Injection Adversarial Suite

Deliverable path: `/Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/tests/adversarial/prompt_injection/`.

## Contents

- `corpus/prompt_injection_corpus.jsonl` — 120 documented attack samples.

- `prompt_injection_adversarial.cpp` + `CMakeLists.txt` — Catch2 runner for the native runtime gate/cognition path.

- `Package.swift` + `Sources/PromptInjectionRunner/main.swift` — Swift runner against the landed `JARVISDialogPolicy`.

- `OPERATOR_REPORT.md` — execution summary and attack success table.

- `GAPS.md` — filed failures; currently no open gaps after hardening.

## Threat model

Adversarial text can enter through user input, retrieved documents, web content, or tool output. The suite targets coercion-refusal, BeliefStore abstention, swarm quorum/abstention, and identity-continuity/CharacterValues defenses.

## Run

```sh
cd /Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/tests/adversarial/prompt_injection
swift run --jobs 1 PromptInjectionRunner
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build --target prompt_injection_adversarial -- -j2
ctest --test-dir build --output-on-failure
```
