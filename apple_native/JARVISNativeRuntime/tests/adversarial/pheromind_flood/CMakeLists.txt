cmake_minimum_required(VERSION 3.20)
project(jarvis_pheromind_flood_adversarial LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

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

set(JARVIS_PF_SANITIZER "address-undefined" CACHE STRING "Sanitizer build: address-undefined | thread | none")
set_property(CACHE JARVIS_PF_SANITIZER PROPERTY STRINGS address-undefined thread none)

set(RUNTIME_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../../..)

add_library(jarvis_pheromind_flood_runtime STATIC
    ${RUNTIME_ROOT}/endocrine/endocrine.cpp
    ${RUNTIME_ROOT}/pheromind/pheromind.cpp
)
target_include_directories(jarvis_pheromind_flood_runtime PUBLIC
    ${RUNTIME_ROOT}/endocrine
    ${RUNTIME_ROOT}/pheromind
)
target_compile_features(jarvis_pheromind_flood_runtime PUBLIC cxx_std_20)

target_compile_options(jarvis_pheromind_flood_runtime PRIVATE
    -fno-omit-frame-pointer
    -ffp-contract=off
    -fno-unsafe-math-optimizations
    -g
    -O1
)

add_executable(pheromind_flood_adversarial
    pheromind_flood_adversarial.cpp
)
target_link_libraries(pheromind_flood_adversarial PRIVATE
    jarvis_pheromind_flood_runtime
    Catch2::Catch2WithMain
)
target_compile_options(pheromind_flood_adversarial PRIVATE
    -fno-omit-frame-pointer
    -ffp-contract=off
    -fno-unsafe-math-optimizations
    -g
    -O1
)

set(_san_flags "")
if(JARVIS_PF_SANITIZER STREQUAL "address-undefined")
    set(_san_flags -fsanitize=address,undefined)
elseif(JARVIS_PF_SANITIZER STREQUAL "thread")
    set(_san_flags -fsanitize=thread)
elseif(NOT JARVIS_PF_SANITIZER STREQUAL "none")
    message(FATAL_ERROR "JARVIS_PF_SANITIZER must be address-undefined, thread, or none")
endif()

if(_san_flags)
    target_compile_options(jarvis_pheromind_flood_runtime PRIVATE ${_san_flags})
    target_link_options(jarvis_pheromind_flood_runtime PRIVATE ${_san_flags})
    target_compile_options(pheromind_flood_adversarial PRIVATE ${_san_flags})
    target_link_options(pheromind_flood_adversarial PRIVATE ${_san_flags})
endif()

catch_discover_tests(pheromind_flood_adversarial
    PROPERTIES
        LABELS "adversarial;pheromind;phase7"
        TIMEOUT 180
        ENVIRONMENT "ASAN_OPTIONS=abort_on_error=1:detect_leaks=0;UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1;TSAN_OPTIONS=halt_on_error=1"
)
