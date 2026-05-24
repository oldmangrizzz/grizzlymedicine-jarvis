cmake_minimum_required(VERSION 3.20)

if(APPLE AND NOT CMAKE_OSX_ARCHITECTURES)
    set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "Build macOS arm64 by default" FORCE)
endif()

project(jarvis_cusum_monitoring VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT TARGET jarvis_audit)
    add_subdirectory(
        ${CMAKE_CURRENT_SOURCE_DIR}/../../integrity/audit
        ${CMAKE_CURRENT_BINARY_DIR}/audit_build
    )
endif()

find_path(SODIUM_INCLUDE_DIR sodium.h
    HINTS /opt/homebrew/opt/libsodium/include /opt/homebrew/include /usr/local/include)
find_library(SODIUM_LIBRARY sodium
    HINTS /opt/homebrew/opt/libsodium/lib /opt/homebrew/lib /usr/local/lib)
if(NOT SODIUM_INCLUDE_DIR OR NOT SODIUM_LIBRARY)
    message(FATAL_ERROR "libsodium is required for consumed challenge HMAC chaining")
endif()

add_library(jarvis_cusum STATIC cusum.cpp)
target_include_directories(jarvis_cusum PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
    $<BUILD_INTERFACE:${SODIUM_INCLUDE_DIR}>
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/../../identity/operator_attestation>
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/../../integrity/audit>
    $<INSTALL_INTERFACE:include>
)
target_compile_features(jarvis_cusum PUBLIC cxx_std_20)
target_link_libraries(jarvis_cusum PUBLIC jarvis_audit ${SODIUM_LIBRARY})

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
    set(JSON_Install    OFF CACHE BOOL "" FORCE)
    FetchContent_MakeAvailable(nlohmann_json)
endif()

include(CTest)

set(CUSUM_TEST_ARTIFACT_DIR "${CMAKE_CURRENT_BINARY_DIR}/test_artifacts")
file(MAKE_DIRECTORY "${CUSUM_TEST_ARTIFACT_DIR}")

add_executable(test_cusum tests/test_cusum.cpp)
target_link_libraries(test_cusum PRIVATE jarvis_cusum Catch2::Catch2WithMain)
target_compile_definitions(test_cusum PRIVATE TEST_ARTIFACT_DIR="${CUSUM_TEST_ARTIFACT_DIR}")
add_test(NAME test_cusum COMMAND test_cusum)

add_executable(test_cusum_oracle tests/test_oracle_equivalence.cpp)
target_link_libraries(test_cusum_oracle PRIVATE jarvis_cusum Catch2::Catch2WithMain nlohmann_json::nlohmann_json)
target_compile_definitions(test_cusum_oracle PRIVATE
    DRIFT_ORACLE_DIR="/Users/rbhanson/research/oracle/drift"
    TEST_ARTIFACT_DIR="${CUSUM_TEST_ARTIFACT_DIR}"
)
add_test(NAME test_cusum_oracle COMMAND test_cusum_oracle)
