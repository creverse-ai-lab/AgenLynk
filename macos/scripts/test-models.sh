#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
SDK=${ACP_MONITOR_SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk}
OUT="$REPO_ROOT/build/macos-model-checks"
mkdir -p "$REPO_ROOT/build/clang-module-cache"

env SDKROOT="$SDK" CLANG_MODULE_CACHE_PATH="$REPO_ROOT/build/clang-module-cache" \
  swiftc -sdk "$SDK" -target arm64-apple-macosx14.0 \
  "$REPO_ROOT/macos/Sources/ACPMonitor/Models.swift" \
  "$REPO_ROOT/macos/Sources/ACPMonitor/GraphProjection.swift" \
  "$REPO_ROOT/macos/Tests/ACPMonitorTests/MonitorModelTests.swift" \
  -o "$OUT"

"$OUT"

SETTINGS_OUT="$REPO_ROOT/build/macos-settings-checks"
env SDKROOT="$SDK" CLANG_MODULE_CACHE_PATH="$REPO_ROOT/build/clang-module-cache" \
  swiftc -sdk "$SDK" -target arm64-apple-macosx14.0 \
  "$REPO_ROOT/macos/Sources/ACPMonitor/AppSettings.swift" \
  "$REPO_ROOT/macos/Tests/ACPMonitorTests/AppSettingsTests.swift" \
  -o "$SETTINGS_OUT"

"$SETTINGS_OUT"
