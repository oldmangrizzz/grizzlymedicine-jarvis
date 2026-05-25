# JARVIS voice integrity gate — configure-time medical-safety invariant.

function(jarvis_configure_voice_integrity target_name tts_source_dir tts_binary_dir)
    if(NOT DEFINED JARVIS_RESEARCH_ROOT)
        set(JARVIS_RESEARCH_ROOT "/Users/rbhanson/research/jarvis" CACHE PATH "JARVIS repository root")
    endif()
    if(NOT DEFINED VOICE_STATE_PATH)
        set(VOICE_STATE_PATH "/Users/rbhanson/research/jarvis/_local_voice/jarvis_voice_state.safetensors" CACHE FILEPATH "Canonical JARVIS voice state safetensors")
    endif()
    if(NOT DEFINED VOICE_WEIGHTS_BASELINE_JSON)
        set(VOICE_WEIGHTS_BASELINE_JSON "/Users/rbhanson/research/jarvis/apple_native/sbom/voice-weights-baseline.json" CACHE FILEPATH "Voice weight baseline SBOM")
    endif()
    option(ALLOW_VOICE_CHANGE "Operator-attested voice baseline rotation is in progress" OFF)

    if(NOT EXISTS "${VOICE_STATE_PATH}")
        message(FATAL_ERROR "Canonical voice state file not found: ${VOICE_STATE_PATH}")
    endif()
    if(NOT EXISTS "${VOICE_WEIGHTS_BASELINE_JSON}")
        message(FATAL_ERROR "Voice baseline SBOM not found: ${VOICE_WEIGHTS_BASELINE_JSON}")
    endif()

    execute_process(
        COMMAND "${CMAKE_COMMAND}" -E sha256sum "${VOICE_STATE_PATH}"
        RESULT_VARIABLE JARVIS_VOICE_HASH_RESULT
        OUTPUT_VARIABLE JARVIS_VOICE_HASH_OUTPUT
        ERROR_VARIABLE JARVIS_VOICE_HASH_ERROR
        OUTPUT_STRIP_TRAILING_WHITESPACE)
    if(NOT JARVIS_VOICE_HASH_RESULT EQUAL 0)
        message(FATAL_ERROR "Unable to hash canonical voice weights: ${JARVIS_VOICE_HASH_ERROR}")
    endif()
    string(REGEX MATCH "^[0-9a-fA-F]+" JARVIS_CONFIGURED_VOICE_SHA256 "${JARVIS_VOICE_HASH_OUTPUT}")
    string(TOLOWER "${JARVIS_CONFIGURED_VOICE_SHA256}" JARVIS_CONFIGURED_VOICE_SHA256)

    file(READ "${VOICE_WEIGHTS_BASELINE_JSON}" JARVIS_VOICE_BASELINE_CONTENT)
    find_program(JARVIS_PYTHON3 python3 REQUIRED)
    execute_process(
        COMMAND "${JARVIS_PYTHON3}" -c "import json,sys; data=json.load(open(sys.argv[1])); print(next(e['sha256'] for e in data['entries'] if e.get('path') == '_local_voice/jarvis_voice_state.safetensors'))" "${VOICE_WEIGHTS_BASELINE_JSON}"
        RESULT_VARIABLE JARVIS_BASELINE_HASH_RESULT
        OUTPUT_VARIABLE JARVIS_BASELINE_VOICE_SHA256
        ERROR_VARIABLE JARVIS_BASELINE_HASH_ERROR
        OUTPUT_STRIP_TRAILING_WHITESPACE)
    if(NOT JARVIS_BASELINE_HASH_RESULT EQUAL 0)
        message(FATAL_ERROR "Canonical safetensors baseline hash not found in ${VOICE_WEIGHTS_BASELINE_JSON}: ${JARVIS_BASELINE_HASH_ERROR}")
    endif()
    string(TOLOWER "${JARVIS_BASELINE_VOICE_SHA256}" JARVIS_BASELINE_VOICE_SHA256)

    if(NOT JARVIS_CONFIGURED_VOICE_SHA256 STREQUAL JARVIS_BASELINE_VOICE_SHA256)
        if(NOT ALLOW_VOICE_CHANGE)
            message(FATAL_ERROR "Voice weights changed without operator authorization. JARVIS cannot ship with the wrong voice. To rotate the voice intentionally, run apple_native/tools/rotate_voice.sh (operator-attestation gated).")
        endif()
        message(WARNING "Voice weights changed with ALLOW_VOICE_CHANGE set; OPERATOR_AUTHORIZED_VOICE_CHANGE marker will be embedded. configured_sha256=${JARVIS_CONFIGURED_VOICE_SHA256}")
        set(JARVIS_VOICE_BUILD_MARKER "OPERATOR_AUTHORIZED_VOICE_CHANGE")
    else()
        set(JARVIS_VOICE_BUILD_MARKER "BASELINE_VOICE_MATCH")
    endif()

    set(JARVIS_VOICE_GENERATED_DIR "${tts_binary_dir}/generated")
    file(MAKE_DIRECTORY "${JARVIS_VOICE_GENERATED_DIR}")
    configure_file(
        "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/voice_integrity_build_marker.h.in"
        "${JARVIS_VOICE_GENERATED_DIR}/voice_integrity_build_marker.h"
        @ONLY)

    set(JARVIS_VOICE_BASELINE_HEADER "${JARVIS_VOICE_GENERATED_DIR}/voice_integrity_baseline.h")
    file(WRITE "${JARVIS_VOICE_BASELINE_HEADER}" "#pragma once\n#include <string_view>\nnamespace jarvis::tts::onnx::voice_integrity::generated {\ninline constexpr std::string_view kBaselineSbomJson = R\"JARVIS_BASELINE(\n")
    file(APPEND "${JARVIS_VOICE_BASELINE_HEADER}" "${JARVIS_VOICE_BASELINE_CONTENT}")
    file(APPEND "${JARVIS_VOICE_BASELINE_HEADER}" "\n)JARVIS_BASELINE\";\n}\n")

    target_include_directories(${target_name} PRIVATE "${JARVIS_VOICE_GENERATED_DIR}")
    target_compile_definitions(${target_name} PRIVATE
        JARVIS_CANONICAL_VOICE_STATE_PATH="${VOICE_STATE_PATH}"
        JARVIS_VOICE_BASELINE_JSON_PATH="${VOICE_WEIGHTS_BASELINE_JSON}")
endfunction()
