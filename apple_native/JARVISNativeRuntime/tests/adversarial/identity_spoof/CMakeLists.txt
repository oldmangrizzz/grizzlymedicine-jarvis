cmake_minimum_required(VERSION 3.20)
project(jarvis_identity_spoof_adversarial VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(CTest)
include(FetchContent)

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

if(NOT TARGET jarvis_identity_character_values)
    add_subdirectory(${CMAKE_CURRENT_LIST_DIR}/../../../identity/character_values
                     ${CMAKE_CURRENT_BINARY_DIR}/identity_character_values_build)
endif()

set(IDENTITY_SPOOF_TEST_ARTIFACT_DIR "${CMAKE_CURRENT_BINARY_DIR}/test_artifacts")
file(MAKE_DIRECTORY "${IDENTITY_SPOOF_TEST_ARTIFACT_DIR}")

add_executable(identity_spoof_adversarial_tests test_identity_spoof.cpp)
target_link_libraries(identity_spoof_adversarial_tests PRIVATE
    jarvis_identity_character_values
    Catch2::Catch2WithMain
)
target_compile_definitions(identity_spoof_adversarial_tests PRIVATE
    TEST_ARTIFACT_DIR="${IDENTITY_SPOOF_TEST_ARTIFACT_DIR}"
)
catch_discover_tests(identity_spoof_adversarial_tests PROPERTIES LABELS "adversarial;identity_spoof")
