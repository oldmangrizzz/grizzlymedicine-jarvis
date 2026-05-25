add_library(jarvis_cutover_lib STATIC cutover_orchestrator.cpp)
target_include_directories(jarvis_cutover_lib PUBLIC ${CMAKE_CURRENT_SOURCE_DIR} ${CMAKE_CURRENT_SOURCE_DIR}/../shadow_router)

find_path(SODIUM_INCLUDE_DIR sodium.h
    HINTS /opt/homebrew/opt/libsodium/include /opt/homebrew/include /usr/local/include)
find_library(SODIUM_LIBRARY sodium
    HINTS /opt/homebrew/opt/libsodium/lib /opt/homebrew/lib /usr/local/lib)
if(NOT SODIUM_INCLUDE_DIR OR NOT SODIUM_LIBRARY)
    message(FATAL_ERROR "libsodium is required for cutover_orchestrator SHA-256 content hashing")
endif()
target_include_directories(jarvis_cutover_lib PUBLIC ${SODIUM_INCLUDE_DIR})
target_link_libraries(jarvis_cutover_lib PUBLIC jarvis_shadow_router ${SODIUM_LIBRARY})
target_compile_options(jarvis_cutover_lib PRIVATE -Wall -Wextra -Wpedantic)
add_library(jarvis::cutover ALIAS jarvis_cutover_lib)

add_executable(jarvis-cutover main.cpp)
target_link_libraries(jarvis-cutover PRIVATE jarvis_cutover_lib)
add_custom_command(TARGET jarvis-cutover POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different ${CMAKE_CURRENT_SOURCE_DIR}/default_cutover_plan.json $<TARGET_FILE_DIR:jarvis-cutover>/default_cutover_plan.json)
