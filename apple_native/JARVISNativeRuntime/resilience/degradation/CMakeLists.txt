cmake_minimum_required(VERSION 3.20)

if(APPLE AND NOT CMAKE_OSX_ARCHITECTURES)
    set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "Build macOS arm64 by default" FORCE)
endif()

project(jarvis_resilience_degradation VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT TARGET jarvis_audit)
    add_subdirectory(
        ${CMAKE_CURRENT_SOURCE_DIR}/../../integrity/audit
        ${CMAKE_CURRENT_BINARY_DIR}/audit_build
    )
endif()

add_library(jarvis_resilience_degradation STATIC
    degradation.cpp
    resource_pressure_monitor.cpp
)
add_library(jarvis::resilience_degradation ALIAS jarvis_resilience_degradation)

target_include_directories(jarvis_resilience_degradation PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
    $<INSTALL_INTERFACE:include>
)
if(NOT TARGET jarvis_identity_distress)
    add_subdirectory(
        ${CMAKE_CURRENT_SOURCE_DIR}/../../identity/distress
        ${CMAKE_CURRENT_BINARY_DIR}/distress_build
    )
endif()

target_link_libraries(jarvis_resilience_degradation PUBLIC jarvis_audit jarvis_identity_distress)
target_compile_features(jarvis_resilience_degradation PUBLIC cxx_std_20)

if(APPLE)
    target_link_libraries(jarvis_resilience_degradation PRIVATE "-framework IOKit" "-framework CoreFoundation")
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
include(CTest)

set(DEGRADATION_TEST_ARTIFACT_DIR "${CMAKE_CURRENT_BINARY_DIR}/test_artifacts")
file(MAKE_DIRECTORY "${DEGRADATION_TEST_ARTIFACT_DIR}")

add_executable(test_degradation_policy tests/test_degradation_policy.cpp)
target_link_libraries(test_degradation_policy PRIVATE jarvis_resilience_degradation Catch2::Catch2WithMain)
target_compile_definitions(test_degradation_policy PRIVATE
    TEST_ARTIFACT_DIR="${DEGRADATION_TEST_ARTIFACT_DIR}"
)
add_test(NAME test_degradation_policy COMMAND test_degradation_policy)
