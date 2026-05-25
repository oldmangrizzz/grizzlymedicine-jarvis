cmake_minimum_required(VERSION 3.20)
project(jarvis_convex_hostile_adversarial VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(CTest)

if(NOT TARGET jarvis_convex_backend)
    add_subdirectory(${CMAKE_CURRENT_LIST_DIR}/../../../storage/convex ${CMAKE_CURRENT_BINARY_DIR}/convex_backend_build)
endif()

add_executable(convex_hostile_tests test_convex_hostile.cpp)
target_link_libraries(convex_hostile_tests PRIVATE jarvis_convex_backend Catch2::Catch2WithMain)
target_compile_definitions(convex_hostile_tests PRIVATE
    TEST_ARTIFACT_DIR="${CMAKE_CURRENT_BINARY_DIR}/test_artifacts"
    CERT_FIXTURE_DIR="${CMAKE_CURRENT_LIST_DIR}/../../../security/test_fixtures")

add_test(NAME convex_hostile_tests COMMAND convex_hostile_tests)
