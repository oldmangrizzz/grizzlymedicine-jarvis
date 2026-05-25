cmake_minimum_required(VERSION 3.20)
project(JARVISTTSCoreML LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "Build macOS arm64")

list(APPEND CMAKE_MODULE_PATH "/Users/rbhanson/research/jarvis/apple_native/cmake")
include(VoiceIntegrityGate)

set(PYTHON_FOR_CONVERSION "/Users/rbhanson/research/oracle_venv/bin/python" CACHE FILEPATH "Python with pocket-tts and coremltools")
set(ORACLE_DIR "/Users/rbhanson/research/oracle/voice" CACHE PATH "JARVIS voice oracle directory")
set(COREML_MODELS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/models" CACHE PATH "CoreML model package directory")

add_library(jarvis_tts_coreml_mel STATIC
    Sources/JARVISMelPipeline/mel_pipeline.cpp
)
target_include_directories(jarvis_tts_coreml_mel PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/Sources/JARVISMelPipeline
)
if(APPLE)
    target_link_libraries(jarvis_tts_coreml_mel PUBLIC "-framework Accelerate")
endif()
jarvis_configure_voice_integrity(jarvis_tts_coreml_mel "${CMAKE_CURRENT_SOURCE_DIR}" "${CMAKE_CURRENT_BINARY_DIR}")

add_custom_target(convert_coreml_models
    COMMAND "${PYTHON_FOR_CONVERSION}" "${CMAKE_CURRENT_SOURCE_DIR}/tools/convert_coreml_native.py" --only all
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    COMMENT "Converting pocket-tts XTTS-v2 clone to CoreML mlpackages"
    VERBATIM
)

find_program(SWIFT_EXECUTABLE swift REQUIRED)
add_custom_target(coreml_swift_build
    COMMAND "${SWIFT_EXECUTABLE}" build
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    COMMENT "Building Swift/CoreML native wrapper"
    VERBATIM
)

enable_testing()
add_test(NAME coreml_equivalence_xctest
    COMMAND "${SWIFT_EXECUTABLE}" test --filter EquivalenceTests/testAllPromptsEquivalence
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
)
set_tests_properties(coreml_equivalence_xctest PROPERTIES
    ENVIRONMENT "COREML_MODELS_DIR=${COREML_MODELS_DIR};ORACLE_DIR=${ORACLE_DIR}"
)
