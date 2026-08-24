#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
BUILD_ROOT="$PROJECT_ROOT/.build/ios-release"
APP_NAME="Sub Buddy"
EXECUTABLE="MKVSubtitleTranslatorIOS"
APP_BUNDLE="$BUILD_ROOT/Payload/$APP_NAME.app"
OUTPUT="$PROJECT_ROOT/outputs/Sub-Buddy-iOS-0.4.0-LiveContainer.ipa"
SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
SWIFTC="$(xcrun --sdk iphoneos --find swiftc)"
FRAMEWORK="$PROJECT_ROOT/Vendor/Frameworks/MKVFFmpeg.framework"
FFMPEG_WRAPPER_SOURCE="$PROJECT_ROOT/Vendor/MKVFFmpeg/src/MKVFFmpeg.c"
FFMPEG_WRAPPER_HEADER="$PROJECT_ROOT/Vendor/MKVFFmpeg/include/MKVFFmpeg.h"

if [[ ! -f "$FRAMEWORK/MKVFFmpeg" \
      || "$FRAMEWORK/MKVFFmpeg" -ot "$FFMPEG_WRAPPER_SOURCE" \
      || "$FRAMEWORK/MKVFFmpeg" -ot "$FFMPEG_WRAPPER_HEADER" ]]; then
    zsh "$PROJECT_ROOT/scripts/build_ffmpeg_ios.sh"
fi

rm -rf "$BUILD_ROOT"
mkdir -p "$APP_BUNDLE"
cp "$PROJECT_ROOT/iOS/Resources/Info.plist" "$APP_BUNDLE/Info.plist"
cp -R "$PROJECT_ROOT/Localization/"*.lproj "$APP_BUNDLE/"
ICON_SOURCE="$PROJECT_ROOT/iOS/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
sips -z 120 120 "$ICON_SOURCE" --out "$APP_BUNDLE/AppIcon60x60@2x.png" >/dev/null
sips -z 180 180 "$ICON_SOURCE" --out "$APP_BUNDLE/AppIcon60x60@3x.png" >/dev/null
sips -z 152 152 "$ICON_SOURCE" --out "$APP_BUNDLE/AppIcon76x76@2x~ipad.png" >/dev/null
sips -z 167 167 "$ICON_SOURCE" --out "$APP_BUNDLE/AppIcon83.5x83.5@2x~ipad.png" >/dev/null
mkdir -p "$APP_BUNDLE/Frameworks"
ditto "$FRAMEWORK" "$APP_BUNDLE/Frameworks/MKVFFmpeg.framework"
cp "$PROJECT_ROOT/Vendor/MKVFFmpeg/FFmpeg-LICENSE-NOTICE.txt" "$APP_BUNDLE/FFmpeg-LICENSE-NOTICE.txt"
cp "$PROJECT_ROOT/Vendor/MKVFFmpeg/FFmpeg-BUILD-CONFIGURATION.txt" "$APP_BUNDLE/FFmpeg-BUILD-CONFIGURATION.txt"

"$SWIFTC" \
    -target arm64-apple-ios16.0 \
    -sdk "$SDK_PATH" \
    -O \
    -parse-as-library \
    -module-name MKVSubtitleTranslatorIOS \
    -framework SwiftUI \
    -framework UIKit \
    -framework UniformTypeIdentifiers \
    -framework Vision \
    -framework CoreGraphics \
    -F "$PROJECT_ROOT/Vendor/Frameworks" \
    -framework MKVFFmpeg \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks \
    "$PROJECT_ROOT/Sources/MKVSubtitleCore/AppError.swift" \
    "$PROJECT_ROOT/Sources/MKVSubtitleCore/Models.swift" \
    "$PROJECT_ROOT/Sources/MKVSubtitleCore/SubtitleParser.swift" \
    "$PROJECT_ROOT/Sources/MKVSubtitleCore/SubtitleWriter.swift" \
    "$PROJECT_ROOT/Sources/MKVSubtitleCore/MovieTitleResolver.swift" \
    "$PROJECT_ROOT/Sources/MKVSubtitleCore/ManualTranslation.swift" \
    "$PROJECT_ROOT/Sources/MKVSubtitleCore/PGSOCRService.swift" \
    "$PROJECT_ROOT/Sources/MKVSubtitleCore/BitmapSubtitleArchive.swift" \
    "$PROJECT_ROOT/iOS/Sources/MobileSubtitleOutputComposer.swift" \
    "$PROJECT_ROOT/iOS/Sources/LocalizedUI.swift" \
    "$PROJECT_ROOT/iOS/Sources/NativeMKVService.swift" \
    "$PROJECT_ROOT/iOS/Sources/MobileWorkspaceStore.swift" \
    "$PROJECT_ROOT/iOS/Sources/SubtitleExportDocument.swift" \
    "$PROJECT_ROOT/iOS/Sources/SystemFilePicker.swift" \
    "$PROJECT_ROOT/iOS/Sources/MobileViewModel.swift" \
    "$PROJECT_ROOT/iOS/Sources/MobileContentView.swift" \
    "$PROJECT_ROOT/iOS/Sources/MKVSubtitleTranslatorIOSApp.swift" \
    -o "$APP_BUNDLE/$EXECUTABLE"

chmod +x "$APP_BUNDLE/$EXECUTABLE"
rm -f "$OUTPUT"
ditto -c -k --norsrc --keepParent "$BUILD_ROOT/Payload" "$OUTPUT"

echo "Created unsigned LiveContainer IPA: $OUTPUT"
