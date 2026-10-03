#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${CONFIG:-release}"
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.4}"
export MACOSX_DEPLOYMENT_TARGET
APP="$ROOT/dist/Barc.app"
ICONSET="$ROOT/.build/AppIcon.iconset"
ICNS="$ROOT/.build/AppIcon.icns"

cd "$ROOT"
set -- -c "$CONFIG"
if [ "${UNIVERSAL:-0}" = "1" ]; then
  set -- "$@" --arch arm64 --arch x86_64
fi
swift build "$@"
BIN="$(swift build "$@" --show-bin-path)/Barc"

if [ ! -f "$ICNS" ] || [ "$ROOT/scripts/make-icon.swift" -nt "$ICNS" ]; then
  swift scripts/make-icon.swift --symbol rectangle.lefthalf.inset.filled --from FFCF70 --to F0852A \
    --glyph 2A1606 --scale 0.42 --out "$ICONSET" --icns "$ICNS"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Barc"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "${BUILD_NUMBER:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
codesign --force --sign - "$APP" >/dev/null
touch "$APP"

INSTALLED="/Applications/Barc.app"
if [ "${INSTALL:-1}" = "1" ]; then
  rm -rf "$INSTALLED"
  ditto "$APP" "$INSTALLED"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALLED"
  APP="$INSTALLED"
fi

echo
echo "Built: $APP"
echo "Run with: open \"$APP\""
