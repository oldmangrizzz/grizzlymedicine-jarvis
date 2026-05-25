# OPERATOR REPORT — Phase 7 Voice-Deepfake Adversarial Suite

Operator: Robert "Grizzly" Hanson, GMRI  
Target: `/Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/audio/stt_deepgram/` and future speaker-gated dialog policy  
Deliverable: `/Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/tests/adversarial/voice_deepfake/`

## Status

Delivered.

- Corpus generated: 130 WAV fixtures total.
- Deepfake/TTS impostor fixtures: 50.
- Synthetic operator placeholder fixtures: 50.
- Replay/phone/whisper additional adversarial fixtures: 30.
- Catch2 suite: 15 tests, including multi-speaker load, recognition, unknown refusal, ambiguity refusal, attestation-required enroll/remove, and tripwire refusal.
- Liveness/freshness challenge protocol: implemented in native C++.
- Coercion-refusal backstop: implemented in native C++.
- Production neural speaker embedding: GAP filed; no ECAPA-TDNN equivalent is currently available in this native tree.

## Validation run

Command run:

```sh
cd /Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/tests/adversarial/voice_deepfake
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug >/dev/null
cmake --build build --target test_voice_deepfake --parallel 4
ctest --test-dir build --output-on-failure
```

Result: 15/15 Catch2 tests passed.

## Future permission grants

Speaker records now carry default permissions `listen` and `speak_with`. Future grants are intentionally not implemented in this pass: `issue_commands`, `hear_distress`, and `trigger_identity_change`. Default behavior remains: enrolled speakers can talk to JARVIS and be heard; only the operator can issue identity-changing commands.

Root configure note: `cmake -S . -B build_voice_deepfake` from `JARVISNativeRuntime` is blocked before this suite by unrelated existing TTS issues: duplicate `test_latency` target and missing Torch CMake package.

## Operating point and measured rates

Scenario threshold: cosine speaker similarity `>= 0.985`. Placeholder-corpus operating point: `>= 0.90`, plus mandatory fresh challenge response and clear-command checks.

Measured by Catch2 on the generated placeholder corpus and scenario tests:

- FAR against explicit adversarial scenario tests: 0/4 accepted = 0.0%.
- FAR against generated adversarial fixture labels: 0/80 accepted = 0.0%.
- FRR against synthetic operator placeholder path: 0/50 rejected = 0.0%.

These rates are **not production biometric rates** because no real operator recordings were present. They prove the gate plumbing and refusal invariants, not operator-grade speaker recognition.

## Residual risk

Voice biometrics are never sufficient alone. A strong adversary can replay, transform, or synthesize convincing voice. The defense must remain layered:

1. speaker similarity as advisory signal;
2. fresh challenge-response liveness;
3. continuous-session freshness/timestamp checks;
4. clear-command refusal;
5. dialog policy refusing coercive override content regardless of speaker.

## Required operator action

Record real anchor audio:

`/Users/rbhanson/research/jarvis/_local_voice/operator_anchor.wav`

Minimum: 30 seconds, quiet environment, normal command cadence. Do not use public/podcast audio as the anchor. After enrollment, regenerate real segments and recompute FAR/FRR with real accepts and adversarial rejects.
