#!/bin/bash
# Builds Lidless.app, installs it into /Applications and launches it.
# Everything is logged to build.log next to this repo so the result can be read back.
#   bash script/build.sh            build, install, launch
#   bash script/build.sh --no-open  build and install only
#   bash script/build.sh --no-install  build and sign only (CI)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="$ROOT/build.log"
exec > >(tee "$LOG") 2>&1

# Build products stay on the internal disk: external drives (exFAT) break codesign with ._ files.
SCRATCH="$HOME/Library/Caches/lidless-build"
APP="$SCRATCH/Lidless.app"
DEST="/Applications/Lidless.app"

step() { printf '\n== %s ==\n' "$1"; }
fail() { printf '\nBUILD FAILED: %s\n' "$1"; exit 1; }
trap 'fail "line $LINENO"' ERR

# Use the full Xcode when it is installed, even if xcode-select points at the Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  XCODE="$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1 || true)"
  if [[ -n "$XCODE" ]]; then export DEVELOPER_DIR="$XCODE/Contents/Developer"; fi
fi

step "Environment"
date
sw_vers
echo "developer dir: ${DEVELOPER_DIR:-$(xcode-select -p)}"
xcodebuild -version 2>/dev/null | head -1 || echo "Xcode not active, building with the Command Line Tools"
swift --version 2>&1 | head -1

cd "$ROOT"

step "Compile (release)"
swift build -c release --scratch-path "$SCRATCH" --product Lidless
swift build -c release --scratch-path "$SCRATCH" --product lidlessd
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)"

step "Icon"
ICONSET="$SCRATCH/Lidless.iconset"
ICNS="$SCRATCH/Lidless.icns"
if [[ ! -f "$ICNS" || "$ROOT/script/make-icon.swift" -nt "$ICNS" ]]; then
  rm -rf "$ICONSET"
  if swift "$ROOT/script/make-icon.swift" "$ICONSET" && iconutil -c icns "$ICONSET" -o "$ICNS"; then
    echo "icon ok"
  else
    echo "icon generation failed, continuing without an icon"
  fi
fi

step "Bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/Lidless" "$APP/Contents/MacOS/Lidless"
cp "$BIN/lidlessd" "$APP/Contents/Helpers/lidlessd"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/install-helper.sh" "$ROOT/Resources/uninstall-helper.sh" "$ROOT/Resources/claude-hook.sh" "$APP/Contents/Resources/"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
if [[ -f "$ICNS" ]]; then cp "$ICNS" "$APP/Contents/Resources/Lidless.icns"; fi
chmod +x "$APP/Contents/MacOS/Lidless" "$APP/Contents/Helpers/lidlessd"
plutil -lint "$APP/Contents/Info.plist"

step "Sign (ad-hoc)"
codesign --force --sign - --identifier dev.iskakov.lidless.daemon "$APP/Contents/Helpers/lidlessd"
codesign --force --sign - --identifier dev.iskakov.lidless "$APP"
codesign --verify --strict --verbose=1 "$APP"

if [[ "${1:-}" == "--no-install" ]]; then
  printf '\nBUILD OK (not installed): %s\n' "$APP"
  exit 0
fi

step "Install"
pkill -x Lidless 2>/dev/null && sleep 1 || true
rm -rf "$DEST"
ditto "$APP" "$DEST"
echo "Installed $DEST"
# Only /Applications/Lidless.app may own lidless:// in LaunchServices, not the build copy.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
"$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true

if [[ "${1:-}" != "--no-open" ]]; then
  open "$DEST"
  sleep 2
  pgrep -x Lidless >/dev/null && echo "Lidless is running" || fail "app did not start"
fi

if [[ -f /Library/LaunchDaemons/dev.iskakov.lidless.daemon.plist ]] &&
   ! cmp -s "$APP/Contents/Helpers/lidlessd" /Library/PrivilegedHelperTools/dev.iskakov.lidless.daemon; then
  echo "NOTE: the closed-lid helper changed. Open Lidless and press Update helper."
fi

printf '\nBUILD OK\n'
