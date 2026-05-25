add_library(jarvis_shadow_router STATIC shadow_router.cpp)
target_include_directories(jarvis_shadow_router PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_options(jarvis_shadow_router PRIVATE -Wall -Wextra -Wpedantic)
add_library(jarvis::shadow_router ALIAS jarvis_shadow_router)
