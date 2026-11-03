#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
bash build.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
mkdir -p dist
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/launchdeck-dmg.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
ditto LaunchDeck.app "$STAGE/LaunchDeck.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/安装说明.txt" <<'EOF'
LaunchDeck — macOS 应用启动台

将 LaunchDeck.app 拖入 Applications 文件夹。更新时先退出旧版，再替换应用。
从“应用程序”打开 LaunchDeck；默认快捷键为 Option+空格。
已有设置、已选应用、排序和文件夹会继续保留。

适用于 Apple Silicon，macOS 13 或更新版本。
此安装包使用本地临时签名，未经过 Apple Developer ID 公证。
EOF
codesign --verify --deep --strict "$STAGE/LaunchDeck.app"
hdiutil create -volname "LaunchDeck $VERSION" -srcfolder "$STAGE" -format UDZO -ov "dist/LaunchDeck-$VERSION-arm64.dmg"
hdiutil verify "dist/LaunchDeck-$VERSION-arm64.dmg"
printf 'Created %s/dist/LaunchDeck-%s-arm64.dmg\n' "$PWD" "$VERSION"
