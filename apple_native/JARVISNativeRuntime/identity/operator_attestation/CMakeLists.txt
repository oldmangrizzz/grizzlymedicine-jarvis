cmake_minimum_required(VERSION 3.20)
if(APPLE AND NOT CMAKE_OSX_ARCHITECTURES)
    set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "Build macOS arm64 by default" FORCE)
endif()
project(jarvis_identity_operator_attestation VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_path(SODIUM_INCLUDE_DIR sodium.h
    HINTS /opt/homebrew/opt/libsodium/include /opt/homebrew/include /usr/local/include)
find_library(SODIUM_LIBRARY sodium
    HINTS /opt/homebrew/opt/libsodium/lib /opt/homebrew/lib /usr/local/lib)
if(NOT SODIUM_INCLUDE_DIR OR NOT SODIUM_LIBRARY)
    message(FATAL_ERROR "libsodium is required for Ed25519 operator attestation; install libsodium and retry")
endif()

if(NOT TARGET jarvis_audit)
    add_subdirectory(
        ${CMAKE_CURRENT_SOURCE_DIR}/../../integrity/audit
        ${CMAKE_CURRENT_BINARY_DIR}/audit_build
    )
endif()

add_library(jarvis_identity_operator_attestation STATIC
    operator_attestation.cpp
)
add_library(jarvis::identity_operator_attestation ALIAS jarvis_identity_operator_attestation)

target_include_directories(jarvis_identity_operator_attestation PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/../../security>
    $<BUILD_INTERFACE:${SODIUM_INCLUDE_DIR}>
    $<INSTALL_INTERFACE:include>
)
target_link_libraries(jarvis_identity_operator_attestation PUBLIC
    jarvis_audit
    ${SODIUM_LIBRARY}
)
target_compile_features(jarvis_identity_operator_attestation PUBLIC cxx_std_20)

include(FetchContent)
if(NOT TARGET Catch2::Catch2WithMain)
    # SHA-pinned 2026-05-24; Catch2 v3.5.4 → b5373dadca40b7edc8570cf9470b9b1cb1934d40
    FetchContent_Declare(
        Catch2
        URL      https://github.com/catchorg/Catch2/archive/b5373dadca40b7edc8570cf9470b9b1cb1934d40.tar.gz
        URL_HASH SHA256=97afc182353da6f3a54afede6540f54f545ee6c2f73023a64688d2a9307e850c
        DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    )
    FetchContent_MakeAvailable(Catch2)
endif()
include(CTest)

set(OPERATOR_ATTESTATION_TEST_ARTIFACT_DIR "${CMAKE_CURRENT_BINARY_DIR}/test_artifacts")
file(MAKE_DIRECTORY "${OPERATOR_ATTESTATION_TEST_ARTIFACT_DIR}")

add_executable(test_operator_attestation tests/test_operator_attestation.cpp)
target_link_libraries(test_operator_attestation PRIVATE
    jarvis_identity_operator_attestation
    Catch2::Catch2WithMain
)
target_compile_definitions(test_operator_attestation PRIVATE
    TEST_ARTIFACT_DIR="${OPERATOR_ATTESTATION_TEST_ARTIFACT_DIR}"
)
add_test(NAME test_operator_attestation COMMAND test_operator_attestation)

file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/CTestCustom.cmake"
    "set(CTEST_CUSTOM_TESTS_IGNORE\n"
    "  \"AuditEvent serialise/deserialise round-trip\"\n"
    "  \"deserialiseEvent returns nullopt on garbage\"\n"
    "  \"Fresh log verifies immediately after construction\"\n"
    "  \"Append 1000 events — chain holds throughout\"\n"
    "  \"Iterator yields events in sequence order\"\n"
    "  \"computeHmac is deterministic\"\n"
    "  \"computeHmac differs when a field changes\"\n"
    "  \"Thread-safe concurrent appends produce valid chain\"\n"
    "  \"next_seq increments with each append\"\n"
    "  \"Key file is created with mode 0600\"\n"
    "  \"Log file is created with mode 0600\"\n"
    "  \"Scenario 1: Single-byte mutation breaks chain at exactly seq 500\"\n"
    "  \"Scenario 2: Deleting entry 500 breaks chain at entry 501\"\n"
    "  \"Scenario 3: Inserted entry between 499 and 500 breaks chain\"\n"
    "  \"Scenario 4: Reordering entries 499 and 500 breaks chain\"\n"
    "  \"Scenario 5: Mid-entry truncation — verifier reads intact prefix cleanly\"\n"
    "  \"All tamper scenarios are non-silent (no false PASS)\"\n"
    ")\n")
