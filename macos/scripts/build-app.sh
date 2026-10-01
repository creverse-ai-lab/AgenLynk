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
if [ -n "${ACP_MONITOR_SDKROOT:-}" ]; then
  SDK=$ACP_MONITOR_SDKROOT
else
  SDK=$(xcrun --sdk macosx --show-sdk-path)
fi
MODULE_CACHE="$CACHE_ROOT/clang-module-cache"
SWIFTPM_CACHE="$CACHE_ROOT/swiftpm-module-cache"

mkdir -p "$MODULE_CACHE"
env SDKROOT="$SDK" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_CACHE" \
  swift build --package-path "$REPO_ROOT/macos" --scratch-path "$SCRATCH" -c release
BIN_DIR=$(env SDKROOT="$SDK" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_CACHE" \
  swift build --package-path "$REPO_ROOT/macos" --scratch-path "$SCRATCH" -c release --show-bin-path)

rm -rf "$APP" "$LEGACY_APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$PET_CONTENTS/MacOS" "$PET_CONTENTS/Resources"
cp "$BIN_DIR/ACPMonitor" "$CONTENTS/MacOS/ACPMonitor"
cp "$REPO_ROOT/macos/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$REPO_ROOT/macos/Resources/ACPLogo.svg" "$CONTENTS/Resources/ACPLogo.svg"
# Provider marks for the dashboard, the same images the Pet ships.
mkdir -p "$CONTENTS/Resources/ProviderIcons"
cp "$REPO_ROOT/macos/Sources/LynkPet/Resources/claude.jpg" "$CONTENTS/Resources/ProviderIcons/claude.jpg"
cp "$REPO_ROOT/macos/Sources/LynkPet/Resources/chatgpt.jpg" "$CONTENTS/Resources/ProviderIcons/codex.jpg"
cp "$REPO_ROOT/macos/Sources/LynkPet/Resources/grok.jpg" "$CONTENTS/Resources/ProviderIcons/grok.jpg"
cp "$BIN_DIR/LynkPet" "$PET_EXECUTABLE"
cp "$REPO_ROOT/macos/Resources/LynkPet-Info.plist" "$PET_CONTENTS/Info.plist"
PET_RESOURCE_BUNDLE="$BIN_DIR/ACPMonitor_LynkPet.bundle"
if [ ! -d "$PET_RESOURCE_BUNDLE" ]; then
  echo "error: bundled Pet resources not found at $PET_RESOURCE_BUNDLE" >&2
  exit 1
fi
cp -R "$PET_RESOURCE_BUNDLE" "$PET_CONTENTS/Resources/ACPMonitor_LynkPet.bundle"

# Optional build-time version overrides. The checked-in Info.plist stays the
# source of truth. A prerelease or release build can still set these explicitly.
# The staged Info.plist is what build-release-manifest-cli.js later
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

# Assemble the ownership roots. node_modules/acp-gateway-daemon is unpacked
# only from the npm tarball gateway.lock.json pins (sha512 integrity and npm
# provenance verified by fetch-gateway-runtime.js), with gateway/ as a relative
# alias to it for agent MCP configs written against runtime/current/gateway;
# sidecar/ is app-owned and is never copied into an installed Gateway version;
# app-runtime/ contains only AgenLynk's install/activate tooling, never Gateway
# implementation code.
GATEWAY_SEED="$CONTENTS/Resources/gateway-seed"
GATEWAY_PACKAGE="$GATEWAY_SEED/node_modules/acp-gateway-daemon"
SIDECAR_ROOT="$CONTENTS/Resources/sidecar"
rm -rf "$GATEWAY_SEED" "$SIDECAR_ROOT"
mkdir -p "$GATEWAY_SEED/app-runtime" "$SIDECAR_ROOT"
node "$REPO_ROOT/scripts/fetch-gateway-runtime.js" --output "$GATEWAY_SEED"
cp "$REPO_ROOT/gateway.lock.json" "$GATEWAY_SEED/gateway.lock.json"

for FILE in \
  build-runtime-manifest-cli.js \
  runtime-installer-cli.js \
  runtime-installer.js \
  runtime-lock.js \
  runtime-manifest.js \
  runtime-pointer.js \
  runtime-smoke-check.js \
  runtime-staging.js \
  runtime-updater-cli.js \
  runtime-updater.js \
  runtime-usage.js \
  verify-runtime-manifest-cli.js; do
  cp "$REPO_ROOT/src/$FILE" "$GATEWAY_SEED/app-runtime/$FILE"
done

cp "$REPO_ROOT/sidecar/package.json" "$SIDECAR_ROOT/package.json"
cp -R "$REPO_ROOT/sidecar/src" "$SIDECAR_ROOT/src"
# The monitoring hook script the sidecar installs for Claude/Codex/Grok.
cp -R "$REPO_ROOT/sidecar/hooks" "$SIDECAR_ROOT/hooks"
for REQUIRED in \
  gateway-seed/node_modules/acp-gateway-daemon/src/index.js \
  gateway-seed/node_modules/acp-gateway-daemon/src/bootstrap.js \
  gateway-seed/node_modules/acp-gateway-daemon/gateway-client/index.js \
  gateway-seed/gateway/src/index.js \
  gateway-seed/gateway/src/guide.js \
  gateway-seed/gateway-package.json \
  gateway-seed/app-runtime/runtime-installer-cli.js \
  sidecar/src/server/monitor.js \
  sidecar/src/local-agents/index.js \
  sidecar/src/gateway/client.js \
  sidecar/hooks/agenlynk-hook.sh; do
  if [ ! -f "$CONTENTS/Resources/$REQUIRED" ]; then
    echo "error: $REQUIRED is missing from the packaged resource roots" >&2
    exit 1
  fi
done

# The npm package ships no Node, so the app provides it: distribution builds
# bundle the complete official Node tree gateway.lock.json pins (`node`),
# including npm/npx. Copying only bin/node is insufficient because first-run
# bootstrap installs registry adapters through npm. Development builds
# deliberately omit Node and keep the source-tree/system fallback used by
# SidecarController.
NODE_DIST=${ACP_LYNK_NODE_DIST_DIR:-}
LOCKED_NODE_VERSION=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).node.version)' "$REPO_ROOT/gateway.lock.json")
rm -rf "$GATEWAY_SEED/node"
if [ -n "$NODE_DIST" ]; then
  NODE_BIN="$NODE_DIST/bin/node"
  if [ ! -x "$NODE_BIN" ] || [ ! -x "$NODE_DIST/bin/npm" ] || [ ! -x "$NODE_DIST/bin/npx" ]; then
    echo "error: ACP_LYNK_NODE_DIST_DIR must contain executable bin/node, bin/npm, and bin/npx" >&2
    exit 1
  fi
  NODE_ARCH=$("$NODE_BIN" -e 'process.stdout.write(process.arch)')
  NODE_MAJOR=$("$NODE_BIN" -e 'process.stdout.write(String(process.versions.node.split(".")[0]))')
  NODE_VERSION=$("$NODE_BIN" -e 'process.stdout.write(process.versions.node)')
  if [ "$NODE_ARCH" != "arm64" ]; then
    echo "error: bundled Node must be arm64 (found '$NODE_ARCH')" >&2
    exit 1
  fi
  if [ "$NODE_VERSION" != "$LOCKED_NODE_VERSION" ]; then
    echo "error: bundled Node $NODE_VERSION is not the Node $LOCKED_NODE_VERSION gateway.lock.json pins" >&2
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
  cp -R "$NODE_DIST" "$GATEWAY_SEED/node"

  # Drop the parts of the official distribution the shipped runtime never
  # executes. include/node is 62MB of C++ headers for compiling native addons;
  # node-gyp downloads its own headers into ~/.node-gyp and never reads these.
  # corepack is the yarn/pnpm shim, and Lynk only ever runs npm/npx. Together
  # with the docs this is ~64MB of payload that also has to be hashed into the
  # runtime manifest on every launch. bin/node, bin/npm, and bin/npx (verified
  # above) and lib/node_modules/npm all stay.
  for UNUSED in include lib/node_modules/corepack bin/corepack share CHANGELOG.md README.md; do
    rm -rf "$GATEWAY_SEED/node/$UNUSED"
  done
  for REQUIRED in bin/node bin/npm bin/npx lib/node_modules/npm; do
    if [ ! -e "$GATEWAY_SEED/node/$REQUIRED" ]; then
      echo "error: trimming the bundled Node distribution removed $REQUIRED" >&2
      exit 1
    fi
  done
fi

# Gateway dependencies are bundled inside the verified npm tarball.
# The app sidecar intentionally has no third-party runtime dependency.

# Sign nested Mach-O files explicitly. Distribution signing uses hardened
# runtime and a timestamp; ad-hoc development signing omits those flags.
# Node/JIT entitlements apply only to the bundled official Node binary.
CODESIGN_IDENTITY=${ACP_LYNK_CODESIGN_IDENTITY:--}
if [ "$CODESIGN_IDENTITY" = "-" ]; then
  SIGN_FLAGS=""
else
  SIGN_FLAGS="--options runtime --timestamp"
fi

if [ -f "$GATEWAY_SEED/node/bin/node" ]; then
  # shellcheck disable=SC2086
  codesign --force $SIGN_FLAGS --entitlements "$REPO_ROOT/macos/Resources/Node.entitlements" --sign "$CODESIGN_IDENTITY" "$GATEWAY_SEED/node/bin/node"
fi

# The npm package is shipped byte-for-byte as its integrity pins it, so
# nothing inside it can be re-signed. Gateway 1.7 bundles no native binary
# (the Claude platform helper is left out; Workers run the user's own CLI).
# Should one ever appear it must already carry a valid signature.
OTHER_UNSIGNED=""
while IFS= read -r FILE; do
  [ -n "$FILE" ] || continue
  file "$FILE" | grep -q 'Mach-O' || continue
  REL=${FILE#"$GATEWAY_PACKAGE/"}
  if ! codesign --verify --strict "$FILE" >/dev/null 2>&1; then
    echo "error: official Gateway Mach-O is not safely signed: $REL" >&2
    OTHER_UNSIGNED=1
  fi
done <<EOF
$(find "$GATEWAY_PACKAGE" -type f)
EOF
if [ -n "$OTHER_UNSIGNED" ]; then
  exit 1
fi

while IFS= read -r FILE; do
  [ -n "$FILE" ] || continue
  file "$FILE" | grep -q 'Mach-O' || continue
  # shellcheck disable=SC2086
  codesign --force $SIGN_FLAGS --sign "$CODESIGN_IDENTITY" "$FILE"
done <<EOF
$(find "$SIDECAR_ROOT" -type f)
EOF

# Distribution builds only: snapshot this seed's gatewayVersion, gatewayBuildId
# (the same src digest the daemon reports), the pinned package integrity,
# gatewayApiVersion, nodeVersion, and a complete payload checksum inventory into
# runtime-manifest.json. This runs *after* the nested-file signing loop above
# but *before* the outer ACPMonitor/app-bundle signing below, for two
# reasons: signing rewrites the embedded signature of every Mach-O file it
# touches (the node binary, native modules), so hashing beforehand would
# snapshot bytes that no longer match what actually ships; and the outer
# app-bundle signature below seals every file under Resources (including
# this one), so runtime-manifest.json must already exist by then or the
# final `codesign --verify --deep --strict` would see an unsealed extra file.
# RuntimeProvisioner (Swift) spawns runtime-installer-cli.js to copy this
# seed into ~/.acp-gateway/runtime/versions/<gatewayVersion>-<runtimeBuildId>/
# on first run and reject an incomplete/corrupt copy using this manifest.
rm -f "$GATEWAY_SEED/runtime-manifest.json"
if [ -x "$GATEWAY_SEED/node/bin/node" ]; then
  BUILD_NODE=$(command -v node || true)
  if [ -z "$BUILD_NODE" ]; then
    echo "error: a system Node is required at build time to generate runtime-manifest.json" >&2
    exit 1
  fi
  "$BUILD_NODE" "$GATEWAY_SEED/app-runtime/build-runtime-manifest-cli.js" "$GATEWAY_SEED"
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
if [ -x "$GATEWAY_SEED/node/bin/node" ]; then
  RESTRICTED_PATH="$GATEWAY_SEED/node/bin:/usr/bin:/bin"
  env -i PATH="$RESTRICTED_PATH" "$GATEWAY_SEED/node/bin/node" --version >/dev/null
  env -i PATH="$RESTRICTED_PATH" "$GATEWAY_SEED/node/bin/npm" --version >/dev/null
  env -i PATH="$RESTRICTED_PATH" "$GATEWAY_SEED/node/bin/npx" --version >/dev/null
  printf '%s\n' "Bundled node/npm/npx executed with a Homebrew/system-Node-free PATH"
fi
printf '%s\n' "Built $APP"
