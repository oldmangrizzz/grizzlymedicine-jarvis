cmake_minimum_required(VERSION 3.20)
project(jarvis_migration LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(FetchContent)
# nlohmann/json v3.11.3 → commit 9cca280a4d0ccf0c08f47a99aa71d1b0e52f8d03 (pinned 2026-05-24)
FetchContent_Declare(
  nlohmann_json
  URL      https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz
  URL_HASH SHA256=d6c65aca6b1ed68e7a182f4757257b107ae403032760ed6ef121c9d55e81757d
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
set(JSON_BuildTests OFF CACHE BOOL "" FORCE)
set(JSON_Install OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(nlohmann_json)

# Catch2 v3.5.4 → commit b5373dadca40b7edc8570cf9470b9b1cb1934d40 (pinned 2026-05-24)
FetchContent_Declare(
  Catch2
  URL      https://github.com/catchorg/Catch2/archive/b5373dadca40b7edc8570cf9470b9b1cb1934d40.tar.gz
  URL_HASH SHA256=97afc182353da6f3a54afede6540f54f545ee6c2f73023a64688d2a9307e850c
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
FetchContent_MakeAvailable(Catch2)
list(APPEND CMAKE_MODULE_PATH ${catch2_SOURCE_DIR}/extras)
include(CTest)
include(Catch)

find_path(SQLCIPHER_INCLUDE_DIR sqlite3.h PATHS /opt/homebrew/include/sqlcipher /usr/local/include/sqlcipher /opt/homebrew/include /usr/local/include)
find_library(SQLCIPHER_LIBRARY NAMES sqlcipher PATHS /opt/homebrew/lib /usr/local/lib)
if(NOT SQLCIPHER_INCLUDE_DIR OR NOT SQLCIPHER_LIBRARY)
  message(FATAL_ERROR "SQLCipher development files not found. Install sqlcipher and rebuild.")
endif()

add_library(jarvis_migration_lib STATIC
  migration_runner/migration.cpp
)
target_include_directories(jarvis_migration_lib PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/migration_runner
  ${SQLCIPHER_INCLUDE_DIR}
)
target_link_libraries(jarvis_migration_lib PUBLIC nlohmann_json::nlohmann_json ${SQLCIPHER_LIBRARY})
target_compile_options(jarvis_migration_lib PRIVATE -Wall -Wextra -Wpedantic)

add_executable(jarvis-migrate migration_runner/main.cpp)
target_link_libraries(jarvis-migrate PRIVATE jarvis_migration_lib)

add_executable(jarvis-migrate-rollback rollback/rollback_main.cpp)
target_link_libraries(jarvis-migrate-rollback PRIVATE jarvis_migration_lib)

add_executable(test_migration tests/test_migration.cpp)
target_link_libraries(test_migration PRIVATE jarvis_migration_lib Catch2::Catch2WithMain)
catch_discover_tests(test_migration)
