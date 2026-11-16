#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
python3 tools/sparkle/bootstrap.py
APP="$PWD/LaunchDeck.app"
CACHE="${TMPDIR:-/tmp}/launchdeck-swift-cache"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$CACHE"
swiftc -swift-version 5 -O -module-cache-path "$CACHE" -target arm64-apple-macosx13.0 \
  -F tools/sparkle/vendor -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks -framework AppKit -framework Carbon -framework ServiceManagement \
  Sources/AppUpdater.swift Sources/Models.swift Sources/main.swift -o "$APP/Contents/MacOS/LaunchDeck"
cp Info.plist "$APP/Contents/Info.plist"
swift -module-cache-path "$CACHE" Sources/Icon.swift "$CACHE/icon.png"
mkdir -p "$CACHE/AppIcon.iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$CACHE/icon.png" --out "$CACHE/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$CACHE/icon.png" --out "$CACHE/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
python3 Sources/pack_icon.py "$CACHE/AppIcon.iconset" "$APP/Contents/Resources/AppIcon.icns"
python3 tools/sparkle/bootstrap.py "$APP"
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/LaunchDeck" --startup-test
"$APP/Contents/MacOS/LaunchDeck" --self-test
"$APP/Contents/MacOS/LaunchDeck" --catalog-test
printf 'Built %s\n' "$APP"
