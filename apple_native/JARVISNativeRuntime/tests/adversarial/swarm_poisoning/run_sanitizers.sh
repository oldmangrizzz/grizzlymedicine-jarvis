#!/usr/bin/env bash
set -euo pipefail

cmake -B build-asan-ubsan -S . -DJARVIS_SWARM_POISONING_SANITIZER=address-undefined
cmake --build build-asan-ubsan --parallel
ctest --test-dir build-asan-ubsan --output-on-failure

cmake -B build-tsan -S . -DJARVIS_SWARM_POISONING_SANITIZER=thread
cmake --build build-tsan --parallel
ctest --test-dir build-tsan --output-on-failure
