# Deepgram streaming STT (native C++)

Native C++20 port of `/jarvis/_baseline/stt_deepgram.py` for the JARVIS runtime. Runtime uses libwebsockets, OpenSSL, the existing SPKI pin store, egress allowlist/filter/audit, and the tamper-evident audit log. No Python is required at runtime.

## API

```cpp
#include "audio/stt_deepgram/deepgram_stt.h"
using namespace jarvis::audio::stt_deepgram;

DeepgramConfig cfg;
cfg.model = "nova-2";
cfg.language = "en";
DeepgramStreamingClient client(ApiKeyRef::keychain("JARVIS_DEEPGRAM_API_KEY"), cfg);
auto session = client.start_session();
session->on_interim([](std::string_view text) { /* partial transcript */ });
session->on_final([](FinalResult result) { /* final transcript */ });
session->feed_audio(std::span<const int16_t>(pcm16_mono_16k));
session->close();
```

Token sources are operator config only: macOS Keychain service (default `JARVIS_DEEPGRAM_API_KEY`) or an explicitly named environment variable. No production constructor accepts a hardcoded token.

## Security wiring

- WSS endpoint: `api.deepgram.com:443/v1/listen`.
- Egress allowlist: verified through `security/egress/EgressAllowlist`; Deepgram is present via `pins_embedded.h::kDeepgram`.
- Egress filter/audit: session connect and audio frames are passed through `EgressFilter` metadata minimization and recorded with `EgressAudit` payload fingerprints.
- Cert pinning: TLS validation uses `security/cert_pinning.{h,cpp}` and `pins_embedded.h`; pin mismatch fails closed and does not reconnect.
- Session audit: open/connect/error/close events append to `integrity/audit/TamperEvidentAuditLog` without transcript or token content.

## Cert-pin rotation calendar

Deepgram leaf cert expires **2026-06-30** (Let's Encrypt 90-day). Next rotation deadline: **2026-05-31**. Regenerate `kDeepgram` in `security/pins_embedded.h` before that date and rerun the mocked tests plus a controlled live pin verification.

## Build and test

```bash
cd /Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/audio/stt_deepgram
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build build
ctest --test-dir build --output-on-failure
```

Unit tests use a local mocked websocket server and do not contact Deepgram.
