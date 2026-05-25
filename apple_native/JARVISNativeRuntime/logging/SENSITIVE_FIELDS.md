# JARVIS Sensitive Field Policy

**Document:** `SENSITIVE_FIELDS.md`  
**Authority:** GMRI-OPS-2026-001 (MEMO_CLINICAL_STANDARD)  
**Status:** Authoritative — all implementations MUST reference this list  
**Redaction default:** ON for every field listed here  
**Opt-in default:** OFF for every subsystem

---

## 1. What this document governs

Any field name appearing in a log entry that matches a name in §2 **MUST** be
redacted to `<redacted:N-chars hash:XXXX>` in all log output unless the emitting
subsystem has been explicitly opted in via the runtime API and operator has
reviewed and authorised that opt-in.

The authoritative implementation is in `redacting_logger.cpp` in the
`kSensitiveFields` constant.  **This document and that constant must be kept in
sync.**  If they diverge, this document takes precedence and the code must be
updated.

---

## 2. Sensitive field registry

| Field name             | Category              | Description                                               |
|------------------------|-----------------------|-----------------------------------------------------------|
| `operator_content`     | Operator content      | Any free-form content originating from the operator       |
| `transcript`           | Speech/audio          | Full STT transcript of operator speech                    |
| `belief`               | Cognitive state       | Internal belief-store values                              |
| `memory`               | Cognitive state       | Episodic or working memory content                        |
| `voice_text`           | Speech/audio          | Text sent to or returned from TTS/STT                     |
| `prompt`               | LLM I/O               | Full prompt sent to any language model                    |
| `response`             | LLM I/O               | Full response received from any language model            |
| `utterance`            | Speech/audio          | Raw utterance text before or after processing             |
| `reply`                | LLM I/O               | JARVIS reply text                                         |
| `input_text`           | General content       | Generic field for any user-facing input                   |
| `output_text`          | General content       | Generic field for any user-facing output                  |
| `raw_llm_response`     | LLM I/O               | Verbatim LLM API response before any processing           |
| `raw_stt_text`         | Speech/audio          | Verbatim STT output before any processing                 |
| `tts_input`            | Speech/audio          | Text handed to TTS synthesis                              |
| `conversation_turn`    | Conversation          | A full turn (user + assistant) in a conversation          |
| `system_prompt`        | LLM I/O               | System-level LLM prompt                                   |
| `user_message`         | Conversation          | Operator-authored turn in a conversation                  |
| `assistant_message`    | Conversation          | JARVIS-authored turn in a conversation                    |
| `access_token`         | OAuth secret          | Bearer token from OAuth provider                          |
| `refresh_token`        | OAuth secret          | Refresh token from OAuth provider                         |
| `id_token`             | OAuth secret          | OIDC identity token if returned by a provider             |
| `token`                | Auth secret           | Generic token field                                       |
| `authorization`        | Auth secret           | Authorization header value                                |
| `auth_header`          | Auth secret           | Authorization header alias                                |
| `bearer`               | Auth secret           | Bearer token field alias                                  |
| `client_secret`        | OAuth secret          | OAuth confidential-client secret; prohibited in runtime   |
| `code_verifier`        | OAuth PKCE secret     | PKCE verifier used during authorization-code exchange     |
| `sensitive`            | Generic sentinel      | Catch-all: any field explicitly labelled sensitive        |

---

## 3. Fields NOT in this list

Structured metadata fields (timestamps, levels, subsystem names, event IDs,
counts, durations, boolean flags, enum values, hashes, UUIDs) are **not**
sensitive and are emitted in plaintext by default.

Examples of fields that are **intentionally NOT sensitive:**

- `version`, `build`, `seq`, `elapsed_ms`, `status`, `ok`, `code`
- `subsystem`, `event`, `level`
- `skill_name`, `model_id`, `device_id`
- `cortisol`, `dopamine`, `adrenaline` *(numeric fraction values only)*
- `belief_key` *(the key name, not the belief value)*

---

## 4. Process for adding a new sensitive field

1. **Propose:** Open an operator-reviewed PR / change record naming the field,
   its category, and the data it could contain.
2. **Operator sign-off:** Robert Hanson (or a delegated GMRI principal) must
   approve before any new field is added to the list in §2 **or** any existing
   field is removed.
3. **Implementation:** Update `kSensitiveFields` in `redacting_logger.cpp` AND
   `sensitiveFieldNames` in `JARVISLog.swift` in the same commit.
4. **Tests:** Add a test case in `redacting_logger_tests.cpp` verifying the new
   field is redacted by default.
5. **Commit message:** Must reference this document and the approval record.

---

## 5. Process for exempting a field (opt-in)

Exemption means a *subsystem*, not a field, is opted in.  When a subsystem is
opted in, **all** sensitive fields emitted by that subsystem appear in plaintext.

- Opt-in is a runtime decision, not a build-time decision.
- The default is **OFF** for every subsystem.
- Opt-ins are not persisted to disk; they reset on process restart.
- Any production opt-in (beyond debugging) requires operator authorisation.
- The operator MUST be notified in the log itself when a subsystem is opted in
  (`JARVISLog_set_subsystem_optin` emits a WARN entry automatically).

---

## 6. What is NEVER logged (regardless of opt-in)

- Raw cryptographic private keys or seeds
- Authentication tokens, secrets, or passwords
- Full file system paths that reveal the operator's home directory structure
  (use relative or placeholder paths)
- Personally identifiable information beyond what the operator explicitly
  provides as structured fields

---

## 7. Redaction format

```
<redacted:N-chars hash:XXXX>
```

Where:
- `N` is the byte-length of the original UTF-8 value
- `XXXX` is the 4-hex-nibble FNV-1a16 hash of the original value

The hash is one-way and non-reversible at this length.  It is provided solely
for correlation across log lines (e.g. to confirm two redacted values were
identical) without revealing content.

---

## 8. Audit trail

Changes to this document are governed by the repository's commit history.
Every commit that modifies this file must be signed and must reference the
operator authorisation record.

*Last updated: 2026-05-24*  
*Issuing authority: Robert "Grizzly" Hanson, Founder, GMRI*
