cmake_minimum_required(VERSION 3.20)
project(jarvis_oauth LANGUAGES CXX)

find_package(OpenSSL REQUIRED)

if(NOT TARGET jarvis_egress)
    add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../security/egress ${CMAKE_CURRENT_BINARY_DIR}/egress)
endif()
if(NOT TARGET jarvis_audit)
    add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../integrity/audit ${CMAKE_CURRENT_BINARY_DIR}/audit)
endif()
if(NOT TARGET jarvis_redacting_logger)
    add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../logging ${CMAKE_CURRENT_BINARY_DIR}/logging)
endif()

add_library(jarvis_oauth STATIC oauth_client.cpp)
target_compile_features(jarvis_oauth PUBLIC cxx_std_20)
target_include_directories(jarvis_oauth PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(jarvis_oauth PUBLIC jarvis_egress jarvis_audit jarvis_redacting_logger OpenSSL::Crypto)
target_compile_options(jarvis_oauth PRIVATE -Wall -Wextra -Wpedantic)

if(NOT TARGET Catch2::Catch2WithMain)
    find_package(Catch2 3 QUIET)
    if(NOT Catch2_FOUND)
        include(FetchContent)
        # SHA-pinned 2026-05-24; Catch2 v3.5.4 → b5373dadca40b7edc8570cf9470b9b1cb1934d40
        FetchContent_Declare(
            Catch2
            URL      https://github.com/catchorg/Catch2/archive/b5373dadca40b7edc8570cf9470b9b1cb1934d40.tar.gz
            URL_HASH SHA256=97afc182353da6f3a54afede6540f54f545ee6c2f73023a64688d2a9307e850c
            DOWNLOAD_EXTRACT_TIMESTAMP TRUE
        )
        FetchContent_MakeAvailable(Catch2)
    endif()
endif()

include(CTest)
add_executable(test_oauth_client tests/test_oauth_client.cpp)
target_link_libraries(test_oauth_client PRIVATE jarvis_oauth Catch2::Catch2WithMain)
target_compile_definitions(test_oauth_client PRIVATE OAUTH_TEST_ARTIFACT_DIR="${CMAKE_CURRENT_BINARY_DIR}/test_artifacts")
file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/test_artifacts")
add_test(NAME test_oauth_client COMMAND test_oauth_client)
