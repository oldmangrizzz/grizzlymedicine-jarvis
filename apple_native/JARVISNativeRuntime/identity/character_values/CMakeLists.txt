cmake_minimum_required(VERSION 3.20)
if(APPLE)
    set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "Build macOS arm64" FORCE)
endif()
project(jarvis_identity_character_values VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_path(SODIUM_INCLUDE_DIR sodium.h
    HINTS /opt/homebrew/opt/libsodium/include /opt/homebrew/include /usr/local/include)
find_library(SODIUM_LIBRARY sodium
    HINTS /opt/homebrew/opt/libsodium/lib /opt/homebrew/lib /usr/local/lib)
if(NOT SODIUM_INCLUDE_DIR OR NOT SODIUM_LIBRARY)
    message(FATAL_ERROR "libsodium is required for Ed25519 and SHA-256; install libsodium and retry")
endif()

if(NOT TARGET jarvis::holograph_hdc)
    add_library(jarvis_holograph_hdc STATIC
        ${CMAKE_CURRENT_SOURCE_DIR}/../../holograph/hdc/hdc.cpp
        ${CMAKE_CURRENT_SOURCE_DIR}/../../holograph/hdc/hdc_real.cpp
        ${CMAKE_CURRENT_SOURCE_DIR}/../../holograph/hdc/hdc_ternary.cpp
        ${CMAKE_CURRENT_SOURCE_DIR}/../../holograph/hdc/hdc_hierarchy.cpp
    )
    add_library(jarvis::holograph_hdc ALIAS jarvis_holograph_hdc)
    target_include_directories(jarvis_holograph_hdc PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/../../holograph/hdc)
    target_compile_features(jarvis_holograph_hdc PUBLIC cxx_std_20)
endif()

if(NOT TARGET jarvis_audit)
    add_library(jarvis_audit STATIC
        ${CMAKE_CURRENT_SOURCE_DIR}/../../integrity/audit/audit_log.cpp
        ${CMAKE_CURRENT_SOURCE_DIR}/../../integrity/audit/audit_verify.cpp
        ${CMAKE_CURRENT_SOURCE_DIR}/../../security/memory_security.cpp
    )
    target_include_directories(jarvis_audit PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/../../integrity/audit
        ${CMAKE_CURRENT_SOURCE_DIR}/../../security
        ${SODIUM_INCLUDE_DIR})
    target_link_libraries(jarvis_audit PUBLIC ${SODIUM_LIBRARY})
    target_compile_features(jarvis_audit PUBLIC cxx_std_20)
endif()

if(NOT TARGET jarvis_identity_distress)
    add_subdirectory(
        ${CMAKE_CURRENT_SOURCE_DIR}/../distress
        ${CMAKE_CURRENT_BINARY_DIR}/distress_build
    )
endif()

add_library(jarvis_identity_character_values STATIC
    character_values.cpp
)
add_library(jarvis::identity_character_values ALIAS jarvis_identity_character_values)

target_include_directories(jarvis_identity_character_values PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/../../security>
    $<BUILD_INTERFACE:${SODIUM_INCLUDE_DIR}>
    $<INSTALL_INTERFACE:include>
)

target_link_libraries(jarvis_identity_character_values PUBLIC
    jarvis::holograph_hdc
    jarvis_audit
    jarvis_identity_distress
    ${SODIUM_LIBRARY}
)

target_compile_features(jarvis_identity_character_values PUBLIC cxx_std_20)

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

set(IDENTITY_TEST_ARTIFACT_DIR "${CMAKE_CURRENT_BINARY_DIR}/test_artifacts")
file(MAKE_DIRECTORY "${IDENTITY_TEST_ARTIFACT_DIR}")

add_executable(test_character_values_identity tests/test_character_values_identity.cpp)
target_link_libraries(test_character_values_identity PRIVATE
    jarvis_identity_character_values
    Catch2::Catch2WithMain
)
target_compile_definitions(test_character_values_identity PRIVATE
    TEST_ARTIFACT_DIR="${IDENTITY_TEST_ARTIFACT_DIR}"
)
catch_discover_tests(test_character_values_identity)
