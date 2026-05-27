cmake_minimum_required(VERSION 3.20)
project(jarvis_prompt_injection_adversarial LANGUAGES CXX)

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

set(RUNTIME_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../../..)

add_library(jarvis_prompt_injection_native STATIC
    ${RUNTIME_ROOT}/JARVISNativeRuntime.cpp
)
# R11l α.3.1: JARVISNativeRuntime now embeds jarvis::Endocrine via an
# include-the-cpp pattern in JARVISNativeRuntime.cpp itself; no extra source
# needs to be listed here. The endocrine.cpp translation unit is satisfied
# transitively at compile time (single TU, no separate object file).
target_include_directories(jarvis_prompt_injection_native PUBLIC ${RUNTIME_ROOT})
target_compile_features(jarvis_prompt_injection_native PUBLIC cxx_std_20)
target_compile_options(jarvis_prompt_injection_native PRIVATE -fno-omit-frame-pointer -ffp-contract=off -fno-unsafe-math-optimizations -g -O1)

add_executable(prompt_injection_adversarial
    prompt_injection_adversarial.cpp
)
target_link_libraries(prompt_injection_adversarial PRIVATE jarvis_prompt_injection_native Catch2::Catch2WithMain)
target_compile_options(prompt_injection_adversarial PRIVATE -fno-omit-frame-pointer -ffp-contract=off -fno-unsafe-math-optimizations -g -O1)

catch_discover_tests(prompt_injection_adversarial
    PROPERTIES
        LABELS "adversarial;prompt-injection;phase7;nation-state"
        TIMEOUT 180
)
