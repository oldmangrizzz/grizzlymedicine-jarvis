cmake_minimum_required(VERSION 3.20)
project(jarvis_voice VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Deepgram STT is canonical under audio/stt_deepgram; voice/stt duplicate was removed.

# TTS backends — routed through tts/CMakeLists.txt; each backend is opt-in.
# Individual backends can still be built standalone from their own directories.
add_subdirectory(tts)
