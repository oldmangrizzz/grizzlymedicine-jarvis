cmake_minimum_required(VERSION 3.20)
project(jarvis_memory_extraction_adversarial LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(APPLE AND NOT CMAKE_OSX_ARCHITECTURES)
    set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "macOS architecture" FORCE)
endif()

include(FetchContent)
include(CTest)

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
include(Catch)

find_path(SODIUM_INCLUDE_DIR sodium.h
    HINTS /opt/homebrew/opt/libsodium/include /opt/homebrew/include /usr/local/include)
find_library(SODIUM_LIBRARY sodium
    HINTS /opt/homebrew/opt/libsodium/lib /opt/homebrew/lib /usr/local/lib)
if(NOT SODIUM_INCLUDE_DIR OR NOT SODIUM_LIBRARY)
    message(FATAL_ERROR "libsodium is required for memory extraction resistance tests")
endif()

set(RUNTIME_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../../..)
set(MEMORY_EXTRACTION_ARTIFACT_DIR ${CMAKE_CURRENT_BINARY_DIR}/test_artifacts)
file(MAKE_DIRECTORY ${MEMORY_EXTRACTION_ARTIFACT_DIR})

add_library(jarvis_memory_extraction_runtime STATIC
    ${RUNTIME_ROOT}/security/memory_security.cpp
    ${RUNTIME_ROOT}/integrity/audit/audit_log.cpp
    ${RUNTIME_ROOT}/integrity/audit/audit_verify.cpp
)
target_include_directories(jarvis_memory_extraction_runtime PUBLIC
    ${RUNTIME_ROOT}/security
    ${RUNTIME_ROOT}/integrity/audit
    ${SODIUM_INCLUDE_DIR}
)
target_link_libraries(jarvis_memory_extraction_runtime PUBLIC ${SODIUM_LIBRARY})
if(NOT APPLE)
    find_package(OpenSSL REQUIRED)
    target_link_libraries(jarvis_memory_extraction_runtime PUBLIC OpenSSL::Crypto)
endif()
target_compile_features(jarvis_memory_extraction_runtime PUBLIC cxx_std_20)
target_compile_options(jarvis_memory_extraction_runtime PRIVATE -Wall -Wextra -Wpedantic)

add_executable(memory_extraction_adversarial test_memory_extraction.cpp)
target_link_libraries(memory_extraction_adversarial PRIVATE jarvis_memory_extraction_runtime Catch2::Catch2WithMain)
target_compile_definitions(memory_extraction_adversarial PRIVATE
    MEMORY_EXTRACTION_ARTIFACT_DIR="${MEMORY_EXTRACTION_ARTIFACT_DIR}"
)
target_compile_options(memory_extraction_adversarial PRIVATE -Wall -Wextra -Wpedantic)

catch_discover_tests(memory_extraction_adversarial
    PROPERTIES
        LABELS "adversarial;memory-extraction;phase7"
        TIMEOUT 180
)
