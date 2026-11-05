#!/bin/sh
# Builds helper.apk without Gradle: aapt2 -> javac -> d8 -> zipalign -> apksigner.
set -e
# d8 34 crashes on JDK 25; use Android Studio's bundled JDK
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"; export PATH="$JAVA_HOME/bin:$PATH"
cd "$(dirname "$0")"
SDK=/opt/homebrew/share/android-commandlinetools
BT=$SDK/build-tools/34.0.0
JAR=$SDK/platforms/android-30/android.jar
rm -rf build && mkdir -p build/classes

"$BT/aapt2" link -o build/base.apk -I "$JAR" --manifest AndroidManifest.xml
/usr/bin/javac --release 8 -g:none -XDstringConcat=inline -classpath "$JAR" -d build/classes $(find src -name '*.java') 2>&1 | grep -v "^warning\|^Note" || true
"$BT/d8" --lib "$JAR" --min-api 24 --output build $(find build/classes -name '*.class')
(cd build && cp base.apk unsigned.apk && zip -q unsigned.apk classes.dex)
"$BT/zipalign" -f 4 build/unsigned.apk build/aligned.apk

[ -f debug.keystore ] || keytool -genkeypair -keystore debug.keystore -storepass android -keypass android \
  -alias debug -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=BT Bridge Debug" >/dev/null 2>&1
"$BT/apksigner" sign --ks debug.keystore --ks-pass pass:android --key-pass pass:android \
  --out helper.apk build/aligned.apk
echo "Built $(pwd)/helper.apk"
