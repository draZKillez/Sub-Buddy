#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
OUTPUT_DIR="$PROJECT_DIR/outputs"
APP_NAME="Sub Buddy"
EXECUTABLE_NAME="MKVSubtitleTranslator"
VERSION="${APP_VERSION:-0.8.2}"
BUILD_NUMBER="${APP_BUILD_NUMBER:-21}"
UPDATE_REPOSITORY="${GITHUB_REPOSITORY:-}"
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
APP_PATH="$OUTPUT_DIR/$APP_NAME.app"
DMG_PATH="$OUTPUT_DIR/$APP_NAME-$VERSION.dmg"
MODULE_CACHE="$PROJECT_DIR/.build/clang-cache"
PACKAGE_CACHE="$PROJECT_DIR/.build/package-cache"
ARM_SCRATCH="$PROJECT_DIR/.build/package-arm64-release"
INTEL_SCRATCH="$PROJECT_DIR/.build/package-x86_64-release"
TOOLS_ROOT="$PROJECT_DIR/Vendor/Tools/macos"
FFMPEG_WRAPPER_SOURCE="$PROJECT_DIR/Vendor/MKVFFmpeg/src/MKVFFmpeg.c"
BITMAP_CLI_SOURCE="$PROJECT_DIR/Vendor/MKVFFmpeg/src/MKVBitmapDecoderCLI.c"
WHISPER_FRAMEWORK="$PROJECT_DIR/Vendor/Frameworks/Whisper/build-apple/whisper.xcframework/macos-arm64_x86_64/whisper.framework"
SPARKLE_FRAMEWORK="$PROJECT_DIR/Vendor/Frameworks/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

if [[ -z "$UPDATE_REPOSITORY" ]]; then
  ORIGIN_URL="$(git -C "$PROJECT_DIR" config --get remote.origin.url 2>/dev/null || true)"
  case "$ORIGIN_URL" in
    https://github.com/*)
      UPDATE_REPOSITORY="${ORIGIN_URL#https://github.com/}"
      ;;
    git@github.com:*)
      UPDATE_REPOSITORY="${ORIGIN_URL#git@github.com:}"
      ;;
    ssh://git@github.com/*)
      UPDATE_REPOSITORY="${ORIGIN_URL#ssh://git@github.com/}"
      ;;
  esac
  UPDATE_REPOSITORY="${UPDATE_REPOSITORY%.git}"
fi
if [[ "$UPDATE_REPOSITORY" != */* ]]; then
  UPDATE_REPOSITORY="OWNER/REPOSITORY"
fi

zsh "$PROJECT_DIR/scripts/setup_dependencies.sh"

if [[ ! -x "$TOOLS_ROOT/ffmpeg" || ! -x "$TOOLS_ROOT/ffprobe" || ! -x "$TOOLS_ROOT/mkvbitmapdecode" \
      || "$TOOLS_ROOT/mkvbitmapdecode" -ot "$FFMPEG_WRAPPER_SOURCE" \
      || "$TOOLS_ROOT/mkvbitmapdecode" -ot "$BITMAP_CLI_SOURCE" ]]; then
  zsh "$PROJECT_DIR/scripts/build_ffmpeg_macos.sh"
fi

mkdir -p "$OUTPUT_DIR" "$MODULE_CACHE" "$PACKAGE_CACHE"

env \
  CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
  SWIFTPM_PACKAGECACHE_PATH="$PACKAGE_CACHE" \
  swift build \
    --disable-sandbox \
    --configuration release \
    --scratch-path "$ARM_SCRATCH" \
    --triple arm64-apple-macosx14.0

env \
  CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
  SWIFTPM_PACKAGECACHE_PATH="$PACKAGE_CACHE" \
  swift build \
    --disable-sandbox \
    --configuration release \
    --scratch-path "$INTEL_SCRATCH" \
    --triple x86_64-apple-macosx14.0

ARM_BIN_DIR="$(env CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" SWIFTPM_PACKAGECACHE_PATH="$PACKAGE_CACHE" swift build --disable-sandbox --configuration release --scratch-path "$ARM_SCRATCH" --triple arm64-apple-macosx14.0 --show-bin-path)"
INTEL_BIN_DIR="$(env CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" SWIFTPM_PACKAGECACHE_PATH="$PACKAGE_CACHE" swift build --disable-sandbox --configuration release --scratch-path "$INTEL_SCRATCH" --triple x86_64-apple-macosx14.0 --show-bin-path)"
ARM_EXECUTABLE="$ARM_BIN_DIR/$EXECUTABLE_NAME"
INTEL_EXECUTABLE="$INTEL_BIN_DIR/$EXECUTABLE_NAME"

if [[ ! -x "$ARM_EXECUTABLE" ]]; then
  print -u2 "arm64 Release executable not found: $ARM_EXECUTABLE"
  exit 1
fi

if [[ ! -x "$INTEL_EXECUTABLE" ]]; then
  print -u2 "x86_64 Release executable not found: $INTEL_EXECUTABLE"
  exit 1
fi

if [[ -e "$APP_PATH" ]]; then
  rm -rf "$APP_PATH"
fi

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$APP_PATH/Contents/Frameworks"
/usr/bin/lipo -create \
  "$ARM_EXECUTABLE" \
  "$INTEL_EXECUTABLE" \
  -output "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
cp "$PROJECT_DIR/Packaging/Info.plist" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SUFeedURL https://github.com/$UPDATE_REPOSITORY/releases/latest/download/appcast.xml" "$APP_PATH/Contents/Info.plist"
cp "$PROJECT_DIR/Packaging/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
cp -R "$PROJECT_DIR/Localization/"*.lproj "$APP_PATH/Contents/Resources/"
ditto "$WHISPER_FRAMEWORK" "$APP_PATH/Contents/Frameworks/whisper.framework"
ditto "$SPARKLE_FRAMEWORK" "$APP_PATH/Contents/Frameworks/Sparkle.framework"
mkdir -p \
  "$APP_PATH/Contents/Resources/Tools" \
  "$APP_PATH/Contents/Resources/ThirdPartyNotices/FFmpeg" \
  "$APP_PATH/Contents/Resources/ThirdPartyNotices/Whisper" \
  "$APP_PATH/Contents/Resources/ThirdPartyNotices/Sparkle"
cp "$TOOLS_ROOT/ffmpeg" "$TOOLS_ROOT/ffprobe" "$TOOLS_ROOT/mkvbitmapdecode" "$APP_PATH/Contents/Resources/Tools/"
cp "$TOOLS_ROOT/COPYING.LGPLv2.1" \
  "$TOOLS_ROOT/FFmpeg-LICENSE.md" \
  "$TOOLS_ROOT/FFmpeg-LICENSE-NOTICE.txt" \
  "$TOOLS_ROOT/FFmpeg-BUILD-CONFIGURATION.txt" \
  "$APP_PATH/Contents/Resources/ThirdPartyNotices/FFmpeg/"
cp "$PROJECT_DIR/Vendor/Whisper-LICENSE.txt" "$APP_PATH/Contents/Resources/ThirdPartyNotices/Whisper/LICENSE.txt"
cp "$PROJECT_DIR/Vendor/Tools/Sparkle/LICENSE" "$APP_PATH/Contents/Resources/ThirdPartyNotices/Sparkle/LICENSE.txt"
chmod 755 "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
chmod 755 "$APP_PATH/Contents/Resources/Tools/ffmpeg" "$APP_PATH/Contents/Resources/Tools/ffprobe" "$APP_PATH/Contents/Resources/Tools/mkvbitmapdecode"

/usr/bin/lipo "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME" -verify_arch arm64 x86_64
/usr/bin/lipo "$APP_PATH/Contents/Resources/Tools/ffmpeg" -verify_arch arm64 x86_64
/usr/bin/lipo "$APP_PATH/Contents/Resources/Tools/ffprobe" -verify_arch arm64 x86_64
/usr/bin/lipo "$APP_PATH/Contents/Resources/Tools/mkvbitmapdecode" -verify_arch arm64 x86_64
/usr/bin/lipo -info "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
/usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"

/usr/bin/codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP_PATH/Contents/Frameworks/whisper.framework"
/usr/bin/codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP_PATH/Contents/Frameworks/Sparkle.framework"
/usr/bin/codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP_PATH"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sub-buddy-dmg.XXXXXX")"
cleanup() {
  if [[ -n "${STAGING_DIR:-}" && "$STAGING_DIR" == *sub-buddy-dmg.* ]]; then
    rm -rf "$STAGING_DIR"
  fi
}
trap cleanup EXIT

/usr/bin/ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

if [[ -e "$DMG_PATH" ]]; then
  rm -f "$DMG_PATH"
fi

/usr/bin/hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -ov \
  "$DMG_PATH"

print "Created app: $APP_PATH"
print "Created DMG: $DMG_PATH"
