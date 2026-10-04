#!/bin/bash
set -e
NDK=/home/user/arce-ai/toolchain/android-sdk/ndk/27.0.12077973
CXX=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/clang++
SYS=$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot
VSDK=/home/user/arce-ai/toolchain/1.3.296.0/x86_64
BK=/home/user/arce-ai/native/build-arm64-vk/llama.cpp/ggml/src/ggml-vulkan
cd /home/user/arce-ai/native/vk_chunks
for f in part_*.cpp; do
  [ -f "${f%.cpp}.o" ] && continue
  $CXX --target=aarch64-linux-android26 --sysroot=$SYS -isystem$VSDK/include -I$BK -fPIC -O0 -DNDEBUG -std=c++17 -c $f -o ${f%.cpp}.o
  echo "chunk $f ok"
done
echo CHUNKS_DONE
