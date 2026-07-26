#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SKILL_DIR="${SCRIPT_DIR:h}"
TEMPLATE_DIR="$SKILL_DIR/assets/app-template"
OUTPUT_DIR="${1:-$PWD/build}"

if [[ -z "$OUTPUT_DIR" || "$OUTPUT_DIR" == "/" || "$OUTPUT_DIR" == "$HOME" ]]; then
  print -u2 "拒绝使用不安全的输出目录：$OUTPUT_DIR"
  exit 2
fi

APP_DIR="$OUTPUT_DIR/CodexRecentTasksSidebar.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
MODULE_CACHE="$OUTPUT_DIR/.module-cache"
ARCH="$(/usr/bin/uname -m)"
MIN_MACOS="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

case "$ARCH" in
  arm64|x86_64) ;;
  *)
    print -u2 "不支持的 Mac 架构：$ARCH"
    exit 3
    ;;
esac

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$MODULE_CACHE"
cp "$TEMPLATE_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$TEMPLATE_DIR/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

/usr/bin/swiftc \
  -parse-as-library \
  -target "${ARCH}-apple-macos${MIN_MACOS}" \
  -module-cache-path "$MODULE_CACHE" \
  "$TEMPLATE_DIR/Codex最近任务栏.swift" \
  -o "$MACOS_DIR/Codex最近任务栏"

/usr/bin/codesign --force --deep --sign - "$APP_DIR"
print "已构建：$APP_DIR"
