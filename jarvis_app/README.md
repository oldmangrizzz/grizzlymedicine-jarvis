# JARVIS — native desktop cockpit

The beta macOS cockpit is the Swift + C++ target in `apple_native/JARVISMacCockpit`.
It is not the old Tauri/WebView wrapper.

## Runtime ownership

- Swift owns macOS lifecycle, UI, microphone permission/capture, model networking, and STT networking.
- C++ owns runtime identity/state, field signals, turn preparation, and turn commit.
- C++ emits a typed `JARVISUISpec` receipt (`JARVISRuntimeUISpecJSON`) for runtime status,
  metric cards, field signals, action descriptors, and query descriptors.
- Swift renders only registered native components (`runtimeStatus`, `metricCards`,
  `fieldSignalList`, `actionList`) and rejects trusted HTML, JavaScript, WebView, or script
  components.
- UI actions carry HASP route, risk, authorization, audit event, and receipt metadata. Native HASP
  dispatch returns receipts now; unimplemented adapters render or complete as blocked/refused.
- Python may remain as reference/dev tooling only; it is not in the beta-critical runtime path.
- Rust/Tauri, Web Speech, and native system-voice fallback are not part of the beta macOS runtime.

## Build and local receipt

```bash
cd ~/research/jarvis/apple_native
xcodegen generate
xcodebuild -project JARVISCompanionApps.xcodeproj -scheme JARVISNativeRuntimeReceipt -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project JARVISCompanionApps.xcodeproj -scheme JARVISNativeHTTPServiceReceipt -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project JARVISCompanionApps.xcodeproj -scheme JARVISMacCockpit -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

The `JARVISNativeRuntimeReceipt` command-line target exercises C++ runtime
create/state/catalog/UI-spec/prepare/commit plus HASP SAFE dispatch,
authorization-required, blocked-adapter, PROHIBITED/refused, and audit receipts
locally without model or STT network calls.
The `JARVISNativeHTTPServiceReceipt` target starts the Swift `Network`
listener and verifies `/state`, `/companion/skills`, `/companion/turn`,
blocked `/companion/speech`, and explicit `/companion/transcribe` missing-audio
receipts without Python or Tauri.

## Native knobs

- `JARVIS_NATIVE_MODEL` selects the requested chat model; default is `glm-5.1`.
- `JARVIS_NATIVE_AUTH_CODE` or `JARVIS_AUTH_CODE` gates native SENSITIVE and
  DESTRUCTIVE skill dispatch. `*_SHA256` variants are accepted when CommonCrypto
  is available. Convex/app queues never carry the private code.
- `JARVIS_NATIVE_MODEL_BASE` selects the native chat endpoint; `OLLAMA_BASE_URL`
  is accepted as a compatibility alias. Default is `https://ollama.com`.
- `OLLAMA_API_KEY` is sent as a bearer token when present.
- `DEEPGRAM_API_KEY` enables native STT; `JARVIS_NATIVE_STT_MODEL` defaults to `nova-3`.
- `JARVIS_NATIVE_SERVICE_HOST` and `JARVIS_NATIVE_SERVICE_PORT` select the local
  Swift HTTP listener; defaults are `127.0.0.1:8788`.
- `JARVIS_RUNTIME_COMPANION_TOKEN` (or `JARVIS_NATIVE_SERVICE_TOKEN`) gates
  `/companion/*` routes with `X-JARVIS-Companion-Token`.
- Native speech is **JARVIS voice or silence**. `JARVIS_NATIVE_VOICE_BACKEND`,
  `JARVIS_NATIVE_VOICE_ID`, and `JARVIS_NATIVE_VOICE_CONFIRMED=1` identify a
  future native JARVIS voice, but the current beta still reports
  `voice_unavailable` until a real native synthesis backend is linked.
- Convex app routes require `JARVIS_RUNTIME_KIND=native` before they will forward
  `/app/realtime-turn`, `/app/speech`, or `/app/transcribe` to
  `JARVIS_RUNTIME_PUBLIC_URL` with `JARVIS_RUNTIME_COMPANION_TOKEN`. Point that
  URL at the Swift service (or an operator-owned tunnel to it), not Python.
- Voice recordings are bounded and stored under the app's Application Support
  recording directory only long enough to read the captured bytes, then removed.

## Native local service surface

The macOS cockpit starts a Swift/Foundation/Network HTTP service backed by
`NativeRuntimeBridge`: `GET /state`, `GET /skills`, `GET /companion/skills`,
`POST /companion/turn`, `POST /companion/transcribe`, `GET|POST /companion/speech`,
and `POST /companion/skill`. Unavailable model/STT/voice/skill-adapter paths
return `ok:false` blocked or unavailable receipts; they do not fake success.

## Archived Tauri/WebView path

`jarvis_app/src-tauri` and the old Python bridge notes are retained only as
legacy reference while the native replacement is completed. They are not the
operator first-run path and should not be used to validate the beta macOS
runtime.
