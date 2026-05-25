# Reproducible Builds — JARVIS Native Runtime

**Operator:** Robert "Grizzly" Hanson <me@grizzlymedicine.org>  
**Applies to:** `apple_native/` — C++ runtime, Mac Cockpit, iOS/watchOS companion apps

---

## TL;DR

| Build phase | Reproducible? | Blocker |
|-------------|:-------------:|---------|
| C++ runtime compile (CMake / Xcode) | ✅ Yes (with pins) | Timestamp in object files — strip with `-Wl,-no_uuid` or accept |
| Swift compilation | ✅ Yes (with pins) | Swift embeds build-time UUID per module; deterministic with same toolchain |
| Asset catalog processing | ⚠️ Mostly | `actool` embeds a timestamp in compiled `.car` files |
| Code signing (development) | ❌ No | Timestamp in signature; entitlement list snapshot at sign time |
| Code signing (release/notarization) | ❌ No | Apple notarization staple embeds Apple's timestamp |
| Provisioning profile selection | ❌ No | Profile selected at sign time by Xcode; UUID changes with each re-provision |
| Notarization staple | ❌ No | Apple-generated; non-reproducible by design |

**Practical stance:** Pin the toolchain. Capture build metadata. Accept that the signed artifact
is not byte-for-byte reproducible. The *source-to-object* compilation step IS reproducible given
the same toolchain, SDK, and flags.

---

## Required Environment

Pin these versions for any build that enters the evidentiary record:

| Component | Pinned value | How to verify |
|-----------|-------------|---------------|
| Xcode | See `BUILD_ENV.xcconfig` | `xcodebuild -version` |
| macOS SDK | See `BUILD_ENV.xcconfig` | `xcrun --sdk macosx --show-sdk-version` |
| Swift toolchain | See `BUILD_ENV.xcconfig` | `swift --version` |
| macOS (build host) | See `BUILD_ENV.xcconfig` | `sw_vers -productVersion` |
| libc++ | Pinned by SDK version | Ships with Xcode CLT |
| CommonCrypto | Pinned by SDK version | Ships with macOS SDK |

Current build environment (captured at doc generation):

```
# Current machine — update BUILD_ENV.xcconfig to match your release environment
JARVIS_REQUIRED_XCODE_VERSION   = (run: xcodebuild -version)
JARVIS_REQUIRED_SDK_VERSION     = (run: xcrun --sdk macosx --show-sdk-version)
JARVIS_REQUIRED_SWIFT_VERSION   = (run: swift --version | head -1)
JARVIS_REQUIRED_MACOS_VERSION   = (run: sw_vers -productVersion)
```

Create `apple_native/BUILD_ENV.xcconfig` with pinned values and import it into
the Xcode project as a base configuration. This file should be committed and is
the authoritative record of the build environment for a given release.

---

## Where Builds CAN Be Reproducible

### C++ Runtime (JARVISNativeRuntime)

The C++ source (`JARVISNativeRuntime.cpp`) depends only on:
- C++ standard library (ships with SDK)
- CommonCrypto (ships with SDK)

No vendored dependencies. No generated code. No macros with `__DATE__` / `__TIME__` unless
explicitly added.

**Determinism requirements:**
```
# Flags that help determinism (add to CXXFLAGS):
-ffile-prefix-map=$(SRCROOT)=.      # strip absolute paths from debug info
-Wno-builtin-macro-redefined
# Avoid if possible (not strictly needed):
# __DATE__, __TIME__, __TIMESTAMP__ macros — exclude from source
```

**UUID stripping** (accepts non-byte-identical binaries but removes timestamp):
```
# In CMakeLists.txt or Xcode build settings:
OTHER_LDFLAGS = -Wl,-no_uuid
```

### Swift Package (JARVISCompanion)

Swift compilation is deterministic given:
1. Same Swift toolchain version
2. Same SDK version  
3. Same source files (no generated output that embeds timestamps)
4. `-wmo` (whole-module-optimization) mode for release builds

```bash
# Deterministic Swift build invocation:
swift build \
    --configuration release \
    --triple arm64-apple-macosx14.0 \
    -Xswiftc -wmo \
    -Xswiftc -Onone   # or -O for release
```

---

## Where Builds CANNOT Be Reproducible

### Code Signing

Every code-signed binary contains an embedded signature with:
1. **CMS timestamp** — the exact second of signing
2. **Certificate chain snapshot** — the certificates used at sign time
3. **Provisioning profile UUID** — selected by Xcode at sign time

These are intentionally non-reproducible. Apple's security model depends on timestamps
being unique per signing event.

**Mitigation for evidentiary purposes:** Use the SBOM + build-info plist to anchor the
artifact to a specific git commit. The signature provides authenticity; the SBOM provides
provenance.

### Notarization Staple

Apple's notarization service attaches a staple (a cryptographic ticket) to the `.app`
bundle after submission. The staple contains:
- Apple's signing timestamp
- Apple's ticket serial number

This is by design non-reproducible. It proves Apple inspected the binary at a specific time.
For legal proceedings, the notarization record (Apple ticket) is itself evidence of provenance.

### Asset Catalogs

`actool` embeds a compilation timestamp in the `.car` file. This makes asset catalogs
non-byte-identical across builds even with identical sources.

**Mitigation:** For evidentiary builds, record the hash of the source `.xcassets` directory,
not the compiled `.car`.

---

## Recommended Build Invocation

Use this invocation for any build that enters the evidentiary record:

```bash
# From repo root: /Users/rbhanson/research/jarvis/
#
# 1. Verify environment pins
./apple_native/tools/embed_build_info.sh --verify-env
#
# 2. Generate SBOM
bash ./apple_native/tools/generate_sbom.sh
#
# 3. Embed build info (writes BuildInfo.plist + build_info.h)
bash ./apple_native/tools/embed_build_info.sh
#
# 4. Build (via xcodegen + xcodebuild)
xcodebuild \
    -project apple_native/JARVISCompanionApps.xcodeproj \
    -scheme JARVISMacCockpit \
    -configuration Release \
    -destination "platform=macOS,arch=arm64" \
    SWIFT_COMPILATION_MODE=wholemodule \
    SWIFT_OPTIMIZATION_LEVEL=-O \
    OTHER_CFLAGS="-ffile-prefix-map=$(pwd)/apple_native=." \
    OTHER_CXXFLAGS="-ffile-prefix-map=$(pwd)/apple_native=." \
    INFOPLIST_OTHER_PREPROCESSOR_FLAGS="" \
    build \
    | xcpretty   # optional: brew install xcpretty
```

---

## Build-Info Plist Embedding

A `BuildInfo.plist` is generated by `embed_build_info.sh` and included in the app bundle.
It records:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
<plist version="1.0">
<dict>
    <key>GitSHA</key>         <string><!-- full SHA --></string>
    <key>GitSHAShort</key>    <string><!-- 12-char --></string>
    <key>BuildTimestamp</key> <string><!-- UTC ISO-8601 --></string>
    <key>BuilderIdentity</key><string><!-- $USER@$HOSTNAME --></string>
    <key>XcodeVersion</key>   <string><!-- e.g. 16.2 --></string>
    <key>SDKVersion</key>     <string><!-- e.g. 15.2 --></string>
    <key>SwiftVersion</key>   <string><!-- e.g. 5.10.0 --></string>
    <key>SBOMSerialNumber</key><string><!-- urn:jarvis:sbom:... --></string>
</dict>
</plist>
```

This plist is the cryptographic anchor between the signed binary and the source commit.
Even though the binary is not byte-reproducible, the plist establishes an auditable chain:

```
git commit SHA → BuildInfo.plist → signed .app bundle → notarization ticket
```

---

## Environment Pinning — BUILD_ENV.xcconfig

Create this file and commit it (update per release):

```xcconfig
// apple_native/BUILD_ENV.xcconfig
// Pinned build environment for evidentiary builds
// Update when toolchain is upgraded; record the change in CHANGELOG.

JARVIS_REQUIRED_XCODE_MAJOR = 16
JARVIS_REQUIRED_SDK_MIN     = 15.0
JARVIS_REQUIRED_SWIFT_MAJOR = 5

// Embed in binary for verification
JARVIS_BUILD_ENV_XCODE  = $(XCODE_VERSION_ACTUAL)
JARVIS_BUILD_ENV_SDK    = $(SDK_VERSION)
JARVIS_BUILD_ENV_TRIPLE = $(CURRENT_ARCH)-apple-$(PLATFORM_NAME)$(DEPLOYMENT_TARGET_SETTING_NAME)
```

---

## Gaps Requiring Operator Action

1. **No CMakeLists.txt** — the C++ runtime is currently built via Xcode directly. When the
   CMake port lands, add determinism flags (`-ffile-prefix-map`, `-no_uuid`) to the CMakeLists.
   The `embed_build_info.sh` script already writes `build_info.h` at a known path for the
   C++ port to include.

2. **BUILD_ENV.xcconfig not yet created** — create it after pinning your release Xcode version.

3. **xcodegen not pinned** — `project.yml` drives project generation. Pin the xcodegen version
   in a `Brewfile` or `.tool-versions` file.

4. **No CI environment documented** — when CI is added, document the macOS runner version,
   Xcode version, and provisioning profile strategy here.
