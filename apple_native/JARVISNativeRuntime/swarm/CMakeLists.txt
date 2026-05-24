cmake_minimum_required(VERSION 3.20)

if(APPLE AND NOT CMAKE_OSX_ARCHITECTURES)
    set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "Build macOS arm64 by default" FORCE)
endif()

project(jarvis_swarm VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT TARGET jarvis_endocrine)
    set(_jarvis_prev_skip_organ_tests ${JARVIS_SKIP_ORGAN_TESTS})
    set(JARVIS_SKIP_ORGAN_TESTS ON)
    add_subdirectory(
        ${CMAKE_CURRENT_SOURCE_DIR}/../endocrine
        ${CMAKE_CURRENT_BINARY_DIR}/endocrine_build
    )
    set(JARVIS_SKIP_ORGAN_TESTS ${_jarvis_prev_skip_organ_tests})
    unset(_jarvis_prev_skip_organ_tests)
endif()

if(NOT TARGET jarvis_pheromind)
    set(_jarvis_prev_skip_organ_tests ${JARVIS_SKIP_ORGAN_TESTS})
    set(JARVIS_SKIP_ORGAN_TESTS ON)
    add_subdirectory(
        ${CMAKE_CURRENT_SOURCE_DIR}/../pheromind
        ${CMAKE_CURRENT_BINARY_DIR}/pheromind_build
    )
    set(JARVIS_SKIP_ORGAN_TESTS ${_jarvis_prev_skip_organ_tests})
    unset(_jarvis_prev_skip_organ_tests)
endif()

add_library(jarvis_swarm STATIC swarm.cpp)
target_include_directories(jarvis_swarm PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
    $<INSTALL_INTERFACE:include>
)
target_link_libraries(jarvis_swarm PUBLIC jarvis_pheromind jarvis_endocrine)

if(NOT JARVIS_SKIP_ORGAN_TESTS)
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

    add_executable(test_swarm tests/test_swarm.cpp)
    target_link_libraries(test_swarm PRIVATE jarvis_swarm Catch2::Catch2WithMain)
    add_test(NAME test_swarm COMMAND test_swarm)

    add_executable(test_swarm_oracle tests/test_swarm_oracle.cpp)
    target_link_libraries(test_swarm_oracle PRIVATE jarvis_swarm Catch2::Catch2WithMain nlohmann_json::nlohmann_json)
    target_compile_definitions(test_swarm_oracle PRIVATE
        ORACLE_DIR="/Users/rbhanson/research/oracle/swarm"
    )
    add_test(NAME test_swarm_oracle COMMAND test_swarm_oracle)
endif()
