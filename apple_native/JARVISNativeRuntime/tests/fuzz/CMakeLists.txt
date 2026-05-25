# tests/fuzz/CMakeLists.txt — JARVIS Fuzz Harness Build Configuration
#
# Gated on -DJARVIS_ENABLE_FUZZING=ON.
# Requires Clang (libFuzzer is Clang-specific; AFL++ uses afl-clang-fast++).
#
# Quick start (libFuzzer):
#   cmake -B build_fuzz \
#         -DJARVIS_ENABLE_FUZZING=ON \
#         -DJARVIS_FUZZ_BACKEND=libfuzzer \
#         -DCMAKE_CXX_COMPILER=clang++ \
#         -DCMAKE_BUILD_TYPE=Release \
#         /path/to/JARVISNativeRuntime
#   cmake --build build_fuzz
#   ctest --test-dir build_fuzz -R fuzz_smoke -V
#
# Quick start (AFL++):
#   cmake -B build_afl \
#         -DJARVIS_ENABLE_FUZZING=ON \
#         -DJARVIS_FUZZ_BACKEND=afl \
#         -DCMAKE_CXX_COMPILER=afl-clang-fast++ \
#         -DCMAKE_BUILD_TYPE=Release \
#         /path/to/JARVISNativeRuntime
#
# See README.md for 24h nightly run instructions and AFL++ parallel mode.

cmake_minimum_required(VERSION 3.20)

# ── Gate: only proceed when fuzzing is explicitly enabled ─────────────────────

if(NOT JARVIS_ENABLE_FUZZING)
    message(STATUS "[jarvis-fuzz] JARVIS_ENABLE_FUZZING is OFF — skipping fuzz targets")
    return()
endif()

# ── Require Clang ─────────────────────────────────────────────────────────────

if(NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang")
    message(FATAL_ERROR
        "[jarvis-fuzz] Fuzzing requires Clang "
        "(detected: ${CMAKE_CXX_COMPILER_ID}). "
        "Set -DCMAKE_CXX_COMPILER=clang++ (libFuzzer) "
        "or -DCMAKE_CXX_COMPILER=afl-clang-fast++ (AFL++).")
endif()

message(STATUS "[jarvis-fuzz] Fuzzing ENABLED (compiler: ${CMAKE_CXX_COMPILER})")

# ── Fuzz backend selection ────────────────────────────────────────────────────

set(JARVIS_FUZZ_BACKEND "libfuzzer"
    CACHE STRING "Fuzzer backend: libfuzzer | afl")
set_property(CACHE JARVIS_FUZZ_BACKEND PROPERTY STRINGS "libfuzzer" "afl")

if(NOT JARVIS_FUZZ_BACKEND MATCHES "^(libfuzzer|afl)$")
    message(FATAL_ERROR
        "[jarvis-fuzz] JARVIS_FUZZ_BACKEND must be 'libfuzzer' or 'afl'; "
        "got '${JARVIS_FUZZ_BACKEND}'")
endif()

message(STATUS "[jarvis-fuzz] Backend: ${JARVIS_FUZZ_BACKEND}")

# ── MSan (optional, slower) ───────────────────────────────────────────────────

option(JARVIS_FUZZ_MSAN "Enable MemorySanitizer (MSan) in fuzz builds (slower)" OFF)

# ── Compiler / sanitizer flags ────────────────────────────────────────────────

# Base flags common to all fuzz targets.
set(JARVIS_FUZZ_COMPILE_FLAGS
    -fno-omit-frame-pointer
    -g
    -O1                          # enough for meaningful coverage; -O2 hides bugs
    -fsanitize=address,undefined
)

set(JARVIS_FUZZ_LINK_FLAGS
    -fsanitize=address,undefined
)

if(JARVIS_FUZZ_MSAN)
    # MSan is incompatible with ASan; use a separate build tree for MSan runs.
    list(APPEND JARVIS_FUZZ_COMPILE_FLAGS -fsanitize=memory -fsanitize-memory-track-origins)
    list(APPEND JARVIS_FUZZ_LINK_FLAGS   -fsanitize=memory)
    message(STATUS "[jarvis-fuzz] MSan ENABLED (incompatible with ASan — use separate build tree)")
endif()

if(JARVIS_FUZZ_BACKEND STREQUAL "libfuzzer")
    list(APPEND JARVIS_FUZZ_COMPILE_FLAGS -fsanitize=fuzzer)
    list(APPEND JARVIS_FUZZ_LINK_FLAGS   -fsanitize=fuzzer)
    set(JARVIS_FUZZ_AFL_DEFINE "")
else()
    # AFL++: instrumentation is injected by afl-clang-fast++ wrapper.
    # We still link ASan/UBSan; AFL++ sets AFL_USE_ASAN=1 at fuzz time.
    set(JARVIS_FUZZ_AFL_DEFINE "JARVIS_FUZZ_AFL")
    message(STATUS "[jarvis-fuzz] AFL++ mode — ensure AFL_USE_ASAN=1 is set at runtime")
endif()

# ── LSAN: leak detection ──────────────────────────────────────────────────────
# LSAN is part of ASan on Linux; on macOS it requires ASAN_OPTIONS.
# The fuzz-smoke.yml CI job sets ASAN_OPTIONS=detect_leaks=1 on Linux.
# On macOS, LSAN is not fully supported; the harness still runs cleanly.

# ── Dependency resolution ─────────────────────────────────────────────────────
# The fuzz CMakeLists is included from the parent JARVISNativeRuntime/CMakeLists.txt
# (via add_subdirectory(tests/fuzz)).  jarvis_endocrine is therefore already
# defined.  Guard defensively in case this file is processed standalone.

if(NOT TARGET jarvis_endocrine)
    message(STATUS "[jarvis-fuzz] jarvis_endocrine not found in parent scope — adding subdirectory")
    add_subdirectory(
        ${CMAKE_CURRENT_SOURCE_DIR}/../../endocrine
        ${CMAKE_CURRENT_BINARY_DIR}/endocrine_dep
    )
endif()

# Logging is NOT linked by the active fuzz targets (endocrine + endocannabinoid
# are pure compute with no logger dependency).  Future targets that set
# JARVIS_FUZZ_HAS_LOGGER should add:
#   if(NOT TARGET jarvis_redacting_logger)
#       add_subdirectory(../../logging ...)
#   endif()
#   target_compile_definitions(<target> PRIVATE JARVIS_FUZZ_HAS_LOGGER)
#   target_link_libraries(<target> PRIVATE jarvis_redacting_logger)

# ── Include directories ───────────────────────────────────────────────────────

set(FUZZ_INCLUDE_DIRS
    ${CMAKE_CURRENT_SOURCE_DIR}                          # fuzz_common.h
    ${CMAKE_CURRENT_SOURCE_DIR}/../../endocrine          # endocrine.h, endocannabinoid.h
)

# ── Corpus directory (source tree — seeds are checked in) ────────────────────

set(JARVIS_FUZZ_CORPUS_DIR ${CMAKE_CURRENT_SOURCE_DIR}/corpus)

# ── Corpus seed generator (build-time tool, not a fuzz target) ───────────────

add_executable(gen_fuzz_seeds
    corpus_seed_generator.cpp
)
target_compile_features(gen_fuzz_seeds PRIVATE cxx_std_20)
target_compile_options(gen_fuzz_seeds PRIVATE -O2)
# No sanitizers on the generator — it runs on the build host.

# After gen_fuzz_seeds is built, run it to populate the corpus directories.
# Oracle CSV paths are resolved from the repository layout.
set(ORACLE_ENDOCRINE_CSV
    "/Users/rbhanson/research/oracle/endocrine/endocrine_trace.csv")
set(ORACLE_ENDOCANNABINOID_CSV
    "/Users/rbhanson/research/oracle/endocrine/endocannabinoid_trace.csv")

add_custom_command(
    TARGET gen_fuzz_seeds POST_BUILD
    COMMAND $<TARGET_FILE:gen_fuzz_seeds>
            ${JARVIS_FUZZ_CORPUS_DIR}/endocrine
            ${JARVIS_FUZZ_CORPUS_DIR}/endocannabinoid
            ${ORACLE_ENDOCRINE_CSV}
            ${ORACLE_ENDOCANNABINOID_CSV}
    COMMENT "[jarvis-fuzz] Seeding corpus directories from oracle traces"
    VERBATIM
)

# ── Helper: add a fuzz target ─────────────────────────────────────────────────

function(jarvis_add_fuzz_target TARGET_NAME SOURCE)
    add_executable(${TARGET_NAME} ${SOURCE})
    target_compile_features(${TARGET_NAME} PRIVATE cxx_std_20)
    target_include_directories(${TARGET_NAME} PRIVATE ${FUZZ_INCLUDE_DIRS})
    target_link_libraries(${TARGET_NAME} PRIVATE jarvis_endocrine)
    target_compile_options(${TARGET_NAME} PRIVATE ${JARVIS_FUZZ_COMPILE_FLAGS})
    target_link_options(${TARGET_NAME} PRIVATE ${JARVIS_FUZZ_LINK_FLAGS})
    if(JARVIS_FUZZ_AFL_DEFINE)
        target_compile_definitions(${TARGET_NAME} PRIVATE ${JARVIS_FUZZ_AFL_DEFINE})
    endif()
    # Ensure seeds are generated before the fuzz binary is used
    add_dependencies(${TARGET_NAME} gen_fuzz_seeds)
endfunction()

# ── Active fuzz targets ───────────────────────────────────────────────────────

jarvis_add_fuzz_target(fuzz_endocrine_replay    fuzz_endocrine_replay.cpp)
jarvis_add_fuzz_target(fuzz_endocannabinoid_replay fuzz_endocannabinoid_replay.cpp)

# ── Stub fuzz targets ─────────────────────────────────────────────────────────
# Stubs compile to catch include-path / ABI breakage early.
# They do nothing at runtime (LLVMFuzzerTestOneInput returns 0 immediately).

jarvis_add_fuzz_target(fuzz_audio_frame_parser   fuzz_audio_frame_parser.cpp)
jarvis_add_fuzz_target(fuzz_wire_protocol        fuzz_wire_protocol.cpp)
jarvis_add_fuzz_target(fuzz_convex_message       fuzz_convex_message.cpp)
jarvis_add_fuzz_target(fuzz_model_api_response   fuzz_model_api_response.cpp)
jarvis_add_fuzz_target(fuzz_sqlite_belief_blob   fuzz_sqlite_belief_blob.cpp)
jarvis_add_fuzz_target(fuzz_pheromind_deposit_seq fuzz_pheromind_deposit_seq.cpp)

# ── 60-second build-time smoke tests (CTest) ──────────────────────────────────
#
# Run with: ctest --test-dir <build_dir> -R fuzz_smoke -V
#
# These are the acceptance gate: zero crashes, zero sanitizer findings in 60s.
# libFuzzer exit code is 0 on clean completion; non-zero signals a finding.
# LSAN_OPTIONS and ASAN_OPTIONS are passed via environment properties.

enable_testing()

if(JARVIS_FUZZ_BACKEND STREQUAL "libfuzzer")

    add_test(
        NAME fuzz_endocrine_60s_smoke
        COMMAND $<TARGET_FILE:fuzz_endocrine_replay>
                -max_total_time=60
                -max_len=4096
                -timeout=5
                -print_final_stats=1
                ${JARVIS_FUZZ_CORPUS_DIR}/endocrine
        WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    )
    set_tests_properties(fuzz_endocrine_60s_smoke PROPERTIES
        TIMEOUT 120
        ENVIRONMENT "LSAN_OPTIONS=detect_leaks=1;ASAN_OPTIONS=detect_leaks=1:abort_on_error=1"
        LABELS "fuzz_smoke"
    )

    add_test(
        NAME fuzz_endocannabinoid_60s_smoke
        COMMAND $<TARGET_FILE:fuzz_endocannabinoid_replay>
                -max_total_time=60
                -max_len=4096
                -timeout=5
                -print_final_stats=1
                ${JARVIS_FUZZ_CORPUS_DIR}/endocannabinoid
        WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    )
    set_tests_properties(fuzz_endocannabinoid_60s_smoke PROPERTIES
        TIMEOUT 120
        ENVIRONMENT "LSAN_OPTIONS=detect_leaks=1;ASAN_OPTIONS=detect_leaks=1:abort_on_error=1"
        LABELS "fuzz_smoke"
    )

    # Coverage: libFuzzer writes coverage report to -artifact_prefix dir.
    # Capture via CI artifact upload (see fuzz-smoke.yml).

else()
    message(STATUS
        "[jarvis-fuzz] AFL++ backend selected — CTest smoke tests skipped. "
        "Run AFL++ manually: see README.md § AFL++ Parallel Mode.")
endif()

# ── Summary ───────────────────────────────────────────────────────────────────

message(STATUS "[jarvis-fuzz] Active targets : fuzz_endocrine_replay, fuzz_endocannabinoid_replay")
message(STATUS "[jarvis-fuzz] Stub targets   : fuzz_audio_frame_parser, fuzz_wire_protocol, "
                                               "fuzz_convex_message, fuzz_model_api_response, "
                                               "fuzz_sqlite_belief_blob, fuzz_pheromind_deposit_seq")
message(STATUS "[jarvis-fuzz] Corpus dir     : ${JARVIS_FUZZ_CORPUS_DIR}")
