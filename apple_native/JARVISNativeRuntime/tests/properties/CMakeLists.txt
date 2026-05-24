# Property-based tests for JARVIS organ modules.
# Fetches RapidCheck (pure C++, no Rust) and Catch2 v3.
#
# Standalone build (from this directory):
#   cmake -B build -S .
#   cmake --build build
#   ctest --test-dir build -L property
#
# Integrated build (from JARVISNativeRuntime parent):
#   cmake -B build -S .  [parent will add_subdirectory here]
#
# Override case count: RC_PARAMS="checks=N" ctest -L property

cmake_minimum_required(VERSION 3.20)
project(jarvis_property_tests LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(FetchContent)
include(CTest)

# ── Catch2 v3 (reuse if already fetched by parent/sibling) ───────────────────
# SHA-pinned 2026-05-24; Catch2 v3.5.4 → b5373dadca40b7edc8570cf9470b9b1cb1934d40
FetchContent_Declare(
    Catch2
    URL      https://github.com/catchorg/Catch2/archive/b5373dadca40b7edc8570cf9470b9b1cb1934d40.tar.gz
    URL_HASH SHA256=97afc182353da6f3a54afede6540f54f545ee6c2f73023a64688d2a9307e850c
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
FetchContent_MakeAvailable(Catch2)
list(APPEND CMAKE_MODULE_PATH ${catch2_SOURCE_DIR}/extras)
include(Catch)

# ── RapidCheck — pure C++20, no Rust required ─────────────────────────────────
# SHA-pinned 2026-05-24; rapidcheck (adding URL_HASH to existing SHA pin) → ff6af6fc683159deb51c543b065eba14dfcf329b
FetchContent_Declare(
    rapidcheck
    URL      https://github.com/emil-e/rapidcheck/archive/ff6af6fc683159deb51c543b065eba14dfcf329b.tar.gz
    URL_HASH SHA256=f978132be070d6e0ae0be097c6cd5b65edeedf19f78c57158b2c43ffa412323d
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
set(RC_ENABLE_CATCH      ON  CACHE BOOL "" FORCE)
set(RC_ENABLE_GTEST     OFF CACHE BOOL "" FORCE)
set(RC_ENABLE_BOOST     OFF CACHE BOOL "" FORCE)
set(RC_ENABLE_TESTS     OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(rapidcheck)

# ── Default test case count (configurable via RC_PARAMS=checks=N) ─────────────
set(RC_DEFAULT_CHECKS 1000 CACHE STRING "RapidCheck cases per property (default)")

# ── Helper macro: define a property test executable ──────────────────────────
macro(add_property_exe name)
    add_executable(${name} ${name}.cpp)
    target_compile_features(${name} PRIVATE cxx_std_20)
    target_compile_options(${name} PRIVATE
        -ffp-contract=off
        -fno-unsafe-math-optimizations
    )
    if(CMAKE_SYSTEM_PROCESSOR MATCHES "arm64|aarch64")
        target_compile_options(${name} PRIVATE -march=native)
    endif()
    catch_discover_tests(${name}
        PROPERTIES
            LABELS "property"
            ENVIRONMENT "RC_PARAMS=checks=${RC_DEFAULT_CHECKS}"
    )
endmacro()

# ── Organ libraries: use existing targets if present (integrated build),
#    otherwise build from source (standalone build) ──────────────────────────
set(_PROP_SRC_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../..)

if(NOT TARGET jarvis_endocrine)
    add_library(_prop_endocrine STATIC
        ${_PROP_SRC_ROOT}/endocrine/endocrine.cpp
        ${_PROP_SRC_ROOT}/endocrine/endocannabinoid.cpp
    )
    target_include_directories(_prop_endocrine PUBLIC
        ${_PROP_SRC_ROOT}/endocrine
    )
    target_compile_features(_prop_endocrine PUBLIC cxx_std_20)
    target_compile_options(_prop_endocrine PRIVATE
        -ffp-contract=off -fno-unsafe-math-optimizations
    )
    set(_ENDOCRINE_LIB _prop_endocrine)
else()
    set(_ENDOCRINE_LIB jarvis_endocrine)
endif()

if(NOT TARGET jarvis_hdc)
    add_library(_prop_hdc STATIC
        ${_PROP_SRC_ROOT}/hdc/hdc.cpp
        ${_PROP_SRC_ROOT}/hdc/hdc_real.cpp
        ${_PROP_SRC_ROOT}/hdc/hdc_ternary.cpp
        ${_PROP_SRC_ROOT}/hdc/hdc_hierarchy.cpp
    )
    target_include_directories(_prop_hdc PUBLIC
        ${_PROP_SRC_ROOT}/hdc
    )
    target_compile_features(_prop_hdc PUBLIC cxx_std_20)
    target_compile_options(_prop_hdc PRIVATE
        -ffp-contract=off -fno-unsafe-math-optimizations
    )
    if(CMAKE_SYSTEM_PROCESSOR MATCHES "arm64|aarch64")
        target_compile_options(_prop_hdc PRIVATE -march=native)
    endif()
    set(_HDC_LIB _prop_hdc)
else()
    set(_HDC_LIB jarvis_hdc)
endif()

# ── Endocrine properties (P1-P7) ─────────────────────────────────────────────
add_property_exe(endocrine_properties)
target_link_libraries(endocrine_properties PRIVATE
    ${_ENDOCRINE_LIB}
    Catch2::Catch2WithMain
    rapidcheck
    rapidcheck_catch
)

# ── Endocannabinoid properties (P8-P12) ──────────────────────────────────────
add_property_exe(endocannabinoid_properties)
target_link_libraries(endocannabinoid_properties PRIVATE
    ${_ENDOCRINE_LIB}
    Catch2::Catch2WithMain
    rapidcheck
    rapidcheck_catch
)

# ── Pheromind properties (P13-P15) — stub: module not yet ported ─────────────
add_property_exe(pheromind_properties)
target_link_libraries(pheromind_properties PRIVATE
    Catch2::Catch2WithMain
    rapidcheck
    rapidcheck_catch
)

# ── HDC properties (P16-P19) ─────────────────────────────────────────────────
add_property_exe(hdc_properties)
target_link_libraries(hdc_properties PRIVATE
    ${_HDC_LIB}
    Catch2::Catch2WithMain
    rapidcheck
    rapidcheck_catch
)

# ── BeliefStore properties — stub: module not yet present ────────────────────
add_property_exe(beliefstore_properties)
target_link_libraries(beliefstore_properties PRIVATE
    Catch2::Catch2WithMain
    rapidcheck
    rapidcheck_catch
)
