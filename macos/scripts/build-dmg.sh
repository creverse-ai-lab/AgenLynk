#!/bin/sh
set -eu

# Reproducible local DMG build: runs build-app.sh, packages AgenLynk.app and an
# Applications symlink into build/AgenLynk.dmg with hdiutil, then (after any
# signing/notarization/stapling) verifies the final DMG and generates its
# release artifacts: build/AgenLynk.dmg.sha256 and build/AgenLynk.release.json.
#
# Signing/notarization are parameterized, never hardcoded, and require no
# credentials for a local build:
#   ACP_LYNK_CODESIGN_IDENTITY  codesign identity for build-app.sh (default: ad-hoc "-")
#   ACP_LYNK_NOTARIZE=1         opt in to notarytool submission + stapling (default: off)
#   ACP_LYNK_NOTARIZE_PROFILE   notarytool keychain profile (required when ACP_LYNK_NOTARIZE=1)
# Build-time version overrides (see build-app.sh; the checked-in Info.plist
# stays the source of truth otherwise):
#   ACP_LYNK_APP_VERSION        overrides CFBundleShortVersionString
#   ACP_LYNK_BUILD_NUMBER       overrides CFBundleVersion
# See macos/README.md for the full release signing/notarization flow.

REPO_ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
APP="$REPO_ROOT/build/AgenLynk.app"
DMG="$REPO_ROOT/build/AgenLynk.dmg"
RELEASE_JSON="$REPO_ROOT/build/AgenLynk.release.json"
STAGING="$REPO_ROOT/build/dmg-staging"

cleanup() {
  rm -rf "$STAGING"
}
trap cleanup EXIT INT TERM

if [ -z "${ACP_LYNK_NODE_DIST_DIR:-}" ]; then
  ACP_LYNK_NODE_DIST_DIR=$(sh "$REPO_ROOT/macos/scripts/prepare-node-runtime.sh")
  export ACP_LYNK_NODE_DIST_DIR
fi

sh "$REPO_ROOT/macos/scripts/build-app.sh"

if [ ! -d "$APP" ]; then
  echo "error: $APP was not built" >&2
  exit 1
fi

rm -rf "$STAGING" "$DMG" "$DMG.sha256" "$RELEASE_JSON"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/AgenLynk.app"
ln -s /Applications "$STAGING/Applications"

# ULMO (LZMA) rather than the conventional UDZO (zlib): the payload is
# dominated by a 245MB agent binary and a 107MB Node binary, and LZMA takes the
# image from ~158MB to ~109MB. It costs about a minute of build time and needs
# macOS 10.15+ to mount, which is far below the app's own 14.0 minimum.
hdiutil create -volname AgenLynk -srcfolder "$STAGING" -ov -format ULMO "$DMG"
cleanup

if [ "${ACP_LYNK_NOTARIZE:-0}" = "1" ]; then
  : "${ACP_LYNK_NOTARIZE_PROFILE:?Set ACP_LYNK_NOTARIZE_PROFILE to a notarytool keychain profile to notarize}"
  xcrun notarytool submit "$DMG" --keychain-profile "$ACP_LYNK_NOTARIZE_PROFILE" --wait
  xcrun stapler staple "$DMG"
  NOTARIZED=true
  STAPLED=true
else
  NOTARIZED=false
  STAPLED=false
fi

# build/AgenLynk.dmg.sha256 in the conventional `shasum -c`-compatible format.
( cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )
DMG_SHA256=$(awk '{print $1}' "$DMG.sha256")
DMG_BYTES=$(stat -f%z "$DMG")

# Evidence-based signing mode/identity: read back what codesign actually put
# on the built app rather than trusting the input env var, so a request for
# a Developer ID identity that silently fell back to ad-hoc can never be
# misreported as signed.
if ! SIGN_INFO=$(codesign -dvvv "$APP" 2>&1); then
  echo "error: could not inspect the built app's signature" >&2
  exit 1
fi
if printf '%s' "$SIGN_INFO" | grep -q '^Signature=adhoc$'; then
  SIGNING_MODE="ad-hoc"
  SIGNING_IDENTITY=""
elif printf '%s' "$SIGN_INFO" | grep -q '^Authority='; then
  SIGNING_MODE="developer-id"
  SIGNING_IDENTITY=$(printf '%s' "$SIGN_INFO" | awk -F'=' '/^Authority=/{print $2; exit}')
else
  echo "error: codesign output proves neither an ad-hoc nor Developer ID signature" >&2
  exit 1
fi

ARCH=$(lipo -archs "$APP/Contents/MacOS/ACPMonitor")
APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
APP_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
MIN_MACOS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")

BUILD_NODE=$(command -v node || true)
: "${BUILD_NODE:?a system Node is required at build time to generate AgenLynk.release.json}"
SIGNING_IDENTITY_ARGS=""
if [ -n "$SIGNING_IDENTITY" ]; then
  SIGNING_IDENTITY_ARGS="--signing-identity=$SIGNING_IDENTITY"
fi
# shellcheck disable=SC2086
"$BUILD_NODE" "$REPO_ROOT/src/build-release-manifest-cli.js" \
  --runtime-root "$APP/Contents/Resources/gateway-seed" \
  --sidecar-root "$APP/Contents/Resources/sidecar" \
  --app-name "AgenLynk.app" \
  --app-version "$APP_VERSION" \
  --app-build "$APP_BUILD" \
  --bundle-id "$BUNDLE_ID" \
  --min-macos "$MIN_MACOS" \
  --arch "$ARCH" \
  --dmg-name "$(basename "$DMG")" \
  --dmg-bytes "$DMG_BYTES" \
  --dmg-sha256 "$DMG_SHA256" \
  --signing-mode "$SIGNING_MODE" \
  $SIGNING_IDENTITY_ARGS \
  --notarized "$NOTARIZED" \
  --stapled "$STAPLED" \
  --out "$RELEASE_JSON"

# Verify the final, post-notarization DMG exactly once after both sibling
# artifacts exist. If verification fails, remove metadata that might
# otherwise make the invalid DMG look releasable while retaining the image
# itself for diagnosis.
if ! sh "$REPO_ROOT/macos/scripts/verify-dmg.sh" "$DMG"; then
  rm -f "$DMG.sha256" "$RELEASE_JSON"
  exit 1
fi

printf '%s\n' "Built $DMG"
printf '%s\n' "Checksum: $DMG.sha256"
printf '%s\n' "Release manifest: $RELEASE_JSON"
