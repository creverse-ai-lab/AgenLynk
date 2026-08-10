#!/bin/sh
set -eu

# Pinned official Node.js LTS distribution used by the arm64 Lynk DMG.
# Override both version and checksum together when intentionally upgrading.
VERSION=${ACP_LYNK_NODE_VERSION:-22.23.2}
ARCHIVE="node-v${VERSION}-darwin-arm64.tar.xz"
DEFAULT_VERSION=22.23.2
DEFAULT_SHA256=5eff7a9011895aae3f29d06f167b84a62b028a591370c7cafb59103559fd26e1

if [ "$VERSION" = "$DEFAULT_VERSION" ]; then
  SHA256=${ACP_LYNK_NODE_SHA256:-$DEFAULT_SHA256}
else
  : "${ACP_LYNK_NODE_SHA256:?Set ACP_LYNK_NODE_SHA256 when overriding ACP_LYNK_NODE_VERSION}"
  SHA256=$ACP_LYNK_NODE_SHA256
fi

REPO_ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
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
fi

printf '%s\n' "$DIST_DIR"
