#!/bin/bash
set -u
NDK=/home/user/arce-ai/toolchain/android-sdk/ndk/27.0.12077973
CMAKE=/home/user/arce-ai/toolchain/android-sdk/cmake/3.22.1/bin/cmake
VSDK=/home/user/arce-ai/toolchain/1.3.296.0/x86_64
SRC=/home/user/arce-ai/native
cd $SRC
rm -rf build-arm64-vk
$CMAKE -B build-arm64-vk -G "Unix Makefiles" \
  -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_FLAGS_RELEASE="-O1 -DNDEBUG" \
  -DGGML_VULKAN=ON \
  -DCMAKE_PREFIX_PATH=$VSDK \
  -DVulkan_DIR=$VSDK/share/cmake/Vulkan \
  -DSPIRV-Headers_DIR=$VSDK/share/cmake/SPIRV-Headers \
  -DVulkan_GLSLC_EXECUTABLE=$VSDK/bin/glslc \
  -DCMAKE_CXX_FLAGS=-isystem$VSDK/include \
  -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TESTS=OFF \
  . > cmake_vk.log 2>&1
if [ $? -ne 0 ]; then echo "VULKAN_CMAKE_CONFIG_FAIL"; tail -25 cmake_vk.log; exit 1; fi
$CMAKE --build build-arm64-vk -j1 > build_vk.log 2>&1
if [ $? -ne 0 ]; then echo "VULKAN_BUILD_FAIL"; tail -25 build_vk.log; exit 1; fi
if [ -f build-arm64-vk/libarce_llama.so ]; then
  cp build-arm64-vk/libarce_llama.so /home/user/arce-ai/app/src/main/jniLibs/arm64-v8a/libarce_llama.so.vk.bak
  ls -la build-arm64-vk/libarce_llama.so
  echo "VULKAN_SO_BUILT"
fi
