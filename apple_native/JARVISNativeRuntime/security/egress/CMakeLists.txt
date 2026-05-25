# CMakeLists.txt — security/egress
# JARVIS digital-personhood project — GMRI
#
# Builds the jarvis_egress static library and its Catch2 v3 test suite.
#
# Depends on:
#   jarvis_redacting_logger  (defined in logging/CMakeLists.txt)
#   OpenSSL::Crypto          (HMAC, SHA-256, RAND_bytes)
#   Threads::Threads         (std::mutex in EgressAudit)
#
# Parent CMakeLists.txt must add_subdirectory(logging) BEFORE this file.

cmake_minimum_required(VERSION 3.20)

# ── Dependencies ──────────────────────────────────────────────────────────────

find_package(OpenSSL REQUIRED)
find_package(Threads REQUIRED)

# jarvis_redacting_logger — defined in logging/ when building from the parent.
# When building egress standalone (e.g. for isolated CI), pull it in here.
if(NOT TARGET jarvis_redacting_logger)
    set(_logging_src ${CMAKE_CURRENT_SOURCE_DIR}/../../logging)
    if(IS_DIRECTORY ${_logging_src})
        add_subdirectory(${_logging_src}
                         ${CMAKE_CURRENT_BINARY_DIR}/logging)
    else()
        message(FATAL_ERROR
            "jarvis_redacting_logger target not found and "
            "${_logging_src} does not exist.  "
            "Build from JARVISNativeRuntime/ or ensure logging/ is present.")
    endif()
endif()

# ── jarvis_egress library ─────────────────────────────────────────────────────

add_library(jarvis_egress STATIC
    egress_allowlist.cpp
    egress_filter.cpp
    egress_audit.cpp
)

target_compile_features(jarvis_egress PUBLIC cxx_std_20)

target_compile_options(jarvis_egress PRIVATE
    -Wall
    -Wextra
    -Wpedantic
    -Wno-unused-parameter
    $<$<CONFIG:Release>:-O2>
    $<$<CONFIG:Debug>:-g -O0>
)

# Public include: security/egress/ itself.
# Also expose security/ parent so #include "../pins_embedded.h" resolves.
target_include_directories(jarvis_egress
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}        # egress/*.h
        ${CMAKE_CURRENT_SOURCE_DIR}/..     # security/pins_embedded.h
)

target_link_libraries(jarvis_egress
    PUBLIC
        jarvis_redacting_logger
        OpenSSL::Crypto
        Threads::Threads
)

# ── Tests ─────────────────────────────────────────────────────────────────────

find_package(Catch2 3 REQUIRED)
include(CTest)

# test_egress_allowlist
add_executable(test_egress_allowlist
    tests/test_egress_allowlist.cpp
)
target_link_libraries(test_egress_allowlist
    PRIVATE jarvis_egress Catch2::Catch2WithMain
)
target_compile_features(test_egress_allowlist PRIVATE cxx_std_20)
add_test(
    NAME    test_egress_allowlist
    COMMAND test_egress_allowlist
)

# test_egress_filter
add_executable(test_egress_filter
    tests/test_egress_filter.cpp
)
target_link_libraries(test_egress_filter
    PRIVATE jarvis_egress Catch2::Catch2WithMain
)
target_compile_features(test_egress_filter PRIVATE cxx_std_20)
add_test(
    NAME    test_egress_filter
    COMMAND test_egress_filter
)

# test_egress_audit
add_executable(test_egress_audit
    tests/test_egress_audit.cpp
)
target_link_libraries(test_egress_audit
    PRIVATE jarvis_egress Catch2::Catch2WithMain
)
target_compile_features(test_egress_audit PRIVATE cxx_std_20)
add_test(
    NAME    test_egress_audit
    COMMAND test_egress_audit
)
