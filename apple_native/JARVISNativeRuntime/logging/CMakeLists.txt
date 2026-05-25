# CMakeLists.txt fragment for JARVISNativeRuntime/logging
#
# Include this file from the parent JARVISNativeRuntime CMakeLists.txt with:
#
#   add_subdirectory(logging)
#   target_link_libraries(JARVISNativeRuntime PRIVATE jarvis_redacting_logger)
#
# Or inline the two source files directly:
#
#   target_sources(JARVISNativeRuntime PRIVATE
#       logging/redacting_logger.cpp)
#   target_include_directories(JARVISNativeRuntime PRIVATE logging)

cmake_minimum_required(VERSION 3.21)

# ── Library ───────────────────────────────────────────────────────────────────

add_library(jarvis_redacting_logger STATIC
    redacting_logger.cpp
)

target_include_directories(jarvis_redacting_logger
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}   # exposes redacting_logger.h
)

target_compile_features(jarvis_redacting_logger PUBLIC cxx_std_20)

target_compile_options(jarvis_redacting_logger PRIVATE
    -Wall
    -Wextra
    -Wpedantic
    -Wno-unused-parameter
    $<$<CONFIG:Release>:-O2>
    $<$<CONFIG:Debug>:-g -O0>
)

# POSIX threads — required for std::thread on Linux (macOS links it automatically)
find_package(Threads REQUIRED)
target_link_libraries(jarvis_redacting_logger PUBLIC Threads::Threads)

if(APPLE)
    # Log directory uses ~/Library/Logs/JARVIS by default; no extra link deps.
    target_compile_definitions(jarvis_redacting_logger PRIVATE JARVIS_PLATFORM_APPLE=1)
endif()

# ── Tests ─────────────────────────────────────────────────────────────────────

if(CMAKE_PROJECT_NAME STREQUAL PROJECT_NAME OR JARVIS_ENABLE_TESTS)
    add_executable(jarvis_logger_tests
        tests/redacting_logger_tests.cpp
    )
    target_link_libraries(jarvis_logger_tests PRIVATE jarvis_redacting_logger)
    target_compile_features(jarvis_logger_tests PRIVATE cxx_std_20)

    # Register with CTest
    enable_testing()
    add_test(
        NAME    jarvis_logger_tests
        COMMAND jarvis_logger_tests
        WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
    )

    # ThreadSanitizer build (optional, enabled via -DJARVIS_TSAN=ON)
    if(JARVIS_TSAN)
        target_compile_options(jarvis_logger_tests PRIVATE -fsanitize=thread -g)
        target_link_options(jarvis_logger_tests PRIVATE -fsanitize=thread)
    endif()
endif()
