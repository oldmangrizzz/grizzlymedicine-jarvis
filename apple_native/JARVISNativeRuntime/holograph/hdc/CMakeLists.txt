cmake_minimum_required(VERSION 3.20)
project(jarvis_holograph_hdc VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# ── Compiler flags ────────────────────────────────────────────────────────────
# Disable FP contraction so float32 arithmetic matches numpy byte-for-byte.
if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang|AppleClang")
    add_compile_options(
        -ffp-contract=off
        -fno-unsafe-math-optimizations
        -O2
    )
    # ARM NEON (Apple Silicon)
    if(CMAKE_SYSTEM_PROCESSOR MATCHES "arm64|aarch64")
        add_compile_options(-march=native)
    endif()
    # x86_64 AVX2
    if(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64")
        add_compile_options(-march=native -mavx2 -mpopcnt)
    endif()
endif()

# ── Static library: jarvis_hdc ────────────────────────────────────────────────
add_library(jarvis_holograph_hdc STATIC
    hdc.cpp
    hdc_real.cpp
    hdc_ternary.cpp
    hdc_hierarchy.cpp
)
add_library(jarvis::holograph_hdc ALIAS jarvis_holograph_hdc)

target_include_directories(jarvis_holograph_hdc PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
    $<INSTALL_INTERFACE:include>
)

target_compile_features(jarvis_holograph_hdc PUBLIC cxx_std_20)

if(NOT JARVIS_SKIP_ORGAN_TESTS)
    # ── Catch2 v3 via FetchContent ────────────────────────────────────────────────
    include(FetchContent)

    # Re-use already-fetched Catch2 if endocrine already pulled it.
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

    # ── Oracle directory — passed to oracle / benchmark tests ─────────────────────
    if(NOT DEFINED HDC_ORACLE_DIR)
        set(HDC_ORACLE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../oracle/holograph"
            CACHE PATH "Path to oracle/holograph directory")
    endif()

    # ── Tests ─────────────────────────────────────────────────────────────────────
    foreach(test_name
        test_hdc
        test_oracle_equivalence
        test_recall_benchmark
    )
        set(target_name holograph_hdc_${test_name})
        add_executable(${target_name} tests/${test_name}.cpp)
        target_link_libraries(${target_name}
            PRIVATE jarvis_holograph_hdc Catch2::Catch2WithMain
        )
        target_compile_definitions(${target_name} PRIVATE
            HDC_ORACLE_DIR="${HDC_ORACLE_DIR}"
        )
        catch_discover_tests(${target_name})
    endforeach()
endif()
