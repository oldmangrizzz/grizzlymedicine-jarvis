cmake_minimum_required(VERSION 3.20)

if(APPLE AND NOT CMAKE_OSX_ARCHITECTURES)
    set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "Build macOS arm64 by default" FORCE)
endif()

project(jarvis_holograph_sage VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang|AppleClang")
    add_compile_options(-ffp-contract=off -fno-unsafe-math-optimizations -O2)
    if(CMAKE_SYSTEM_PROCESSOR MATCHES "arm64|aarch64|x86_64|AMD64")
        add_compile_options(-march=native)
    endif()
endif()

if(NOT TARGET jarvis_holograph_hdc)
    add_library(jarvis_holograph_hdc STATIC
        ${CMAKE_CURRENT_SOURCE_DIR}/../hdc/hdc.cpp
        ${CMAKE_CURRENT_SOURCE_DIR}/../hdc/hdc_real.cpp
        ${CMAKE_CURRENT_SOURCE_DIR}/../hdc/hdc_ternary.cpp
        ${CMAKE_CURRENT_SOURCE_DIR}/../hdc/hdc_hierarchy.cpp
    )
    add_library(jarvis::holograph_hdc ALIAS jarvis_holograph_hdc)
    target_include_directories(jarvis_holograph_hdc PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/../hdc)
    target_compile_features(jarvis_holograph_hdc PUBLIC cxx_std_20)
endif()

if(NOT TARGET jarvis_holograph_beliefstore)
    add_library(jarvis_holograph_beliefstore STATIC
        ${CMAKE_CURRENT_SOURCE_DIR}/../beliefstore/beliefstore.cpp
    )
    add_library(jarvis::holograph_beliefstore ALIAS jarvis_holograph_beliefstore)
    target_include_directories(jarvis_holograph_beliefstore PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/../beliefstore)
    target_link_libraries(jarvis_holograph_beliefstore PUBLIC jarvis_holograph_hdc)
    target_compile_features(jarvis_holograph_beliefstore PUBLIC cxx_std_20)
endif()

if(NOT TARGET jarvis_holograph_hmem)
    add_library(jarvis_holograph_hmem STATIC
        ${CMAKE_CURRENT_SOURCE_DIR}/../hmem/hmem.cpp
    )
    add_library(jarvis::holograph_hmem ALIAS jarvis_holograph_hmem)
    target_include_directories(jarvis_holograph_hmem PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/../hmem)
    target_link_libraries(jarvis_holograph_hmem PUBLIC jarvis_holograph_hdc jarvis_holograph_beliefstore)
    target_compile_features(jarvis_holograph_hmem PUBLIC cxx_std_20)
endif()

add_library(jarvis_holograph_sage STATIC sage.cpp)
add_library(jarvis::holograph_sage ALIAS jarvis_holograph_sage)

target_include_directories(jarvis_holograph_sage PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
    $<INSTALL_INTERFACE:include>
)
target_link_libraries(jarvis_holograph_sage PUBLIC jarvis_holograph_hdc jarvis_holograph_beliefstore jarvis_holograph_hmem)
target_compile_features(jarvis_holograph_sage PUBLIC cxx_std_20)

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

if(NOT DEFINED SAGE_ORACLE_DIR)
    set(SAGE_ORACLE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../oracle/holograph"
        CACHE PATH "Path to oracle/holograph directory")
endif()

add_executable(test_sage tests/test_sage.cpp)
target_link_libraries(test_sage PRIVATE jarvis_holograph_sage Catch2::Catch2WithMain)
catch_discover_tests(test_sage)

add_executable(test_sage_oracle tests/test_sage_oracle.cpp)
target_link_libraries(test_sage_oracle PRIVATE jarvis_holograph_sage Catch2::Catch2WithMain nlohmann_json::nlohmann_json)
target_compile_definitions(test_sage_oracle PRIVATE SAGE_ORACLE_DIR="${SAGE_ORACLE_DIR}")
catch_discover_tests(test_sage_oracle)
