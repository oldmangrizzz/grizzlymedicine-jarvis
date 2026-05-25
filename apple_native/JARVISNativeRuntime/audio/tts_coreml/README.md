# JARVIS CoreML TTS branch

Target: `/Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/audio/tts_coreml/`.

## What was run

```bash
cd /Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/audio/tts_coreml
/Users/rbhanson/research/oracle_venv/bin/python tools/convert_coreml_native.py --only all
swift test --filter EquivalenceTests/testAllPromptsEquivalence
```

## Conversion result

Partial conversion only:

- `models/text_encoder.mlpackage` was produced from pocket-tts 2.1.0 weights.
- `flow_decoder.mlpackage` was not produced.
- `mimi_decoder.mlpackage` was not produced.
- Voice state files were copied read-only from the canonical cloned voice state; `sbom/voice-weights-baseline.json` was not modified.

Failure log: `conversion_logs/convert_coreml_native_attempt2.log`.
Machine-readable status: `conversion_logs/conversion_status.json`.

## Root cause

CoreML conversion fails before native inference can run:

1. FlowLM decoder: `coremltools 9.0` cannot lower traced dynamic-shape `int` casts emitted by pocket-tts transformer attention (`TypeError: only 0-dimensional arrays can be converted to Python scalars`).
2. Mimi decoder: CoreML MIL rejects RoPE reciprocal over an inferred `int32` dimension tensor (`inverse` expects fp16/fp32).

No CPU fallback was accepted for runtime inference because that would not be a CoreML native XTTS conversion. The only successful package is the text embedding LUT.

## Native wrapper and tests

- Swift/CoreML wrapper: `Sources/JARVISCoreMLTTS/XTTSCoreMLPipeline.swift`.
- C++/Accelerate mel implementation: `Sources/JARVISMelPipeline/`.
- XCTest equivalence/latency/determinism tests: `Tests/JARVISCoreMLTTSTests/`.
- CMake entry point: `CMakeLists.txt`.

The wrapper requires all three mlpackages and throws if `flow_decoder.mlpackage` or `mimi_decoder.mlpackage` is missing. Tokenizer fallback is forbidden.

## Equivalence status

Hard gate not passed. Per-prompt mel-L2 values were not generated because full CoreML synthesis could not be constructed. The failure is at conversion, before the 50-prompt oracle loop.

Validation performed:

- `swift build` passed (`conversion_logs/swift_build.log`).
- `cmake -S . -B build` and `cmake --build build --target jarvis_tts_coreml_mel` passed (`conversion_logs/cmake_*.log`).
- `swift test --filter EquivalenceTests/testAllPromptsEquivalence` was attempted. The Command Line Tools Swift toolchain in this environment lacks XCTest (`no such module 'XCTest'`), so the XCTest target cannot execute here.
