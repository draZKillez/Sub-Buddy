#!/bin/bash
# Isolated debug bundle; never stops or replaces the installed release app.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
MODE="${1:-run}"
case "$MODE" in run|--verify|--snapshot) ;; *) echo 'Usage: build_and_run.sh [--verify|--snapshot]' >&2; exit 2;; esac
pkill -x SubBuddyQA >/dev/null 2>&1 || true
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-cache"
swift build --disable-sandbox --cache-path .build/package-cache --scratch-path .build/prompt-verification
BIN_DIR="$(swift build --disable-sandbox --scratch-path .build/prompt-verification --show-bin-path)"
BUNDLE="$ROOT_DIR/outputs/debug-run/Sub Buddy.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources" "$BUNDLE/Contents/Frameworks"
cp "$BIN_DIR/MKVSubtitleTranslator" "$BUNDLE/Contents/MacOS/SubBuddyQA"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$BUNDLE/Contents/MacOS/SubBuddyQA"
cp Packaging/Info.plist "$BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable SubBuddyQA' "$BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.subbuddy.local-debug' "$BUNDLE/Contents/Info.plist"
cp Packaging/AppIcon.icns "$BUNDLE/Contents/Resources/"
cp -R Localization/*.lproj "$BUNDLE/Contents/Resources/"
ditto Vendor/Frameworks/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$BUNDLE/Contents/Frameworks/Sparkle.framework"
ditto Vendor/Frameworks/Whisper/build-apple/whisper.xcframework/macos-arm64_x86_64/whisper.framework "$BUNDLE/Contents/Frameworks/whisper.framework"
codesign --force --deep --sign - "$BUNDLE"
if [[ "$MODE" == --snapshot ]]; then
    SNAPSHOT_DIR="$(mktemp -d "$ROOT_DIR/outputs/debug-run/snapshot.XXXXXX")"
    # LaunchServices environment applies only to this new debug app instance.
    /usr/bin/open -n -W --stdout "$SNAPSHOT_DIR/stdout.log" --stderr "$SNAPSHOT_DIR/stderr.log" --env SUBBUDDY_UI_SNAPSHOT="$SNAPSHOT_DIR/screen.png" --env SUBBUDDY_UI_STEP=2 --env SUBBUDDY_UI_REASONING=1 "$BUNDLE"
    test -s "$SNAPSHOT_DIR/screen.png"
    cp "$SNAPSHOT_DIR/screen.png" "$ROOT_DIR/outputs/reasoning-ui.png"
else
    /usr/bin/open -n "$BUNDLE"
    if [[ "$MODE" == --verify ]]; then
        sleep 1
        pgrep -x SubBuddyQA >/dev/null
    fi
fi
