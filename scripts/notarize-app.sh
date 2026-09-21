#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="$root/.build/distribution"
app="$output_dir/Transom.app"
profile="${NOTARY_PROFILE:-transom-notary}"
auth_args=(--keychain-profile "$profile")
if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then
  auth_args+=(--keychain "$NOTARY_KEYCHAIN")
fi
submission="$output_dir/notarization.json"
log="$output_dir/notarization-log.json"

if [[ ! -d "$app" ]]; then
  echo "Build the Developer ID app with mise run signed-app first." >&2
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "$app"
version="$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")"
dmg="$output_dir/Transom-$version-arm64.dmg"
if [[ ! -f "$dmg" ]]; then
  echo "Build the disk image with mise run dmg first." >&2
  exit 1
fi
codesign --verify --strict --verbose=2 "$dmg"

# Apple checks the signed application inside the final signed disk image.
echo "Submitting to Apple using Keychain profile: $profile"
submission_exit=0
xcrun notarytool submit "$dmg" \
  "${auth_args[@]}" \
  --wait --output-format json > "$submission" || submission_exit=$?

submission_id="$(plutil -extract id raw -o - "$submission" 2>/dev/null || true)"
status="$(plutil -extract status raw -o - "$submission" 2>/dev/null || true)"
if [[ -n "$submission_id" ]]; then
  echo "Submission: $submission_id ($status)"
  xcrun notarytool log "$submission_id" "${auth_args[@]}" "$log"
  echo "Notarization log: $log"
fi
if [[ "$submission_exit" != 0 || "$status" != Accepted ]]; then
  echo "Notarization was not accepted. Details: $submission" >&2
  exit 1
fi

xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
codesign --verify --strict --verbose=2 "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg"
# Record the hash only after stapling has finished modifying the artifact.
cd "$output_dir"
shasum -a 256 "$(basename "$dmg")" > SHA256SUMS
echo "Notarized release: $dmg"
