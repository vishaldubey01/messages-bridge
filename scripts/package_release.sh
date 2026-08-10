#!/bin/zsh
set -euo pipefail

repository_root="${0:A:h:h}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$repository_root/bridge/Info.plist")"
release_work_directory="$(mktemp -d)"
trap 'rm -rf "$release_work_directory"' EXIT
signing_identity="${MESSAGES_BRIDGE_SIGNING_IDENTITY:-}"
bundle_identifier="${MESSAGES_BRIDGE_BUNDLE_ID:-}"
notary_profile="${MESSAGES_BRIDGE_NOTARY_PROFILE:-}"

if [[ "$signing_identity" != "Developer ID Application:"* ]]; then
  echo "Set MESSAGES_BRIDGE_SIGNING_IDENTITY to a Developer ID Application identity." >&2
  exit 1
fi
if [[ -z "$bundle_identifier" || "$bundle_identifier" == local.* ]]; then
  echo "Set MESSAGES_BRIDGE_BUNDLE_ID to the permanent public bundle identifier." >&2
  exit 1
fi
if [[ -z "$notary_profile" ]]; then
  echo "Set MESSAGES_BRIDGE_NOTARY_PROFILE to a notarytool Keychain profile." >&2
  exit 1
fi

mkdir -p "$repository_root/dist"
MESSAGES_BRIDGE_INSTALL_ROOT="$release_work_directory" \
  "$repository_root/scripts/build_bridge.sh" >/dev/null

app_path="$release_work_directory/Messages Bridge.app"
submission_path="$release_work_directory/Messages-Bridge-$version-notarization.zip"
ditto -c -k --sequesterRsrc --keepParent \
  "$app_path" \
  "$submission_path"

xcrun notarytool submit "$submission_path" \
  --keychain-profile "$notary_profile" \
  --wait
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
spctl --assess --type execute --verbose=4 "$app_path"

dmg_source="$release_work_directory/dmg"
mkdir -p "$dmg_source"
ditto "$app_path" "$dmg_source/Messages Bridge.app"
ln -s /Applications "$dmg_source/Applications"

dmg_path="$repository_root/dist/Messages-Bridge-$version.dmg"
hdiutil create \
  -volname "Messages Bridge" \
  -srcfolder "$dmg_source" \
  -format UDZO \
  -ov \
  "$dmg_path" >/dev/null
codesign --force --timestamp --sign "$signing_identity" "$dmg_path"
xcrun notarytool submit "$dmg_path" \
  --keychain-profile "$notary_profile" \
  --wait
xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"
spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path"

checksum_path="$dmg_path.sha256"
shasum -a 256 "$dmg_path" | tee "$checksum_path"
