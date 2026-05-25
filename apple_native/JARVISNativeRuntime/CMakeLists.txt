cmake_minimum_required(VERSION 3.20)
project(JARVISNativeRuntime LANGUAGES CXX)

include(CTest)
include(CheckCXXCompilerFlag)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ---------------------------------------------------------------------------
# Release hardening flags (Release / RelWithDebInfo builds only).
# Each flag is gated on a compiler-support check so the build does not break
# on compilers that reject it.  macOS Clang accepts all four; document any
# rejection in a comment but do not include broken flags.
# ---------------------------------------------------------------------------
if(CMAKE_BUILD_TYPE MATCHES "^(Release|RelWithDebInfo)$")

    check_cxx_compiler_flag(-fstack-protector-strong COMPILER_SUPPORTS_STACK_PROTECTOR_STRONG)
    if(COMPILER_SUPPORTS_STACK_PROTECTOR_STRONG)
        add_compile_options(-fstack-protector-strong)
    endif()

    # _FORTIFY_SOURCE=2 requires -O1 or higher to take effect; Release has -O3.
    # Passed as a preprocessor define, not a -D flag, so check_cxx_compiler_flag
    # is not applicable — accepted by all GCC/Clang targets.
    add_compile_definitions(_FORTIFY_SOURCE=2)

    check_cxx_compiler_flag(-fPIE COMPILER_SUPPORTS_FPIE)
    if(COMPILER_SUPPORTS_FPIE)
        add_compile_options(-fPIE)
        # -pie is a linker flag; apply to all link steps in this build tree.
        add_link_options(-pie)
    endif()

    check_cxx_compiler_flag(-fno-omit-frame-pointer COMPILER_SUPPORTS_NO_OMIT_FP)
    if(COMPILER_SUPPORTS_NO_OMIT_FP)
        add_compile_options(-fno-omit-frame-pointer)
    endif()

endif()
# ---------------------------------------------------------------------------

add_subdirectory(endocrine)
add_subdirectory(pheromind)
add_subdirectory(swarm)
add_subdirectory(hdc)

# Phase 7: cross-cutting abstention-under-uncertainty invariant.
add_subdirectory(identity/abstention)

if(IS_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/monitoring/cusum)
    add_subdirectory(monitoring/cusum)
endif()

# Logging (jarvis_redacting_logger) must be defined before voice/egress consumers.
if(IS_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/logging)
    add_subdirectory(logging)
endif()

add_subdirectory(voice/classifier)
add_subdirectory(voice)
add_subdirectory(integrity)
if(NOT TARGET jarvis_identity_distress)
    add_subdirectory(identity/distress)
endif()
add_subdirectory(identity/character_values)
add_subdirectory(identity/operator_attestation)
add_subdirectory(identity/continuity)
add_subdirectory(identity/coercion_refusal)

# Phase 7 graceful degradation under load/attack, preserving cognition organs.
if(IS_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/resilience/degradation)
    add_subdirectory(resilience/degradation)
endif()

# JARVIS proprioceptive self-health loop: read-only internal organ-state sense.
if(IS_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/identity/self_health)
    add_subdirectory(identity/self_health)
endif()

# Phase 7 regression-against-oracle tests — requires organ targets first.
if(IS_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/tests/regression)
    add_subdirectory(tests/regression)
endif()

# Phase 7 property-based tests.
if(IS_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/tests/property)
    option(JARVIS_ENABLE_PROPERTY_TESTS "Build property-based tests (requires network for rapidcheck)" ON)
    if(JARVIS_ENABLE_PROPERTY_TESTS)
        add_subdirectory(tests/property)
    endif()
endif()

# Fuzz harnesses — gated on JARVIS_ENABLE_FUZZING=ON inside the subdirectory;
# safe to always include (returns immediately when fuzzing is off).
if(IS_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/tests/fuzz)
    add_subdirectory(tests/fuzz)
endif()

# Phase 7: egress allowlist + per-endpoint filter + tamper-evident audit.
add_subdirectory(security/egress)

# OAuth public-client + PKCE token handling for external model heads/tools.
if(IS_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/auth/oauth)
    add_subdirectory(auth/oauth)
endif()

# Native Deepgram streaming STT client for the audio runtime.
if(IS_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/audio/stt_deepgram)
    add_subdirectory(audio/stt_deepgram)
endif()

# Phase 7 adversarial voice-deepfake suite for speaker/liveness gating.
if(IS_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/tests/adversarial/voice_deepfake)
    add_subdirectory(tests/adversarial/voice_deepfake)
endif()

# Native Convex backend worker (C++ replacement for _baseline/convex_backend.py).
add_subdirectory(storage/convex)

# Phase 7: Convex-hostile nation-state adversarial suite.
if(IS_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/tests/adversarial/convex_hostile)
    add_subdirectory(tests/adversarial/convex_hostile)
endif()

# Phase 7: memory-extraction resistance suite.
if(IS_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/tests/adversarial/memory_extraction)
    add_subdirectory(tests/adversarial/memory_extraction)
endif()

# Phase 7: Nation-state prompt-injection adversarial corpus.
if(IS_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/tests/adversarial/prompt_injection)
    add_subdirectory(tests/adversarial/prompt_injection)
endif()

# Phase 7: side-channel timing/cache audit for security-sensitive native paths.
if(IS_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/tests/adversarial/side_channel)
    add_subdirectory(tests/adversarial/side_channel)
endif()

# Phase 7: identity-spoofing adversarial suite.
if(IS_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/tests/adversarial/identity_spoof)
    add_subdirectory(tests/adversarial/identity_spoof)
endif()

# FINAL GATE: coordinated multi-adversary red-team exercise.
if(IS_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/tests/adversarial/coordinated)
    add_subdirectory(tests/adversarial/coordinated)
endif()

# Phase 7: soak + bodily-integrity fault-injection harness.
if(IS_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/tests/soak)
    add_subdirectory(tests/soak)
endif()
