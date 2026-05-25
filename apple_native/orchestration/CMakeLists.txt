cmake_minimum_required(VERSION 3.20)
project(jarvis_cutover_orchestration LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(CTest)

add_subdirectory(shadow_router)
add_subdirectory(orchestrator)
add_subdirectory(tests)
