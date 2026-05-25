#!/usr/bin/env bash
# embed_build_info.sh — Capture build provenance and embed in artifact
#
# Operator: Robert "Grizzly" Hanson <me@grizzlymedicine.org>
# Project:  JARVIS Digital Person — apple_native
#
# Outputs (both idempotent, overwrite on each call):
#
#   apple_native/JARVISNativeRuntime/build_info.h
#       C++17 constexpr struct included by the C++ runtime.
#       Include as: #include "build_info.h"
#
#   apple_native/build/BuildInfo.plist
#       Property list bundled into app Resources.
#       Add to Xcode target as Copy Bundle Resources.
#       (Path is configurable via --plist-out)
#
# Usage:
#   bash apple_native/tools/embed_build_info.sh [options]
#
# Options:
#   --repo-root  <path>     Repo root (default: auto-detected from script location)
#   --plist-out  <path>     Destination for BuildInfo.plist (default: apple_native/build/BuildInfo.plist)
#   --header-out <path>     Destination for build_info.h   (default: apple_native/JARVISNativeRuntime/build_info.h)
#   --verify-env            Check Xcode/SDK/Swift versions and exit (non-destructive)
#   --sbom-json  <path>     SBOM JSON path to pull serial number from
#
# Integration:
#   Add a "Run Script" build phase in Xcode (before Compile Sources):
#       bash "${SRCROOT}/../tools/embed_build_info.sh" \
#           --plist-out "${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Resources/BuildInfo.plist"
#
# CMake integration (when C++ port lands):
#   add_custom_target(EmbedBuildInfo ALL
#       COMMAND bash ${CMAKE_SOURCE_DIR}/tools/embed_build_info.sh
#           --header-out ${CMAKE_CURRENT_BINARY_DIR}/build_info.h
#       BYPRODUCTS ${CMAKE_CURRENT_BINARY_DIR}/build_info.h
#   )
#   include_directories(${CMAKE_CURRENT_BINARY_DIR})

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLE_NATIVE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${APPLE_NATIVE_DIR}/.." && pwd)"

PLIST_OUT="${APPLE_NATIVE_DIR}/build/BuildInfo.plist"
HEADER_OUT="${APPLE_NATIVE_DIR}/JARVISNativeRuntime/build_info.h"
SBOM_JSON="${APPLE_NATIVE_DIR}/sbom/sbom.json"
VERIFY_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-root)  REPO_ROOT="$2";  APPLE_NATIVE_DIR="${REPO_ROOT}/apple_native"; shift 2 ;;
        --plist-out)  PLIST_OUT="$2";  shift 2 ;;
        --header-out) HEADER_OUT="$2"; shift 2 ;;
        --sbom-json)  SBOM_JSON="$2";  shift 2 ;;
        --verify-env) VERIFY_ONLY=1;   shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Capture environment
# ---------------------------------------------------------------------------
GIT_SHA="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo "unknown")"
GIT_SHA_SHORT="${GIT_SHA:0:12}"
GIT_DIRTY="$(git -C "${REPO_ROOT}" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
GIT_BRANCH="$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"

if [[ -n "${SOURCE_DATE_EPOCH:-}" ]]; then
    [[ "${SOURCE_DATE_EPOCH}" =~ ^[0-9]+$ ]] || { echo "ERROR: SOURCE_DATE_EPOCH must be an integer Unix timestamp" >&2; exit 1; }
    BUILD_TIMESTAMP_UNIX="${SOURCE_DATE_EPOCH}"
    BUILD_TIMESTAMP="$(date -u -r "${SOURCE_DATE_EPOCH}" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || python3 -c "import datetime,sys; print(datetime.datetime.utcfromtimestamp(int(sys.argv[1])).strftime('%Y-%m-%dT%H:%M:%SZ'))" "${SOURCE_DATE_EPOCH}")"
else
    BUILD_TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    BUILD_TIMESTAMP_UNIX="$(date -u +%s)"
fi
BUILDER_USER="${USER:-unknown}"
BUILDER_HOST="$(hostname -s 2>/dev/null || echo "unknown")"
BUILDER_IDENTITY="${BUILDER_USER}@${BUILDER_HOST}"

XCODE_VERSION="$(xcodebuild -version 2>/dev/null | head -1 | sed 's/Xcode //' || true)"
if [[ -z "${XCODE_VERSION}" ]]; then
    XCODE_VERSION="$(defaults read /Applications/Xcode.app/Contents/Info CFBundleShortVersionString 2>/dev/null || true)"
fi
if [[ -z "${XCODE_VERSION}" ]]; then XCODE_VERSION="unknown"; fi
XCODE_BUILD="$(xcodebuild -version 2>/dev/null | tail -1 | sed 's/Build version //' || true)"
if [[ -z "${XCODE_BUILD}" ]]; then XCODE_BUILD="unknown"; fi
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
if [[ -z "${SDK_VERSION}" ]]; then SDK_VERSION="unknown"; fi
SWIFT_VERSION="$(swift --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)"
if [[ -z "${SWIFT_VERSION}" ]]; then SWIFT_VERSION="unknown"; fi
MACOS_VERSION="$(sw_vers -productVersion 2>/dev/null || true)"
if [[ -z "${MACOS_VERSION}" ]]; then MACOS_VERSION="unknown"; fi

# Pull SBOM serial number if available
SBOM_SERIAL="none"
if [[ -f "${SBOM_JSON}" ]]; then
    SBOM_SERIAL="$(python3 -c "import json; d=json.load(open('${SBOM_JSON}')); print(d.get('serialNumber','none'))" 2>/dev/null || echo "none")"
fi

# Hash the source files for integrity annotation
RUNTIME_CPP_HASH="n/a"
RUNTIME_H_HASH="n/a"
RUNTIME_CPP="${APPLE_NATIVE_DIR}/JARVISNativeRuntime/JARVISNativeRuntime.cpp"
RUNTIME_H="${APPLE_NATIVE_DIR}/JARVISNativeRuntime/JARVISNativeRuntime.h"
[[ -f "${RUNTIME_CPP}" ]] && RUNTIME_CPP_HASH="$(shasum -a 256 "${RUNTIME_CPP}" | awk '{print $1}')"
[[ -f "${RUNTIME_H}" ]]   && RUNTIME_H_HASH="$(shasum -a 256 "${RUNTIME_H}" | awk '{print $1}')"

# ---------------------------------------------------------------------------
# --verify-env: print and exit
# ---------------------------------------------------------------------------
if [[ "${VERIFY_ONLY}" -eq 1 ]]; then
    echo "Build Environment Verification"
    echo "────────────────────────────────────────"
    echo "  Git SHA:       ${GIT_SHA}"
    echo "  Git branch:    ${GIT_BRANCH}"
    echo "  Dirty files:   ${GIT_DIRTY}"
    echo "  Xcode:         ${XCODE_VERSION} (${XCODE_BUILD})"
    echo "  macOS SDK:     ${SDK_VERSION}"
    echo "  Swift:         ${SWIFT_VERSION}"
    echo "  macOS:         ${MACOS_VERSION}"
    echo "  Builder:       ${BUILDER_IDENTITY}"
    echo "  SBOM serial:   ${SBOM_SERIAL}"
    echo "────────────────────────────────────────"
    [[ "${GIT_DIRTY}" -gt 0 ]] && echo "⚠️  WARNING: working tree is dirty (${GIT_DIRTY} modified files)"
    echo "✅ Environment verification complete."
    exit 0
fi

echo "🔧 embed_build_info.sh"
echo "   Git SHA:       ${GIT_SHA_SHORT}  (dirty: ${GIT_DIRTY})"
echo "   Branch:        ${GIT_BRANCH}"
echo "   Timestamp:     ${BUILD_TIMESTAMP}"
echo "   Builder:       ${BUILDER_IDENTITY}"
echo "   Xcode:         ${XCODE_VERSION}"
echo "   SDK:           macOS ${SDK_VERSION}"
echo "   Swift:         ${SWIFT_VERSION}"
echo "   SBOM serial:   ${SBOM_SERIAL}"

# ---------------------------------------------------------------------------
# Write BuildInfo.plist
# ---------------------------------------------------------------------------
PLIST_DIR="$(dirname "${PLIST_OUT}")"
mkdir -p "${PLIST_DIR}"

cat > "${PLIST_OUT}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Source provenance -->
    <key>GitSHA</key>
    <string>${GIT_SHA}</string>
    <key>GitSHAShort</key>
    <string>${GIT_SHA_SHORT}</string>
    <key>GitBranch</key>
    <string>${GIT_BRANCH}</string>
    <key>GitDirtyFileCount</key>
    <integer>${GIT_DIRTY}</integer>

    <!-- Build timestamp (UTC) -->
    <key>BuildTimestamp</key>
    <string>${BUILD_TIMESTAMP}</string>
    <key>BuildTimestampUnix</key>
    <integer>${BUILD_TIMESTAMP_UNIX}</integer>

    <!-- Builder identity -->
    <key>BuilderIdentity</key>
    <string>${BUILDER_IDENTITY}</string>

    <!-- Toolchain versions -->
    <key>XcodeVersion</key>
    <string>${XCODE_VERSION}</string>
    <key>XcodeBuildVersion</key>
    <string>${XCODE_BUILD}</string>
    <key>MacOSSDKVersion</key>
    <string>${SDK_VERSION}</string>
    <key>SwiftVersion</key>
    <string>${SWIFT_VERSION}</string>
    <key>MacOSVersion</key>
    <string>${MACOS_VERSION}</string>

    <!-- SBOM linkage -->
    <key>SBOMSerialNumber</key>
    <string>${SBOM_SERIAL}</string>

    <!-- Source file hashes (SHA-256) -->
    <key>RuntimeCppSHA256</key>
    <string>${RUNTIME_CPP_HASH}</string>
    <key>RuntimeHeaderSHA256</key>
    <string>${RUNTIME_H_HASH}</string>
</dict>
</plist>
PLIST

echo "   Written: ${PLIST_OUT}"

# ---------------------------------------------------------------------------
# Write build_info.h (C++17 constexpr)
# ---------------------------------------------------------------------------
HEADER_DIR="$(dirname "${HEADER_OUT}")"
mkdir -p "${HEADER_DIR}"

# Escape strings for C: backslash and double-quote
cpp_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

GIT_SHA_ESC="$(cpp_escape "${GIT_SHA}")"
GIT_SHA_SHORT_ESC="$(cpp_escape "${GIT_SHA_SHORT}")"
GIT_BRANCH_ESC="$(cpp_escape "${GIT_BRANCH}")"
BUILD_TIMESTAMP_ESC="$(cpp_escape "${BUILD_TIMESTAMP}")"
BUILDER_IDENTITY_ESC="$(cpp_escape "${BUILDER_IDENTITY}")"
XCODE_VERSION_ESC="$(cpp_escape "${XCODE_VERSION}")"
SDK_VERSION_ESC="$(cpp_escape "${SDK_VERSION}")"
SWIFT_VERSION_ESC="$(cpp_escape "${SWIFT_VERSION}")"
SBOM_SERIAL_ESC="$(cpp_escape "${SBOM_SERIAL}")"
RUNTIME_CPP_HASH_ESC="$(cpp_escape "${RUNTIME_CPP_HASH}")"

cat > "${HEADER_OUT}" <<HEADER
// build_info.h — Auto-generated by embed_build_info.sh
// DO NOT edit by hand. Regenerate via: bash apple_native/tools/embed_build_info.sh
//
// Operator: Robert "Grizzly" Hanson <me@grizzlymedicine.org>
// Project:  JARVIS Digital Person
//
// Generated: ${BUILD_TIMESTAMP}

#pragma once

#include <string_view>

namespace jarvis {

/// Build provenance record embedded in the C++ runtime at compile time.
/// Equivalent data is in BuildInfo.plist (bundled in app Resources).
struct BuildInfoRecord {
    std::string_view gitSHA;
    std::string_view gitSHAShort;
    std::string_view gitBranch;
    int              gitDirtyFileCount;
    std::string_view buildTimestamp;      ///< UTC ISO-8601
    long long        buildTimestampUnix;
    std::string_view builderIdentity;
    std::string_view xcodeVersion;
    std::string_view macosSDKVersion;
    std::string_view swiftVersion;
    std::string_view sbomSerialNumber;
    std::string_view runtimeCppSHA256;    ///< SHA-256 of JARVISNativeRuntime.cpp at build time
};

/// Compile-time build provenance. Include this header and reference kBuildInfo.
inline constexpr BuildInfoRecord kBuildInfo = {
    .gitSHA              = "${GIT_SHA_ESC}",
    .gitSHAShort         = "${GIT_SHA_SHORT_ESC}",
    .gitBranch           = "${GIT_BRANCH_ESC}",
    .gitDirtyFileCount   = ${GIT_DIRTY},
    .buildTimestamp      = "${BUILD_TIMESTAMP_ESC}",
    .buildTimestampUnix  = ${BUILD_TIMESTAMP_UNIX}LL,
    .builderIdentity     = "${BUILDER_IDENTITY_ESC}",
    .xcodeVersion        = "${XCODE_VERSION_ESC}",
    .macosSDKVersion     = "${SDK_VERSION_ESC}",
    .swiftVersion        = "${SWIFT_VERSION_ESC}",
    .sbomSerialNumber    = "${SBOM_SERIAL_ESC}",
    .runtimeCppSHA256    = "${RUNTIME_CPP_HASH_ESC}",
};

} // namespace jarvis
HEADER

echo "   Written: ${HEADER_OUT}"
echo ""
echo "✅ Build info embedding complete."
echo "   Plist:  ${PLIST_OUT}"
echo "   Header: ${HEADER_OUT}"
echo ""
echo "   To include in C++ runtime:"
echo "     #include \"build_info.h\""
echo "     // Access: jarvis::kBuildInfo.gitSHA"
echo ""
echo "   To bundle the plist in Xcode:"
echo "     Add BuildInfo.plist to target's Copy Bundle Resources build phase."
