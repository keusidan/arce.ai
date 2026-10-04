# Standalone native build for ARCE.AI (produces libarce_llama.so for arm64-v8a)
# Build:
#   cmake -B build-arm64 \
#     -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake \
#     -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 \
#     -DCMAKE_BUILD_TYPE=Release -DGGML_VULKAN=ON
#   cmake --build build-arm64 -j1
cmake_minimum_required(VERSION 3.22)
project(arce_native CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(BUILD_SHARED_LIBS OFF)

option(GGML_VULKAN "Enable Vulkan GPU backend" ON)

# llama.cpp pinned submodule
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../llama.cpp ${CMAKE_CURRENT_BINARY_DIR}/llama.cpp)

set_target_properties(llama PROPERTIES
    CXX_VISIBILITY_PRESET default
    POSITION_INDEPENDENT_CODE ON)

add_library(arce_llama SHARED
    ${CMAKE_CURRENT_SOURCE_DIR}/../app/src/main/cpp/arce_llama.cpp)

target_include_directories(arce_llama PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../llama.cpp/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../llama.cpp/ggml/include)

target_sources(arce_llama PRIVATE vk_shim.cpp)  # Vulkan 1.1 symbol shim (API<28 devices)
target_link_libraries(arce_llama PRIVATE
    llama
    ggml
    ggml-base
    ggml-cpu
    log
    atomic
    m
    dl)

if(GGML_VULKAN)
    target_link_libraries(arce_llama PRIVATE ggml-vulkan vulkan)
endif()

# ARCE.AI low-RAM workaround: split objects for the giant mul_mm shader table
# (see ggml-vulkan CMakeLists skip of mul_mm.comp; chunks in native/vk_chunks)
file(GLOB _arce_vk_chunk_objects "${CMAKE_SOURCE_DIR}/vk_chunks/*.o")
list(SORT _arce_vk_chunk_objects)
if(_arce_vk_chunk_objects)
    target_link_libraries(arce_llama PRIVATE ${_arce_vk_chunk_objects})
endif()

set_target_properties(arce_llama PROPERTIES
    POSITION_INDEPENDENT_CODE ON
    CXX_VISIBILITY_PRESET default)
