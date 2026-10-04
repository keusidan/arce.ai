#!/bin/bash
export JAVA_HOME=/home/user/arce-ai/toolchain/jdk-17.0.20.1+1
export ANDROID_HOME=/home/user/arce-ai/toolchain/android-sdk
SDKM=$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager
yes | $SDKM --sdk_root=$ANDROID_HOME --licenses > /home/user/arce-ai/toolchain/licenses.log 2>&1
echo "LICENSES_EXIT=$?"
$SDKM --sdk_root=$ANDROID_HOME "platform-tools" "platforms;android-34" "build-tools;34.0.0" "ndk;27.0.12077973" "cmake;3.22.1" > /home/user/arce-ai/toolchain/sdkmanager.log 2>&1
echo "SDKMANAGER_EXIT=$?"
ls $ANDROID_HOME
echo "### SDK3 COMPLETE"
