cmake_minimum_required(VERSION 3.20)
project(jarvis_integrity LANGUAGES CXX)

if(NOT TARGET jarvis_audit)
    add_subdirectory(audit)
endif()
