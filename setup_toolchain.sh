#!/bin/bash
set -x
cd /home/user/arce-ai/toolchain

echo "### [1/4] Download JDK 17"
curl -sL -o jdk17.tar.gz "https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse"
tar xzf jdk17.tar.gz
rm jdk17.tar.gz
ls -d jdk-17*

echo "### [2/4] Download Android cmdline-tools"
curl -sL -o cmdtools.zip "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
unzip -q cmdtools.zip
rm cmdtools.zip
mkdir -p android-sdk/cmdline-tools
mv cmdline-tools android-sdk/cmdline-tools/latest

export JAVA_HOME=/home/user/arce-ai/toolchain/$(ls -d jdk-17*)
export ANDROID_HOME=/home/user/arce-ai/toolchain/android-sdk

echo "### [3/4] sdkmanager installs (platform, build-tools, NDK, cmake)"
yes | $JAVA_HOME/bin/java -Djava.awt.headless=true -jar $ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager --sdk_root=$ANDROID_HOME --licenses > licenses.log 2>&1 || true
$JAVA_HOME/bin/java -Djava.awt.headless=true -jar $ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager --sdk_root=$ANDROID_HOME "platform-tools" "platforms;android-34" "build-tools;34.0.0" "ndk;27.0.12077973" "cmake;3.22.1" > sdkmanager.log 2>&1
echo "SDKMANAGER_EXIT=$?"

echo "### [4/4] Clone llama.cpp"
cd /home/user/arce-ai
rm -rf llama.cpp
git clone --depth 1 https://github.com/ggml-org/llama.cpp.git > clone.log 2>&1
echo "CLONE_EXIT=$?"
cd llama.cpp && git log -1 --oneline && ls llama.h ggml/ | head
echo "### SETUP COMPLETE"
