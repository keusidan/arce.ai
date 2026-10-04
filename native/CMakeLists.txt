# Shared llama.cpp runtime for the Windows and Linux Flutter bundles.
# Android keeps its JNI bridge in android/app/src/main/cpp so its symbol names stay stable.
cmake_minimum_required(VERSION 3.22)

set(ARCE_LLAMA_SRC "${CMAKE_CURRENT_LIST_DIR}/../third_party/llama.cpp")
if(NOT EXISTS "${ARCE_LLAMA_SRC}/CMakeLists.txt")
  message(FATAL_ERROR "third_party/llama.cpp is missing. Clone with --recurse-submodules.")
endif()

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(LLAMA_BUILD_COMMON ON CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP OFF CACHE BOOL "" FORCE)
set(LLAMA_OPENSSL OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_LLAMAFILE OFF CACHE BOOL "" FORCE)

add_subdirectory("${ARCE_LLAMA_SRC}" "${CMAKE_BINARY_DIR}/llama-build")

add_library(arce_llama SHARED llama/arce_llama_desktop.cpp)
target_compile_features(arce_llama PRIVATE cxx_std_17)
target_include_directories(arce_llama PRIVATE "${ARCE_LLAMA_SRC}/include" "${ARCE_LLAMA_SRC}/common")
target_link_libraries(arce_llama PRIVATE llama llama-common)

if(MSVC)
  target_compile_options(arce_llama PRIVATE /W4)
else()
  target_compile_options(arce_llama PRIVATE -Wall -Wextra)
endif()
