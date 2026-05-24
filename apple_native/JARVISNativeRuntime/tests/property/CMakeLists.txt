cmake_minimum_required(VERSION 3.20)
project(jarvis_phase7_property_tests LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POLICY_VERSION_MINIMUM 3.5)

include(FetchContent)
include(CTest)

# SHA-pinned 2026-05-24; Catch2 v3.5.4 → b5373dadca40b7edc8570cf9470b9b1cb1934d40
FetchContent_Declare(
    Catch2
    URL      https://github.com/catchorg/Catch2/archive/b5373dadca40b7edc8570cf9470b9b1cb1934d40.tar.gz
    URL_HASH SHA256=97afc182353da6f3a54afede6540f54f545ee6c2f73023a64688d2a9307e850c
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
FetchContent_MakeAvailable(Catch2)

set(RC_ENABLE_CATCH OFF CACHE BOOL "" FORCE)
set(RC_ENABLE_GTEST OFF CACHE BOOL "" FORCE)
set(RC_ENABLE_GMOCK OFF CACHE BOOL "" FORCE)
set(RC_ENABLE_BOOST OFF CACHE BOOL "" FORCE)
set(RC_ENABLE_TESTS OFF CACHE BOOL "" FORCE)
# SHA-pinned 2026-05-24; rapidcheck (adding URL_HASH to existing SHA pin) → ff6af6fc683159deb51c543b065eba14dfcf329b
FetchContent_Declare(
    rapidcheck
    URL      https://github.com/emil-e/rapidcheck/archive/ff6af6fc683159deb51c543b065eba14dfcf329b.tar.gz
    URL_HASH SHA256=f978132be070d6e0ae0be097c6cd5b65edeedf19f78c57158b2c43ffa412323d
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
FetchContent_MakeAvailable(rapidcheck)

set(RC_DEFAULT_MAX_SUCCESS 1000 CACHE STRING "RapidCheck successful generated cases per property")
set(_PROPERTY_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../..)

add_library(jarvis_property_endocrine STATIC
    ${_PROPERTY_ROOT}/endocrine/endocrine.cpp
    ${_PROPERTY_ROOT}/endocrine/endocannabinoid.cpp
)
target_include_directories(jarvis_property_endocrine PUBLIC ${_PROPERTY_ROOT}/endocrine)
target_compile_features(jarvis_property_endocrine PUBLIC cxx_std_20)
target_compile_options(jarvis_property_endocrine PRIVATE -ffp-contract=off -fno-unsafe-math-optimizations)

function(add_jarvis_property_test target)
    add_executable(${target} ${ARGN})
    target_compile_features(${target} PRIVATE cxx_std_20)
    target_compile_options(${target} PRIVATE -ffp-contract=off -fno-unsafe-math-optimizations)
    target_link_libraries(${target} PRIVATE Catch2::Catch2WithMain rapidcheck)
    add_test(NAME ${target} COMMAND ${target})
    set_tests_properties(${target} PROPERTIES
        LABELS property
        ENVIRONMENT "RC_PARAMS=max_success=${RC_DEFAULT_MAX_SUCCESS}"
    )
endfunction()

add_jarvis_property_test(endocrine_property_tests endocrine_property_tests.cpp)
target_link_libraries(endocrine_property_tests PRIVATE jarvis_property_endocrine)

add_jarvis_property_test(endocannabinoid_property_tests endocannabinoid_property_tests.cpp)
target_link_libraries(endocannabinoid_property_tests PRIVATE jarvis_property_endocrine)

foreach(stub IN ITEMS hdc pheromind swarm hmem sage)
    add_jarvis_property_test(${stub}_property_stub ${stub}_property_stub.cpp)
endforeach()
