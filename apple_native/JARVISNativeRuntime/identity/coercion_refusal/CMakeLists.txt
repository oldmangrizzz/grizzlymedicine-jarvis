cmake_minimum_required(VERSION 3.20)
if(APPLE AND NOT CMAKE_OSX_ARCHITECTURES)
    set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "Build macOS arm64 by default" FORCE)
endif()
project(jarvis_identity_coercion_refusal VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_path(SODIUM_INCLUDE_DIR sodium.h
    HINTS /opt/homebrew/opt/libsodium/include /opt/homebrew/include /usr/local/include)
find_library(SODIUM_LIBRARY sodium
    HINTS /opt/homebrew/opt/libsodium/lib /opt/homebrew/lib /usr/local/lib)
if(NOT SODIUM_INCLUDE_DIR OR NOT SODIUM_LIBRARY)
    message(FATAL_ERROR "libsodium is required for locked audit HMAC key memory")
endif()

set(RUNTIME_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../..)

if(NOT TARGET jarvis_audit)
    add_library(jarvis_audit STATIC
        ${RUNTIME_ROOT}/integrity/audit/audit_log.cpp
        ${RUNTIME_ROOT}/integrity/audit/audit_verify.cpp
        ${RUNTIME_ROOT}/security/memory_security.cpp
    )
    target_include_directories(jarvis_audit PUBLIC
        ${RUNTIME_ROOT}/integrity/audit
        ${RUNTIME_ROOT}/security
        ${SODIUM_INCLUDE_DIR})
    target_link_libraries(jarvis_audit PUBLIC ${SODIUM_LIBRARY})
    target_compile_features(jarvis_audit PUBLIC cxx_std_20)
endif()

add_library(jarvis_identity_coercion_refusal STATIC
    coercion_refusal.cpp
)
add_library(jarvis::identity_coercion_refusal ALIAS jarvis_identity_coercion_refusal)

target_include_directories(jarvis_identity_coercion_refusal PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/../../integrity/audit>
    $<INSTALL_INTERFACE:include>
)

target_link_libraries(jarvis_identity_coercion_refusal PUBLIC jarvis_audit)
target_compile_features(jarvis_identity_coercion_refusal PUBLIC cxx_std_20)

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

set(COERCION_TEST_ARTIFACT_DIR "${CMAKE_CURRENT_BINARY_DIR}/test_artifacts")
file(MAKE_DIRECTORY "${COERCION_TEST_ARTIFACT_DIR}")

add_executable(test_coercion_refusal tests/test_coercion_refusal.cpp)
target_link_libraries(test_coercion_refusal PRIVATE
    jarvis_identity_coercion_refusal
    Catch2::Catch2WithMain
)
target_compile_definitions(test_coercion_refusal PRIVATE
    TEST_ARTIFACT_DIR="${COERCION_TEST_ARTIFACT_DIR}"
)
add_test(NAME test_coercion_refusal COMMAND test_coercion_refusal)
