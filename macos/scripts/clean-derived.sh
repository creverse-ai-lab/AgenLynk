#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
BUILD_DIR="$REPO_ROOT/build"

# Preserve release outputs (AgenLynk.app, AgenLynk.dmg, checksum, release manifest)
# and the extracted Node distribution. Remove only reproducible intermediates.
rm -rf \
  "$BUILD_DIR/cache" \
  "$BUILD_DIR/dmg-staging" \
  "$BUILD_DIR/macos-swift" \
  "$BUILD_DIR/clang-module-cache" \
  "$BUILD_DIR/swiftpm-module-cache" \
  "$BUILD_DIR/AppIcon.iconset" \
  "$BUILD_DIR/macos-model-checks" \
  "$BUILD_DIR/macos-settings-checks" \
  "$BUILD_DIR/macos-onboarding-checks" \
  "$BUILD_DIR/macos-pet-check"

for ARCHIVE_PATH in "$BUILD_DIR"/node-runtime-cache/node-v*-darwin-arm64.tar.xz; do
  [ -f "$ARCHIVE_PATH" ] || continue
  rm -f "$ARCHIVE_PATH"
done

# Swift occasionally leaves empty atomic-save placeholders beside its old
# scratch directory. Remove only empty directories matching that exact shape.
for PLACEHOLDER in \
  "$BUILD_DIR"/\(A\ Document\ Being\ Saved\ By\ swift-build* \
  "$BUILD_DIR"/\(A\ Document\ Being\ Saved\ By\ swift-test*; do
  [ -d "$PLACEHOLDER" ] || continue
  rmdir "$PLACEHOLDER" 2>/dev/null || true
done

printf '%s\n' "Removed reproducible macOS build/test intermediates; release artifacts and extracted Node runtime were preserved."
