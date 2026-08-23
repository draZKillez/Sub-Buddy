#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
WHISPER_ARCHIVE="$PROJECT_DIR/Vendor/Downloads/whisper-v1.9.2-xcframework.zip"
SPARKLE_ARCHIVE="$PROJECT_DIR/Vendor/Downloads/Sparkle-2.9.6.tar.xz"
WHISPER_SHA256="af74fed13ea7f2d5ca2a39d9f58ec177713fafd7cab63aef4e27b79f3ceca80b"
SPARKLE_SHA256="52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192"
WHISPER_DEST="$PROJECT_DIR/Vendor/Frameworks/Whisper"
SPARKLE_TOOLS="$PROJECT_DIR/Vendor/Tools/Sparkle"
SPARKLE_XCFRAMEWORK="$PROJECT_DIR/Vendor/Frameworks/Sparkle/Sparkle.xcframework"

verify_archive() {
  local archive="$1"
  local expected="$2"
  if [[ ! -f "$archive" ]]; then
    print -u2 "缺少依赖归档：$archive"
    exit 2
  fi
  local actual
  actual="$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    print -u2 "依赖归档校验失败：$archive"
    exit 2
  fi
}

if [[ ! -d "$WHISPER_DEST/build-apple/whisper.xcframework" ]]; then
  verify_archive "$WHISPER_ARCHIVE" "$WHISPER_SHA256"
  mkdir -p "$WHISPER_DEST"
  /usr/bin/unzip -q "$WHISPER_ARCHIVE" -d "$WHISPER_DEST"
fi

if [[ ! -x "$SPARKLE_TOOLS/bin/generate_appcast" || ! -d "$SPARKLE_TOOLS/Sparkle.framework" ]]; then
  verify_archive "$SPARKLE_ARCHIVE" "$SPARKLE_SHA256"
  mkdir -p "$SPARKLE_TOOLS"
  /usr/bin/tar -xJf "$SPARKLE_ARCHIVE" -C "$SPARKLE_TOOLS"
fi

if [[ ! -d "$SPARKLE_XCFRAMEWORK" ]]; then
  mkdir -p "${SPARKLE_XCFRAMEWORK:h}"
  /usr/bin/xcodebuild -create-xcframework \
    -framework "$SPARKLE_TOOLS/Sparkle.framework" \
    -output "$SPARKLE_XCFRAMEWORK"
fi

print "Whisper 1.9.2 and Sparkle 2.9.6 dependencies are ready."
