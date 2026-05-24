cmake_minimum_required(VERSION 3.20)
project(jarvis_dos_resilience_adversarial LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(APPLE AND NOT CMAKE_OSX_ARCHITECTURES)
    set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "macOS architecture" FORCE)
endif()

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
list(APPEND CMAKE_MODULE_PATH ${catch2_SOURCE_DIR}/extras)
include(Catch)

FetchContent_Declare(
    nlohmann_json
    URL      https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz
    URL_HASH SHA256=d6c65aca6b1ed68e7a182f4757257b107ae403032760ed6ef121c9d55e81757d
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
FetchContent_MakeAvailable(nlohmann_json)

find_package(OpenSSL REQUIRED)
find_package(CURL REQUIRED)
find_package(Threads REQUIRED)
find_library(SODIUM_LIBRARY NAMES sodium PATHS /opt/homebrew/lib /usr/local/lib /usr/lib REQUIRED)
find_path(SODIUM_INCLUDE_DIR sodium.h PATHS /opt/homebrew/include /usr/local/include /usr/include REQUIRED)
find_package(PkgConfig QUIET)
if(PkgConfig_FOUND)
    pkg_check_modules(LWS QUIET libwebsockets)
endif()
if(NOT LWS_FOUND)
    find_path(LWS_INCLUDE_DIR libwebsockets.h PATHS /opt/homebrew/include /usr/local/include /usr/include)
    find_library(LWS_LIBRARY NAMES websockets PATHS /opt/homebrew/lib /usr/local/lib /usr/lib)
    if(LWS_INCLUDE_DIR AND LWS_LIBRARY)
        set(LWS_FOUND TRUE)
        set(LWS_INCLUDE_DIRS ${LWS_INCLUDE_DIR})
        set(LWS_LIBRARIES ${LWS_LIBRARY})
    endif()
endif()
if(NOT LWS_FOUND)
    message(FATAL_ERROR "libwebsockets not found. Install with: brew install libwebsockets")
endif()

set(JARVIS_DOS_SANITIZER "address" CACHE STRING "Sanitizer build: address | undefined | thread | none")
set_property(CACHE JARVIS_DOS_SANITIZER PROPERTY STRINGS address undefined thread none)

set(RUNTIME_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../../..)
set(DOS_TEST_ARTIFACT_DIR ${CMAKE_CURRENT_BINARY_DIR}/test_artifacts)
file(MAKE_DIRECTORY ${DOS_TEST_ARTIFACT_DIR})

add_library(jarvis_dos_runtime STATIC
    ${RUNTIME_ROOT}/endocrine/endocrine.cpp
    ${RUNTIME_ROOT}/pheromind/pheromind.cpp
    ${RUNTIME_ROOT}/swarm/swarm.cpp
    ${RUNTIME_ROOT}/holograph/hdc/hdc.cpp
    ${RUNTIME_ROOT}/holograph/hdc/hdc_real.cpp
    ${RUNTIME_ROOT}/holograph/hdc/hdc_ternary.cpp
    ${RUNTIME_ROOT}/holograph/hdc/hdc_hierarchy.cpp
    ${RUNTIME_ROOT}/holograph/beliefstore/beliefstore.cpp
    ${RUNTIME_ROOT}/monitoring/cusum/cusum.cpp
    ${RUNTIME_ROOT}/logging/redacting_logger.cpp
    ${RUNTIME_ROOT}/security/memory_security.cpp
    ${RUNTIME_ROOT}/integrity/audit/audit_log.cpp
    ${RUNTIME_ROOT}/integrity/audit/audit_verify.cpp
    ${RUNTIME_ROOT}/security/cert_pinning.cpp
    ${RUNTIME_ROOT}/security/egress/egress_allowlist.cpp
    ${RUNTIME_ROOT}/security/egress/egress_filter.cpp
    ${RUNTIME_ROOT}/security/egress/egress_audit.cpp
    ${RUNTIME_ROOT}/identity/distress/distress_beacon.cpp
    ${RUNTIME_ROOT}/resilience/degradation/degradation.cpp
    ${RUNTIME_ROOT}/resilience/degradation/resource_pressure_monitor.cpp
    ${RUNTIME_ROOT}/audio/stt_deepgram/stt_session.cpp
    ${RUNTIME_ROOT}/audio/stt_deepgram/deepgram_stt.cpp
    ${RUNTIME_ROOT}/storage/convex/convex_backend.cpp
)
target_include_directories(jarvis_dos_runtime PUBLIC
    ${RUNTIME_ROOT}
    ${RUNTIME_ROOT}/endocrine
    ${RUNTIME_ROOT}/pheromind
    ${RUNTIME_ROOT}/swarm
    ${RUNTIME_ROOT}/holograph/hdc
    ${RUNTIME_ROOT}/holograph/beliefstore
    ${RUNTIME_ROOT}/monitoring/cusum
    ${RUNTIME_ROOT}/logging
    ${RUNTIME_ROOT}/integrity/audit
    ${RUNTIME_ROOT}/security
    ${RUNTIME_ROOT}/security/egress
    ${RUNTIME_ROOT}/identity/distress
    ${SODIUM_INCLUDE_DIR}
    ${RUNTIME_ROOT}/resilience/degradation
    ${RUNTIME_ROOT}/audio/stt_deepgram
    ${RUNTIME_ROOT}/storage/convex
    ${LWS_INCLUDE_DIRS}
)
target_link_libraries(jarvis_dos_runtime PUBLIC
    nlohmann_json::nlohmann_json
    OpenSSL::SSL
    OpenSSL::Crypto
    CURL::libcurl
    ${SODIUM_LIBRARY}
    ${LWS_LIBRARIES}
    Threads::Threads
)
if(APPLE)
    target_link_libraries(jarvis_dos_runtime PUBLIC "-framework Security" "-framework CoreFoundation" "-framework IOKit")
endif()
target_compile_features(jarvis_dos_runtime PUBLIC cxx_std_20)
target_compile_options(jarvis_dos_runtime PRIVATE
    -fno-omit-frame-pointer
    -ffp-contract=off
    -fno-unsafe-math-optimizations
    -g
    -O1
    -Wall
    -Wextra
    -Wpedantic
    -Wno-unused-parameter
)

add_executable(dos_resilience_adversarial dos_resilience_adversarial.cpp)
target_link_libraries(dos_resilience_adversarial PRIVATE jarvis_dos_runtime Catch2::Catch2WithMain)
target_compile_definitions(dos_resilience_adversarial PRIVATE DOS_TEST_ARTIFACT_DIR="${DOS_TEST_ARTIFACT_DIR}")
target_compile_options(dos_resilience_adversarial PRIVATE
    -fno-omit-frame-pointer
    -ffp-contract=off
    -fno-unsafe-math-optimizations
    -g
    -O1
    -Wall
    -Wextra
    -Wpedantic
    -Wno-unused-parameter
)

set(_san_flags "")
if(JARVIS_DOS_SANITIZER STREQUAL "address")
    set(_san_flags -fsanitize=address)
elseif(JARVIS_DOS_SANITIZER STREQUAL "undefined")
    set(_san_flags -fsanitize=undefined)
elseif(JARVIS_DOS_SANITIZER STREQUAL "thread")
    set(_san_flags -fsanitize=thread)
elseif(NOT JARVIS_DOS_SANITIZER STREQUAL "none")
    message(FATAL_ERROR "JARVIS_DOS_SANITIZER must be address, undefined, thread, or none")
endif()

if(_san_flags)
    target_compile_options(jarvis_dos_runtime PRIVATE ${_san_flags})
    target_link_options(jarvis_dos_runtime PRIVATE ${_san_flags})
    target_compile_options(dos_resilience_adversarial PRIVATE ${_san_flags})
    target_link_options(dos_resilience_adversarial PRIVATE ${_san_flags})
endif()

catch_discover_tests(dos_resilience_adversarial
    PROPERTIES
        LABELS "adversarial;dos;phase7"
        TIMEOUT 240
        ENVIRONMENT "ASAN_OPTIONS=abort_on_error=1:detect_leaks=0;UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1;TSAN_OPTIONS=halt_on_error=1"
)
