#!/bin/sh
set -eu

# Reproducible local DMG build: runs build-app.sh, then packages Lynk.app and
# an Applications symlink into build/Lynk.dmg with hdiutil.
#
# Signing/notarization are parameterized, never hardcoded, and require no
# credentials for a local build:
#   ACP_LYNK_CODESIGN_IDENTITY  codesign identity for build-app.sh (default: ad-hoc "-")
#   ACP_LYNK_NOTARIZE=1         opt in to notarytool submission + stapling (default: off)
#   ACP_LYNK_NOTARIZE_PROFILE   notarytool keychain profile (required when ACP_LYNK_NOTARIZE=1)
# See macos/README.md for the full release signing/notarization flow.

REPO_ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
APP="$REPO_ROOT/build/Lynk.app"
DMG="$REPO_ROOT/build/Lynk.dmg"
STAGING="$REPO_ROOT/build/dmg-staging"

if [ -z "${ACP_LYNK_NODE_DIST_DIR:-}" ]; then
  ACP_LYNK_NODE_DIST_DIR=$(sh "$REPO_ROOT/macos/scripts/prepare-node-runtime.sh")
  export ACP_LYNK_NODE_DIST_DIR
fi

sh "$REPO_ROOT/macos/scripts/build-app.sh"

if [ ! -d "$APP" ]; then
  echo "error: $APP was not built" >&2
  exit 1
fi

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/Lynk.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname Lynk -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

if [ "${ACP_LYNK_NOTARIZE:-0}" = "1" ]; then
  : "${ACP_LYNK_NOTARIZE_PROFILE:?Set ACP_LYNK_NOTARIZE_PROFILE to a notarytool keychain profile to notarize}"
  xcrun notarytool submit "$DMG" --keychain-profile "$ACP_LYNK_NOTARIZE_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

printf '%s\n' "Built $DMG"
