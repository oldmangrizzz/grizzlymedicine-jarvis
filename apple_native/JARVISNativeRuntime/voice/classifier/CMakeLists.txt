cmake_minimum_required(VERSION 3.20)
project(jarvis_audio_classifier VERSION 0.1.0 LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Objective-C++ standard must match
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

# macOS 26 (Tahoe) beta: the SDK headers use a new libc++ ABI (nqe210106)
# that the shipped system dylib doesn't export yet.  The polyfills static
# library backfills those symbols so our executables link correctly.
if(APPLE)
    set(_POLYFILLS_15
        "${CMAKE_OSX_SYSROOT}/usr/lib/libc++polyfills.a")
    if(NOT CMAKE_OSX_SYSROOT)
        execute_process(
            COMMAND xcrun --show-sdk-path
            OUTPUT_VARIABLE CMAKE_OSX_SYSROOT
            OUTPUT_STRIP_TRAILING_WHITESPACE)
    endif()
    set(_POLYFILLS "${CMAKE_OSX_SYSROOT}/usr/lib/libc++polyfills.a")
    if(EXISTS "${_POLYFILLS}")
        set(JARVIS_LIBC_POLYFILLS "${_POLYFILLS}")
        message(STATUS "libc++ polyfills: ${JARVIS_LIBC_POLYFILLS}")
    endif()
endif()

# ── Logging dependency ────────────────────────────────────────────────────────
# Pull in the redacting_logger from the parent runtime tree.
# Guard against double-add when built as a subdirectory of JARVISNativeRuntime.
# Override Debug TSan flag — we don't need TSAN in the classifier build.
set(JARVIS_TSAN OFF CACHE BOOL "Enable ThreadSanitizer on logging library" FORCE)

if(NOT TARGET jarvis_redacting_logger)
    add_subdirectory(
        ${CMAKE_CURRENT_SOURCE_DIR}/../../logging
        ${CMAKE_CURRENT_BINARY_DIR}/logging
        EXCLUDE_FROM_ALL
    )
endif()

# ── Classifier static library ─────────────────────────────────────────────────
add_library(jarvis_audio_classifier STATIC
    scene_classifier.cpp
    feature_extractor.cpp
    model_runtime.mm        # Objective-C++ — CoreML bridge
)

target_include_directories(jarvis_audio_classifier
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
)

target_compile_features(jarvis_audio_classifier PUBLIC cxx_std_20)

target_compile_options(jarvis_audio_classifier PRIVATE
    -Wall
    -Wextra
    -Wpedantic
    -Wno-unused-parameter
    $<$<CONFIG:Release>:-O3>
    $<$<CONFIG:Debug>:-g -O0>
)

target_link_libraries(jarvis_audio_classifier
    PUBLIC
        jarvis_redacting_logger
    PRIVATE
        "-framework Accelerate"
        "-framework CoreML"
        "-framework Foundation"
)

# ── Catch2 (v3) ───────────────────────────────────────────────────────────────
include(FetchContent)
# SHA-pinned 2026-05-24; Catch2 v3.5.4 → b5373dadca40b7edc8570cf9470b9b1cb1934d40
FetchContent_Declare(
    Catch2
    URL      https://github.com/catchorg/Catch2/archive/b5373dadca40b7edc8570cf9470b9b1cb1934d40.tar.gz
    URL_HASH SHA256=97afc182353da6f3a54afede6540f54f545ee6c2f73023a64688d2a9307e850c
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
FetchContent_MakeAvailable(Catch2)
list(APPEND CMAKE_MODULE_PATH ${catch2_SOURCE_DIR}/extras)
include(CTest)
include(Catch)

# ── Tests ─────────────────────────────────────────────────────────────────────
foreach(test_name test_classifier test_latency)
    add_executable(${test_name} tests/${test_name}.cpp)

    target_link_libraries(${test_name}
        PRIVATE
            jarvis_audio_classifier
            Catch2::Catch2WithMain
            $<$<BOOL:${JARVIS_LIBC_POLYFILLS}>:${JARVIS_LIBC_POLYFILLS}>
    )
    target_compile_features(${test_name} PRIVATE cxx_std_20)

    # Paths injected at compile time so tests are hermetic
    target_compile_definitions(${test_name} PRIVATE
        ORACLE_WAV_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../../../../oracle/voice/wav"
        FIXTURES_DIR="${CMAKE_CURRENT_BINARY_DIR}/fixtures"
        TEST_MODEL_PATH=""   # set to .mlpackage path if a trained model is available
    )

    catch_discover_tests(${test_name})
endforeach()

# Suppress the logging library's own tests from appearing in our CTest run.
# They are registered when logging/ is added as a subdirectory but the binary
# is excluded from the build (EXCLUDE_FROM_ALL).
# CTestCustom.cmake is read automatically by ctest before running tests.
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/CTestCustom.cmake"
    "set(CTEST_CUSTOM_TESTS_IGNORE jarvis_logger_tests)\n"
)

# ── Generate synthetic test fixtures at configure time ────────────────────────
find_program(PYTHON3 python3)
if(PYTHON3)
    file(MAKE_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/fixtures)
    execute_process(
        COMMAND ${PYTHON3}
            ${CMAKE_CURRENT_SOURCE_DIR}/tools/generate_test_fixtures.py
            --out-dir ${CMAKE_CURRENT_BINARY_DIR}/fixtures
        RESULT_VARIABLE _fix_rc
        OUTPUT_VARIABLE _fix_out
        ERROR_VARIABLE  _fix_err
    )
    if(NOT _fix_rc EQUAL 0)
        message(WARNING "generate_test_fixtures.py failed: ${_fix_err}")
    else()
        message(STATUS "Audio test fixtures: ${_fix_out}")
    endif()
else()
    message(WARNING "python3 not found — synthetic test fixtures not generated")
endif()
