#!/bin/zsh
set -euo pipefail

repository_root="${0:A:h:h}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$repository_root/bridge/Info.plist")"
release_work_directory="$(mktemp -d)"
trap 'rm -rf "$release_work_directory"' EXIT

if [[ -z "${MESSAGES_BRIDGE_SIGNING_IDENTITY:-}" || "${MESSAGES_BRIDGE_SIGNING_IDENTITY:-}" == "-" ]]; then
  echo "Set MESSAGES_BRIDGE_SIGNING_IDENTITY to a Developer ID Application identity." >&2
  exit 1
fi
if [[ -z "${MESSAGES_BRIDGE_BUNDLE_ID:-}" ]]; then
  echo "Set MESSAGES_BRIDGE_BUNDLE_ID to the permanent public bundle identifier." >&2
  exit 1
fi

mkdir -p "$repository_root/dist"
MESSAGES_BRIDGE_INSTALL_ROOT="$release_work_directory" \
  "$repository_root/scripts/build_bridge.sh" >/dev/null

archive_path="$repository_root/dist/Messages-Bridge-$version.zip"
ditto -c -k --sequesterRsrc --keepParent \
  "$release_work_directory/Messages Bridge.app" \
  "$archive_path"

shasum -a 256 "$archive_path"
