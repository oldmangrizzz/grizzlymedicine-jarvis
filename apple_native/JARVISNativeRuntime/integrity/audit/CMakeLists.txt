cmake_minimum_required(VERSION 3.20)
project(jarvis_audit VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# ── OpenSSL / CommonCrypto ────────────────────────────────────────────────────
# On Apple platforms, use CommonCrypto (ships with the OS, no external dep).
# On Linux, use OpenSSL.

find_path(SODIUM_INCLUDE_DIR sodium.h
    HINTS /opt/homebrew/opt/libsodium/include /opt/homebrew/include /usr/local/include)
find_library(SODIUM_LIBRARY sodium
    HINTS /opt/homebrew/opt/libsodium/lib /opt/homebrew/lib /usr/local/lib)
if(NOT SODIUM_INCLUDE_DIR OR NOT SODIUM_LIBRARY)
    message(FATAL_ERROR "libsodium is required for locked audit HMAC key memory")
endif()

set(RUNTIME_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../..)

if(APPLE)
    # CommonCrypto is part of the Security framework; no find_package needed.
    set(AUDIT_CRYPTO_LIBS "")
    set(AUDIT_CRYPTO_DEFS "")
else()
    find_package(OpenSSL REQUIRED)
    set(AUDIT_CRYPTO_LIBS OpenSSL::Crypto)
    set(AUDIT_CRYPTO_DEFS "")
endif()

# ── Static library: jarvis_audit ─────────────────────────────────────────────

add_library(jarvis_audit STATIC
    audit_log.cpp
    audit_verify.cpp
    trust_envelope.cpp
    ${RUNTIME_ROOT}/security/memory_security.cpp
)

target_include_directories(jarvis_audit PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
    $<BUILD_INTERFACE:${RUNTIME_ROOT}/security>
    $<BUILD_INTERFACE:${SODIUM_INCLUDE_DIR}>
    $<INSTALL_INTERFACE:include>
)

target_link_libraries(jarvis_audit PUBLIC ${AUDIT_CRYPTO_LIBS} ${SODIUM_LIBRARY})
target_compile_definitions(jarvis_audit PRIVATE ${AUDIT_CRYPTO_DEFS})

# ── CLI binary: jarvis-audit-verify ──────────────────────────────────────────
# audit_verify.cpp doubles as the CLI entry point when compiled with
# -DJARVIS_AUDIT_VERIFY_MAIN.

add_executable(jarvis-audit-verify
    audit_verify.cpp
    audit_log.cpp
    trust_envelope.cpp
    ${RUNTIME_ROOT}/security/memory_security.cpp
)

target_include_directories(jarvis-audit-verify PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${RUNTIME_ROOT}/security
    ${SODIUM_INCLUDE_DIR}
)

target_compile_definitions(jarvis-audit-verify PRIVATE JARVIS_AUDIT_VERIFY_MAIN)
target_link_libraries(jarvis-audit-verify PRIVATE ${AUDIT_CRYPTO_LIBS} ${SODIUM_LIBRARY})

# ── Catch2 via FetchContent ───────────────────────────────────────────────────

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

# ── Test artifact directory ───────────────────────────────────────────────────
# Tests write here — never to ~/.jarvis.
set(AUDIT_TEST_ARTIFACT_DIR "${CMAKE_CURRENT_BINARY_DIR}/test_artifacts")
file(MAKE_DIRECTORY "${AUDIT_TEST_ARTIFACT_DIR}")

# ── Test executables ──────────────────────────────────────────────────────────

foreach(test_name
    test_audit_log
    test_audit_log_no_key_fail_closed
    test_tamper_detection
)
    add_executable(${test_name} tests/${test_name}.cpp)
    target_link_libraries(${test_name}
        PRIVATE jarvis_audit Catch2::Catch2WithMain
    )
    target_compile_definitions(${test_name} PRIVATE
        TEST_ARTIFACT_DIR="${AUDIT_TEST_ARTIFACT_DIR}"
    )
    catch_discover_tests(${test_name})
endforeach()
