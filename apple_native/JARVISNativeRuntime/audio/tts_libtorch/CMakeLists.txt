cmake_minimum_required(VERSION 3.21)
project(JARVISVoiceLibtorch LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

list(APPEND CMAKE_MODULE_PATH "/Users/rbhanson/research/jarvis/apple_native/cmake")
include(VoiceIntegrityGate)

# ──────────────────────────────────────────────────────────────────────────────
# LibTorch
# ──────────────────────────────────────────────────────────────────────────────
# Set CMAKE_PREFIX_PATH to your LibTorch install before configuring:
#
#   Apple Silicon (MPS, recommended for this project):
#     Download "LibTorch macOS arm64" from https://pytorch.org/
#     cmake -S . -B build -DCMAKE_PREFIX_PATH=/path/to/libtorch
#
#   CUDA (x86 Linux/Windows):
#     cmake -S . -B build -DCMAKE_PREFIX_PATH=/path/to/libtorch
#
#   CPU-only (any platform, for CI):
#     cmake -S . -B build -DCMAKE_PREFIX_PATH=/path/to/libtorch/cpu
#
# The JARVIS CI uses:
#   macOS 14 arm64, PyTorch 2.6.0, LibTorch from pip wheel (see README §5).

if(NOT DEFINED CMAKE_PREFIX_PATH AND DEFINED ENV{LIBTORCH_PREFIX})
    set(CMAKE_PREFIX_PATH "$ENV{LIBTORCH_PREFIX}")
endif()

find_package(Torch REQUIRED)
message(STATUS "LibTorch found: ${TORCH_INCLUDE_DIRS}")

# ──────────────────────────────────────────────────────────────────────────────
# SentencePiece
# ──────────────────────────────────────────────────────────────────────────────
# Option A (preferred): system install via Homebrew / apt:
#   brew install sentencepiece
#   apt install libsentencepiece-dev
#
# Option B: vcpkg or manually built.
find_package(sentencepiece CONFIG QUIET)
if(NOT sentencepiece_FOUND)
    # Fallback: look for the headers + library manually
    find_path(SENTENCEPIECE_INCLUDE_DIR sentencepiece_processor.h
              HINTS /usr/local/include /opt/homebrew/include
                    /opt/homebrew/opt/sentencepiece/include
                    /usr/local/opt/sentencepiece/include
                    /usr/include)
    find_library(SENTENCEPIECE_LIBRARY NAMES sentencepiece
                 HINTS /usr/local/lib /opt/homebrew/lib
                       /opt/homebrew/opt/sentencepiece/lib
                       /usr/local/opt/sentencepiece/lib
                       /usr/lib)
    if(SENTENCEPIECE_INCLUDE_DIR AND SENTENCEPIECE_LIBRARY)
        add_library(sentencepiece::sentencepiece UNKNOWN IMPORTED)
        set_target_properties(sentencepiece::sentencepiece PROPERTIES
            IMPORTED_LOCATION "${SENTENCEPIECE_LIBRARY}"
            INTERFACE_INCLUDE_DIRECTORIES "${SENTENCEPIECE_INCLUDE_DIR}")
        message(STATUS "SentencePiece (manual): ${SENTENCEPIECE_LIBRARY}")
    else()
        message(FATAL_ERROR
            "SentencePiece not found.  Install with:\n"
            "  brew install sentencepiece      # macOS\n"
            "  apt install libsentencepiece-dev  # Debian/Ubuntu")
    endif()
endif()

# ──────────────────────────────────────────────────────────────────────────────
# KissFFT (used on non-Apple-Silicon platforms)
# ──────────────────────────────────────────────────────────────────────────────
if(APPLE AND CMAKE_SYSTEM_PROCESSOR MATCHES "arm64|aarch64")
    set(USE_ACCELERATE ON)
    message(STATUS "Mel backend: Accelerate.framework vDSP (Apple Silicon)")
else()
    set(USE_ACCELERATE OFF)
    message(STATUS "Mel backend: KissFFT")
    # Fetch KissFFT if not present
    include(FetchContent)
    # SHA-pinned 2026-05-24; kissfft 131.1.0 → 8f47a67f595a6641c566087bf5277034be64f24d
    FetchContent_Declare(
        kissfft
        URL      https://github.com/mborgerding/kissfft/archive/8f47a67f595a6641c566087bf5277034be64f24d.tar.gz
        URL_HASH SHA256=93cfa11a344ad552472f7d93c228d55969ac586275692d73d5e7ce73a69b047f
        DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    )
    FetchContent_MakeAvailable(kissfft)
endif()

# ──────────────────────────────────────────────────────────────────────────────
# safetensors parser support
# ──────────────────────────────────────────────────────────────────────────────
# Use the local manual safetensors parser in voice_state_loader.cpp. It depends
# only on nlohmann/json and avoids binding to an unstable third-party C++ header API.
find_package(nlohmann_json QUIET)
if(NOT nlohmann_json_FOUND)
    include(FetchContent)
    FetchContent_Declare(nlohmann_json
        URL https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz
        URL_HASH SHA256=d6c65aca6b1ed68e7a182f4757257b107ae403032760ed6ef121c9d55e81757d
        DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
    FetchContent_MakeAvailable(nlohmann_json)
endif()
set(SAFETENSORS_INCLUDE_DIR "")
set(JARVIS_USE_MANUAL_SAFETENSORS ON)
if(NOT TARGET nlohmann_json::nlohmann_json)
    message(FATAL_ERROR "nlohmann_json target not available")
endif()

# ──────────────────────────────────────────────────────────────────────────────
# Main library: jarvis_voice_libtorch
# ──────────────────────────────────────────────────────────────────────────────
add_library(jarvis_voice_libtorch STATIC
    tokenizer.cpp
    voice_state_loader.cpp
    mel_pipeline.cpp
    xtts_pipeline.cpp
)

target_include_directories(jarvis_voice_libtorch PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${TORCH_INCLUDE_DIRS}
    ${SAFETENSORS_INCLUDE_DIR}
)

target_link_libraries(jarvis_voice_libtorch PUBLIC
    ${TORCH_LIBRARIES}
    sentencepiece::sentencepiece
    nlohmann_json::nlohmann_json
)

target_compile_definitions(jarvis_voice_libtorch PRIVATE JARVIS_SAFETENSORS_FALLBACK=1)
jarvis_configure_voice_integrity(jarvis_voice_libtorch "${CMAKE_CURRENT_SOURCE_DIR}" "${CMAKE_CURRENT_BINARY_DIR}")

if(USE_ACCELERATE)
    target_compile_definitions(jarvis_voice_libtorch PRIVATE JARVIS_USE_ACCELERATE=1)
    target_link_libraries(jarvis_voice_libtorch PUBLIC
        "-framework Accelerate"
    )
else()
    target_link_libraries(jarvis_voice_libtorch PUBLIC kissfft::kissfft-float)
    target_compile_definitions(jarvis_voice_libtorch PRIVATE JARVIS_USE_KISSFFT=1)
endif()

target_compile_options(jarvis_voice_libtorch PRIVATE
    $<$<CXX_COMPILER_ID:Clang,AppleClang,GNU>:-Wall -Wextra -Wno-unused-parameter>
)

# C++20 requires explicit torch header compatibility
target_compile_definitions(jarvis_voice_libtorch PUBLIC
    _GLIBCXX_USE_CXX11_ABI=0  # match PyTorch's ABI on Linux
)

# ──────────────────────────────────────────────────────────────────────────────
# Tests
# ──────────────────────────────────────────────────────────────────────────────
option(BUILD_TESTING "Build libtorch TTS tests" ON)
if(BUILD_TESTING)
    enable_testing()

    # Catch2 v3
    find_package(Catch2 3 QUIET)
    if(NOT Catch2_FOUND)
        include(FetchContent)
        # SHA-pinned 2026-05-24; Catch2 v3.5.2 → 05e10dfccc28c7f973727c54f850237d07d5e10f
        FetchContent_Declare(
            Catch2
            URL      https://github.com/catchorg/Catch2/archive/05e10dfccc28c7f973727c54f850237d07d5e10f.tar.gz
            URL_HASH SHA256=e7bbe2a99e111dfc9eb931f5e95b11b02f18f64c4f5b3aff6fdbd118fe440107
            DOWNLOAD_EXTRACT_TIMESTAMP TRUE
        )
        FetchContent_MakeAvailable(Catch2)
        list(APPEND CMAKE_MODULE_PATH "${catch2_SOURCE_DIR}/extras")
    endif()
    include(Catch)

    # Helper macro for registering a test executable
    macro(add_tts_test name src)
        add_executable(${name} ${src})
        target_link_libraries(${name} PRIVATE
            jarvis_voice_libtorch
            Catch2::Catch2WithMain
        )
        catch_discover_tests(${name})
    endmacro()

    add_tts_test(test_equivalence         tests/test_equivalence.cpp)
    add_tts_test(test_determinism         tests/test_determinism.cpp)
    add_tts_test(test_latency             tests/test_latency.cpp)
    add_tts_test(test_tokenizer_byte_equiv tests/test_tokenizer_byte_equiv.cpp)
endif()

# ──────────────────────────────────────────────────────────────────────────────
# Installation (for integration with parent JARVISNativeRuntime build)
# ──────────────────────────────────────────────────────────────────────────────
install(TARGETS jarvis_voice_libtorch
        ARCHIVE DESTINATION lib
        LIBRARY DESTINATION lib)
install(FILES
    xtts_pipeline.h
    tokenizer.h
    voice_state_loader.h
    mel_pipeline.h
    DESTINATION include/jarvis/tts/libtorch)
