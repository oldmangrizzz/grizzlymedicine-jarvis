cmake_minimum_required(VERSION 3.20)
project(jarvis_endocrine VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# ---- static library ----
add_library(jarvis_endocrine STATIC
    endocrine.cpp
    endocannabinoid.cpp
)
target_include_directories(jarvis_endocrine PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
    $<INSTALL_INTERFACE:include>
)

if(NOT JARVIS_SKIP_ORGAN_TESTS)
    # ---- Catch2 v3 via FetchContent ----
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

    # ---- test executables ----
    foreach(test_name
        test_endocrine
        test_endocannabinoid
        test_oracle_equivalence
    )
        add_executable(${test_name} tests/${test_name}.cpp)
        target_link_libraries(${test_name}
            PRIVATE jarvis_endocrine Catch2::Catch2WithMain
        )
        # Pass oracle directory to oracle test
        if(test_name STREQUAL "test_oracle_equivalence")
            target_compile_definitions(${test_name} PRIVATE
                ORACLE_DIR="/Users/rbhanson/research/oracle/endocrine"
            )
        endif()
        catch_discover_tests(${test_name})
    endforeach()
endif()
