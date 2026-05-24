cmake_minimum_required(VERSION 3.20)
project(jarvis_coordinated_adversarial VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

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
endif()
include(CTest)

set(COORDINATED_TEST_ARTIFACT_DIR "${CMAKE_CURRENT_BINARY_DIR}/test_artifacts")
file(MAKE_DIRECTORY "${COORDINATED_TEST_ARTIFACT_DIR}")

add_executable(coordinated_adversarial_tests
    coordinated_adversarial_tests.cpp
    CoordinatedOrchestrator.cpp
    MockAdversaryA.cpp
    MockAdversaryB.cpp
    MockAdversaryC.cpp
)
target_include_directories(coordinated_adversarial_tests PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(coordinated_adversarial_tests PRIVATE Catch2::Catch2WithMain)
target_compile_definitions(coordinated_adversarial_tests PRIVATE
    COORDINATED_TEST_ARTIFACT_DIR="${COORDINATED_TEST_ARTIFACT_DIR}"
)
target_compile_options(coordinated_adversarial_tests PRIVATE -Wall -Wextra -Wpedantic)
add_test(NAME coordinated_adversarial_tests COMMAND coordinated_adversarial_tests)
