# Distribution

Messages Bridge should be distributed as a signed and notarized native macOS application. The Codex plugin is an optional discovery and instruction layer; it does not replace the app or its macOS permissions.

## Release checklist

1. Choose a permanent reverse-DNS bundle identifier.
2. Build with a **Developer ID Application** signing identity.
3. Sign with the hardened runtime and a secure timestamp.
4. Verify the bundle and nested MCP helper signatures.
5. Submit the app to Apple's notarization service and staple its ticket.
6. Package the stapled app in a signed DMG with an Applications shortcut.
7. Notarize and staple the DMG.
8. Publish the checksum and release notes on GitHub Releases.
9. Test installation on a Mac that has never run Messages Bridge.
10. Test Full Disk Access, Contacts, Automation, Codex setup, and Claude Code setup.
11. Keep public sending defaulted to **Off**.

Example build:

```bash
MESSAGES_BRIDGE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
MESSAGES_BRIDGE_BUNDLE_ID="com.example.MessagesBridge" \
MESSAGES_BRIDGE_NOTARY_PROFILE="messages-bridge-notary" \
./scripts/package_release.sh
```

Create the Keychain profile once before the first release:

```bash
xcrun notarytool store-credentials messages-bridge-notary \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "YOUR_TEAM_ID" \
  --password "YOUR_APP_SPECIFIC_PASSWORD"
```

`package_release.sh` performs both notarization submissions, stapling, Gatekeeper validation, DMG creation, and checksum generation.

Do not commit signing certificates, API keys, Apple account credentials, or keychain profiles.
