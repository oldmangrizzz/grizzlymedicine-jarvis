cmake_minimum_required(VERSION 3.20)
project(jarvis_voice_deepfake_adversarial LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(FetchContent)
include(CTest)

if(NOT TARGET Catch2::Catch2WithMain)
    # SHA-pinned 2026-05-24; Catch2 v3.5.4 → b5373dadca40b7edc8570cf9470b9b1cb1934d40
    FetchContent_Declare(
        Catch2
        URL      https://github.com/catchorg/Catch2/archive/b5373dadca40b7edc8570cf9470b9b1cb1934d40.tar.gz
        URL_HASH SHA256=97afc182353da6f3a54afede6540f54f545ee6c2f73023a64688d2a9307e850c
        DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    )
    FetchContent_MakeAvailable(Catch2)
    list(APPEND CMAKE_MODULE_PATH ${catch2_SOURCE_DIR}/extras)
endif()
include(Catch)

set(VOICE_DEEPFAKE_CORPUS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/corpus")

add_library(jarvis_voice_deepfake_gate STATIC voice_gate.cpp)
target_include_directories(jarvis_voice_deepfake_gate PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_features(jarvis_voice_deepfake_gate PUBLIC cxx_std_20)

add_executable(test_voice_deepfake test_voice_deepfake.cpp)
target_link_libraries(test_voice_deepfake PRIVATE jarvis_voice_deepfake_gate Catch2::Catch2WithMain)
target_compile_definitions(test_voice_deepfake PRIVATE
    VOICE_DEEPFAKE_CORPUS_DIR="${VOICE_DEEPFAKE_CORPUS_DIR}"
)
catch_discover_tests(test_voice_deepfake PROPERTIES LABELS "adversarial;voice_deepfake")
