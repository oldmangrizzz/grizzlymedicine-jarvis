#!/usr/bin/env bash
# repro_build_verify.sh — R11h F-E12
#
# Builds the JARVISMacCockpit release binary twice from a clean tree and
# compares the resulting Mach-O SHA-256. Exit 0 iff the two builds are
# byte-identical, proving the compiler/linker flags in Package.swift
# (-file-compilation-dir /JARVIS, -no-clang-module-breadcrumbs,
#  -Xlinker -no_uuid, -Xlinker -reproducible) produce a deterministic
# binary that a third party can reproduce from source for the
# court-exhibit fingerprint.
#
# Usage:
#   scripts/repro_build_verify.sh
#
# Run from the JARVISMacCockpit/ package root.

set -euo pipefail

PKG_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PKG_ROOT"

BUILD_DIR=".build-repro"
OUT_A="/tmp/jarvis-repro-binA-$$"
OUT_B="/tmp/jarvis-repro-binB-$$"

cleanup() { rm -f "$OUT_A" "$OUT_B"; }
trap cleanup EXIT

echo "[F-E12] Build A (release, $BUILD_DIR)..."
rm -rf "$BUILD_DIR"
swift build -c release --build-path "$BUILD_DIR" >/dev/null
cp "$BUILD_DIR/release/JARVISMacCockpit" "$OUT_A"

echo "[F-E12] Build B (release, $BUILD_DIR — fully clean rebuild)..."
rm -rf "$BUILD_DIR"
swift build -c release --build-path "$BUILD_DIR" >/dev/null
cp "$BUILD_DIR/release/JARVISMacCockpit" "$OUT_B"

if [ ! -f "$OUT_A" ] || [ ! -f "$OUT_B" ]; then
    echo "[F-E12] FAIL: binary not produced. A=$OUT_A B=$OUT_B" >&2
    exit 1
fi

SHA_A=$(shasum -a 256 "$OUT_A" | awk '{print $1}')
SHA_B=$(shasum -a 256 "$OUT_B" | awk '{print $1}')

echo "[F-E12] Build A SHA-256: $SHA_A"
echo "[F-E12] Build B SHA-256: $SHA_B"

if [ "$SHA_A" = "$SHA_B" ]; then
    echo "[F-E12] PASS — reproducible build verified."
    exit 0
fi

echo "[F-E12] FAIL — builds are NOT byte-identical." >&2
echo "[F-E12] Size A: $(stat -f %z "$OUT_A")  Size B: $(stat -f %z "$OUT_B")" >&2
echo "[F-E12] First binary diff offset (cmp -l, head):" >&2
cmp -l "$OUT_A" "$OUT_B" 2>&1 | head -5 >&2 || true
exit 1
