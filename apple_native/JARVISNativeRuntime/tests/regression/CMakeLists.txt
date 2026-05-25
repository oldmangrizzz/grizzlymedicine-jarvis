cmake_minimum_required(VERSION 3.20)
project(jarvis_oracle_regression LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(CTest)

set(JARVIS_ORACLE_ROOT "/Users/rbhanson/research/oracle"
    CACHE PATH "Root directory containing Python oracle captures")
set(JARVIS_REGRESSION_OUTPUT_DIR "${CMAKE_CURRENT_BINARY_DIR}/reports"
    CACHE PATH "Directory for regression JSON and human reports")

set(JARVIS_REGRESSION_ENDOCRINE_ABS_TOL "1e-9" CACHE STRING "Endocrine scalar absolute drift threshold")
set(JARVIS_REGRESSION_ECS_ABS_TOL "1e-9" CACHE STRING "Endocannabinoid scalar absolute drift threshold")
set(JARVIS_REGRESSION_ECS_RAW_ABS_TOL "1e-6" CACHE STRING "Endocannabinoid raw AEA/2-AG threshold for 6dp oracle fields")
set(JARVIS_REGRESSION_HDC_ABS_TOL "0" CACHE STRING "HDC/HoloGraph exact-byte default threshold for future C++ port")

file(MAKE_DIRECTORY "${JARVIS_REGRESSION_OUTPUT_DIR}")

if(NOT TARGET jarvis_endocrine)
    add_subdirectory(
        ${CMAKE_CURRENT_SOURCE_DIR}/../../endocrine
        ${CMAKE_CURRENT_BINARY_DIR}/endocrine_dep
    )
endif()

add_executable(jarvis_oracle_regression
    regression_oracle.cpp
)
target_include_directories(jarvis_oracle_regression PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/../../endocrine
)
target_link_libraries(jarvis_oracle_regression PRIVATE jarvis_endocrine)
target_compile_features(jarvis_oracle_regression PRIVATE cxx_std_20)
target_compile_definitions(jarvis_oracle_regression PRIVATE
    JARVIS_ORACLE_ROOT="${JARVIS_ORACLE_ROOT}"
    JARVIS_REGRESSION_OUTPUT_DIR="${JARVIS_REGRESSION_OUTPUT_DIR}"
    JARVIS_REGRESSION_ENDOCRINE_ABS_TOL=${JARVIS_REGRESSION_ENDOCRINE_ABS_TOL}
    JARVIS_REGRESSION_ECS_ABS_TOL=${JARVIS_REGRESSION_ECS_ABS_TOL}
    JARVIS_REGRESSION_ECS_RAW_ABS_TOL=${JARVIS_REGRESSION_ECS_RAW_ABS_TOL}
    JARVIS_REGRESSION_HDC_ABS_TOL=${JARVIS_REGRESSION_HDC_ABS_TOL}
)

add_test(NAME jarvis_oracle_regression COMMAND jarvis_oracle_regression)
set_tests_properties(jarvis_oracle_regression PROPERTIES
    LABELS "regression"
    WORKING_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}"
)

add_executable(regression_run_all run_all.cpp)
target_compile_features(regression_run_all PRIVATE cxx_std_20)
