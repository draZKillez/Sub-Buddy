#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
REPOSITORY="${1:-}"
SPARKLE_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-com.mkvsubtitletranslator.mac}"
GENERATE_KEYS="$PROJECT_DIR/Vendor/Tools/Sparkle/bin/generate_keys"
PLIST="$PROJECT_DIR/Packaging/Info.plist"

if ! command -v gh >/dev/null 2>&1; then
  print -u2 "未找到 GitHub CLI。请先运行：brew install gh"
  exit 2
fi
if ! gh auth status >/dev/null 2>&1; then
  print -u2 "GitHub CLI 尚未登录。请先运行：gh auth login"
  exit 2
fi
if [[ -z "$REPOSITORY" ]]; then
  REPOSITORY="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
fi
if [[ -z "$REPOSITORY" || "$REPOSITORY" != */* ]]; then
  print -u2 "用法：zsh scripts/configure_github_updates.sh GitHub用户名/仓库名"
  exit 2
fi

PUBLIC_KEY="$($GENERATE_KEYS --account "$SPARKLE_ACCOUNT" -p)"
PLIST_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")"
if [[ "$PUBLIC_KEY" != "$PLIST_PUBLIC_KEY" ]]; then
  print -u2 "钥匙串公钥与 Packaging/Info.plist 不一致。为避免旧版本无法更新，已停止配置。"
  exit 3
fi

PRIVATE_KEY_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/ai-viewing-companion-sparkle.XXXXXX")"
PRIVATE_KEY_FILE="$PRIVATE_KEY_DIRECTORY/private-key"
cleanup() {
  if [[ -n "${PRIVATE_KEY_DIRECTORY:-}" && "$PRIVATE_KEY_DIRECTORY" == *ai-viewing-companion-sparkle.* ]]; then
    /bin/rm -f "$PRIVATE_KEY_FILE"
    /bin/rmdir "$PRIVATE_KEY_DIRECTORY" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM
/bin/chmod 700 "$PRIVATE_KEY_DIRECTORY"
"$GENERATE_KEYS" --account "$SPARKLE_ACCOUNT" -x "$PRIVATE_KEY_FILE" >/dev/null
/bin/chmod 600 "$PRIVATE_KEY_FILE"
gh secret set SPARKLE_PRIVATE_KEY --repo "$REPOSITORY" < "$PRIVATE_KEY_FILE"

print "已为 $REPOSITORY 配置 SPARKLE_PRIVATE_KEY。"
print "私钥仍保存在本机钥匙串；临时导出文件已经删除。"
print "以后在 GitHub Actions 运行 Build and publish macOS update，填写版本号和递增构建号即可。"
