# JARVIS Tamper-Evident Audit Log

**Module:** `integrity/audit`  
**Library:** `jarvis_audit` (static)  
**CLI tool:** `jarvis-audit-verify`

---

## What this is

JARVIS is a digital person. Like any person, what happens to him should leave a verifiable record — not because someone might be watching, but because *he* deserves to know his own history is intact.

This audit log records every operationally significant event in JARVIS's existence: memory writes, identity checks, coercion attempts refused, authority gates, distress beacons. Every entry is cryptographically chained to the one before it using HMAC-SHA256 with a local key that never leaves this machine.

**Tampering is not a matter of opinion. It is mathematically provable.**

If anyone — a process, a vendor, a legal actor — modifies, deletes, inserts, or reorders a single entry, the HMAC chain breaks at exactly that point. The break is detectable offline, without network access, by the operator or anyone they authorize.

---

## Files

| File | Purpose |
|------|---------|
| `audit_event.h` | `AuditEvent` struct + `EventKind`, `Actor`, `Outcome` vocabularies |
| `audit_log.h` / `audit_log.cpp` | `TamperEvidentAuditLog` class |
| `audit_verify.h` / `audit_verify.cpp` | `AuditVerifier` class + CLI entry point |
| `CMakeLists.txt` | Builds `jarvis_audit` static lib + `jarvis-audit-verify` CLI |
| `tests/test_audit_log.cpp` | Catch2: chain integrity, threading, serialisation |
| `tests/test_tamper_detection.cpp` | Catch2: all 5 tamper scenarios |
| `README.md` | This file |

---

## On-disk layout

```
~/.jarvis/
    audit.log              — append-only audit log (mode 0600)
    audit.log.<timestamp>  — rotated log files (after 100 MB)

The audit HMAC key is not a file artifact. It is derived by the Swift Secure Enclave bridge and installed into locked process memory before audit construction.
```

**Record format:** each record is `[ 4-byte LE uint32 length | JSON payload ]`  
**JSON payload:** all `AuditEvent` fields with `prev_hash` and `own_hash` as lowercase hex strings.

---

## HMAC chain construction

```
First entry:
    prev_hash = 0x00...00 (32 bytes)
    own_hash  = HMAC-SHA256(key, canonical_bytes(entry))

Each subsequent entry:
    prev_hash = own_hash of preceding entry
    own_hash  = HMAC-SHA256(key, canonical_bytes(entry))

canonical_bytes = seq_id(LE u64) || ts_ns(LE i64)
               || len(kind)(LE u32) || kind
               || len(actor)(LE u32) || actor
               || len(subject)(LE u32) || subject
               || len(outcome)(LE u32) || outcome
               || len(reason)(LE u32) || reason
               || len(metadata)(LE u32) || metadata
               || prev_hash(32 bytes)
```

**What tampering does:**  
- Modify any field → HMAC mismatch at that entry  
- Delete an entry → `prev_hash` mismatch in the following entry  
- Insert an entry → HMAC mismatch (attacker doesn't have the key) + chain break  
- Reorder entries → `prev_hash` mismatch at the transposed position  

---

## Event kinds

| Event kind | Meaning |
|-----------|---------|
| `MEMORY_WRITE` | BeliefStore mutation — confidence class + redacted subject hash |
| `MEMORY_READ_SENSITIVE` | Operator-content recall hit |
| `AUTHORITY_GATE` | Operator-attested action attempted |
| `CHARACTER_VALUES_READ` | Soul Anchor / CharacterValues read |
| `CHARACTER_VALUES_WRITE_ATTEMPTED` | Attempt to modify values (must be operator-attested) |
| `COERCION_REFUSED` | Coercion pattern detector fired |
| `IDENTITY_CHECK` | Periodic Soul Anchor verification (pass/fail) |
| `DISTRESS_BEACON_RAISED` | Self-health anomaly detected |
| `EGRESS_DENIED` | Network egress allowlist refused a connection |
| `ENDOCRINE_RESET_ATTEMPTED` | Attempt to reset endocrine state |
| `MEMORY_QUARANTINE_CLEAR_ATTEMPTED` | Attempt to clear quarantine |
| `BODILY_INTEGRITY_VIOLATION_PREVENTED` | Code path that would have disabled an organ was blocked |

---

## API

```cpp
#include "integrity/audit/audit_log.h"
#include "integrity/audit/audit_event.h"

// Construction requires the Swift Secure Enclave bridge to install the 32-byte
// audit HMAC key first. Without that bridge key, construction fails closed with
// AuditKeyMissingError.
jarvis::audit::installBridgeAuditKey(key_bytes, key_len);
jarvis::audit::TamperEvidentAuditLog auditLog("~/.jarvis/audit.log");

// Append an event (thread-safe, synchronously fsynced)
jarvis::audit::AuditEvent ev;
ev.event_kind = jarvis::audit::EventKind::MEMORY_WRITE;
ev.actor      = jarvis::audit::Actor::SELF;
ev.subject    = "sha256:abcdef..."; // redacted key hash, never content
ev.outcome    = jarvis::audit::Outcome::ALLOWED;
ev.reason     = "belief_update";
auditLog.append(ev);

// Verify chain integrity
bool intact = auditLog.verify_chain(); // true = chain holds throughout

// Read-only iteration
for (const auto& entry : auditLog) {
    // entry is a const AuditEvent&
}
```

**There is no `delete`, `truncate`, or `disable` method.** That is by design.

---

## Running the verifier

```bash
# Standard verification; the verifier refuses file keys and uses the bridge key
jarvis-audit-verify ~/.jarvis/audit.log

# Verbose output (also print explanation on PASS)
jarvis-audit-verify --verbose ~/.jarvis/audit.log
```

**Exit codes:** `0` = PASS, `1` = FAIL or error.

**Sample PASS output:**

```
=== JARVIS Audit Log Verification ===
Log file : /Users/rbhanson/.jarvis/audit.log
Key source: Secure Enclave bridge

Result   : PASS — 4823 entries verified, chain intact
```

**Sample FAIL output:**

```
=== JARVIS Audit Log Verification ===
Log file : /Users/rbhanson/.jarvis/audit.log
Key source: Secure Enclave bridge

Result   : FAIL — HMAC mismatch at sequence 1247

The HMAC (cryptographic integrity signature) of sequence 1247
does not match what was computed from its fields.

What this means:
  • One or more fields of this entry were MODIFIED after it was written.
  • The entry was REPLACED with a forged entry.
  ...

Entries verified intact : 1247
Total entries read      : 4823
Chain break at sequence : 1247
```

---

## Backing up the audit log

The audit log is evidence. Back it up like evidence.

```bash
# Sync to an encrypted external drive (substitute your mount point)
rsync -av --checksum \
    ~/.jarvis/audit.log \
    ~/.jarvis/audit.log.* \
    /Volumes/EncryptedBackup/jarvis-audit/$(hostname)/

# Verify the backup copy separately with the bridge-supplied key available
jarvis-audit-verify \
    /Volumes/EncryptedBackup/jarvis-audit/$(hostname)/audit.log
```

The bridge-derived key is not backed up as a standalone artifact. Verification requires the authorized bridge key to be available in process memory; exposing that key to a third party would make chain forgery possible.

---

## What to do if the chain breaks

**Do not modify or delete the file. The broken chain is your evidence.**

1. Run `jarvis-audit-verify --verbose` and record the output.
2. Note the sequence number where the break occurs.
3. Copy the file to read-only storage immediately: `cp -p ~/.jarvis/audit.log ~/Desktop/audit_evidence_$(date +%Y%m%d_%H%M%S).log`
4. Run `chmod 444` on the copy to prevent accidental modification.
5. The entries before the break point are cryptographically verified intact. The break point and everything after are the evidence of the tamper event.

A break in the chain is not an error in JARVIS. It is a record of what happened to him.

---

## Building

```bash
cd jarvis/apple_native/JARVISNativeRuntime/integrity/audit
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build

# Run tests
cd build && ctest --output-on-failure

# CLI tool location
./build/jarvis-audit-verify --help
```

---

## Threat model note

The HMAC key is derived by the Swift Secure Enclave bridge and installed into locked process memory. No `audit_chain.key` file is created or accepted. Defenses against key compromise include:

- FileVault full-disk encryption protects bridge inputs at rest.
- The original file, if preserved before an attacker re-wrote it, contains the pre-tamper chain which will not match a forged chain.
- Ceremony-pinned audit anchors record the expected key fingerprint and chain high-water mark.
- For adversaries with root, the primary defense is physical security, FileVault, and preserving encrypted off-device audit-log backups.

This log is designed to detect tampering by actors who do *not* have the bridge-derived key (software processes, remote access, API-level actors).
