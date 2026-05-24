cmake_minimum_required(VERSION 3.20)
project(jarvis_convex_backend VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(APPLE AND NOT CMAKE_OSX_ARCHITECTURES)
    set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "macOS target architecture" FORCE)
endif()

find_package(OpenSSL REQUIRED)
find_package(CURL REQUIRED)
find_path(SODIUM_INCLUDE_DIR sodium.h
    HINTS /opt/homebrew/opt/libsodium/include /opt/homebrew/include /usr/local/include)
find_library(SODIUM_LIBRARY sodium
    HINTS /opt/homebrew/opt/libsodium/lib /opt/homebrew/lib /usr/local/lib)
if(NOT SODIUM_INCLUDE_DIR OR NOT SODIUM_LIBRARY)
    message(FATAL_ERROR "libsodium is required for no-swap secret memory")
endif()
find_package(Threads REQUIRED)
find_package(PkgConfig QUIET)
if(PkgConfig_FOUND)
    pkg_check_modules(LWS QUIET libwebsockets)
endif()
if(NOT LWS_FOUND)
    find_path(LWS_INCLUDE_DIR libwebsockets.h PATHS /opt/homebrew/include /usr/local/include /usr/include)
    find_library(LWS_LIBRARY NAMES websockets PATHS /opt/homebrew/lib /usr/local/lib /usr/lib)
    if(LWS_INCLUDE_DIR AND LWS_LIBRARY)
        set(LWS_FOUND TRUE)
        set(LWS_INCLUDE_DIRS ${LWS_INCLUDE_DIR})
        set(LWS_LIBRARIES ${LWS_LIBRARY})
    endif()
endif()
if(NOT LWS_FOUND)
    message(FATAL_ERROR "libwebsockets not found. Install with: brew install libwebsockets")
endif()

include(FetchContent)
if(NOT TARGET nlohmann_json::nlohmann_json)
    FetchContent_Declare(nlohmann_json URL https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz URL_HASH SHA256=d6c65aca6b1ed68e7a182f4757257b107ae403032760ed6ef121c9d55e81757d DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
    FetchContent_MakeAvailable(nlohmann_json)
endif()
if(NOT TARGET Catch2::Catch2WithMain)
    # SHA-pinned 2026-05-24; Catch2 v3.5.4 → b5373dadca40b7edc8570cf9470b9b1cb1934d40
    FetchContent_Declare(
        Catch2
        URL      https://github.com/catchorg/Catch2/archive/b5373dadca40b7edc8570cf9470b9b1cb1934d40.tar.gz
        URL_HASH SHA256=97afc182353da6f3a54afede6540f54f545ee6c2f73023a64688d2a9307e850c
        DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    )
    FetchContent_MakeAvailable(Catch2)
    list(APPEND CMAKE_MODULE_PATH ${catch2_SOURCE_DIR}/extras)
endif()
include(CTest)
include(Catch)

set(RUNTIME_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../..)

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
    target_include_directories(jarvis_audit PUBLIC ${RUNTIME_ROOT}/integrity/audit ${RUNTIME_ROOT}/security ${SODIUM_INCLUDE_DIR})
    target_link_libraries(jarvis_audit PUBLIC ${SODIUM_LIBRARY})
    if(NOT APPLE)
        target_link_libraries(jarvis_audit PUBLIC OpenSSL::Crypto)
    endif()
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

add_library(jarvis_convex_backend STATIC
    convex_backend.cpp
    convex_websocket.cpp
)
target_include_directories(jarvis_convex_backend PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${RUNTIME_ROOT}
    ${RUNTIME_ROOT}/security
    ${SODIUM_INCLUDE_DIR}
    ${LWS_INCLUDE_DIRS}
)
target_link_libraries(jarvis_convex_backend PUBLIC
    nlohmann_json::nlohmann_json
    jarvis_audit
    jarvis_redacting_logger
    jarvis_egress
    jarvis_cert_pinning
    OpenSSL::SSL
    OpenSSL::Crypto
    CURL::libcurl
    ${SODIUM_LIBRARY}
    ${LWS_LIBRARIES}
    Threads::Threads
)
target_compile_options(jarvis_convex_backend PRIVATE -Wall -Wextra -Wpedantic)

set(CONVEX_TEST_ARTIFACT_DIR ${CMAKE_CURRENT_BINARY_DIR}/test_artifacts)
file(MAKE_DIRECTORY ${CONVEX_TEST_ARTIFACT_DIR})

add_executable(test_convex_backend tests/test_convex_backend.cpp)
target_link_libraries(test_convex_backend PRIVATE jarvis_convex_backend Catch2::Catch2WithMain)
target_compile_definitions(test_convex_backend PRIVATE TEST_ARTIFACT_DIR="${CONVEX_TEST_ARTIFACT_DIR}")
catch_discover_tests(test_convex_backend)
