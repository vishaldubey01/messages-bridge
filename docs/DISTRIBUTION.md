# Distribution

Messages Bridge should be distributed as a signed and notarized native macOS application. The Codex plugin is an optional discovery and instruction layer; it does not replace the app or its macOS permissions.

## Release checklist

1. Choose a permanent reverse-DNS bundle identifier.
2. Build with a **Developer ID Application** signing identity.
3. Verify the bundle and nested MCP helper signatures.
4. Submit the archive to Apple's notarization service.
5. Staple the notarization ticket to the app.
6. Package the stapled app as a DMG or ZIP.
7. Publish the checksum and release notes on GitHub Releases.
8. Test installation on a Mac that has never run Messages Bridge.
9. Test Full Disk Access, Contacts, Automation, Codex setup, and Claude Code setup.
10. Keep public sending defaulted to **Off**.

Example build:

```bash
MESSAGES_BRIDGE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
MESSAGES_BRIDGE_BUNDLE_ID="com.example.MessagesBridge" \
./scripts/package_release.sh
```

Example notarization flow after the ZIP is created:

```bash
xcrun notarytool submit dist/Messages-Bridge-0.3.0.zip \
  --keychain-profile messages-bridge-notary \
  --wait

xcrun stapler staple "path/to/Messages Bridge.app"
```

Do not commit signing certificates, API keys, Apple account credentials, or keychain profiles.
