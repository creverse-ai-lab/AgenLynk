#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)

# The official Node.js distribution the arm64 Lynk DMG bundles. The Gateway
# npm package ships no Node, so the app provides it, and gateway.lock.json
# (`node`) pins which one: bump version and sha256 there to upgrade. The env
# overrides exist for experiments only; build-app.sh still refuses a bundled
# Node that is not the locked version.
lock_field() {
  node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).node[process.argv[2]]))' \
    "$REPO_ROOT/gateway.lock.json" "$1"
}
DEFAULT_VERSION=$(lock_field version)
DEFAULT_SHA256=$(lock_field sha256)
VERSION=${ACP_LYNK_NODE_VERSION:-$DEFAULT_VERSION}
ARCHIVE="node-v${VERSION}-darwin-arm64.tar.xz"

if [ "$VERSION" = "$DEFAULT_VERSION" ]; then
  SHA256=${ACP_LYNK_NODE_SHA256:-$DEFAULT_SHA256}
else
  : "${ACP_LYNK_NODE_SHA256:?Set ACP_LYNK_NODE_SHA256 when overriding ACP_LYNK_NODE_VERSION}"
  SHA256=$ACP_LYNK_NODE_SHA256
fi

CACHE_ROOT=${ACP_LYNK_NODE_CACHE_DIR:-"$REPO_ROOT/build/node-runtime-cache"}
ARCHIVE_PATH="$CACHE_ROOT/$ARCHIVE"
DIST_DIR="$CACHE_ROOT/node-v${VERSION}-darwin-arm64"
URL="https://nodejs.org/download/release/v${VERSION}/${ARCHIVE}"

if [ ! -x "$DIST_DIR/bin/node" ] || [ ! -x "$DIST_DIR/bin/npm" ] || [ ! -x "$DIST_DIR/bin/npx" ]; then
  mkdir -p "$CACHE_ROOT"
  if [ ! -f "$ARCHIVE_PATH" ]; then
    printf '%s\n' "Downloading $URL" >&2
    curl --fail --location --retry 3 --output "$ARCHIVE_PATH" "$URL"
  fi
  ACTUAL=$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')
  if [ "$ACTUAL" != "$SHA256" ]; then
    echo "error: Node archive checksum mismatch: expected $SHA256, got $ACTUAL" >&2
    exit 1
  fi
  rm -rf "$DIST_DIR"
  tar -xJf "$ARCHIVE_PATH" -C "$CACHE_ROOT"
  rm -f "$ARCHIVE_PATH"
fi

printf '%s\n' "$DIST_DIR"
