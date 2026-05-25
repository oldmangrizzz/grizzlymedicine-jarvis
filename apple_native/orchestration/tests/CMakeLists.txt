include(FetchContent)
if(NOT TARGET Catch2::Catch2WithMain)
  # Catch2 v3.5.4 → commit b5373dadca40b7edc8570cf9470b9b1cb1934d40 (pinned 2026-05-24)
  FetchContent_Declare(
    Catch2
    URL      https://github.com/catchorg/Catch2/archive/b5373dadca40b7edc8570cf9470b9b1cb1934d40.tar.gz
    URL_HASH SHA256=97afc182353da6f3a54afede6540f54f545ee6c2f73023a64688d2a9307e850c
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
  )
  FetchContent_MakeAvailable(Catch2)
endif()
list(APPEND CMAKE_MODULE_PATH ${catch2_SOURCE_DIR}/extras)
include(Catch)

set(CUTOVER_TEST_ARTIFACT_DIR "${CMAKE_CURRENT_BINARY_DIR}/test_artifacts")
file(MAKE_DIRECTORY "${CUTOVER_TEST_ARTIFACT_DIR}")

add_executable(test_cutover test_cutover.cpp)
target_link_libraries(test_cutover PRIVATE jarvis_cutover_lib Catch2::Catch2WithMain)
target_compile_definitions(test_cutover PRIVATE TEST_ARTIFACT_DIR="${CUTOVER_TEST_ARTIFACT_DIR}")
catch_discover_tests(test_cutover)
