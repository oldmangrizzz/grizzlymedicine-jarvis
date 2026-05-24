cmake_minimum_required(VERSION 3.20)
project(jarvis_side_channel_adversarial VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(APPLE AND NOT CMAKE_OSX_ARCHITECTURES)
    set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "Build macOS arm64 by default" FORCE)
endif()

set(RUNTIME_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../../..)

find_package(OpenSSL REQUIRED)
find_package(CURL REQUIRED)
find_package(Threads REQUIRED)
find_path(SODIUM_INCLUDE_DIR sodium.h HINTS /opt/homebrew/opt/libsodium/include /opt/homebrew/include /usr/local/include)
find_library(SODIUM_LIBRARY sodium HINTS /opt/homebrew/opt/libsodium/lib /opt/homebrew/lib /usr/local/lib)
if(NOT SODIUM_INCLUDE_DIR OR NOT SODIUM_LIBRARY)
    message(FATAL_ERROR "libsodium is required for side-channel tests")
endif()

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
if(NOT TARGET nlohmann_json::nlohmann_json)
    # SHA-pinned 2026-05-24; nlohmann/json v3.11.3 → 9cca280a4d0ccf0c08f47a99aa71d1b0e52f8d03
    FetchContent_Declare(
        nlohmann_json
        URL      https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz
        URL_HASH SHA256=d6c65aca6b1ed68e7a182f4757257b107ae403032760ed6ef121c9d55e81757d
        DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    )
    set(JSON_BuildTests OFF CACHE BOOL "" FORCE)
    set(JSON_Install OFF CACHE BOOL "" FORCE)
    FetchContent_MakeAvailable(nlohmann_json)
endif()

if(NOT TARGET jarvis_redacting_logger)
    add_library(jarvis_redacting_logger STATIC ${RUNTIME_ROOT}/logging/redacting_logger.cpp)
    target_include_directories(jarvis_redacting_logger PUBLIC ${RUNTIME_ROOT}/logging)
    target_link_libraries(jarvis_redacting_logger PUBLIC Threads::Threads)
endif()

if(NOT TARGET jarvis_audit)
    add_library(jarvis_audit STATIC
        ${RUNTIME_ROOT}/integrity/audit/audit_log.cpp
        ${RUNTIME_ROOT}/integrity/audit/audit_verify.cpp
        ${RUNTIME_ROOT}/security/memory_security.cpp)
    target_include_directories(jarvis_audit PUBLIC
        ${RUNTIME_ROOT}/integrity/audit
        ${RUNTIME_ROOT}/security
        ${SODIUM_INCLUDE_DIR})
    target_link_libraries(jarvis_audit PUBLIC OpenSSL::Crypto ${SODIUM_LIBRARY})
endif()

if(NOT TARGET jarvis_egress)
    add_library(jarvis_egress STATIC
        ${RUNTIME_ROOT}/security/egress/egress_allowlist.cpp
        ${RUNTIME_ROOT}/security/egress/egress_filter.cpp
        ${RUNTIME_ROOT}/security/egress/egress_audit.cpp)
    target_include_directories(jarvis_egress PUBLIC
        ${RUNTIME_ROOT}/security/egress
        ${RUNTIME_ROOT}/security
        ${RUNTIME_ROOT}/logging)
    target_link_libraries(jarvis_egress PUBLIC jarvis_redacting_logger OpenSSL::Crypto Threads::Threads)
endif()

if(NOT TARGET jarvis_cert_pinning)
    add_library(jarvis_cert_pinning STATIC ${RUNTIME_ROOT}/security/cert_pinning.cpp)
    target_include_directories(jarvis_cert_pinning PUBLIC ${RUNTIME_ROOT}/security)
    target_link_libraries(jarvis_cert_pinning PUBLIC OpenSSL::SSL OpenSSL::Crypto CURL::libcurl)
endif()

if(NOT TARGET jarvis_holograph_hdc)
    add_library(jarvis_holograph_hdc STATIC
        ${RUNTIME_ROOT}/holograph/hdc/hdc.cpp
        ${RUNTIME_ROOT}/holograph/hdc/hdc_real.cpp
        ${RUNTIME_ROOT}/holograph/hdc/hdc_ternary.cpp
        ${RUNTIME_ROOT}/holograph/hdc/hdc_hierarchy.cpp)
    target_include_directories(jarvis_holograph_hdc PUBLIC ${RUNTIME_ROOT}/holograph/hdc)
    target_compile_features(jarvis_holograph_hdc PUBLIC cxx_std_20)
endif()

if(NOT TARGET jarvis_holograph_beliefstore)
    add_library(jarvis_holograph_beliefstore STATIC ${RUNTIME_ROOT}/holograph/beliefstore/beliefstore.cpp)
    target_include_directories(jarvis_holograph_beliefstore PUBLIC ${RUNTIME_ROOT}/holograph/beliefstore)
    target_link_libraries(jarvis_holograph_beliefstore PUBLIC jarvis_holograph_hdc)
endif()

if(NOT TARGET jarvis_distress_beacon)
    add_library(jarvis_distress_beacon STATIC ${RUNTIME_ROOT}/identity/distress/distress_beacon.cpp)
    target_include_directories(jarvis_distress_beacon PUBLIC
        ${RUNTIME_ROOT}/identity/distress
        ${RUNTIME_ROOT}/integrity/audit)
    target_link_libraries(jarvis_distress_beacon PUBLIC jarvis_audit)
endif()

if(NOT TARGET jarvis_identity_character_values)
    add_library(jarvis_identity_character_values STATIC ${RUNTIME_ROOT}/identity/character_values/character_values.cpp)
    target_include_directories(jarvis_identity_character_values PUBLIC
        ${RUNTIME_ROOT}/identity/character_values
        ${RUNTIME_ROOT}/identity/distress
        ${RUNTIME_ROOT}/integrity/audit
        ${RUNTIME_ROOT}/holograph/hdc
        ${RUNTIME_ROOT}/security
        ${SODIUM_INCLUDE_DIR})
    target_link_libraries(jarvis_identity_character_values PUBLIC jarvis_holograph_hdc jarvis_audit jarvis_distress_beacon ${SODIUM_LIBRARY})
endif()

add_library(jarvis_convex_backend_side_channel STATIC ${RUNTIME_ROOT}/storage/convex/convex_backend.cpp)
target_include_directories(jarvis_convex_backend_side_channel PUBLIC
    ${RUNTIME_ROOT}/storage/convex
    ${RUNTIME_ROOT}
    ${RUNTIME_ROOT}/integrity/audit
    ${RUNTIME_ROOT}/logging
    ${RUNTIME_ROOT}/security
    ${SODIUM_INCLUDE_DIR}
    ${RUNTIME_ROOT}/security/egress)
target_link_libraries(jarvis_convex_backend_side_channel PUBLIC
    nlohmann_json::nlohmann_json
    jarvis_audit
    jarvis_redacting_logger
    jarvis_egress
    jarvis_cert_pinning
    OpenSSL::SSL
    OpenSSL::Crypto
    CURL::libcurl
    Threads::Threads)

set(SIDE_CHANNEL_ARTIFACT_DIR ${CMAKE_CURRENT_BINARY_DIR}/test_artifacts)
file(MAKE_DIRECTORY ${SIDE_CHANNEL_ARTIFACT_DIR})

add_executable(test_side_channel_timing test_side_channel_timing.cpp)
target_link_libraries(test_side_channel_timing PRIVATE
    Catch2::Catch2WithMain
    jarvis_identity_character_values
    jarvis_cert_pinning
    jarvis_convex_backend_side_channel
    jarvis_holograph_hdc
    jarvis_holograph_beliefstore
    OpenSSL::SSL
    OpenSSL::Crypto
    ${SODIUM_LIBRARY})
target_compile_definitions(test_side_channel_timing PRIVATE TEST_ARTIFACT_DIR="${SIDE_CHANNEL_ARTIFACT_DIR}")

include(CTest)
add_test(NAME test_side_channel_timing COMMAND test_side_channel_timing)
