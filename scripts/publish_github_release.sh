#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
VERSION="${APP_VERSION:-0.7.0}"
BUILD_NUMBER="${APP_BUILD_NUMBER:-17}"
REPOSITORY="${GITHUB_REPOSITORY:-}"
TAG="${RELEASE_TAG:-v$VERSION}"
SPARKLE_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-com.mkvsubtitletranslator.mac}"
SPARKLE_TOOL="$PROJECT_DIR/Vendor/Tools/Sparkle/bin/generate_appcast"
DMG="$PROJECT_DIR/outputs/AI看剧伴侣-$VERSION.dmg"
RELEASE_DIR="$PROJECT_DIR/outputs/release-$VERSION"
RELEASE_DMG="$RELEASE_DIR/AI-Viewing-Companion-$VERSION.dmg"

if [[ -z "$REPOSITORY" || "$REPOSITORY" != */* ]]; then
  print -u2 "请设置 GITHUB_REPOSITORY=你的用户名/仓库名"
  exit 2
fi
if ! command -v gh >/dev/null 2>&1; then
  print -u2 "未找到 GitHub CLI。请先安装并运行 gh auth login。"
  exit 2
fi

GITHUB_REPOSITORY="$REPOSITORY" APP_VERSION="$VERSION" APP_BUILD_NUMBER="$BUILD_NUMBER" \
  zsh "$PROJECT_DIR/scripts/package_dmg.sh"

mkdir -p "$RELEASE_DIR"
/usr/bin/ditto "$DMG" "$RELEASE_DMG"
"$SPARKLE_TOOL" \
  --account "$SPARKLE_ACCOUNT" \
  --download-url-prefix "https://github.com/$REPOSITORY/releases/download/$TAG/" \
  --link "https://github.com/$REPOSITORY" \
  --maximum-versions 1 \
  "$RELEASE_DIR"

gh release create "$TAG" \
  "$RELEASE_DMG" \
  "$RELEASE_DIR/appcast.xml" \
  --repo "$REPOSITORY" \
  --title "AI看剧伴侣 $VERSION" \
  --generate-notes

print "发布完成：https://github.com/$REPOSITORY/releases/tag/$TAG"
print "旧版本会从 releases/latest/download/appcast.xml 自动检查本次更新。"
