# Voice-Weight Integrity Tripwire — Test Record

**Project:** JARVIS Digital Person  
**Operator:** Robert "Grizzly" Hanson, EMT-P (Ret.), GMRI  
**Executed by:** Copilot fleet sub-agent (p5-sbom-voice-weights)  
**Executed:** 2026-05-24T03:30Z  
**Repo:** `fc8857bb65967aa6982bfe1c9e62f9a383aae891`

---

## Test Procedure

### Setup
- Voice weight baseline created: `apple_native/sbom/voice-weights-baseline.json`
- 7 entries: 2 ONNX files, 3 CoreML mlpackage member files, 2 `_local_voice/` assets

### Corruption Step
Single-byte mutation at offset 4 of `gpt_decoder.onnx`:

```
Original byte: 0x70
Mutated byte:  0x8f  (XOR 0xFF)
```

Before hash: `c2196dfac7c2a043a43d76f7bf92c51ddc5176454e79e0cf891099a3af98bcf0`  
After hash:  `e53d2e4806d9d50eb7e050e96e638c137b47576b97c944631c0246099a230cee`

### Tripwire Execution
Command: `bash apple_native/tools/generate_sbom.sh`

**Output (relevant section):**
```
🔒 Integrity tripwire check...

  ⚠️  WARNING: voice weight hash changed since last SBOM baseline.
     File:      apple_native/JARVISNativeRuntime/voice/tts/onnx/onnx_models/gpt_decoder.onnx
     Baseline:  c2196dfac7c2a043a43d76f7bf92c51ddc5176454e79e0cf891099a3af98bcf0
     Current:   e53d2e4806d9d50eb7e050e96e638c137b47576b97c944631c0246099a230cee
     Verify this was an authorized voice update.

  ACTION REQUIRED: If this was an authorized update:
    (a) Verify the new file is from an authorized source
    (b) Update apple_native/sbom/voice-weights-baseline.json
        — add new hash + timestamp + reason, remove old entry
    (c) Re-run generate_sbom.sh to confirm clean tripwire
    (d) Commit baseline + SBOM together
```

**Script exit code:** `2` (non-zero — CI will catch this)

### Restore Step
File restored via backup copy. Post-restore hash matches original:  
`c2196dfac7c2a043a43d76f7bf92c51ddc5176454e79e0cf891099a3af98bcf0` ✅

### Clean Confirmation
Second run after restore:
```
  ✅ All 7 voice weight hashes match baseline — no tampering detected
✅ SBOM generation complete.
Exit: 0
```

---

## Verdict

**PASS.** Single-byte mutation detected. Tripwire fires on next SBOM run. Script exits
with code 2 (CI-catchable). SBOM is still fully written even when tripwire fires — the
integrity record is captured regardless.

---

## Notes

- The tripwire does NOT block the SBOM write — it fires after generation so the
  evidence artifact (new SBOM with tampered hash) is preserved.
- Exit code 2 on tamper detection — suitable for CI `|| exit` gates.
- The baseline is append-only on new files and NOT auto-updated on hash changes.
  Only the operator can authorize a hash change by editing the baseline file.
- Files not yet present (TTS race output: `*.pt`, `*.ckpt` from libtorch race) are
  gracefully skipped — they do not trigger false tamper warnings.

---

## TTS Race — Files Not Yet Present (Expected Later)

The following paths are skipped gracefully today and will be picked up automatically
on the next `generate_sbom.sh` run once the TTS race agents complete:

| Pattern | Race | Expected Path |
|---------|------|---------------|
| `*.pt` / `*.ckpt` | voice-libtorch | `voice/tts/libtorch/models/*.pt` |
| `*.safetensors` (voice dir) | voice-libtorch | `voice/tts/libtorch/models/*.safetensors` |
| `*.onnx` (additional) | voice-onnx | `voice/tts/onnx/onnx_models/*.onnx` |
| `*.mlpackage/` (additional) | voice-coreml | `voice/tts/coreml/models/*.mlpackage` |

When these files appear: run `generate_sbom.sh`, review the new baseline entries
(they will be appended automatically), then commit baseline + SBOM.
