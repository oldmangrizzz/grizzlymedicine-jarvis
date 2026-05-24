#!/usr/bin/env bash
# generate_sbom.sh — CycloneDX 1.5 SBOM generator for JARVIS Digital Person
#
# Operator: Robert "Grizzly" Hanson <me@grizzlymedicine.org>
# Project:  JARVIS Digital Person — apple_native
# Version:  2.0.0  (p5-sbom-voice-weights extension)
#
# Output:
#   apple_native/sbom/sbom.json                — CycloneDX 1.5 JSON SBOM
#   apple_native/sbom/sbom.md                  — human-readable summary
#   apple_native/sbom/voice-weights-baseline.json — per-file hash baseline
#
# ── IDEMPOTENCY GUARANTEE ───────────────────────────────────────────────────
# Running this script twice with no filesystem changes produces byte-identical
# SBOM JSON output.  Two mechanisms enforce this:
#
#   1. SOURCE_DATE_EPOCH — if set, the metadata timestamp and serial number
#      are derived from this fixed epoch value instead of wall-clock time.
#      Set before a release tag:
#        export SOURCE_DATE_EPOCH=$(git log -1 --format=%ct)
#        bash apple_native/tools/generate_sbom.sh
#
#   2. Lexicographic component sort — all CycloneDX components are sorted by
#      bom-ref before serialization.  File discovery uses sorted() throughout.
#      No component ordering depends on filesystem readdir order.
#
# ── INTEGRITY TRIPWIRE ───────────────────────────────────────────────────────
# After generating the new SBOM, the script diffs every voice-weight SHA-256
# hash against voice-weights-baseline.json (if present).  Any hash change that
# was NOT pre-authorized via a baseline update triggers:
#
#   ⚠️  WARNING: voice weight hash changed since last SBOM baseline.
#
# This surfaces model-weight tampering on the next SBOM run.
# Operator workflow for an authorized voice update:
#   (a) Commit the new voice file(s)
#   (b) Run:  bash apple_native/tools/generate_sbom.sh
#   (c) Edit voice-weights-baseline.json — add new hash entry with timestamp
#       and reason (e.g. "operator-authorized update on YYYY-MM-DD: …")
#   (d) Re-run generate_sbom.sh to confirm clean (no tamper warning)
#   (e) Commit baseline + SBOM together
#
# Usage:
#   bash apple_native/tools/generate_sbom.sh [--repo-root /path/to/jarvis]
#
# Requirements:
#   - bash >= 3.2 (macOS system bash is fine)
#   - python3
#   - git (for commit SHA)
#   - xcodebuild (optional; for Xcode/SDK version capture)

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLE_NATIVE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${APPLE_NATIVE_DIR}/.." && pwd)"

# Allow override via --repo-root
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-root) REPO_ROOT="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

APPLE_NATIVE_DIR="${REPO_ROOT}/apple_native"
RUNTIME_DIR="${APPLE_NATIVE_DIR}/JARVISNativeRuntime"
COMPANION_DIR="${REPO_ROOT}/apple_companion"
SBOM_DIR="${APPLE_NATIVE_DIR}/sbom"
SBOM_JSON="${SBOM_DIR}/sbom.json"
SBOM_MD="${SBOM_DIR}/sbom.md"

mkdir -p "${SBOM_DIR}"

# ---------------------------------------------------------------------------
# Metadata
# ---------------------------------------------------------------------------
GIT_SHA="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo "unknown")"
GIT_SHA_SHORT="${GIT_SHA:0:12}"

# SOURCE_DATE_EPOCH support — set this env var for deterministic/reproducible output.
# When set, timestamp and serial number are derived from this fixed epoch value
# instead of wall-clock time.  Two runs with the same SOURCE_DATE_EPOCH and
# identical file contents produce byte-identical SBOM JSON.
#   Usage:  export SOURCE_DATE_EPOCH=$(git log -1 --format=%ct)
if [[ -n "${SOURCE_DATE_EPOCH:-}" ]]; then
    TIMESTAMP="$(date -u -r "${SOURCE_DATE_EPOCH}" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
                 || python3 -c "import datetime,sys; print(datetime.datetime.utcfromtimestamp(int(sys.argv[1])).strftime('%Y-%m-%dT%H:%M:%SZ'))" "${SOURCE_DATE_EPOCH}")"
    EPOCH_FOR_SERIAL="${SOURCE_DATE_EPOCH}"
else
    TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    EPOCH_FOR_SERIAL="$(date -u +%s)"
fi
SERIAL_NUMBER="urn:jarvis:sbom:${GIT_SHA_SHORT}:${EPOCH_FOR_SERIAL}"

XCODE_VERSION="$(xcodebuild -version 2>/dev/null | head -1 | sed 's/Xcode //' || true)"
if [[ -z "${XCODE_VERSION}" ]]; then
    XCODE_VERSION="$(defaults read /Applications/Xcode.app/Contents/Info CFBundleShortVersionString 2>/dev/null || true)"
fi
if [[ -z "${XCODE_VERSION}" ]]; then XCODE_VERSION="unknown"; fi
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
if [[ -z "${SDK_VERSION}" ]]; then SDK_VERSION="unknown"; fi
SWIFT_VERSION="$(swift --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)"
if [[ -z "${SWIFT_VERSION}" ]]; then SWIFT_VERSION="unknown"; fi

echo "🔍 JARVIS SBOM Generator v2.0.0"
echo "   Repo root:     ${REPO_ROOT}"
echo "   Git SHA:       ${GIT_SHA_SHORT}"
echo "   Xcode:         ${XCODE_VERSION}"
echo "   SDK:           macOS ${SDK_VERSION}"
echo "   Swift:         ${SWIFT_VERSION}"
echo "   Timestamp:     ${TIMESTAMP}"
if [[ -n "${SOURCE_DATE_EPOCH:-}" ]]; then
    echo "   Deterministic: SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} (reproducible build)"
else
    echo "   Deterministic: set SOURCE_DATE_EPOCH for reproducible output"
fi
echo ""

# ---------------------------------------------------------------------------
# Component inventory functions
# ---------------------------------------------------------------------------

# Hash a file for integrity field
sha256_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        echo "n/a"
    fi
}

# ---------------------------------------------------------------------------
# C++ Runtime components
# ---------------------------------------------------------------------------
# The JARVISNativeRuntime has NO vendored third-party libraries.
# It depends exclusively on:
#   - C++ standard library (libc++ — ships with Xcode/Apple CLT)
#   - CommonCrypto   — Apple system framework, part of macOS SDK
#   - C++ standard headers: algorithm, chrono, filesystem, etc. — part of libc++
#
# These are Apple-supplied system components pinned by SDK version.

RUNTIME_CPP_HASH="$(sha256_file "${RUNTIME_DIR}/JARVISNativeRuntime.cpp")"
RUNTIME_H_HASH="$(sha256_file "${RUNTIME_DIR}/JARVISNativeRuntime.h")"

echo "📦 C++ Runtime components:"
echo "   JARVISNativeRuntime.cpp  sha256:${RUNTIME_CPP_HASH:0:16}..."
echo "   JARVISNativeRuntime.h    sha256:${RUNTIME_H_HASH:0:16}..."
echo "   System deps: libc++ (macOS SDK ${SDK_VERSION}), CommonCrypto (macOS SDK ${SDK_VERSION})"

# ---------------------------------------------------------------------------
# Swift Package components
# ---------------------------------------------------------------------------
# JARVISCompanion is a local-only package (no remote SwiftPM dependencies).
# Targets: JARVISCompanionCore, JARVISCompanionUI, JARVISCompanionSelfTest

PACKAGE_SWIFT_HASH="$(sha256_file "${COMPANION_DIR}/Package.swift")"

echo ""
echo "📦 Swift Package components:"
echo "   JARVISCompanion (local)  Package.swift sha256:${PACKAGE_SWIFT_HASH:0:16}..."
echo "   No remote SwiftPM dependencies (no Package.resolved)."

# Check for Package.resolved anywhere in the xcodeproj
RESOLVED_FILE=""
if [[ -f "${APPLE_NATIVE_DIR}/JARVISCompanionApps.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" ]]; then
    RESOLVED_FILE="${APPLE_NATIVE_DIR}/JARVISCompanionApps.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
fi

SWIFT_EXTERNAL_COMPONENTS="[]"
if [[ -n "${RESOLVED_FILE}" ]]; then
    echo "   Found Package.resolved — parsing external dependencies..."
    # Parse with python3
    SWIFT_EXTERNAL_COMPONENTS="$(python3 - "${RESOLVED_FILE}" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
pins = data.get("pins", [])
comps = []
for pin in pins:
    identity = pin.get("identity", pin.get("package", "unknown"))
    url = pin.get("location", pin.get("repositoryURL", ""))
    state = pin.get("state", {})
    version = state.get("version") or state.get("branch") or state.get("revision", "unknown")
    revision = state.get("revision", "")
    comps.append({
        "type": "library",
        "bom-ref": f"swiftpm:{identity}",
        "name": identity,
        "version": version,
        "purl": f"pkg:swift/{url}@{version}" if url else f"pkg:swift/{identity}@{version}",
        "externalReferences": [{"type": "vcs", "url": url}] if url else [],
        "hashes": [{"alg": "SHA-1", "content": revision}] if revision else [],
        "supplier": {"name": "external", "url": [url] if url else []},
        "licenses": [{"license": {"name": "see repository"}}]
    })
print(json.dumps(comps, indent=2))
PYEOF
)"
fi

# ---------------------------------------------------------------------------
# Voice model file discovery and hashing
# ---------------------------------------------------------------------------
# Scans apple_native/JARVISNativeRuntime/voice/ for model weights.
#
# Supported types:
#   *.onnx              — ONNX model files (text_encoder, gpt_decoder, etc.)
#   *.mlpackage/        — CoreML package directories; each member file is hashed
#                         individually, and a package-level entry uses the
#                         Manifest.json hash as the primary representative hash.
#                         Member count is recorded in jarvis:mlpackage-files.
#   *.pt / *.ckpt       — PyTorch/torchscript checkpoints (libtorch race output)
#   *.safetensors       — canonical safetensors model state files
#
# Files not yet present (TTS race output expected later) are skipped gracefully.

VOICE_DIR="${RUNTIME_DIR}/voice"
LOCAL_VOICE_DIR="${REPO_ROOT}/_local_voice"

echo "🔊 Voice model file discovery:"
if [[ -d "${VOICE_DIR}" ]]; then
    echo "   Scanning ${VOICE_DIR}"
else
    echo "   ⚠️  voice/ directory not found — will record as absent"
fi
if [[ -d "${LOCAL_VOICE_DIR}" ]]; then
    echo "   Scanning ${LOCAL_VOICE_DIR} (canonical identity voice)"
else
    echo "   ⚠️  _local_voice/ directory not found"
fi

# Collect voice model file metadata as JSON for the Python block.
# Uses Python for deterministic discovery + sorting so bash array portability
# across macOS bash 3.2 is not a concern.
VOICE_COMPONENTS_JSON="$(VOICE_DIR="${VOICE_DIR}" LOCAL_VOICE_DIR="${LOCAL_VOICE_DIR}" \
REPO_ROOT="${REPO_ROOT}" TIMESTAMP="${TIMESTAMP}" \
python3 - <<'PYEOF'
import json, os, subprocess, hashlib

voice_dir      = os.environ["VOICE_DIR"]
local_voice    = os.environ["LOCAL_VOICE_DIR"]
repo_root      = os.environ["REPO_ROOT"]
timestamp      = os.environ["TIMESTAMP"]

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()

def rel(path):
    """Return path relative to repo root."""
    return os.path.relpath(path, repo_root)

components = []

# ── ONNX / PT / CKPT / SAFETENSORS — individual files ──────────────────────
if os.path.isdir(voice_dir):
    for dirpath, dirnames, filenames in os.walk(voice_dir):
        # Skip CMake build artifacts inside voice/ (classifier/build, etc.)
        dirnames[:] = sorted(
            d for d in dirnames
            if not d.endswith(".mlpackage")  # handled separately below
            and d not in ("build", "_deps", "CMakeFiles")
            and not d.startswith(".")
        )
        for fname in sorted(filenames):
            ext = os.path.splitext(fname)[1].lower()
            if ext not in (".onnx", ".pt", ".ckpt", ".safetensors"):
                continue
            fpath = os.path.join(dirpath, fname)
            rpath = rel(fpath)
            fhash = sha256(fpath)
            if ext == ".onnx":
                category = "voice-weight"
                ctype    = "data"
                desc     = "ONNX voice model weight"
            elif ext in (".pt", ".ckpt"):
                category = "voice-weight"
                ctype    = "data"
                desc     = "PyTorch/TorchScript voice model checkpoint"
            elif ext == ".safetensors":
                category = "voice-weight"
                ctype    = "data"
                desc     = "SafeTensors voice model state"
            else:
                category = "voice-weight"
                ctype    = "data"
                desc     = "Voice model weight"
            components.append({
                "type": ctype,
                "bom-ref": f"jarvis:voice:{rpath}",
                "name": rpath,
                "version": "unknown",
                "description": desc,
                "hashes": [{"alg": "SHA-256", "content": fhash}],
                "properties": [
                    {"name": "jarvis:category", "value": category},
                    {"name": "jarvis:voice-dir", "value": rel(dirpath)},
                ],
            })

# ── CoreML .mlpackage directories ────────────────────────────────────────────
# Strategy: hash every member file individually so the SBOM captures granular
# integrity.  Also record a package-level entry whose representative hash is the
# SHA-256 of Manifest.json (the CoreML package manifest that lists all members).
# Determinism: member files are discovered via sorted os.walk.
if os.path.isdir(voice_dir):
    for dirpath, dirnames, filenames in os.walk(voice_dir):
        dirnames.sort()
        for dname in list(dirnames):
            if dname.endswith(".mlpackage"):
                pkg_path = os.path.join(dirpath, dname)
                pkg_rel  = rel(pkg_path)
                manifest_path = os.path.join(pkg_path, "Manifest.json")
                manifest_hash = sha256(manifest_path) if os.path.isfile(manifest_path) else "missing"
                member_files = []
                for wp, wdirs, wfiles in os.walk(pkg_path):
                    wdirs.sort()
                    for wf in sorted(wfiles):
                        mpath = os.path.join(wp, wf)
                        mrel  = rel(mpath)
                        mhash = sha256(mpath)
                        member_files.append((mrel, mhash))
                        components.append({
                            "type": "data",
                            "bom-ref": f"jarvis:voice:{mrel}",
                            "name": mrel,
                            "version": "unknown",
                            "description": f"CoreML package member file ({dname})",
                            "hashes": [{"alg": "SHA-256", "content": mhash}],
                            "properties": [
                                {"name": "jarvis:category", "value": "voice-weight"},
                                {"name": "jarvis:mlpackage", "value": pkg_rel},
                            ],
                        })
                # Package-level rollup entry (bom-ref uses the package dir path)
                components.append({
                    "type": "data",
                    "bom-ref": f"jarvis:voice:{pkg_rel}",
                    "name": pkg_rel,
                    "version": "unknown",
                    "description": f"CoreML .mlpackage — {dname} (manifest-hash representative)",
                    "hashes": [{"alg": "SHA-256", "content": manifest_hash}],
                    "properties": [
                        {"name": "jarvis:category", "value": "voice-weight"},
                        {"name": "jarvis:mlpackage-files", "value": str(len(member_files))},
                    ],
                })

# ── _local_voice/ reference assets ────────────────────────────────────────────
# This directory IS the canonical voice identity.  Any tampering here is an
# identity violation.  Hash every file except .gitignore and cache metadata.
SKIP_EXTENSIONS = {".gitignore", ".metadata", ".lock"}
SKIP_DIRS       = {"hf_cache", ".cache"}
if os.path.isdir(local_voice):
    for dirpath, dirnames, filenames in os.walk(local_voice):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS and not d.startswith("."))
        for fname in sorted(filenames):
            if fname.startswith(".") or os.path.splitext(fname)[1] in SKIP_EXTENSIONS:
                continue
            fpath = os.path.join(dirpath, fname)
            rpath = rel(fpath)
            fhash = sha256(fpath)
            components.append({
                "type": "data",
                "bom-ref": f"jarvis:local-voice:{rpath}",
                "name": rpath,
                "version": "unknown",
                "description": "Canonical voice reference asset (_local_voice/)",
                "hashes": [{"alg": "SHA-256", "content": fhash}],
                "properties": [
                    {"name": "jarvis:category", "value": "reference-asset"},
                    {"name": "jarvis:identity-critical", "value": "true"},
                ],
            })

# Sort by bom-ref for deterministic output
components.sort(key=lambda c: c["bom-ref"])
print(json.dumps(components))
PYEOF
)"

echo "   Voice components found: $(echo "${VOICE_COMPONENTS_JSON}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d))')"

# ---------------------------------------------------------------------------
# Third-party vendored library discovery
# ---------------------------------------------------------------------------
# Scans apple_native/JARVISNativeRuntime/third_party/ for compiled artifacts.
# Handles: *.a (static libs), *.so / *.dylib (shared libs), *.framework dirs.
# If third_party/ is absent or empty, emits an empty array gracefully.
# Fetched-at-build-time deps (Catch2 via FetchContent, onnxruntime if downloaded)
# are documented as external references in SBOM metadata, not as file components.

THIRD_PARTY_DIR="${RUNTIME_DIR}/third_party"
echo ""
echo "📚 Third-party library scan:"
if [[ -d "${THIRD_PARTY_DIR}" ]]; then
    echo "   Scanning ${THIRD_PARTY_DIR}"
else
    echo "   third_party/ absent — no vendored libs present (expected: empty)"
fi

THIRD_PARTY_COMPONENTS_JSON="$(THIRD_PARTY_DIR="${THIRD_PARTY_DIR}" REPO_ROOT="${REPO_ROOT}" \
python3 - <<'PYEOF'
import json, os, hashlib, re

third_party = os.environ["THIRD_PARTY_DIR"]
repo_root   = os.environ["REPO_ROOT"]

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()

def rel(path):
    return os.path.relpath(path, repo_root)

def version_from_tag(dirpath):
    """Try to read version from .tag or version.txt in same directory."""
    for candidate in (".tag", "version.txt", "VERSION", "version"):
        p = os.path.join(dirpath, candidate)
        if os.path.isfile(p):
            try:
                return open(p).read().strip()[:40]
            except Exception:
                pass
    return "unknown"

def version_from_filename(fname):
    """Extract version from filename like libfoo-1.2.3.a"""
    m = re.search(r'[-_]([0-9]+\.[0-9]+(?:\.[0-9]+)?)', fname)
    return m.group(1) if m else "unknown"

components = []

if not os.path.isdir(third_party):
    print(json.dumps(components))
    raise SystemExit(0)

LIB_EXTENSIONS = {".a", ".so", ".dylib"}

for dirpath, dirnames, filenames in os.walk(third_party):
    dirnames.sort()
    # Check for .framework bundles
    for dname in sorted(dirnames):
        if dname.endswith(".framework"):
            fw_path  = os.path.join(dirpath, dname)
            fw_rel   = rel(fw_path)
            # Hash the binary inside the framework
            fw_bin   = os.path.join(fw_path, os.path.splitext(dname)[0])
            fw_hash  = sha256(fw_bin) if os.path.isfile(fw_bin) else "n/a"
            version  = version_from_tag(fw_path)
            components.append({
                "type": "library",
                "bom-ref": f"jarvis:third-party:{fw_rel}",
                "name": fw_rel,
                "version": version,
                "description": f"Vendored .framework: {dname}",
                "hashes": [{"alg": "SHA-256", "content": fw_hash}],
                "properties": [
                    {"name": "jarvis:category", "value": "third-party-lib"},
                    {"name": "jarvis:lib-type", "value": "framework"},
                ],
            })
    for fname in sorted(filenames):
        ext = os.path.splitext(fname)[1].lower()
        if ext not in LIB_EXTENSIONS:
            continue
        fpath = os.path.join(dirpath, fname)
        rpath = rel(fpath)
        fhash = sha256(fpath)
        version = version_from_tag(dirpath)
        if version == "unknown":
            version = version_from_filename(fname)
        components.append({
            "type": "library",
            "bom-ref": f"jarvis:third-party:{rpath}",
            "name": rpath,
            "version": version,
            "description": f"Vendored C++ library ({ext})",
            "hashes": [{"alg": "SHA-256", "content": fhash}],
            "properties": [
                {"name": "jarvis:category", "value": "third-party-lib"},
                {"name": "jarvis:lib-type", "value": ext.lstrip(".")},
            ],
        })

components.sort(key=lambda c: c["bom-ref"])
print(json.dumps(components))
PYEOF
)"
echo "   Third-party components found: $(echo "${THIRD_PARTY_COMPONENTS_JSON}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d))')"
echo ""
echo "✍️  Writing ${SBOM_JSON}"

python3 - <<PYEOF
import json, hashlib, os, sys

repo_root = "${REPO_ROOT}"
timestamp = "${TIMESTAMP}"
git_sha   = "${GIT_SHA}"
git_sha_short = "${GIT_SHA_SHORT}"
serial    = "${SERIAL_NUMBER}"
sdk_ver   = "${SDK_VERSION}"
xcode_ver = "${XCODE_VERSION}"
swift_ver = "${SWIFT_VERSION}"
sbom_path = "${SBOM_JSON}"
runtime_cpp_hash = "${RUNTIME_CPP_HASH}"
runtime_h_hash   = "${RUNTIME_H_HASH}"
package_swift_hash = "${PACKAGE_SWIFT_HASH}"
swift_external_raw   = '''${SWIFT_EXTERNAL_COMPONENTS}'''
voice_components_raw = '''${VOICE_COMPONENTS_JSON}'''
third_party_raw      = '''${THIRD_PARTY_COMPONENTS_JSON}'''

try:
    swift_external = json.loads(swift_external_raw) if swift_external_raw.strip() not in ["", "[]"] else []
except Exception:
    swift_external = []

try:
    voice_components = json.loads(voice_components_raw) if voice_components_raw.strip() not in ["", "[]"] else []
except Exception:
    voice_components = []

try:
    third_party_components = json.loads(third_party_raw) if third_party_raw.strip() not in ["", "[]"] else []
except Exception:
    third_party_components = []

# First-party components (JARVIS source under this repo)
first_party = [
    {
        "type": "library",
        "bom-ref": "jarvis:JARVISNativeRuntime",
        "name": "JARVISNativeRuntime",
        "version": git_sha_short,
        "description": "JARVIS C++ runtime — cognitive state, skill dispatch, audit trail",
        "supplier": {"name": "Grizzly Medicine Research Institute", "contact": [{"email": "me@grizzlymedicine.org"}]},
        "author": "Robert \"Grizzly\" Hanson",
        "licenses": [{"license": {"name": "Proprietary — GMRI"}}],
        "hashes": [
            {"alg": "SHA-256", "content": runtime_cpp_hash},
        ],
        "purl": f"pkg:generic/gmri/JARVISNativeRuntime@{git_sha_short}",
        "externalReferences": [],
        "properties": [
            {"name": "jarvis:language", "value": "C++20"},
            {"name": "jarvis:source-file", "value": "apple_native/JARVISNativeRuntime/JARVISNativeRuntime.cpp"},
        ],
    },
    {
        "type": "library",
        "bom-ref": "jarvis:JARVISCompanionCore",
        "name": "JARVISCompanionCore",
        "version": git_sha_short,
        "description": "JARVIS Swift companion core library",
        "supplier": {"name": "Grizzly Medicine Research Institute", "contact": [{"email": "me@grizzlymedicine.org"}]},
        "author": "Robert \"Grizzly\" Hanson",
        "licenses": [{"license": {"name": "Proprietary — GMRI"}}],
        "hashes": [
            {"alg": "SHA-256", "content": package_swift_hash},
        ],
        "purl": f"pkg:generic/gmri/JARVISCompanionCore@{git_sha_short}",
        "properties": [
            {"name": "jarvis:language", "value": "Swift 6"},
            {"name": "jarvis:swift-tools-version", "value": "6.0"},
            {"name": "jarvis:source-dir", "value": "apple_companion/Sources/JARVISCompanionCore"},
        ],
    },
    {
        "type": "library",
        "bom-ref": "jarvis:JARVISCompanionUI",
        "name": "JARVISCompanionUI",
        "version": git_sha_short,
        "description": "JARVIS Swift companion UI library (SwiftUI)",
        "supplier": {"name": "Grizzly Medicine Research Institute", "contact": [{"email": "me@grizzlymedicine.org"}]},
        "author": "Robert \"Grizzly\" Hanson",
        "licenses": [{"license": {"name": "Proprietary — GMRI"}}],
        "purl": f"pkg:generic/gmri/JARVISCompanionUI@{git_sha_short}",
        "properties": [
            {"name": "jarvis:language", "value": "Swift 6"},
            {"name": "jarvis:source-dir", "value": "apple_companion/Sources/JARVISCompanionUI"},
        ],
    },
]

# Apple system framework components (pinned by SDK version)
system_components = [
    {
        "type": "framework",
        "bom-ref": f"apple:libc++@{sdk_ver}",
        "name": "libc++ (LLVM C++ Standard Library)",
        "version": sdk_ver,
        "description": "Apple LLVM C++ standard library, part of macOS SDK",
        "supplier": {"name": "Apple Inc.", "url": ["https://developer.apple.com"]},
        "licenses": [{"license": {"id": "MIT", "url": "https://opensource.org/licenses/MIT"}}],
        "purl": f"pkg:generic/apple/libc%2B%2B@{sdk_ver}",
        "properties": [
            {"name": "jarvis:sdk-version", "value": sdk_ver},
            {"name": "jarvis:xcode-version", "value": xcode_ver},
        ],
    },
    {
        "type": "framework",
        "bom-ref": f"apple:CommonCrypto@{sdk_ver}",
        "name": "CommonCrypto",
        "version": sdk_ver,
        "description": "Apple Common Cryptographic library (SHA-256 digest, used for state hashing)",
        "supplier": {"name": "Apple Inc.", "url": ["https://developer.apple.com"]},
        "licenses": [{"license": {"name": "Apple SDK License Agreement"}}],
        "purl": f"pkg:generic/apple/CommonCrypto@{sdk_ver}",
        "properties": [
            {"name": "jarvis:sdk-version", "value": sdk_ver},
            {"name": "jarvis:used-by", "value": "JARVISNativeRuntime"},
        ],
    },
    {
        "type": "framework",
        "bom-ref": f"apple:SwiftStdlib@{swift_ver}",
        "name": "Swift Standard Library",
        "version": swift_ver,
        "description": "Apple Swift standard library and Swift runtime",
        "supplier": {"name": "Apple Inc.", "url": ["https://developer.apple.com"]},
        "licenses": [{"license": {"id": "Apache-2.0", "url": "https://github.com/apple/swift/blob/main/LICENSE.txt"}}],
        "purl": f"pkg:generic/apple/SwiftStdlib@{swift_ver}",
        "properties": [
            {"name": "jarvis:swift-version", "value": swift_ver},
        ],
    },
    {
        "type": "framework",
        "bom-ref": f"apple:SwiftUI@{sdk_ver}",
        "name": "SwiftUI",
        "version": sdk_ver,
        "description": "Apple SwiftUI declarative UI framework",
        "supplier": {"name": "Apple Inc.", "url": ["https://developer.apple.com"]},
        "licenses": [{"license": {"name": "Apple SDK License Agreement"}}],
        "purl": f"pkg:generic/apple/SwiftUI@{sdk_ver}",
    },
    {
        "type": "framework",
        "bom-ref": f"apple:AVFoundation@{sdk_ver}",
        "name": "AVFoundation",
        "version": sdk_ver,
        "description": "Apple media framework — used for microphone/audio in companion apps",
        "supplier": {"name": "Apple Inc.", "url": ["https://developer.apple.com"]},
        "licenses": [{"license": {"name": "Apple SDK License Agreement"}}],
        "purl": f"pkg:generic/apple/AVFoundation@{sdk_ver}",
    },
]

# Combine all component categories, then sort lexicographically by bom-ref.
# This is the determinism guarantee: regardless of filesystem readdir order or
# discovery sequence, the JSON output is always identical for identical inputs.
all_components_unsorted = (
    first_party
    + system_components
    + swift_external
    + voice_components
    + third_party_components
)
all_components = sorted(all_components_unsorted, key=lambda c: c["bom-ref"])

# External references for fetched-at-build-time deps not vendored in the repo.
# These are documented for supply-chain traceability even though we don't ship them.
fetch_content_refs = [
    {
        "type": "distribution",
        "url": "https://github.com/catchorg/Catch2",
        "comment": "Catch2 test framework — fetched via CMake FetchContent at build time; not vendored in repo. Expected version: v3.x (see CMakeLists.txt). Hash not captured (not in repo).",
    },
    {
        "type": "distribution",
        "url": "https://github.com/microsoft/onnxruntime",
        "comment": "ONNX Runtime C++ — if downloaded at build time, not vendored in repo. Expected version: see voice/tts/onnx/ build setup. Hash not captured (not in repo).",
    },
]

sbom = {
    "bomFormat": "CycloneDX",
    "specVersion": "1.5",
    "serialNumber": serial,
    "version": 1,
    "metadata": {
        "timestamp": timestamp,
        "tools": [
            {
                "vendor": "GMRI",
                "name": "generate_sbom.sh",
                "version": "2.0.0",
            }
        ],
        "authors": [
            {
                "name": "Robert \"Grizzly\" Hanson",
                "email": "me@grizzlymedicine.org",
                "phone": "(682) 371-8439",
            }
        ],
        "component": {
            "type": "application",
            "bom-ref": "jarvis:root",
            "name": "JARVIS",
            "version": git_sha_short,
            "description": "JARVIS Digital Person — Apple native runtime, Mac Cockpit, iOS/watchOS companion",
            "supplier": {"name": "Grizzly Medicine Research Institute"},
            "purl": f"pkg:generic/gmri/JARVIS@{git_sha_short}",
            "properties": [
                {"name": "jarvis:git-sha", "value": git_sha},
                {"name": "jarvis:xcode-version", "value": xcode_ver},
                {"name": "jarvis:sdk-version", "value": sdk_ver},
                {"name": "jarvis:swift-version", "value": swift_ver},
                {"name": "jarvis:build-host", "value": "macOS"},
                {"name": "jarvis:sbom-generator-version", "value": "2.0.0"},
                {"name": "jarvis:voice-weight-count", "value": str(len(voice_components))},
                {"name": "jarvis:third-party-count", "value": str(len(third_party_components))},
            ],
        },
        "externalReferences": fetch_content_refs,
    },
    "components": all_components,
    "dependencies": [
        {
            "ref": "jarvis:root",
            "dependsOn": sorted([c["bom-ref"] for c in all_components]),
        },
        {
            "ref": "jarvis:JARVISNativeRuntime",
            "dependsOn": [
                f"apple:libc++@{sdk_ver}",
                f"apple:CommonCrypto@{sdk_ver}",
            ],
        },
        {
            "ref": "jarvis:JARVISCompanionCore",
            "dependsOn": [
                f"apple:SwiftStdlib@{swift_ver}",
                f"apple:AVFoundation@{sdk_ver}",
            ],
        },
        {
            "ref": "jarvis:JARVISCompanionUI",
            "dependsOn": [
                "jarvis:JARVISCompanionCore",
                f"apple:SwiftUI@{sdk_ver}",
                f"apple:SwiftStdlib@{swift_ver}",
            ],
        },
    ],
}

with open(sbom_path, "w") as f:
    json.dump(sbom, f, indent=2)
    f.write("\n")

print(f"  Written: {sbom_path}")
print(f"  Total components: {len(all_components)}")
print(f"    First-party:        {len(first_party)}")
print(f"    Apple system:       {len(system_components)}")
print(f"    SwiftPM external:   {len(swift_external)}")
print(f"    Voice weights:      {len(voice_components)}")
print(f"    Third-party libs:   {len(third_party_components)}")
PYEOF

# ---------------------------------------------------------------------------
# Generate / update voice-weights-baseline.json
# ---------------------------------------------------------------------------
# This file is the operator-authorized hash baseline.  Updating it is a
# deliberate operator action (see TRIPWIRE section above).  On first run it is
# created from the current hashes with source "operator-authorized initial
# baseline".  On subsequent runs it is NOT overwritten automatically — only new
# files not yet in the baseline are appended.  Existing entries are preserved
# so a changed hash shows up as a drift, not silently updated.
echo ""
echo "📋 Updating voice-weights-baseline.json..."

BASELINE_JSON="${SBOM_DIR}/voice-weights-baseline.json"
VOICE_COMPONENTS_JSON="${VOICE_COMPONENTS_JSON}" \
BASELINE_PATH="${BASELINE_JSON}" \
TIMESTAMP="${TIMESTAMP}" \
python3 - <<'PYEOF'
import json, os, sys

voice_raw     = os.environ["VOICE_COMPONENTS_JSON"]
baseline_path = os.environ["BASELINE_PATH"]
timestamp     = os.environ["TIMESTAMP"]

try:
    voice_components = json.loads(voice_raw) if voice_raw.strip() not in ["", "[]"] else []
except Exception:
    voice_components = []

# Build index of current voice-weight hashes from SBOM voice components.
# Skip mlpackage rollup entries (they duplicate member file hashes).
current_hashes = {}
for c in voice_components:
    props = {p["name"]: p["value"] for p in c.get("properties", [])}
    if props.get("jarvis:category") not in ("voice-weight", "reference-asset"):
        continue
    # Skip rollup entries — they have jarvis:mlpackage-files property
    if "jarvis:mlpackage-files" in props:
        continue
    name = c.get("name", "")
    for h in c.get("hashes", []):
        if h["alg"] == "SHA-256":
            current_hashes[name] = h["content"]

# Load existing baseline if present
if os.path.isfile(baseline_path):
    with open(baseline_path) as f:
        baseline = json.load(f)
else:
    baseline = {
        "_comment": "Voice weight integrity baseline. Operator updates this file deliberately to authorize a voice change. An unexpected hash drift without a corresponding entry update = tamper signal.",
        "entries": []
    }

existing_paths = {e["path"] for e in baseline.get("entries", [])}
new_entries = 0
for path, sha256 in sorted(current_hashes.items()):
    if path not in existing_paths:
        baseline.setdefault("entries", []).append({
            "path": path,
            "sha256": sha256,
            "timestamp": timestamp,
            "source": "operator-authorized initial baseline",
        })
        new_entries += 1

with open(baseline_path, "w") as f:
    json.dump(baseline, f, indent=2)
    f.write("\n")

total = len(baseline.get("entries", []))
print(f"  Baseline entries: {total} total ({new_entries} new)")
print(f"  Written: {baseline_path}")
PYEOF

# ---------------------------------------------------------------------------
# Integrity tripwire — diff new SBOM voice hashes against baseline
# ---------------------------------------------------------------------------
# Any voice-weight hash in the new SBOM that differs from the baseline entry
# is a tamper signal.  The operator MUST update voice-weights-baseline.json
# manually to authorize the change before the warning clears.
echo ""
echo "🔒 Integrity tripwire check..."

BASELINE_PATH="${BASELINE_JSON}" \
VOICE_COMPONENTS_JSON="${VOICE_COMPONENTS_JSON}" \
python3 - <<'PYEOF'
import json, os, sys

baseline_path = os.environ["BASELINE_PATH"]
voice_raw     = os.environ["VOICE_COMPONENTS_JSON"]

if not os.path.isfile(baseline_path):
    print("  ⚠️  No baseline found — skipping tripwire (run again after baseline is created)")
    sys.exit(0)

try:
    voice_components = json.loads(voice_raw) if voice_raw.strip() not in ["", "[]"] else []
except Exception:
    voice_components = []

with open(baseline_path) as f:
    baseline = json.load(f)

baseline_index = {e["path"]: e["sha256"] for e in baseline.get("entries", [])}

current_hashes = {}
for c in voice_components:
    props = {p["name"]: p["value"] for p in c.get("properties", [])}
    if props.get("jarvis:category") not in ("voice-weight", "reference-asset"):
        continue
    if "jarvis:mlpackage-files" in props:
        continue
    name = c.get("name", "")
    for h in c.get("hashes", []):
        if h["alg"] == "SHA-256":
            current_hashes[name] = h["content"]

tamper_detected = False
for path, current_hash in sorted(current_hashes.items()):
    baseline_hash = baseline_index.get(path)
    if baseline_hash is None:
        # New file not in baseline yet — not a tamper, baseline was just updated above
        continue
    if current_hash != baseline_hash:
        print("")
        print(f"  ⚠️  WARNING: voice weight hash changed since last SBOM baseline.")
        print(f"     File:      {path}")
        print(f"     Baseline:  {baseline_hash}")
        print(f"     Current:   {current_hash}")
        print(f"     Verify this was an authorized voice update.")
        tamper_detected = True

if tamper_detected:
    print("")
    print("  ACTION REQUIRED: If this was an authorized update:")
    print("    (a) Verify the new file is from an authorized source")
    print("    (b) Update apple_native/sbom/voice-weights-baseline.json")
    print("        — add new hash + timestamp + reason, remove old entry")
    print("    (c) Re-run generate_sbom.sh to confirm clean tripwire")
    print("    (d) Commit baseline + SBOM together")
    sys.exit(2)  # Non-zero exit so CI can catch tamper events
else:
    matched = len(set(current_hashes.keys()) & set(baseline_index.keys()))
    print(f"  ✅ All {matched} voice weight hashes match baseline — no tampering detected")
PYEOF

# Capture tripwire exit code but don't abort the script — we always want
# the full SBOM written even if a tamper warning fires.
TRIPWIRE_EXIT=$?

# ---------------------------------------------------------------------------
# Generate human-readable Markdown summary
# ---------------------------------------------------------------------------
echo ""
echo "✍️  Writing ${SBOM_MD}"

SBOM_JSON="${SBOM_JSON}" SBOM_MD="${SBOM_MD}" \
GIT_SHA="${GIT_SHA}" TIMESTAMP="${TIMESTAMP}" \
XCODE_VERSION="${XCODE_VERSION}" SDK_VERSION="${SDK_VERSION}" SWIFT_VERSION="${SWIFT_VERSION}" \
python3 - <<'PYEOF'
import json, os

sbom_path = os.environ['SBOM_JSON']
md_path   = os.environ['SBOM_MD']
git_sha   = os.environ['GIT_SHA']
timestamp = os.environ['TIMESTAMP']
xcode_ver = os.environ['XCODE_VERSION']
sdk_ver   = os.environ['SDK_VERSION']
swift_ver = os.environ['SWIFT_VERSION']

bt = "`"  # backtick — avoids shell interpretation

with open(sbom_path) as f:
    sbom = json.load(f)

total = len(sbom["components"])
voice_count = sum(
    1 for c in sbom["components"]
    if any(p["name"] == "jarvis:category" and p["value"] in ("voice-weight", "reference-asset")
           for p in c.get("properties", []))
)
third_party_count = sum(
    1 for c in sbom["components"]
    if any(p["name"] == "jarvis:category" and p["value"] == "third-party-lib"
           for p in c.get("properties", []))
)

lines = [
    "# JARVIS SBOM — Software Bill of Materials",
    "",
    f"**Generated:** {timestamp}  ",
    f"**Git SHA:** {bt}{git_sha}{bt}  ",
    f"**Serial:** {bt}{sbom['serialNumber']}{bt}  ",
    f"**Format:** CycloneDX 1.5 JSON  ",
    f"**Generator version:** 2.0.0  ",
    f"**Xcode:** {xcode_ver}  ",
    f"**macOS SDK:** {sdk_ver}  ",
    f"**Swift:** {swift_ver}  ",
    "",
    "---",
    "",
    "## Summary",
    "",
    f"| Category | Count |",
    f"|----------|-------|",
    f"| Total components | {total} |",
    f"| Voice weights & reference assets | {voice_count} |",
    f"| Third-party vendored libs | {third_party_count} |",
    "",
    "---",
    "",
    "## Components",
    "",
    "| BOM-Ref | Name | Version | Type | SHA-256 (first 16) | Category |",
    "|---------|------|---------|------|--------------------|----------|",
]

for c in sbom["components"]:
    name     = c.get("name", "")
    version  = c.get("version", "")
    ctype    = c.get("type", "")
    ref      = c.get("bom-ref", "")
    hashes   = c.get("hashes", [])
    sha256   = next((h["content"][:16] + "…" for h in hashes if h["alg"] == "SHA-256"), "—")
    props    = {p["name"]: p["value"] for p in c.get("properties", [])}
    category = props.get("jarvis:category", "—")
    lines.append(f"| {bt}{ref}{bt} | {name} | {version} | {ctype} | {bt}{sha256}{bt} | {category} |")

lines += [
    "",
    "---",
    "",
    "## Integrity Tripwire",
    "",
    "Voice weight hashes are tracked in `apple_native/sbom/voice-weights-baseline.json`.",
    "Running `generate_sbom.sh` compares all voice-weight SHA-256s against this baseline.",
    "Any change without a corresponding baseline update triggers:",
    "",
    "```",
    "⚠️  WARNING: voice weight hash changed since last SBOM baseline.",
    "```",
    "",
    "**Operator workflow for an authorized voice update:**",
    "1. Commit the new voice file(s)",
    "2. `bash apple_native/tools/generate_sbom.sh`",
    "3. Edit `voice-weights-baseline.json` — update hash + timestamp + reason",
    "4. Re-run `generate_sbom.sh` to confirm clean tripwire",
    "5. Commit baseline + SBOM together",
    "",
    "---",
    "",
    "## Notes",
    "",
    "- **Voice weights** (`voice/tts/onnx/`, `voice/tts/coreml/`) are hashed individually.",
    "  CoreML `.mlpackage` directories have per-member-file entries plus a package-level rollup.",
    "- **`_local_voice/`** is the canonical voice identity — tampering here is an identity violation.",
    "- **No vendored third-party C++ libraries currently present.** The runtime uses only",
    "  Apple SDK system frameworks (libc++, CommonCrypto).",
    "- **Fetched-at-build-time deps** (Catch2 via CMake FetchContent, onnxruntime if downloaded)",
    "  are documented in SBOM `externalReferences` metadata. Not hashed (not in repo).",
    "- **Idempotency:** set `SOURCE_DATE_EPOCH=$(git log -1 --format=%ct)` for reproducible output.",
    f"- Regenerate: {bt}bash apple_native/tools/generate_sbom.sh{bt}",
]

with open(md_path, "w") as f:
    f.write("\n".join(lines) + "\n")

print(f"  Written: {md_path}")
PYEOF

echo ""
echo "✅ SBOM generation complete."
echo "   JSON:     ${SBOM_JSON}"
echo "   MD:       ${SBOM_MD}"
echo "   Baseline: ${SBOM_DIR}/voice-weights-baseline.json"
if [[ "${TRIPWIRE_EXIT}" -ne 0 ]]; then
    echo ""
    echo "⚠️  TRIPWIRE FIRED — see warnings above. Voice weight hash mismatch detected."
    exit "${TRIPWIRE_EXIT}"
fi
