# JARVIS native state migration

## Pre-migration checklist
1. Close cockpit/native runtime so no organ writes during migration.
2. Back up the current native destination tree.
3. Create an operator attestation token under `identity/operator_attestation/` containing `JARVIS_MIGRATION_ATTESTED`.
4. Run `--dry-run` first.
5. Provide a 32-byte SQLCipher key as 64 hex characters. Do not write decrypted rows to disk.

Voice weights are off-limits. The runner never traverses `_local_voice`. If external voice hashes are supplied, mismatch halts as `CRITICAL_VOICE_INTEGRITY_VIOLATION`.

## Build
```sh
cmake -S /Users/rbhanson/research/jarvis/apple_native/migration -B /Users/rbhanson/research/jarvis/apple_native/migration/build
cmake --build /Users/rbhanson/research/jarvis/apple_native/migration/build --target jarvis-migrate jarvis-migrate-rollback test_migration
```

## Dry run
```sh
jarvis-migrate --dry-run \
  --source /Users/rbhanson/research/jarvis/_baseline \
  --destination /Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime \
  --attestation-token /Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/identity/operator_attestation/migration.token
```

## Migrate
```sh
jarvis-migrate --migrate \
  --source /Users/rbhanson/research/jarvis/_baseline \
  --destination /Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime \
  --attestation-token /Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/identity/operator_attestation/migration.token \
  --sqlcipher-key-hex <64-hex-chars>
```

## Verify
```sh
jarvis-migrate --verify --source <same-source> --destination <same-destination> \
  --attestation-token <token> --sqlcipher-key-hex <64-hex-chars>
```

## Rollback
The migration writes `MIGRATION_<timestamp>.manifest` under the destination unless `--manifest` is supplied.
```sh
jarvis-migrate-rollback --manifest <MIGRATION_timestamp.manifest> --attestation-token <token>
```
Rollback restores the byte-copied destination backup recorded in the manifest and appends rollback audit entries.
