#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
for san in address undefined thread; do
  build_dir="build_${san}"
  cmake -S . -B "${build_dir}" -DJARVIS_DOS_SANITIZER="${san}" -DCMAKE_BUILD_TYPE=RelWithDebInfo
  cmake --build "${build_dir}" --target dos_resilience_adversarial --parallel
  ctest --test-dir "${build_dir}" --output-on-failure
  echo "${san}: PASS"
done
