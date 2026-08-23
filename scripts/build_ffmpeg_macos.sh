#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
VERSION="8.1.2"
EXPECTED_SHA="464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c"
ARCHIVE="$PROJECT_ROOT/Vendor/Downloads/ffmpeg-$VERSION.tar.xz"
SOURCE_PARENT="/tmp/mkv-subtitle-translator-ffmpeg-source-$VERSION"
SOURCE_ROOT="$SOURCE_PARENT/ffmpeg-$VERSION"
BUILD_ROOT="$PROJECT_ROOT/.build/ffmpeg-macos"
OUTPUT_ROOT="$PROJECT_ROOT/Vendor/Tools/macos"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"
BUILD_JOBS="${FFMPEG_BUILD_JOBS:-4}"

if [[ ! -f "$ARCHIVE" ]]; then
  print -u2 "Missing $ARCHIVE. Download the official source from https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
  exit 1
fi

ACTUAL_SHA="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
  print -u2 "FFmpeg source checksum mismatch: $ACTUAL_SHA"
  exit 1
fi

if [[ ! -x "$SOURCE_ROOT/configure" ]]; then
  mkdir -p "$SOURCE_PARENT"
  tar -xf "$ARCHIVE" -C "$SOURCE_PARENT"
fi

build_arch() {
  local arch="$1"
  local arch_root="$BUILD_ROOT/$arch"
  local reproducible_flags="-mmacosx-version-min=14.0 -ffile-prefix-map=$SOURCE_ROOT=/usr/src/ffmpeg-$VERSION"
  local wrapper_source="$PROJECT_ROOT/Vendor/MKVFFmpeg/src/MKVFFmpeg.c"
  local cli_source="$PROJECT_ROOT/Vendor/MKVFFmpeg/src/MKVBitmapDecoderCLI.c"
  if [[ "${FFMPEG_FORCE_REBUILD:-0}" != "1" && -x "$arch_root/ffmpeg" && -x "$arch_root/ffprobe" \
        && -x "$arch_root/mkvbitmapdecode" && "$arch_root/mkvbitmapdecode" -nt "$wrapper_source" \
        && "$arch_root/mkvbitmapdecode" -nt "$cli_source" \
        && -f "$arch_root/config_components.h" ]] && grep -q '^#define CONFIG_DVDSUB_DECODER 1' "$arch_root/config_components.h"; then
    print "Reusing completed $arch FFmpeg tools"
    return
  fi
  local rebuild_ffmpeg=1
  if [[ "${FFMPEG_FORCE_REBUILD:-0}" != "1" && -x "$arch_root/ffmpeg" && -x "$arch_root/ffprobe" \
        && -f "$arch_root/config_components.h" ]] && grep -q '^#define CONFIG_DVDSUB_DECODER 1' "$arch_root/config_components.h"; then
    rebuild_ffmpeg=0
    print "Rebuilding only the $arch VobSub helper"
  fi
  if (( rebuild_ffmpeg )); then
    rm -rf "$arch_root"
    mkdir -p "$arch_root"
    cd "$arch_root"

    "$SOURCE_ROOT/configure" \
    --prefix="/opt/mkv-subtitle-translator/ffmpeg-$arch" \
    --target-os=darwin \
    --arch="$arch" \
    --cc="$CLANG -arch $arch" \
    --sysroot="$SDK_PATH" \
    --extra-cflags="$reproducible_flags" \
    --extra-ldflags="-mmacosx-version-min=14.0" \
    --extra-libs="-liconv" \
    --enable-cross-compile \
    --enable-static \
    --disable-shared \
    --enable-small \
    --disable-x86asm \
    --disable-everything \
    --disable-autodetect \
    --disable-doc \
    --disable-debug \
    --disable-network \
    --disable-avdevice \
    --disable-ffplay \
    --disable-sdl2 \
    --disable-gpl \
    --disable-nonfree \
    --enable-zlib \
    --enable-iconv \
    --enable-ffmpeg \
    --enable-ffprobe \
    --enable-avcodec \
    --enable-avformat \
    --enable-avfilter \
    --enable-avutil \
    --enable-swresample \
    --enable-swscale \
    --enable-protocol=file \
    --enable-protocol=pipe \
    --enable-demuxer=matroska \
    --enable-demuxer=srt \
    --enable-demuxer=ass \
    --enable-demuxer=webvtt \
    --enable-demuxer=sup \
    --enable-muxer=matroska \
    --enable-muxer=srt \
    --enable-muxer=ass \
    --enable-muxer=webvtt \
    --enable-muxer=sup \
    --enable-decoder=subrip \
    --enable-decoder=ass \
    --enable-decoder=ssa \
    --enable-decoder=webvtt \
    --enable-decoder=pgssub \
    --enable-decoder=dvdsub \
    --enable-encoder=subrip \
    --enable-encoder=ass \
    --enable-encoder=ssa \
    --enable-encoder=webvtt \
    --enable-bsf=pgs_frame_merge \
    --enable-filter=null \
    --enable-filter=anull \
    --enable-filter=format \
    --enable-filter=aformat \
    --enable-filter=aresample

    make -j"$BUILD_JOBS" ffmpeg ffprobe
  fi

  "$CLANG" \
    -arch "$arch" \
    -isysroot "$SDK_PATH" \
    -mmacosx-version-min=14.0 \
    -fvisibility=hidden \
    -I"$PROJECT_ROOT/Vendor/MKVFFmpeg/include" \
    -I"$arch_root" \
    -I"$SOURCE_ROOT" \
    "$wrapper_source" \
    "$cli_source" \
    "$arch_root/libavformat/libavformat.a" \
    "$arch_root/libavcodec/libavcodec.a" \
    "$arch_root/libavutil/libavutil.a" \
    -lz -liconv \
    -framework CoreFoundation \
    -framework CoreVideo \
    -framework VideoToolbox \
    -o "$arch_root/mkvbitmapdecode"
}

build_arch arm64
build_arch x86_64

mkdir -p "$OUTPUT_ROOT"
for tool in ffmpeg ffprobe mkvbitmapdecode; do
  /usr/bin/lipo -create \
    "$BUILD_ROOT/arm64/$tool" \
    "$BUILD_ROOT/x86_64/$tool" \
    -output "$OUTPUT_ROOT/$tool"
  chmod 755 "$OUTPUT_ROOT/$tool"
  /usr/bin/lipo "$OUTPUT_ROOT/$tool" -verify_arch arm64 x86_64
done

cp "$SOURCE_ROOT/COPYING.LGPLv2.1" "$OUTPUT_ROOT/COPYING.LGPLv2.1"
cp "$SOURCE_ROOT/LICENSE.md" "$OUTPUT_ROOT/FFmpeg-LICENSE.md"
cp "$PROJECT_ROOT/Vendor/MKVFFmpeg/FFmpeg-LICENSE-NOTICE.txt" "$OUTPUT_ROOT/FFmpeg-LICENSE-NOTICE.txt"
cp "$PROJECT_ROOT/Vendor/MKVFFmpeg/FFmpeg-MACOS-BUILD-CONFIGURATION.txt" "$OUTPUT_ROOT/FFmpeg-BUILD-CONFIGURATION.txt"

print "Created Universal 2 FFmpeg tools in $OUTPUT_ROOT"
