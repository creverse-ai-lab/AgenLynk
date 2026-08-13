#!/bin/sh
set -eu

# Read-only verification of a packaged Lynk DMG. Never mutates the DMG or
# its mounted contents. Usage:
#   macos/scripts/verify-dmg.sh [path/to/AgenLynk.dmg]
# Defaults to build/AgenLynk.dmg. See macos/README.md for the full release flow.

REPO_ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
DMG=${1:-"$REPO_ROOT/build/AgenLynk.dmg"}

if [ ! -f "$DMG" ]; then
  echo "error: $DMG not found" >&2
  exit 1
fi

SYSTEM_NODE=$(command -v node || true)
if [ -z "$SYSTEM_NODE" ]; then
  echo "error: verify-dmg.sh requires a system Node to check the runtime manifest" >&2
  exit 1
fi

printf '%s\n' "Verifying $DMG"

# 1) Image integrity (internal UDIF checksum), before mounting anything.
hdiutil verify "$DMG"
printf '%s\n' "hdiutil verify passed"

# 2) Mount read-only/no-browse at a private mktemp mountpoint, with cleanup
# guaranteed on any exit path. Never attach with write access.
MOUNT_POINT=$(mktemp -d "${TMPDIR:-/tmp}/acp-lynk-dmg-verify.XXXXXX")
cleanup() {
  hdiutil detach "$MOUNT_POINT" -quiet -force >/dev/null 2>&1 || true
  rmdir "$MOUNT_POINT" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

hdiutil attach "$DMG" -mountpoint "$MOUNT_POINT" -readonly -nobrowse -noautofsck -noautoopen -quiet

APP="$MOUNT_POINT/AgenLynk.app"
if [ ! -d "$APP" ]; then
  echo "error: $APP not found inside the DMG" >&2
  exit 1
fi

if [ ! -L "$MOUNT_POINT/Applications" ]; then
  echo "error: DMG is missing the /Applications symlink" >&2
  exit 1
fi
APPLICATIONS_TARGET=$(readlink "$MOUNT_POINT/Applications")
if [ "$APPLICATIONS_TARGET" != "/Applications" ]; then
  echo "error: DMG's Applications symlink points to '$APPLICATIONS_TARGET', expected /Applications" >&2
  exit 1
fi
printf '%s\n' "AgenLynk.app and an /Applications symlink are both present"

PET_APP="$APP/Contents/Helpers/LynkPet.app"
PET_EXECUTABLE="$PET_APP/Contents/MacOS/LynkPet"
PET_RESOURCES="$PET_APP/Contents/Resources/ACPMonitor_LynkPet.bundle"
if [ ! -x "$PET_EXECUTABLE" ]; then
  echo "error: bundled default Pet executable is missing" >&2
  exit 1
fi
for PET_ASSET in chatgpt.jpg claude.jpg grok.jpg; do
  if [ ! -f "$PET_RESOURCES/$PET_ASSET" ]; then
    echo "error: bundled default Pet asset is missing: $PET_ASSET" >&2
    exit 1
  fi
done
"$PET_EXECUTABLE" --self-test
codesign --verify --deep --strict "$PET_APP"
printf '%s\n' "Bundled default Pet self-test and code signature passed"

# A binary that still points at the build machine's scratch directory resolves
# something through a path no user has. SwiftPM's generated Bundle.module does
# exactly this, which once made the Pet trap on every Mac but the one that
# built it; the Pet's self-test proves its own resources load, and this proves
# nothing else acquired the same dependency.
# Plain `strings` (not `strings -`) deliberately: the debug map lists every
# .o file by absolute path, and those are symbol references, not something the
# program resolves at run time.
for BINARY in "$APP/Contents/MacOS/ACPMonitor" "$PET_EXECUTABLE"; do
  if strings "$BINARY" | grep -qE '/\.build/|/swift-build/'; then
    echo "error: $(basename "$BINARY") references a build-machine path:" >&2
    strings "$BINARY" | grep -E '/\.build/|/swift-build/' | sort -u | head -5 >&2
    exit 1
  fi
done
printf '%s\n' "No shipped binary resolves through a build-machine path"

RUNTIME_DIR="$APP/Contents/Resources/runtime"
if [ ! -f "$RUNTIME_DIR/src/index.js" ] || [ ! -f "$RUNTIME_DIR/sidecar/src/server/monitor.js" ] || [ ! -f "$RUNTIME_DIR/package.json" ]; then
  echo "error: $RUNTIME_DIR does not look like a bundled runtime seed" >&2
  exit 1
fi
"$SYSTEM_NODE" "$REPO_ROOT/src/verify-runtime-manifest-cli.js" "$RUNTIME_DIR"

codesign --verify --deep --strict "$APP"
printf '%s\n' "codesign --verify passed"

# Bundled Node must execute entirely from the mounted image, proving it does
# not depend on a system Node/npm/npx at all. A development build with no
# bundled Node distribution skips this (see build-app.sh).
if [ -x "$RUNTIME_DIR/node/bin/node" ]; then
  RESTRICTED_PATH="$RUNTIME_DIR/node/bin:/usr/bin:/bin"
  env -i PATH="$RESTRICTED_PATH" "$RUNTIME_DIR/node/bin/node" --version >/dev/null
  env -i PATH="$RESTRICTED_PATH" "$RUNTIME_DIR/node/bin/npm" --version >/dev/null
  env -i PATH="$RESTRICTED_PATH" "$RUNTIME_DIR/node/bin/npx" --version >/dev/null
  printf '%s\n' "Bundled node/npm/npx executed from the mounted DMG with a Homebrew/system-Node-free PATH"
else
  printf '%s\n' "note: no bundled Node distribution in this DMG (development build)"
fi

# Cleanly unmount before touching sibling release artifacts on the host
# filesystem — nothing below this line reads from $MOUNT_POINT.
hdiutil detach "$MOUNT_POINT" -quiet
trap - EXIT INT TERM
rmdir "$MOUNT_POINT" 2>/dev/null || true

# 3) Release checksum/manifest agreement, only when those sibling artifacts
# exist (they may not yet, e.g. when build-dmg.sh calls this script before
# generating them).
ACTUAL_SHA256=$(shasum -a 256 "$DMG" | awk '{print $1}')
ACTUAL_BYTES=$(stat -f%z "$DMG")

SHA_FILE="$DMG.sha256"
if [ -f "$SHA_FILE" ]; then
  RECORDED_SHA256=$(awk '{print $1}' "$SHA_FILE")
  if [ "$RECORDED_SHA256" != "$ACTUAL_SHA256" ]; then
    echo "error: $(basename "$SHA_FILE") does not match the DMG's actual sha256" >&2
    exit 1
  fi
  printf '%s\n' "$(basename "$SHA_FILE") matches the DMG"
fi

RELEASE_JSON="$(dirname "$DMG")/AgenLynk.release.json"
if [ -f "$RELEASE_JSON" ]; then
  "$SYSTEM_NODE" -e '
    const fs = require("fs");
    const release = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const actualSha256 = process.argv[2];
    const actualBytes = Number(process.argv[3]);
    if (release.dmg?.sha256 !== actualSha256) {
      console.error(`release manifest sha256 mismatch: recorded ${release.dmg && release.dmg.sha256}, actual ${actualSha256}`);
      process.exit(1);
    }
    if (release.dmg?.bytes !== actualBytes) {
      console.error(`release manifest byte size mismatch: recorded ${release.dmg && release.dmg.bytes}, actual ${actualBytes}`);
      process.exit(1);
    }
    console.log("AgenLynk.release.json dmg sha256/bytes agree with the DMG");
  ' "$RELEASE_JSON" "$ACTUAL_SHA256" "$ACTUAL_BYTES"
fi

printf '%s\n' "Verified $DMG"
