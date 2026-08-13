#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
CACHE_ROOT="$REPO_ROOT/build/cache"
SCRATCH="$CACHE_ROOT/swift-build"
APP="$REPO_ROOT/build/AgenLynk.app"
LEGACY_APP="$REPO_ROOT/build/ACP Monitor.app"
CONTENTS="$APP/Contents"
PET_APP="$CONTENTS/Helpers/LynkPet.app"
PET_CONTENTS="$PET_APP/Contents"
PET_EXECUTABLE="$PET_CONTENTS/MacOS/LynkPet"
SDK=${ACP_MONITOR_SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk}
MODULE_CACHE="$CACHE_ROOT/clang-module-cache"
SWIFTPM_CACHE="$CACHE_ROOT/swiftpm-module-cache"

mkdir -p "$MODULE_CACHE"
env SDKROOT="$SDK" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_CACHE" \
  swift build --package-path "$REPO_ROOT/macos" --scratch-path "$SCRATCH" -c release
BIN_DIR=$(env SDKROOT="$SDK" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_CACHE" \
  swift build --package-path "$REPO_ROOT/macos" --scratch-path "$SCRATCH" -c release --show-bin-path)

rm -rf "$APP" "$LEGACY_APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/runtime/src" "$PET_CONTENTS/MacOS" "$PET_CONTENTS/Resources"
cp "$BIN_DIR/ACPMonitor" "$CONTENTS/MacOS/ACPMonitor"
cp "$REPO_ROOT/macos/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$REPO_ROOT/macos/Resources/ACPLogo.svg" "$CONTENTS/Resources/ACPLogo.svg"
cp "$BIN_DIR/LynkPet" "$PET_EXECUTABLE"
cp "$REPO_ROOT/macos/Resources/LynkPet-Info.plist" "$PET_CONTENTS/Info.plist"
PET_RESOURCE_BUNDLE="$BIN_DIR/ACPMonitor_LynkPet.bundle"
if [ ! -d "$PET_RESOURCE_BUNDLE" ]; then
  echo "error: bundled Pet resources not found at $PET_RESOURCE_BUNDLE" >&2
  exit 1
fi
cp -R "$PET_RESOURCE_BUNDLE" "$PET_CONTENTS/Resources/ACPMonitor_LynkPet.bundle"

# Optional build-time version overrides. The checked-in Info.plist stays the
# source of truth (still pre-1.0 — see macos/Resources/Info.plist) until
# there is actual release evidence; a release build sets these explicitly
# instead. The staged Info.plist is what build-release-manifest-cli.js later
# reads, so overriding it here (rather than only recording the env var) is
# what keeps the app bundle and release manifest from ever disagreeing.
if [ -n "${ACP_LYNK_APP_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $ACP_LYNK_APP_VERSION" "$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $ACP_LYNK_APP_VERSION" "$PET_CONTENTS/Info.plist"
fi
if [ -n "${ACP_LYNK_BUILD_NUMBER:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $ACP_LYNK_BUILD_NUMBER" "$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $ACP_LYNK_BUILD_NUMBER" "$PET_CONTENTS/Info.plist"
fi

ICONSET="$CACHE_ROOT/AppIcon.iconset"
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

# Copy the Gateway fork and AgenLynk sidecar as separate runtime namespaces.
# src/version.js fingerprints only the Gateway payload; sidecar/src/version.js
# owns the independent sidecar build id.
rm -rf "$CONTENTS/Resources/runtime/src"
cp -R "$REPO_ROOT/src" "$CONTENTS/Resources/runtime/src"
rm -rf "$CONTENTS/Resources/runtime/sidecar"
mkdir -p "$CONTENTS/Resources/runtime/sidecar"
cp "$REPO_ROOT/sidecar/package.json" "$CONTENTS/Resources/runtime/sidecar/package.json"
cp -R "$REPO_ROOT/sidecar/src" "$CONTENTS/Resources/runtime/sidecar/src"
for REQUIRED in src/index.js sidecar/src/server/monitor.js sidecar/src/local-agents/index.js sidecar/src/gateway/legacy-adapter.js; do
  if [ ! -f "$CONTENTS/Resources/runtime/$REQUIRED" ]; then
    echo "error: $REQUIRED is missing from the runtime seed" >&2
    exit 1
  fi
done

# Bundle package metadata and the agent-delegator skill so the installed
# runtime resolves node_modules/skills the same way the source checkout does
# (src/version.js hashes package.json/package-lock.json next to src/, and
# src/installer.js installs skills/agent-delegator relative to src/).
cp "$REPO_ROOT/package.json" "$CONTENTS/Resources/runtime/package.json"
cp "$REPO_ROOT/package-lock.json" "$CONTENTS/Resources/runtime/package-lock.json"
rm -rf "$CONTENTS/Resources/runtime/skills"
cp -R "$REPO_ROOT/skills" "$CONTENTS/Resources/runtime/skills"

# Distribution builds provide the complete official Node tree, including
# npm/npx. Copying only bin/node is insufficient because first-run bootstrap
# installs registry adapters through npm. Development builds deliberately omit
# Node and keep the source-tree/system fallback used by SidecarController.
NODE_DIST=${ACP_LYNK_NODE_DIST_DIR:-}
rm -rf "$CONTENTS/Resources/runtime/node"
if [ -n "$NODE_DIST" ]; then
  NODE_BIN="$NODE_DIST/bin/node"
  if [ ! -x "$NODE_BIN" ] || [ ! -x "$NODE_DIST/bin/npm" ] || [ ! -x "$NODE_DIST/bin/npx" ]; then
    echo "error: ACP_LYNK_NODE_DIST_DIR must contain executable bin/node, bin/npm, and bin/npx" >&2
    exit 1
  fi
  NODE_ARCH=$("$NODE_BIN" -e 'process.stdout.write(process.arch)')
  NODE_MAJOR=$("$NODE_BIN" -e 'process.stdout.write(String(process.versions.node.split(".")[0]))')
  if [ "$NODE_ARCH" != "arm64" ]; then
    echo "error: bundled Node must be arm64 (found '$NODE_ARCH')" >&2
    exit 1
  fi
  case "$NODE_MAJOR" in
    ''|*[!0-9]*)
      echo "error: could not read the bundled Node major version (got '$NODE_MAJOR')" >&2
      exit 1
      ;;
  esac
  if [ "$NODE_MAJOR" -lt 22 ]; then
    echo "error: bundled Node must be >=22 (found major version $NODE_MAJOR)" >&2
    exit 1
  fi
  if otool -L "$NODE_BIN" | tail -n +2 | grep -qE '@rpath|/opt/|/usr/local/|Cellar'; then
    echo "error: $NODE_BIN depends on non-system shared libraries; use the official nodejs.org darwin-arm64 distribution" >&2
    exit 1
  fi
  cp -R "$NODE_DIST" "$CONTENTS/Resources/runtime/node"

  # Drop the parts of the official distribution the shipped runtime never
  # executes. include/node is 62MB of C++ headers for compiling native addons;
  # node-gyp downloads its own headers into ~/.node-gyp and never reads these.
  # corepack is the yarn/pnpm shim, and Lynk only ever runs npm/npx. Together
  # with the docs this is ~64MB of payload that also has to be hashed into the
  # runtime manifest on every launch. bin/node, bin/npm, and bin/npx (verified
  # above) and lib/node_modules/npm all stay.
  for UNUSED in include lib/node_modules/corepack bin/corepack share CHANGELOG.md README.md; do
    rm -rf "$CONTENTS/Resources/runtime/node/$UNUSED"
  done
  for REQUIRED in bin/node bin/npm bin/npx lib/node_modules/npm; do
    if [ ! -e "$CONTENTS/Resources/runtime/node/$REQUIRED" ]; then
      echo "error: trimming the bundled Node distribution removed $REQUIRED" >&2
      exit 1
    fi
  done
fi

# Bundle production dependencies. Reuse the checkout's installed node_modules
# when present (package.json declares no devDependencies, so it is already
# production-only); otherwise install them fresh from the lockfile.
rm -rf "$CONTENTS/Resources/runtime/node_modules"
if [ -d "$REPO_ROOT/node_modules" ]; then
  cp -R "$REPO_ROOT/node_modules" "$CONTENTS/Resources/runtime/node_modules"
else
  ( cd "$CONTENTS/Resources/runtime" && npm ci --omit=dev )
fi

# Sign nested Mach-O files explicitly. Distribution signing uses hardened
# runtime and a timestamp; ad-hoc development signing omits those flags.
CODESIGN_IDENTITY=${ACP_LYNK_CODESIGN_IDENTITY:--}
if [ "$CODESIGN_IDENTITY" = "-" ]; then
  SIGN_FLAGS=""
else
  SIGN_FLAGS="--options runtime --timestamp"
fi
find "$CONTENTS/Resources/runtime" -type f | while IFS= read -r FILE; do
  if file "$FILE" | grep -q 'Mach-O'; then
    if [ "$FILE" = "$CONTENTS/Resources/runtime/node/bin/node" ]; then
      # shellcheck disable=SC2086
      codesign --force $SIGN_FLAGS --entitlements "$REPO_ROOT/macos/Resources/Node.entitlements" --sign "$CODESIGN_IDENTITY" "$FILE"
    else
      # shellcheck disable=SC2086
      codesign --force $SIGN_FLAGS --sign "$CODESIGN_IDENTITY" "$FILE"
    fi
  fi
done

# Distribution builds only: snapshot this seed's gatewayVersion/gatewayBuildId
# (reused as-is from src/version.js, not reinvented), gatewayApiVersion,
# nodeVersion, and a complete payload checksum inventory into
# runtime-manifest.json. This runs *after* the nested-file signing loop above
# but *before* the outer ACPMonitor/app-bundle signing below, for two
# reasons: signing rewrites the embedded signature of every Mach-O file it
# touches (the node binary, native modules), so hashing beforehand would
# snapshot bytes that no longer match what actually ships; and the outer
# app-bundle signature below seals every file under Resources (including
# this one), so runtime-manifest.json must already exist by then or the
# final `codesign --verify --deep --strict` would see an unsealed extra file.
# RuntimeProvisioner (Swift) spawns runtime-installer-cli.js to copy this
# seed into ~/.acp-gateway/runtime/versions/<gatewayVersion>-<gatewayBuildId>/
# on first run and reject an incomplete/corrupt copy using this manifest.
rm -f "$CONTENTS/Resources/runtime/runtime-manifest.json"
if [ -x "$CONTENTS/Resources/runtime/node/bin/node" ]; then
  BUILD_NODE=$(command -v node || true)
  if [ -z "$BUILD_NODE" ]; then
    echo "error: a system Node is required at build time to generate runtime-manifest.json" >&2
    exit 1
  fi
  "$BUILD_NODE" "$REPO_ROOT/src/build-runtime-manifest-cli.js" "$CONTENTS/Resources/runtime"
fi

# LynkPet is a nested LSUIElement helper app. Validate its pure contract/layout
# checks and resources, then sign inside-out before sealing the parent app.
for PET_ASSET in chatgpt.jpg claude.jpg grok.jpg; do
  if [ ! -f "$PET_CONTENTS/Resources/ACPMonitor_LynkPet.bundle/$PET_ASSET" ]; then
    echo "error: bundled Pet asset is missing: $PET_ASSET" >&2
    exit 1
  fi
done
"$PET_EXECUTABLE" --self-test
# shellcheck disable=SC2086
codesign --force $SIGN_FLAGS --sign "$CODESIGN_IDENTITY" "$PET_EXECUTABLE"
# shellcheck disable=SC2086
codesign --force $SIGN_FLAGS --sign "$CODESIGN_IDENTITY" "$PET_APP"

# shellcheck disable=SC2086
codesign --force $SIGN_FLAGS --sign "$CODESIGN_IDENTITY" "$CONTENTS/MacOS/ACPMonitor"
# shellcheck disable=SC2086
codesign --force $SIGN_FLAGS --sign "$CODESIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

# Packaging smoke check (distribution builds only): with PATH restricted to
# the installed runtime's own bin plus minimal system paths — no Homebrew,
# no other system Node — node/npm/npx must still execute. npm/npx are
# `#!/usr/bin/env node` shims, so this also proves the runtime's own PATH
# ordering (bin first) resolves them to the bundled node, not any other one.
if [ -x "$CONTENTS/Resources/runtime/node/bin/node" ]; then
  RESTRICTED_PATH="$CONTENTS/Resources/runtime/node/bin:/usr/bin:/bin"
  env -i PATH="$RESTRICTED_PATH" "$CONTENTS/Resources/runtime/node/bin/node" --version >/dev/null
  env -i PATH="$RESTRICTED_PATH" "$CONTENTS/Resources/runtime/node/bin/npm" --version >/dev/null
  env -i PATH="$RESTRICTED_PATH" "$CONTENTS/Resources/runtime/node/bin/npx" --version >/dev/null
  printf '%s\n' "Bundled node/npm/npx executed with a Homebrew/system-Node-free PATH"
fi
printf '%s\n' "Built $APP"
