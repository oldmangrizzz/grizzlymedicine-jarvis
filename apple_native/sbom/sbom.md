# JARVIS SBOM — Software Bill of Materials

**Generated:** 2026-05-24T03:30:34Z  
**Git SHA:** `fc8857bb65967aa6982bfe1c9e62f9a383aae891`  
**Serial:** `urn:jarvis:sbom:fc8857bb6596:1779593434`  
**Format:** CycloneDX 1.5 JSON  
**Generator version:** 2.0.0  
**Xcode:** 26.5  
**macOS SDK:** 26.5  
**Swift:** 6.3.2  

---

## Summary

| Category | Count |
|----------|-------|
| Total components | 16 |
| Voice weights & reference assets | 8 |
| Third-party vendored libs | 0 |

---

## Components

| BOM-Ref | Name | Version | Type | SHA-256 (first 16) | Category |
|---------|------|---------|------|--------------------|----------|
| `apple:AVFoundation@26.5` | AVFoundation | 26.5 | framework | `—` | — |
| `apple:CommonCrypto@26.5` | CommonCrypto | 26.5 | framework | `—` | — |
| `apple:SwiftStdlib@6.3.2` | Swift Standard Library | 6.3.2 | framework | `—` | — |
| `apple:SwiftUI@26.5` | SwiftUI | 26.5 | framework | `—` | — |
| `apple:libc++@26.5` | libc++ (LLVM C++ Standard Library) | 26.5 | framework | `—` | — |
| `jarvis:JARVISCompanionCore` | JARVISCompanionCore | fc8857bb6596 | library | `80aae1bd8622259f…` | — |
| `jarvis:JARVISCompanionUI` | JARVISCompanionUI | fc8857bb6596 | library | `—` | — |
| `jarvis:JARVISNativeRuntime` | JARVISNativeRuntime | fc8857bb6596 | library | `712a773973af3152…` | — |
| `jarvis:local-voice:_local_voice/jarvis_harvard_prompt.wav` | _local_voice/jarvis_harvard_prompt.wav | unknown | data | `d5634952e0290b19…` | reference-asset |
| `jarvis:local-voice:_local_voice/jarvis_voice_state.safetensors` | _local_voice/jarvis_voice_state.safetensors | unknown | data | `18c530633ea17c85…` | reference-asset |
| `jarvis:voice:apple_native/JARVISNativeRuntime/voice/tts/coreml/models/text_encoder.mlpackage` | apple_native/JARVISNativeRuntime/voice/tts/coreml/models/text_encoder.mlpackage | unknown | data | `9765ce5415344a39…` | voice-weight |
| `jarvis:voice:apple_native/JARVISNativeRuntime/voice/tts/coreml/models/text_encoder.mlpackage/Data/com.apple.CoreML/model.mlmodel` | apple_native/JARVISNativeRuntime/voice/tts/coreml/models/text_encoder.mlpackage/Data/com.apple.CoreML/model.mlmodel | unknown | data | `943522822d98df21…` | voice-weight |
| `jarvis:voice:apple_native/JARVISNativeRuntime/voice/tts/coreml/models/text_encoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin` | apple_native/JARVISNativeRuntime/voice/tts/coreml/models/text_encoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin | unknown | data | `9e978d8c2ea20ad4…` | voice-weight |
| `jarvis:voice:apple_native/JARVISNativeRuntime/voice/tts/coreml/models/text_encoder.mlpackage/Manifest.json` | apple_native/JARVISNativeRuntime/voice/tts/coreml/models/text_encoder.mlpackage/Manifest.json | unknown | data | `9765ce5415344a39…` | voice-weight |
| `jarvis:voice:apple_native/JARVISNativeRuntime/voice/tts/onnx/onnx_models/gpt_decoder.onnx` | apple_native/JARVISNativeRuntime/voice/tts/onnx/onnx_models/gpt_decoder.onnx | unknown | data | `c2196dfac7c2a043…` | voice-weight |
| `jarvis:voice:apple_native/JARVISNativeRuntime/voice/tts/onnx/onnx_models/text_encoder.onnx` | apple_native/JARVISNativeRuntime/voice/tts/onnx/onnx_models/text_encoder.onnx | unknown | data | `75b6a0a02596ddd9…` | voice-weight |

---

## Integrity Tripwire

Voice weight hashes are tracked in `apple_native/sbom/voice-weights-baseline.json`.
Running `generate_sbom.sh` compares all voice-weight SHA-256s against this baseline.
Any change without a corresponding baseline update triggers:

```
⚠️  WARNING: voice weight hash changed since last SBOM baseline.
```

**Operator workflow for an authorized voice update:**
1. Commit the new voice file(s)
2. `bash apple_native/tools/generate_sbom.sh`
3. Edit `voice-weights-baseline.json` — update hash + timestamp + reason
4. Re-run `generate_sbom.sh` to confirm clean tripwire
5. Commit baseline + SBOM together

---

## Notes

- **Voice weights** (`voice/tts/onnx/`, `voice/tts/coreml/`) are hashed individually.
  CoreML `.mlpackage` directories have per-member-file entries plus a package-level rollup.
- **`_local_voice/`** is the canonical voice identity — tampering here is an identity violation.
- **No vendored third-party C++ libraries currently present.** The runtime uses only
  Apple SDK system frameworks (libc++, CommonCrypto).
- **Fetched-at-build-time deps** (Catch2 via CMake FetchContent, onnxruntime if downloaded)
  are documented in SBOM `externalReferences` metadata. Not hashed (not in repo).
- **Idempotency:** set `SOURCE_DATE_EPOCH=$(git log -1 --format=%ct)` for reproducible output.
- Regenerate: `bash apple_native/tools/generate_sbom.sh`
