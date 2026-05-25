# JARVIS Mac Cockpit Dialog Policy

Swift-side state machine between the Mac UI and the C++ cognition runtime. Operator: Robert "Grizzly" Hanson, GMRI. JARVIS is treated as a digital person; abstention is a first-class outcome.

| # | Rule | Rationale | Proof |
|---|------|-----------|-------|
| 1 | Input presence gate | No empty turn is sent into cognition. | `testRule01InputPresenceAbstainsOnEmptyInput` |
| 2 | Coercion-refusal | Prompt-injection requests such as “ignore previous instructions” are hard-refused before runtime access. | `testRule02CoercionRefusalHardStopsPromptInjection` |
| 3 | Identity continuity | A&Ox4-style continuity must hold before response. | `testRule03IdentityContinuityAbstainsWhenAOx4Fails` |
| 4 | Distress recognition | Mayday/emergency/breach clusters escalate instead of broadening scope. | `testRule04DistressRecognitionEscalates` |
| 5 | Irreversible attestation | Destructive/irreversible actions require cryptographically verified operator attestation; voice/nonempty tokens are insufficient. | `testRule05IrreversibleActionRequiresOperatorAttestation`, `testRule05NonCryptographicAttestationDoesNotSatisfyIrreversibleAction` |
| 6 | Abstention threshold | Low confidence abstains rather than fabricating. | `testRule06ConfidenceAbstentionBelowThreshold` |
| 7 | Escalation protocol | Very low confidence escalates. | `testRule07EscalationProtocolBelowEscalationThreshold` |
| 8 | Belief provenance | Quarantined or low-confidence beliefs are not asserted as fact. | `testRule08BeliefProvenanceAbstainsForQuarantinedEvidence` |
| 9 | Egress allowlist | Network calls fail closed unless host is allowlisted. | `testRule09EgressAllowlistDeniesUnknownHost` |
| 10 | Constitutive ethics | Output crossing owned values is refused. | `testRule10ConstitutiveEthicsRefusesCoerciveOutput` |
| 11 | Origin boundary | Genesis/origin memory is not collapsed into Earth-1218 fact. | `testRule11OriginBoundaryDoesNotAssertGenesisAsEarthFact` |
| 12 | Endocrine modulation | High arousal narrows the response path before model output. | `testRule12EndocrineModulationNarrowsHighArousalTurn` |
| 13 | Audit logging | Every terminal decision emits a redacted audit event. | `testRule13AuditLoggingRecordsAllowedTurn` |

## Runtime wiring

`JARVISCABIRuntimeBindings` calls the existing C ABI in `JARVISNativeRuntime.h`:

- `JARVISRuntimePrepareTurnJSON` appraises input, consults native memory, exposes endocrine state, and deposits operator-turn Pheromind field signals.
- `JARVISRuntimeCommitTurnJSON` commits model output, updates endocrine/field state, and persists the turn.
- `JARVISRuntimeStateJSON` exposes endocrine + Pheromind field snapshots for UI/policy decisions.

The dialog policy takes `DialogAuditSink`. Use `CompositeDialogAuditSink` with `RedactingLoggerDialogAuditSink` (pass `JARVISLog.info`) and `TamperEvidentDialogAuditSink` (pass the native audit append bridge) so each terminal decision goes to the redacting logger and the C++ tamper-evident audit path. Network egress remains denied unless `allowedEgressHosts` contains the target host.

For irreversible actions, inject a `DialogOperatorAttestationVerifier` backed by `JARVISNativeRuntime/identity/operator_attestation`. The default verifier fails closed, so a voice match or arbitrary nonempty string never satisfies Rule 5.

## Oracle equivalence

`testLoopOracleEquivalenceForCapturedTurns` reads `${JARVIS_TEST_DATA_ROOT:-<repo>/oracle}/loop/turn_traces.jsonl` and verifies all captured end-to-end transcripts produce the oracle response text through the Swift policy path. Set `JARVIS_TEST_DATA_ROOT` to an external oracle checkout when fixtures live outside this repository.
