#!/bin/bash
# Idempotent toolchain setup: JDK17 + Android SDK (platform-34, build-tools, NDK, cmake)
# Safe to re-run: skips components that are intact, re-downloads broken ones.
set -u
TC=/home/user/arce-ai/toolchain
mkdir -p $TC
JDK_DIR=$TC/jdk-17
export JAVA_HOME=$JDK_DIR
export ANDROID_HOME=$TC/android-sdk

echo "### JDK check"
if ! $JDK_DIR/bin/java -version >/dev/null 2>&1 || [ ! -f $JDK_DIR/lib/libjli.so ]; then
  echo "JDK broken -> re-download"
  rm -rf $JDK_DIR $TC/jdk17.tar.gz
  curl -sL -o $TC/jdk17.tar.gz "https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse"
  tar xzf $TC/jdk17.tar.gz -C $TC
  rm -rf $JDK_DIR
  mv $TC/jdk-17* $JDK_DIR
  rm -f $TC/jdk17.tar.gz
fi
chmod -R a+x $JDK_DIR/bin 2>/dev/null || true
$JDK_DIR/bin/java -version 2>&1 | head -1

echo "### cmdline-tools check"
if [ ! -f $ANDROID_HOME/cmdline-tools/latest/lib/sdkmanager-classpath.jar ]; then
  curl -sL -o $TC/cmdtools.zip "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
  rm -rf $ANDROID_HOME/cmdline-tools
  unzip -q $TC/cmdtools.zip -d $TC
  rm -f $TC/cmdtools.zip
  mkdir -p $ANDROID_HOME/cmdline-tools
  mv $TC/cmdline-tools $ANDROID_HOME/cmdline-tools/latest
fi
chmod -R a+x $ANDROID_HOME/cmdline-tools/latest/bin 2>/dev/null || true

echo "### sdkmanager licenses + components"
SDKM=$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager
yes | $SDKM --sdk_root=$ANDROID_HOME --licenses > $TC/licenses.log 2>&1
# install only missing pieces
PKGS=()
[ -d $ANDROID_HOME/platforms/android-34 ] || PKGS+=("platforms;android-34")
[ -d $ANDROID_HOME/build-tools/34.0.0 ] || PKGS+=("build-tools;34.0.0")
[ -d $ANDROID_HOME/platform-tools ] || PKGS+=("platform-tools")
[ -d $ANDROID_HOME/ndk/27.0.12077973 ] || PKGS+=("ndk;27.0.12077973")
[ -d $ANDROID_HOME/cmake/3.22.1 ] || PKGS+=("cmake;3.22.1")
if [ ${#PKGS[@]} -gt 0 ]; then
  echo "installing: ${PKGS[*]}"
  $SDKM --sdk_root=$ANDROID_HOME "${PKGS[@]}" > $TC/sdkmanager.log 2>&1
  echo "SDKMANAGER_EXIT=$?"
else
  echo "all SDK components present"
fi
ls $ANDROID_HOME
echo "### SETUP_TOOLCHAIN_DONE"
