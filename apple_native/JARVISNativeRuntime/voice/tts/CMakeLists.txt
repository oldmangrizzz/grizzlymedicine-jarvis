# voice/tts/CMakeLists.txt
# Shared TTS backends CMake entry point.
# Each sibling branch is independently buildable and opt-in.

# ONNX Runtime backend (agent 2 / sibling)
if(IS_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/onnx")
    option(JARVIS_TTS_ONNX    "Build ONNX TTS backend"    ON)
    if(JARVIS_TTS_ONNX)
        add_subdirectory(onnx)
    endif()
endif()

# LibTorch backend (agent 3 / this file)
if(IS_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/libtorch")
    option(JARVIS_TTS_LIBTORCH "Build LibTorch TTS backend" ON)
    if(JARVIS_TTS_LIBTORCH)
        add_subdirectory(libtorch)
    endif()
endif()

# CoreML backend (agent 1 / sibling)
if(IS_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/coreml" AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/coreml/CMakeLists.txt")
    option(JARVIS_TTS_COREML  "Build CoreML TTS backend"   ON)
    if(JARVIS_TTS_COREML)
        add_subdirectory(coreml)
    endif()
endif()
