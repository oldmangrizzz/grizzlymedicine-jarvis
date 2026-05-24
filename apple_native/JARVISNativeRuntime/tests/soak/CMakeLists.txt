cmake_minimum_required(VERSION 3.20)
project(jarvis_phase7_soak LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(CTest)
include(FetchContent)

function(jarvis_soak_add_dep dir bindir)
    set(_prev_skip ${JARVIS_SKIP_ORGAN_TESTS})
    set(JARVIS_SKIP_ORGAN_TESTS ON CACHE BOOL "" FORCE)
    add_subdirectory(${dir} ${bindir})
    set(JARVIS_SKIP_ORGAN_TESTS ${_prev_skip} CACHE BOOL "" FORCE)
endfunction()

set(_RUNTIME_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../..)

if(NOT TARGET jarvis_endocrine)
    jarvis_soak_add_dep(${_RUNTIME_ROOT}/endocrine ${CMAKE_CURRENT_BINARY_DIR}/endocrine_build)
endif()
if(NOT TARGET jarvis_pheromind)
    jarvis_soak_add_dep(${_RUNTIME_ROOT}/pheromind ${CMAKE_CURRENT_BINARY_DIR}/pheromind_build)
endif()
if(NOT TARGET jarvis_swarm)
    jarvis_soak_add_dep(${_RUNTIME_ROOT}/swarm ${CMAKE_CURRENT_BINARY_DIR}/swarm_build)
endif()
if(NOT TARGET jarvis_holograph_sage)
    jarvis_soak_add_dep(${_RUNTIME_ROOT}/holograph/sage ${CMAKE_CURRENT_BINARY_DIR}/sage_build)
endif()
if(NOT TARGET jarvis_audit)
    add_subdirectory(${_RUNTIME_ROOT}/integrity/audit ${CMAKE_CURRENT_BINARY_DIR}/audit_build)
endif()
if(NOT TARGET jarvis_resilience_degradation)
    add_subdirectory(${_RUNTIME_ROOT}/resilience/degradation ${CMAKE_CURRENT_BINARY_DIR}/degradation_build)
endif()

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

add_library(jarvis_soak_core STATIC soak_harness.cpp)
target_compile_features(jarvis_soak_core PUBLIC cxx_std_20)
target_include_directories(jarvis_soak_core PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${_RUNTIME_ROOT}/endocrine
    ${_RUNTIME_ROOT}/pheromind
    ${_RUNTIME_ROOT}/swarm
    ${_RUNTIME_ROOT}/holograph/hdc
    ${_RUNTIME_ROOT}/holograph/beliefstore
    ${_RUNTIME_ROOT}/holograph/hmem
    ${_RUNTIME_ROOT}/holograph/sage
    ${_RUNTIME_ROOT}/integrity/audit
    ${_RUNTIME_ROOT}/resilience/degradation
)
target_link_libraries(jarvis_soak_core PUBLIC
    jarvis_endocrine
    jarvis_pheromind
    jarvis_swarm
    jarvis_holograph_sage
    jarvis_holograph_hmem
    jarvis_holograph_beliefstore
    jarvis_holograph_hdc
    jarvis_audit
    jarvis_resilience_degradation
)
if(APPLE)
    target_link_libraries(jarvis_soak_core PUBLIC "-framework IOKit" "-framework CoreFoundation")
endif()

add_executable(jarvis_soak_runner soak_main.cpp)
target_link_libraries(jarvis_soak_runner PRIVATE jarvis_soak_core)

add_executable(jarvis_soak_catch soak_catch.cpp)
target_link_libraries(jarvis_soak_catch PRIVATE jarvis_soak_core Catch2::Catch2WithMain)

add_test(NAME jarvis_phase7_soak_1h COMMAND jarvis_soak_catch)
set_tests_properties(jarvis_phase7_soak_1h PROPERTIES
    LABELS "soak;phase7"
    TIMEOUT 3900
    ENVIRONMENT "JARVIS_SOAK_DURATION_SECONDS=3600;JARVIS_SOAK_FAULT_INTERVAL_SECONDS=300;JARVIS_SOAK_REPORT_DIR=${CMAKE_CURRENT_SOURCE_DIR};JARVIS_SOAK_AUDIT_DIR=${CMAKE_CURRENT_BINARY_DIR}/audit"
)
