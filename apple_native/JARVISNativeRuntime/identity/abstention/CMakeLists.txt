cmake_minimum_required(VERSION 3.20)

if(APPLE AND NOT CMAKE_OSX_ARCHITECTURES)
    set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "Build macOS arm64 by default" FORCE)
endif()

project(jarvis_abstention VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(_jarvis_abstention_prev_skip_organ_tests ${JARVIS_SKIP_ORGAN_TESTS})
set(JARVIS_SKIP_ORGAN_TESTS ON)

if(NOT TARGET jarvis_holograph_beliefstore)
    add_subdirectory(
        ${CMAKE_CURRENT_SOURCE_DIR}/../../holograph/beliefstore
        ${CMAKE_CURRENT_BINARY_DIR}/beliefstore_build
    )
endif()

if(NOT TARGET jarvis_swarm)
    add_subdirectory(
        ${CMAKE_CURRENT_SOURCE_DIR}/../../swarm
        ${CMAKE_CURRENT_BINARY_DIR}/swarm_build
    )
endif()

set(JARVIS_SKIP_ORGAN_TESTS ${_jarvis_abstention_prev_skip_organ_tests})
unset(_jarvis_abstention_prev_skip_organ_tests)

add_library(jarvis_abstention STATIC
    abstention.cpp
    abstention_audit.cpp
)
add_library(jarvis::abstention ALIAS jarvis_abstention)

target_include_directories(jarvis_abstention PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
    $<INSTALL_INTERFACE:include>
)
target_link_libraries(jarvis_abstention PUBLIC
    jarvis_holograph_beliefstore
    jarvis_swarm
    jarvis_holograph_hdc
)
target_compile_features(jarvis_abstention PUBLIC cxx_std_20)

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

add_executable(test_abstention tests/test_abstention.cpp)
target_link_libraries(test_abstention PRIVATE jarvis_abstention Catch2::Catch2WithMain)
add_test(NAME test_abstention COMMAND test_abstention)
