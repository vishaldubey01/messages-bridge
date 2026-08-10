#!/bin/zsh
set -euo pipefail

plugin_root="${0:A:h:h}"
source_file="$plugin_root/bridge/MessagesBridge.swift"
integrations_file="$plugin_root/bridge/IntegrationsWindow.swift"
integrations_presentation_file="$plugin_root/bridge/PolishedIntegrationsWindow.swift"
mcp_source_file="$plugin_root/bridge/MessagesBridgeMCP.swift"
plist_file="$plugin_root/bridge/Info.plist"
entitlements_file="$plugin_root/bridge/MessagesBridge.entitlements"
icon_source="$plugin_root/bridge/assets/AppIcon-1024.png"
install_root="${MESSAGES_BRIDGE_INSTALL_ROOT:-$HOME/Applications}"
app_path="$install_root/Messages Bridge.app"
contents_path="$app_path/Contents"
signing_identity="${MESSAGES_BRIDGE_SIGNING_IDENTITY:--}"
bundle_identifier="${MESSAGES_BRIDGE_BUNDLE_ID:-local.messagesbridge.MessagesBridge}"

mkdir -p "$install_root" "$contents_path/MacOS" "$contents_path/Resources"
icon_work_dir="$(mktemp -d)"
trap 'rm -rf "$icon_work_dir"' EXIT
iconset_path="$icon_work_dir/AppIcon.iconset"
mkdir -p "$iconset_path"
sips --resampleHeightWidth 16 16 "$icon_source" --out "$iconset_path/icon_16x16.png" >/dev/null
sips --resampleHeightWidth 32 32 "$icon_source" --out "$iconset_path/icon_16x16@2x.png" >/dev/null
sips --resampleHeightWidth 32 32 "$icon_source" --out "$iconset_path/icon_32x32.png" >/dev/null
sips --resampleHeightWidth 64 64 "$icon_source" --out "$iconset_path/icon_32x32@2x.png" >/dev/null
sips --resampleHeightWidth 128 128 "$icon_source" --out "$iconset_path/icon_128x128.png" >/dev/null
sips --resampleHeightWidth 256 256 "$icon_source" --out "$iconset_path/icon_128x128@2x.png" >/dev/null
sips --resampleHeightWidth 256 256 "$icon_source" --out "$iconset_path/icon_256x256.png" >/dev/null
sips --resampleHeightWidth 512 512 "$icon_source" --out "$iconset_path/icon_256x256@2x.png" >/dev/null
sips --resampleHeightWidth 512 512 "$icon_source" --out "$iconset_path/icon_512x512.png" >/dev/null
sips --resampleHeightWidth 1024 1024 "$icon_source" --out "$iconset_path/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$iconset_path" -o "$contents_path/Resources/AppIcon.icns"
swiftc \
  -swift-version 5 \
  -O \
  -framework AppKit \
  -framework Contacts \
  -framework CoreServices \
  -framework ScriptingBridge \
  -lsqlite3 \
  "$source_file" "$integrations_file" "$integrations_presentation_file" \
  -o "$contents_path/MacOS/MessagesBridge"
swiftc \
  -swift-version 5 \
  -O \
  "$mcp_source_file" \
  -o "$contents_path/MacOS/MessagesBridgeMCP"
cp "$plist_file" "$contents_path/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_identifier" "$contents_path/Info.plist"
if [[ "$signing_identity" != "-" ]] && ! security find-identity -v -p codesigning | rg -F "$signing_identity" >/dev/null; then
  echo "Messages Bridge signing identity is unavailable: $signing_identity" >&2
  exit 1
fi
codesign \
  --force \
  --options runtime \
  --timestamp=none \
  --sign "$signing_identity" \
  "$contents_path/MacOS/MessagesBridgeMCP"
codesign \
  --force \
  --options runtime \
  --timestamp=none \
  --entitlements "$entitlements_file" \
  --sign "$signing_identity" \
  --identifier "$bundle_identifier" \
  "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
echo "$app_path"
