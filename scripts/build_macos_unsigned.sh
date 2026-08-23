#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$REPO_ROOT/app"
DIST_DIR="${DIST_DIR:-$REPO_ROOT/dist/macos}"
FLUTTER_BIN="${FLUTTER_BIN:-$(command -v flutter || true)}"
BUILD_NAME="${BUILD_NAME:-$(sed -n 's/^version: \([0-9][0-9.]*\).*/\1/p' "$APP_DIR/pubspec.yaml" | head -n 1)}"
BUILD_NUMBER="${BUILD_NUMBER:-2}"

if [[ -z "$FLUTTER_BIN" || ! -x "$FLUTTER_BIN" ]]; then
  echo "找不到 Flutter。请设置 FLUTTER_BIN=/path/to/flutter/bin/flutter" >&2
  exit 1
fi

if [[ -n "${PUB_HOSTED_URL:-}" ]]; then
  echo "不要设置 PUB_HOSTED_URL；项目依赖应从 pub.dev 解析。" >&2
  exit 1
fi

BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vsasr-macos-build.XXXXXX")"
trap 'rm -rf "$BUILD_ROOT"' EXIT
PRODUCTS_DIR="$BUILD_ROOT/products"
DERIVED_DIR="$BUILD_ROOT/derived"
STAGING_DIR="$BUILD_ROOT/dmg"
APP_SOURCE="$PRODUCTS_DIR/vsasr_app.app"
APP_DEST="$DIST_DIR/VoiceSmallASR.app"
DMG_DEST="$DIST_DIR/VoiceSmallASR-unsigned.dmg"

mkdir -p "$DIST_DIR" "$STAGING_DIR"

(
  cd "$APP_DIR"
  "$FLUTTER_BIN" pub get
  "$FLUTTER_BIN" build macos --config-only \
    --build-name "$BUILD_NAME" \
    --build-number "$BUILD_NUMBER"
)

(
  cd "$APP_DIR/macos"
  xcodebuild -quiet \
    -workspace Runner.xcworkspace \
    -scheme Runner \
    -configuration Release \
    -derivedDataPath "$DERIVED_DIR" \
    CONFIGURATION_BUILD_DIR="$PRODUCTS_DIR" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO
)

if [[ ! -d "$APP_SOURCE" ]]; then
  echo "Xcode 构建成功但没有找到 $APP_SOURCE" >&2
  exit 1
fi

# GitHub 的 macOS runner 偶尔会把版本化 Framework 的 `Versions/Current`
# 展开成实体目录；codesign 会把这种结构判定为歧义 Bundle。签名前恢复标准
# `Current -> A` 链接，原目录移到临时构建根中并随 BUILD_ROOT 一起清理。
framework_backup_index=0
shopt -s nullglob
for framework in "$APP_SOURCE/Contents/Frameworks/"*.framework; do
  current="$framework/Versions/Current"
  version_a="$framework/Versions/A"
  if [[ -d "$framework/Versions" && ! -L "$current" ]]; then
    framework_backup_index=$((framework_backup_index + 1))
    backup_dir="$BUILD_ROOT/framework-current-backups/$framework_backup_index"
    mkdir -p "$backup_dir"
    if [[ ! -d "$version_a" && -d "$current" ]]; then
      mv "$current" "$version_a"
    elif [[ -e "$current" ]]; then
      mv "$current" "$backup_dir/Current"
    fi
    if [[ ! -d "$version_a" ]]; then
      echo "无法规范化 Framework 版本目录：$framework" >&2
      ls -la "$framework" "$framework/Versions" >&2
      exit 1
    fi
    ln -s A "$current"

    framework_name="$(basename "$framework" .framework)"
    for entry in "$framework_name" Resources; do
      root_entry="$framework/$entry"
      if [[ -e "$version_a/$entry" && ! -L "$root_entry" ]]; then
        if [[ -e "$root_entry" ]]; then
          mv "$root_entry" "$backup_dir/$entry"
        fi
        ln -s "Versions/Current/$entry" "$root_entry"
      fi
    done
    echo "已规范化 Framework 链接：$(basename "$framework")"
  fi
done
shopt -u nullglob

# CODE_SIGNING_ALLOWED=NO 会让嵌入的第三方 Framework 也保持未签名；新版本 macOS
# 会拒绝从未签名 Framework 加载动态库。这里使用 ad-hoc 签名，不需要开发者证书，
# 只为保证个人使用的无证书 App 能在本机启动。
codesign --force --deep --sign - --timestamp=none "$APP_SOURCE"
codesign --verify --deep --strict "$APP_SOURCE"

rm -rf "$APP_DEST"
ditto "$APP_SOURCE" "$APP_DEST"

rm -rf "$STAGING_DIR/VoiceSmallASR.app"
ditto "$APP_DEST" "$STAGING_DIR/VoiceSmallASR.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -quiet \
  -volname "VoiceSmallASR" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_DEST"

echo "已生成："
echo "  $APP_DEST"
echo "  $DMG_DEST"
