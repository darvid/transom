#!/usr/bin/env bash
set -euo pipefail

configuration="${1:-release}"
signing_mode="${2:-local}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
version="$(< "$root/version.txt")"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "version.txt must contain a stable major.minor.patch version." >&2
  exit 1
fi
architecture="$(uname -m)"

case "$signing_mode" in
  local) app_dir="$root/.build/Transom.app" ;;
  developer-id)
    : "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to a Developer ID Application identity}"
    if [[ "$SIGNING_IDENTITY" != "Developer ID Application: "* ]]; then
      echo "A Developer ID Application identity is required." >&2
      exit 1
    fi
    app_dir="$root/.build/distribution/Transom.app"
    architecture=arm64
    ;;
  *) echo "Unknown signing mode: $signing_mode" >&2; exit 1 ;;
esac

swift build --configuration "$configuration" --product Transom --arch "$architecture"
bin_dir="$(swift build --configuration "$configuration" --arch "$architecture" --show-bin-path)"

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/Transom" "$app_dir/Contents/MacOS/Transom"
cp "$root/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$root/Resources/Transom.icns" "$app_dir/Contents/Resources/Transom.icns"
cp "$root/LICENSE" "$app_dir/Contents/Resources/LICENSE"
plutil -replace CFBundleShortVersionString -string "$version" "$app_dir/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$version" "$app_dir/Contents/Info.plist"
if [[ "$signing_mode" == developer-id ]]; then
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$SIGNING_IDENTITY" \
    "$app_dir"
else
  codesign \
    --force \
    --sign - \
    --requirements '=designated => identifier "com.transom.app"' \
    "$app_dir"
fi
codesign --verify --deep --strict --verbose=2 "$app_dir"

echo "$app_dir"
