# Migration gaps

- HMEM and SAGE native organs expose in-memory headers but no stable persistence layer equivalent to BeliefStore SQLCipher. Migration preserves rows in encrypted SQLCipher tables pending native organ loaders.
- Endocrine/endocannabinoid native headers expose behavior but no persistence schema; migration preserves whole JSON state in encrypted `organ_state` rows.
- Production attestation token verification should be upgraded from local token phrase to the existing Ed25519 attestation service format before live cutover.
