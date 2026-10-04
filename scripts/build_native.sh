#!/bin/bash
# Build libarce_llama.so (arm64-v8a) from the pinned llama.cpp submodule.
# Tries Vulkan GPU backend first; falls back to CPU-only if the Vulkan build fails.
set -u
NDK=/home/user/arce-ai/toolchain/android-sdk/ndk/27.0.12077973
CMAKE=/home/user/arce-ai/toolchain/android-sdk/cmake/3.22.1/bin/cmake
SRC=/home/user/arce-ai/native
cd $SRC

build() {
  local VULKAN=$1
  local DIR=build-arm64
  rm -rf $DIR
  $CMAKE -B $DIR -G "Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake \
    -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_VULKAN=$VULKAN \
    -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TESTS=OFF \
    . > cmake.log 2>&1
  if [ $? -ne 0 ]; then echo "CMAKE_CONFIG_FAIL"; return 1; fi
  $CMAKE --build $DIR -j1 > build.log 2>&1
  if [ $? -ne 0 ]; then echo "BUILD_FAIL"; return 1; fi
  if [ -f $DIR/libarce_llama.so ]; then
    mkdir -p /home/user/arce-ai/app/src/main/jniLibs/arm64-v8a
    cp $DIR/libarce_llama.so /home/user/arce-ai/app/src/main/jniLibs/arm64-v8a/
    echo "SO_BUILT_VULKAN=$VULKAN"
    ls -la /home/user/arce-ai/app/src/main/jniLibs/arm64-v8a/
    return 0
  fi
  echo "NO_SO"; return 1
}

if build ON; then
  echo "### NATIVE_BUILD_OK (Vulkan)"
elif build OFF; then
  echo "### NATIVE_BUILD_OK (CPU-only)"
else
  tail -40 cmake.log
  tail -40 build.log
  echo "### NATIVE_BUILD_FAILED"
fi
