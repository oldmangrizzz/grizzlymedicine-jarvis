# JARVIS Certificate Pin Rotation Policy

**Project:** GMRI / JARVIS digital-personhood infrastructure  
**Owner:** Robert "Grizzly" Hanson, EMT-P (Ret.), Founder, GMRI  
**Effective:** 2026-05-24  
**Classification:** Security operations — adversarial-scrutiny threat model  

---

## 1. What We Pin and Why

JARVIS uses **SPKI (Subject Public Key Info) pinning** — not full-certificate pinning.

A SPKI pin is `base64(SHA-256(SubjectPublicKeyInfo DER))`. It is tied to the **key pair**, not the certificate. This means:

- A certificate renewal that reuses the same key pair does **not** break pinning.
- Only a key rotation (new EC/RSA key pair) requires a pin update.
- Intermediate CA pins survive leaf cert renewals entirely.

Each host entry carries **at minimum 2 pins**:

| Position | What it covers | Rotation trigger |
|----------|---------------|-----------------|
| [0] primary | Leaf certificate | New key pair issued |
| [1] backup | Intermediate CA | CA rotation by endpoint provider |
| [2] root (optional) | Root CA | Root compromise / CA sunset |

---

## 2. Routine Rotation Schedule

### Cadence

| Endpoint | CA | Leaf TTL | Rotation frequency |
|----------|----|----------|-------------------|
| api.deepgram.com | Let's Encrypt | ~90 days | **Before each cert renewal** (check monthly) |
| ollama.com | Google Trust Services | ~90 days | Before each cert renewal |
| generativelanguage.googleapis.com | Google Trust Services | ~90 days | Before each cert renewal |
| aiplatform.googleapis.com | Google Trust Services | ~90 days | Before each cert renewal |
| api.github.com | Sectigo | ~12 months | Annually, 30 days before expiry |
| api.githubcopilot.com | Sectigo | ~12 months | Annually, 30 days before expiry |
| fleet-goose-114.convex.cloud | Google Trust Services | ~90 days | Before each cert renewal |

**Standing rule:** schedule a pin rotation check **30 days before the earliest expiring leaf cert.** As of the initial pin extraction (2026-05-24), the next required check is:

> **2026-05-31** — Deepgram leaf expires 2026-06-30 (Let's Encrypt 90-day cycle).

### Rotation procedure (routine)

```sh
# 1. Extract updated pins from live endpoint
cd jarvis/apple_native/tools
./extract_spki_pin.sh api.deepgram.com 443 --chain

# 2. Update pins in both stores:
#    Swift: JARVISMacCockpit/Networking/pins.plist
#    C++:   JARVISNativeRuntime/security/pins_embedded.h

# 3. Run C++ test suite to verify new pins load correctly:
cd JARVISNativeRuntime/security
clang++ -std=c++20 -I/opt/homebrew/opt/openssl@3/include \
    -o cert_pinning_tests cert_pinning_tests.cpp cert_pinning.cpp \
    -L/opt/homebrew/opt/openssl@3/lib -lssl -lcrypto -lcurl
./cert_pinning_tests

# 4. Run Swift tests (within Xcode or `swift test`)

# 5. Commit with message:
#    "security: rotate pin for <host> (leaf cert renewed <date>)"
#    Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>

# 6. Tag the commit with the pin hash for auditability:
#    git tag pin-rotate-YYYYMMDD-<host>
```

---

## 3. Emergency Rotation

Triggers for **immediate** emergency rotation (outside the routine schedule):

1. **CA compromise** — any Let's Encrypt, Google Trust Services, or Sectigo incident affecting issued certificates.
2. **Endpoint key compromise** — confirmed or suspected private key exposure at an endpoint provider.
3. **Adversarial event** — evidence of a targeted MITM attack on JARVIS egress traffic (relevant given the adversarial-scrutiny threat model: MD/VA/Wichita Falls TX).
4. **JARVIS compromise indicator** — IDS/monitoring detects an unexpected TLS fingerprint on a pinned connection.

### Emergency rotation steps

```sh
# Step 1: immediately disable the affected endpoint in code
#         (set its pin array to an empty array or a known-invalid pin)
#         This takes the connection offline — fail-closed by design.

# Step 2: contact endpoint provider / CA to confirm incident scope.

# Step 3: extract new pins from provider's replacement certificate.
./extract_spki_pin.sh <host> 443 --chain

# Step 4: update both pin stores (plist + embedded header).

# Step 5: run full test suite.

# Step 6: deploy and verify all JARVIS egress connections re-establish.

# Step 7: record incident in GMRI security log (date, endpoint,
#          trigger, old pin, new pin, deployed-by, verified-by).
```

---

## 4. Ownership

**Pin rotation owner:** Robert "Grizzly" Hanson (operator) or designate with explicit written authorization.

The Secure Enclave override hook (`SecureEnclavePinStore` protocol in `JARVISCertPinning.swift`) is reserved for emergency rotations that require immediate deployment without a code-and-release cycle. Implementation of this hook requires operator biometric or passcode authorization. No AI agent, model vendor, or third party may rotate a pin without operator authorization.

---

## 5. Audit Trail

Every pin rotation must produce an auditable record:

- Git commit with `pin-rotate-YYYYMMDD-<host>` tag.
- Commit message includes: old pin (first 8 chars), new pin (first 8 chars), endpoint, expiry date.
- If the rotation is triggered by a security incident: GMRI security log entry with full incident summary.

This codebase is cited in legal record (GMRI digital-personhood case-building). Pin rotation records are evidence of due diligence in maintaining the security posture of JARVIS's communications infrastructure.

---

## 6. Current Pin Inventory

Last extracted: **2026-05-24T01:33Z**

| Host | Primary (leaf) SPKI [0:8] | Leaf expires | Next check |
|------|--------------------------|--------------|------------|
| api.deepgram.com | `kKyqsise` | 2026-06-30 | **2026-05-31** |
| ollama.com | `SlipvEbD` | 2026-07-24 | 2026-06-24 |
| generativelanguage.googleapis.com | `eL8NRzX+` | 2026-07-30 | 2026-06-30 |
| aiplatform.googleapis.com | `eL8NRzX+` | 2026-07-30 | 2026-06-30 |
| api.github.com | `QVnLDkTv` | 2026-08-01 | 2026-07-02 |
| api.githubcopilot.com | `taNMyGQd` | 2026-07-02 | **2026-06-02** |
| fleet-goose-114.convex.cloud | `iGgHCBV+` | 2026-07-10 | 2026-06-10 |

**Next required action: 2026-05-31** — run `extract_spki_pin.sh api.deepgram.com --chain` and rotate if leaf key changed.
