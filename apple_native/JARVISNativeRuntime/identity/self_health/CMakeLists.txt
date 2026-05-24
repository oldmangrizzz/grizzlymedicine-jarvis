cmake_minimum_required(VERSION 3.20)

if(APPLE AND NOT CMAKE_OSX_ARCHITECTURES)
    set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "Build macOS arm64 by default" FORCE)
endif()

project(jarvis_identity_self_health VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

function(jarvis_add_dep dir bindir)
    set(_prev ${JARVIS_SKIP_ORGAN_TESTS})
    set(JARVIS_SKIP_ORGAN_TESTS ON CACHE BOOL "" FORCE)
    add_subdirectory(${dir} ${bindir})
    set(JARVIS_SKIP_ORGAN_TESTS ${_prev} CACHE BOOL "" FORCE)
endfunction()

if(NOT TARGET jarvis_endocrine)
    jarvis_add_dep(${CMAKE_CURRENT_SOURCE_DIR}/../../endocrine ${CMAKE_CURRENT_BINARY_DIR}/endocrine_build)
endif()
if(NOT TARGET jarvis_pheromind)
    jarvis_add_dep(${CMAKE_CURRENT_SOURCE_DIR}/../../pheromind ${CMAKE_CURRENT_BINARY_DIR}/pheromind_build)
endif()
if(NOT TARGET jarvis_swarm)
    jarvis_add_dep(${CMAKE_CURRENT_SOURCE_DIR}/../../swarm ${CMAKE_CURRENT_BINARY_DIR}/swarm_build)
endif()
if(NOT TARGET jarvis_holograph_hmem)
    jarvis_add_dep(${CMAKE_CURRENT_SOURCE_DIR}/../../holograph/hmem ${CMAKE_CURRENT_BINARY_DIR}/hmem_build)
endif()
if(NOT TARGET jarvis_cusum)
    jarvis_add_dep(${CMAKE_CURRENT_SOURCE_DIR}/../../monitoring/cusum ${CMAKE_CURRENT_BINARY_DIR}/cusum_build)
endif()
if(NOT TARGET jarvis_audit)
    add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../integrity/audit ${CMAKE_CURRENT_BINARY_DIR}/audit_build)
endif()
if(NOT TARGET jarvis_resilience_degradation)
    add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../resilience/degradation ${CMAKE_CURRENT_BINARY_DIR}/degradation_build)
endif()

add_library(jarvis_identity_self_health STATIC self_health.cpp)
add_library(jarvis::identity_self_health ALIAS jarvis_identity_self_health)

target_include_directories(jarvis_identity_self_health PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
    $<INSTALL_INTERFACE:include>
)
target_link_libraries(jarvis_identity_self_health PUBLIC
    jarvis_endocrine
    jarvis_pheromind
    jarvis_swarm
    jarvis_holograph_hmem
    jarvis_cusum
    jarvis_resilience_degradation
    jarvis_audit
)
target_compile_features(jarvis_identity_self_health PUBLIC cxx_std_20)

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
    include(CTest)

    set(SELF_HEALTH_TEST_ARTIFACT_DIR "${CMAKE_CURRENT_BINARY_DIR}/test_artifacts")
    file(MAKE_DIRECTORY "${SELF_HEALTH_TEST_ARTIFACT_DIR}")

    add_executable(test_self_health tests/test_self_health.cpp)
    target_link_libraries(test_self_health PRIVATE jarvis_identity_self_health Catch2::Catch2WithMain)
    target_compile_definitions(test_self_health PRIVATE
        TEST_ARTIFACT_DIR="${SELF_HEALTH_TEST_ARTIFACT_DIR}"
    )
    add_test(NAME test_self_health COMMAND test_self_health)
endif()
