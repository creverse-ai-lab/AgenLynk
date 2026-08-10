#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
SDK=${ACP_MONITOR_SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk}
CACHE_ROOT="$REPO_ROOT/build/cache"
CHECK_ROOT="$CACHE_ROOT/checks"
MODULE_CACHE="$CACHE_ROOT/clang-module-cache"
OUT="$CHECK_ROOT/models"
SHARED_DIR="$CACHE_ROOT/shared"
mkdir -p "$CHECK_ROOT" "$MODULE_CACHE" "$SHARED_DIR"

# ACPShared is a real SwiftPM library target, so these standalone check binaries
# have to build and link it the same way `swift build` does.
env SDKROOT="$SDK" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
  swiftc -sdk "$SDK" -target arm64-apple-macosx14.0 \
  -emit-module -emit-library -static -parse-as-library \
  -module-name ACPShared \
  -emit-module-path "$SHARED_DIR/ACPShared.swiftmodule" \
  -o "$SHARED_DIR/libACPShared.a" \
  "$REPO_ROOT/macos/Sources/ACPShared/Timestamp.swift"
SHARED_FLAGS="-I $SHARED_DIR -L $SHARED_DIR -lACPShared"

env SDKROOT="$SDK" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
  swiftc -sdk "$SDK" -target arm64-apple-macosx14.0 $SHARED_FLAGS \
  "$REPO_ROOT/macos/Sources/ACPMonitor/Models.swift" \
  "$REPO_ROOT/macos/Sources/ACPMonitor/GraphProjection.swift" \
  "$REPO_ROOT/macos/Tests/ACPMonitorTests/MonitorModelTests.swift" \
  -o "$OUT"

"$OUT"

SETTINGS_OUT="$CHECK_ROOT/settings"
env SDKROOT="$SDK" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
  swiftc -sdk "$SDK" -target arm64-apple-macosx14.0 \
  "$REPO_ROOT/macos/Sources/ACPMonitor/AppSettings.swift" \
  "$REPO_ROOT/macos/Tests/ACPMonitorTests/AppSettingsTests.swift" \
  -o "$SETTINGS_OUT"

"$SETTINGS_OUT"

PET_CONTROLLER_OUT="$CHECK_ROOT/pet-controller"
env SDKROOT="$SDK" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
  swiftc -sdk "$SDK" -target arm64-apple-macosx14.0 $SHARED_FLAGS \
  "$REPO_ROOT/macos/Sources/ACPMonitor/Models.swift" \
  "$REPO_ROOT/macos/Sources/ACPMonitor/PetController.swift" \
  "$REPO_ROOT/macos/Tests/ACPMonitorTests/PetControllerTests.swift" \
  -o "$PET_CONTROLLER_OUT"

"$PET_CONTROLLER_OUT"

ONBOARDING_OUT="$CHECK_ROOT/onboarding"
env SDKROOT="$SDK" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
  swiftc -sdk "$SDK" -target arm64-apple-macosx14.0 \
  "$REPO_ROOT/macos/Sources/ACPMonitor/BundledRuntime.swift" \
  "$REPO_ROOT/macos/Sources/ACPMonitor/InstallStateChecker.swift" \
  "$REPO_ROOT/macos/Sources/ACPMonitor/InstallerController.swift" \
  "$REPO_ROOT/macos/Sources/ACPMonitor/RuntimeProvisioner.swift" \
  "$REPO_ROOT/macos/Sources/ACPMonitor/SeedNodeProcess.swift" \
  "$REPO_ROOT/macos/Tests/ACPMonitorTests/OnboardingLogicTests.swift" \
  -o "$ONBOARDING_OUT"

"$ONBOARDING_OUT"

for SCRIPT in build-app.sh build-dmg.sh clean-derived.sh prepare-node-runtime.sh verify-dmg.sh; do
  sh -n "$REPO_ROOT/macos/scripts/$SCRIPT"
done
printf '%s\n' "Shell build script syntax checks passed"
