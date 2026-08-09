#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
SCRATCH="$REPO_ROOT/build/macos-swift"
APP="$REPO_ROOT/build/Lynk.app"
LEGACY_APP="$REPO_ROOT/build/ACP Monitor.app"
CONTENTS="$APP/Contents"
SDK=${ACP_MONITOR_SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk}
MODULE_CACHE="$REPO_ROOT/build/clang-module-cache"

mkdir -p "$MODULE_CACHE"
env SDKROOT="$SDK" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" SWIFTPM_MODULECACHE_OVERRIDE="$REPO_ROOT/build/swiftpm-module-cache" \
  swift build --package-path "$REPO_ROOT/macos" --scratch-path "$SCRATCH" -c release
BIN_DIR=$(env SDKROOT="$SDK" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" SWIFTPM_MODULECACHE_OVERRIDE="$REPO_ROOT/build/swiftpm-module-cache" \
  swift build --package-path "$REPO_ROOT/macos" --scratch-path "$SCRATCH" -c release --show-bin-path)

rm -rf "$APP" "$LEGACY_APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/runtime/src"
cp "$BIN_DIR/ACPMonitor" "$CONTENTS/MacOS/ACPMonitor"
cp "$REPO_ROOT/macos/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$REPO_ROOT/macos/Resources/ACPLogo.svg" "$CONTENTS/Resources/ACPLogo.svg"

ICONSET="$REPO_ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  sips -s format png -z "$SIZE" "$SIZE" "$REPO_ROOT/macos/Resources/AppIcon.svg" \
    --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE_SIZE=$((SIZE * 2))
  sips -s format png -z "$DOUBLE_SIZE" "$DOUBLE_SIZE" "$REPO_ROOT/macos/Resources/AppIcon.svg" \
    --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"

for FILE in "$REPO_ROOT"/src/*.js; do
  cp "$FILE" "$CONTENTS/Resources/runtime/src/$(basename "$FILE")"
done

codesign --force --deep --sign - "$APP"
printf '%s\n' "Built $APP"
