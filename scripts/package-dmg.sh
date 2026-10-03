#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")-beta.1}"
if ! printf '%s\n' "$VERSION" | /usr/bin/grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$'; then
  echo "VERSION must have the form X.Y.Z-beta.N" >&2
  exit 1
fi
RELEASE_VERSION="$VERSION"
VERSION="${VERSION%%-beta.*}"
export VERSION

INSTALL=0 UNIVERSAL=1 CONFIG=release "$ROOT/build.sh"
APP="$ROOT/dist/Barc.app"
lipo "$APP/Contents/MacOS/Barc" -verify_arch arm64
lipo "$APP/Contents/MacOS/Barc" -verify_arch x86_64
codesign --verify --deep --strict "$APP"

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/barc-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT HUP INT TERM
ditto "$APP" "$STAGING/Barc.app"
ln -s /Applications "$STAGING/Applications"
DMG="$ROOT/dist/Barc-$RELEASE_VERSION-universal.dmg"
hdiutil create -volname Barc -srcfolder "$STAGING" -format UDZO -ov "$DMG"
hdiutil verify "$DMG"
cd "$ROOT/dist"
shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256"
echo "Packaged: $DMG"
