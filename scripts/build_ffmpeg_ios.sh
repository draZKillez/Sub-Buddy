#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
VERSION="8.1.2"
EXPECTED_SHA="464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c"
ARCHIVE="$PROJECT_ROOT/Vendor/Downloads/ffmpeg-$VERSION.tar.xz"
SOURCE_PARENT="/tmp/mkv-subtitle-translator-ffmpeg-source-$VERSION"
SOURCE_ROOT="$SOURCE_PARENT/ffmpeg-$VERSION"
BUILD_ROOT="/tmp/mkv-subtitle-translator-ffmpeg-ios-arm64-build"
INSTALL_ROOT="$BUILD_ROOT/install"
FRAMEWORK="$PROJECT_ROOT/Vendor/Frameworks/MKVFFmpeg.framework"
SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun --sdk iphoneos --find clang)"

if [[ ! -f "$ARCHIVE" ]]; then
    echo "Missing $ARCHIVE. Download it from https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
    exit 1
fi
ACTUAL_SHA="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
    echo "FFmpeg source checksum mismatch."
    exit 1
fi
if [[ ! -x "$SOURCE_ROOT/configure" ]]; then
    mkdir -p "$SOURCE_PARENT"
    tar -xf "$ARCHIVE" -C "$SOURCE_PARENT"
fi

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT" "$PROJECT_ROOT/Vendor/Frameworks"
cd "$BUILD_ROOT"

"$SOURCE_ROOT/configure" \
    --prefix="$INSTALL_ROOT" \
    --target-os=darwin \
    --arch=arm64 \
    --cpu=armv8-a \
    --cc="$CC" \
    --sysroot="$SDK_PATH" \
    --extra-cflags="-arch arm64 -miphoneos-version-min=16.0 -fembed-bitcode-marker" \
    --extra-ldflags="-arch arm64 -miphoneos-version-min=16.0" \
    --enable-cross-compile \
    --enable-pic \
    --enable-small \
    --disable-asm \
    --disable-autodetect \
    --disable-programs \
    --disable-doc \
    --disable-debug \
    --disable-network \
    --disable-avdevice \
    --disable-avfilter \
    --disable-swscale \
    --disable-swresample \
    --disable-everything \
    --enable-avformat \
    --enable-avcodec \
    --enable-avutil \
    --enable-protocol=file \
    --enable-demuxer=matroska \
    --enable-decoder=dvdsub

make -j"${FFMPEG_BUILD_JOBS:-4}"
make install

rm -rf "$FRAMEWORK"
mkdir -p "$FRAMEWORK/Headers" "$FRAMEWORK/Modules"
cp "$PROJECT_ROOT/Vendor/MKVFFmpeg/include/MKVFFmpeg.h" "$FRAMEWORK/Headers/MKVFFmpeg.h"
cp "$PROJECT_ROOT/Vendor/MKVFFmpeg/FFmpeg-LICENSE-NOTICE.txt" "$FRAMEWORK/FFmpeg-LICENSE-NOTICE.txt"
cp "$PROJECT_ROOT/Vendor/MKVFFmpeg/FFmpeg-BUILD-CONFIGURATION.txt" "$FRAMEWORK/FFmpeg-BUILD-CONFIGURATION.txt"
cp "$SOURCE_ROOT/COPYING.LGPLv2.1" "$FRAMEWORK/COPYING.LGPLv2.1"
cp "$SOURCE_ROOT/LICENSE.md" "$FRAMEWORK/FFmpeg-LICENSE.md"

"$CC" \
    -dynamiclib \
    -arch arm64 \
    -isysroot "$SDK_PATH" \
    -miphoneos-version-min=16.0 \
    -fvisibility=hidden \
    -I"$PROJECT_ROOT/Vendor/MKVFFmpeg/include" \
    -I"$INSTALL_ROOT/include" \
    "$PROJECT_ROOT/Vendor/MKVFFmpeg/src/MKVFFmpeg.c" \
    "$INSTALL_ROOT/lib/libavformat.a" \
    "$INSTALL_ROOT/lib/libavcodec.a" \
    "$INSTALL_ROOT/lib/libavutil.a" \
    -lz -lbz2 -liconv \
    -framework CoreFoundation \
    -framework CoreVideo \
    -framework VideoToolbox \
    -install_name "@rpath/MKVFFmpeg.framework/MKVFFmpeg" \
    -current_version 8.1.2 \
    -compatibility_version 1.0 \
    -o "$FRAMEWORK/MKVFFmpeg"

cat > "$FRAMEWORK/Modules/module.modulemap" <<'MODULEMAP'
framework module MKVFFmpeg {
    umbrella header "MKVFFmpeg.h"
    export *
}
MODULEMAP

cat > "$FRAMEWORK/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>MKVFFmpeg</string>
<key>CFBundleIdentifier</key><string>com.mkvsubtitletranslator.MKVFFmpeg</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>MKVFFmpeg</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>8.1.2</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
<key>MinimumOSVersion</key><string>16.0</string>
</dict></plist>
PLIST

echo "Created $FRAMEWORK"
