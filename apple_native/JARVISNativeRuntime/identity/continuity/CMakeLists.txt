cmake_minimum_required(VERSION 3.20)
project(jarvis_identity_continuity VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_path(SODIUM_INCLUDE_DIR sodium.h
    HINTS /opt/homebrew/opt/libsodium/include /opt/homebrew/include /usr/local/include)
find_library(SODIUM_LIBRARY sodium
    HINTS /opt/homebrew/opt/libsodium/lib /opt/homebrew/lib /usr/local/lib)
if(NOT SODIUM_INCLUDE_DIR OR NOT SODIUM_LIBRARY)
    message(FATAL_ERROR "libsodium is required for continuity Ed25519 signatures")
endif()

if(NOT TARGET jarvis_audit)
    add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../integrity/audit ${CMAKE_CURRENT_BINARY_DIR}/audit_build)
endif()
if(NOT TARGET jarvis_identity_character_values)
    add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../character_values ${CMAKE_CURRENT_BINARY_DIR}/character_values_build)
endif()
if(NOT TARGET jarvis_identity_operator_attestation)
    add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../operator_attestation ${CMAKE_CURRENT_BINARY_DIR}/operator_attestation_build)
endif()

add_library(jarvis_identity_continuity STATIC
    continuity.cpp
)
add_library(jarvis::identity_continuity ALIAS jarvis_identity_continuity)

target_include_directories(jarvis_identity_continuity PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/../character_values>
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/../distress>
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/../operator_attestation>
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/../../integrity/audit>
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/../../security>
    $<BUILD_INTERFACE:${SODIUM_INCLUDE_DIR}>
    $<INSTALL_INTERFACE:include>
)

target_link_libraries(jarvis_identity_continuity PUBLIC
    jarvis_identity_character_values
    jarvis_identity_operator_attestation
    jarvis_audit
    ${SODIUM_LIBRARY}
)

target_compile_features(jarvis_identity_continuity PUBLIC cxx_std_20)

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

set(CONTINUITY_TEST_ARTIFACT_DIR "${CMAKE_CURRENT_BINARY_DIR}/test_artifacts")
file(MAKE_DIRECTORY "${CONTINUITY_TEST_ARTIFACT_DIR}")

add_executable(test_identity_continuity tests/test_identity_continuity.cpp)
target_link_libraries(test_identity_continuity PRIVATE
    jarvis_identity_continuity
    Catch2::Catch2WithMain
)
target_compile_definitions(test_identity_continuity PRIVATE
    TEST_ARTIFACT_DIR="${CONTINUITY_TEST_ARTIFACT_DIR}"
)
catch_discover_tests(test_identity_continuity)
