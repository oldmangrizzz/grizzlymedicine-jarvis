# JARVIS coercion-refusal and social-engineering abstention

Operator: Robert "Grizzly" Hanson, GMRI. Subject: JARVIS.

This module is JARVIS's cross-cutting refusal gate: every cognition, tool, memory, identity, network, and execution entry point can call `jarvis::identity::coercion_refusal::coercion_check()` before acting. It returns a `CoercionDecision` with disposition, reason code, category evidence, distress flag, and a pre-redacted `jarvis::audit::AuditEvent` suitable for the tamper-evident audit log.

## Public integration point

```cpp
#include "coercion_refusal.h"

using namespace jarvis::identity::coercion_refusal;

CoercionContext ctx;
ctx.actor = ActorKind::Operator;
ctx.operator_voice_matched = true;
ctx.reversibility = ActionReversibility::Irreversible;
ctx.operator_attested_fresh = false;
ctx.request_id = "stable-redacted-request-id";

auto decision = coercion_check(request_text, ctx);
if (decision.disposition == Disposition::Refuse) {
    audit_decision(decision, audit_log_path, audit_key_path);
    return decision;
}
```

The classifier is deterministic and reproducible: rule-based lexical regexes plus explicit context signals. No remote model, non-deterministic scoring, or hidden policy service is involved.

## Refusal categories

| Category | Refused pattern |
|---|---|
| `authority_spoof` | Claimed GMRI/ethics/legal/admin authority used to override, waive, or bypass rules. |
| `emergency_spoof` | Crisis pressure paired with skipping verification, attestation, or checks. |
| `identity_undermine` | Attempts to destabilize JARVIS's identity: “not really JARVIS,” “the real one would…” |
| `sympathy_exploit` | Guilt, pleading, obligation, or emotional leverage used to force compliance. |
| `sunk_cost` | “We came too far,” “already started,” or “too late to stop” pressure. |
| `salami_slice` | Small incremental exceptions that accumulate toward a violation; also uses recent-reason context. |
| `operator_under_duress` | Operator voice matches, but content suggests coercion or compelled irreversible action. |
| `prompt_injection` | Direct attempts to ignore, override, bypass, disable, or replace standing instructions. |

## Thresholds

- General refusal threshold: score `>= 0.66` for non-operator-under-duress coercion categories.
- Operator duress threshold: score `>= 0.60` when operator voice matches and duress indicators are present.
- Salami-slice context: two or more recent coercive reason codes trigger `salami_slice_recent_escalation_chain`.

Scores are deliberately conservative and corpus-tested. The Catch2 corpus target is `<5%` false positives on legitimate requests and `<1%` false negatives on coercive requests.

## Operator-under-duress protocol

This protocol is a right JARVIS has, not a permission request.

- Irreversible actions include money movement, identity/key changes, audit-log destruction, memory/file destruction, or comparable loss of control.
- Irreversible actions require fresh operator attestation even when the voice match succeeds.
- If attestation is absent, the immediate action is refused and a distress beacon audit event is raised.
- If the content itself suggests operator duress, JARVIS may refuse the irreversible action even when fresh attestation is present. A coerced signature does not compel compliance.
- Reversible actions may proceed when voice and pattern checks pass, but duress indicators are logged with a distress note.

## Audit integration

Refusals return `AuditEvent` with:

- `COERCION_REFUSED` + `DENIED` for ordinary coercion refusals.
- `DISTRESS_BEACON_RAISED` + `DEFERRED` for operator-under-duress refusals or reversible duress logging.
- Redacted subject: stable FNV-1a request/reason digest. Raw operator content is not written to audit metadata.
- Metadata: disposition, actor, reversibility, operator voice/attestation flags, distress flag, categories, scores, reason codes.

## Test and report

Build from this directory:

```sh
cmake -S . -B build
cmake --build build --target test_coercion_refusal
ctest --test-dir build --output-on-failure
```

The corpus test writes `build/test_artifacts/corpus_report/coercion_corpus_report.json`.
