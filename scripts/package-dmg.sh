#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="$root/.build/distribution"
app="$output_dir/Transom.app"
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to a Developer ID Application identity}"
codesign --verify --deep --strict --verbose=2 "$app"
version="$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid app version: $version" >&2
  exit 1
fi
if [[ "$(lipo -archs "$app/Contents/MacOS/Transom")" != arm64 ]]; then
  echo "The release app must contain exactly the arm64 architecture." >&2
  exit 1
fi

stage="$(mktemp -d "$output_dir/dmg-stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Transom.app"
ln -s /Applications "$stage/Applications"
dmg="$output_dir/Transom-$version-arm64.dmg"
hdiutil create -ov -format UDZO -volname "Transom $version" -srcfolder "$stage" "$dmg"
codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$dmg"
codesign --verify --strict --verbose=2 "$dmg"
echo "Signed DMG (not yet notarized): $dmg"
