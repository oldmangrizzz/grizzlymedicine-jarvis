cmake_minimum_required(VERSION 3.20)

if(APPLE AND NOT CMAKE_OSX_ARCHITECTURES)
    set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "Build macOS arm64 by default" FORCE)
endif()

project(jarvis_holograph_beliefstore VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang|AppleClang")
    add_compile_options(-ffp-contract=off -fno-unsafe-math-optimizations -O2)
    if(CMAKE_SYSTEM_PROCESSOR MATCHES "arm64|aarch64")
        add_compile_options(-march=native)
    endif()
endif()

set(RUNTIME_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../..)

find_path(SQLCIPHER_INCLUDE_DIR sqlite3.h
    HINTS /opt/homebrew/opt/sqlcipher/include/sqlcipher /usr/local/opt/sqlcipher/include/sqlcipher
          /opt/homebrew/include/sqlcipher /usr/local/include/sqlcipher)
find_library(SQLCIPHER_LIBRARY sqlcipher
    HINTS /opt/homebrew/opt/sqlcipher/lib /usr/local/opt/sqlcipher/lib
          /opt/homebrew/lib /usr/local/lib)
if(NOT SQLCIPHER_INCLUDE_DIR OR NOT SQLCIPHER_LIBRARY)
    message(FATAL_ERROR "SQLCipher is required for BeliefStore at-rest encryption. Install with: brew install sqlcipher")
endif()

find_path(SODIUM_INCLUDE_DIR sodium.h
    HINTS /opt/homebrew/opt/libsodium/include /opt/homebrew/include /usr/local/include)
find_library(SODIUM_LIBRARY sodium
    HINTS /opt/homebrew/opt/libsodium/lib /opt/homebrew/lib /usr/local/lib)
if(NOT SODIUM_INCLUDE_DIR OR NOT SODIUM_LIBRARY)
    message(FATAL_ERROR "libsodium is required for BeliefStore locked key memory; install with: brew install libsodium")
endif()

if(NOT TARGET jarvis_holograph_hdc)
    set(_jarvis_prev_skip_organ_tests ${JARVIS_SKIP_ORGAN_TESTS})
    set(JARVIS_SKIP_ORGAN_TESTS ON)
    add_subdirectory(
        ${CMAKE_CURRENT_SOURCE_DIR}/../hdc
        ${CMAKE_CURRENT_BINARY_DIR}/hdc_build
    )
    set(JARVIS_SKIP_ORGAN_TESTS ${_jarvis_prev_skip_organ_tests})
    unset(_jarvis_prev_skip_organ_tests)
endif()

if(NOT TARGET jarvis_audit)
    set(_jarvis_prev_skip_organ_tests ${JARVIS_SKIP_ORGAN_TESTS})
    set(JARVIS_SKIP_ORGAN_TESTS ON)
    add_subdirectory(
        ${RUNTIME_ROOT}/integrity/audit
        ${CMAKE_CURRENT_BINARY_DIR}/audit_build
    )
    set(JARVIS_SKIP_ORGAN_TESTS ${_jarvis_prev_skip_organ_tests})
    unset(_jarvis_prev_skip_organ_tests)
endif()

add_library(jarvis_holograph_beliefstore STATIC beliefstore.cpp beliefstore_persistence.cpp)
add_library(jarvis::holograph_beliefstore ALIAS jarvis_holograph_beliefstore)

target_include_directories(jarvis_holograph_beliefstore PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
    $<BUILD_INTERFACE:${RUNTIME_ROOT}/security>
    $<BUILD_INTERFACE:${RUNTIME_ROOT}/integrity/audit>
    $<BUILD_INTERFACE:${SQLCIPHER_INCLUDE_DIR}/..>
    $<BUILD_INTERFACE:${SODIUM_INCLUDE_DIR}>
    $<INSTALL_INTERFACE:include>
)
target_link_libraries(jarvis_holograph_beliefstore PUBLIC
    jarvis_holograph_hdc
    jarvis_audit
    ${SQLCIPHER_LIBRARY}
    ${SODIUM_LIBRARY}
)
target_compile_features(jarvis_holograph_beliefstore PUBLIC cxx_std_20)

if(NOT JARVIS_SKIP_ORGAN_TESTS)
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

    if(NOT DEFINED BELIEFSTORE_ORACLE_DIR)
        set(BELIEFSTORE_ORACLE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../oracle/holograph"
            CACHE PATH "Path to oracle/holograph directory")
    endif()
    set(BELIEFSTORE_TEST_ARTIFACT_DIR "${CMAKE_CURRENT_BINARY_DIR}/test_artifacts")
    file(MAKE_DIRECTORY "${BELIEFSTORE_TEST_ARTIFACT_DIR}")

    add_executable(test_beliefstore tests/test_beliefstore.cpp)
    target_link_libraries(test_beliefstore PRIVATE jarvis_holograph_beliefstore Catch2::Catch2WithMain)
    catch_discover_tests(test_beliefstore)

    add_executable(test_beliefstore_oracle tests/test_beliefstore_oracle.cpp)
    target_link_libraries(test_beliefstore_oracle
        PRIVATE jarvis_holograph_beliefstore Catch2::Catch2WithMain nlohmann_json::nlohmann_json
    )
    target_compile_definitions(test_beliefstore_oracle PRIVATE
        BELIEFSTORE_ORACLE_DIR="${BELIEFSTORE_ORACLE_DIR}"
        TEST_ARTIFACT_DIR="${BELIEFSTORE_TEST_ARTIFACT_DIR}"
    )
    catch_discover_tests(test_beliefstore_oracle)

    add_executable(test_beliefstore_sqlcipher tests/test_beliefstore_sqlcipher.cpp)
    target_link_libraries(test_beliefstore_sqlcipher
        PRIVATE jarvis_holograph_beliefstore Catch2::Catch2WithMain
    )
    target_compile_definitions(test_beliefstore_sqlcipher PRIVATE
        TEST_ARTIFACT_DIR="${BELIEFSTORE_TEST_ARTIFACT_DIR}"
    )
    catch_discover_tests(test_beliefstore_sqlcipher)
endif()
