# Messages Bridge

Messages Bridge is a small, native macOS menu-bar app that gives local MCP clients bounded access to Apple Messages. The app—not the AI harness—holds Full Disk Access, Contacts access, and permission to automate Messages.

It supports:

- Enumerating recent direct and group conversations with unread counts
- Reading unread messages across the inbox without marking them read
- Reading direct conversations and group chats
- Resolving participants through Contacts
- Reading attachments that belong to the selected conversation, embedding originals up to 20 MB and locally previewing larger supported files
- Sending direct and group text messages under an app-controlled policy
- One-click user-scope setup for Codex and Claude Code
- Standard local STDIO MCP configuration for other clients

Messages Bridge cannot edit or delete messages, execute arbitrary SQL, or read arbitrary files.

HEIC, HEIF, TIFF, and other macOS-decodable image formats are converted locally to JPEG when the MCP client cannot render them directly. PDFs, videos, and other files up to 20 MB keep their original bytes and include a JPEG preview when macOS Quick Look supports the format. Larger previewable attachments still return metadata and a preview without embedding the original file. MCP does not define an inline video player, so videos are delivered as the original resource plus a preview frame when size permits.

## Requirements

- macOS 13 or newer, on Apple silicon or Intel
- Messages configured on the Mac
- An MCP-capable local client such as Codex or Claude Code

## Install and connect

1. Download the latest `Messages-Bridge-*.dmg` from [GitHub Releases](https://github.com/vishaldubey01/messages-bridge/releases/latest).
2. Open the DMG and drag **Messages Bridge** to **Applications**.
3. Open **Messages Bridge** from Applications.

To build the app from source instead:

```bash
git clone https://github.com/vishaldubey01/messages-bridge.git
cd messages-bridge
./scripts/build_bridge.sh
open "$HOME/Applications/Messages Bridge.app"
```

On first launch, the Setup window shows Messages history, Contacts, Codex, and Claude Code in one place. Click **Finish setup** to request Contacts access, connect every detected client, and open the correct Full Disk Access page when needed. macOS requires you to enable **Messages Bridge** manually in that page; return to the app and click refresh afterward.

Choose a Sending mode from the menu when you want to send: **Off**, **Ask Before Sending**, or **Send Automatically**.

The bundled `MessagesBridgeMCP` executable starts the app in the background when necessary. A harness never needs Full Disk Access itself. Both bundled executables are universal binaries with a macOS 13 deployment target.

## Architecture

```text
Codex / Claude / MCP client
            │ STDIO MCP
            ▼
MessagesBridgeMCP (bundled, no Python dependency)
            │ same-user Unix socket
            ▼
Messages Bridge.app
   ├── chat.db opened read-only
   ├── Contacts name resolution
   └── Messages Apple Events for policy-controlled sends
```

The Codex plugin in this repository is optional. It contributes usage instructions; the app's **Setup…** window manages the actual user-level MCP connection.

To install the optional Codex plugin from this repository:

```bash
codex plugin marketplace add vishaldubey01/messages-bridge
codex plugin add messages-bridge@messages-bridge
```

Install and connect the native app first. Claude Code does not need a plugin; connect it directly from the app.

## Build options

The development build defaults to ad-hoc signing and installs in `$HOME/Applications`:

```bash
./scripts/build_bridge.sh
```

The monochrome app icon is generated from the same native two-bubble symbol used in the menu bar:

```bash
swift scripts/generate_app_icon.swift bridge/assets/AppIcon-1024.png
```

To preserve a stable app identity across builds, provide a signing identity and bundle identifier:

```bash
MESSAGES_BRIDGE_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" \
MESSAGES_BRIDGE_BUNDLE_ID="com.example.MessagesBridge" \
./scripts/build_bridge.sh
```

Changing the signing identity or bundle identifier can cause macOS to request privacy permissions again.

To create a signed, notarized, and stapled DMG:

```bash
MESSAGES_BRIDGE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
MESSAGES_BRIDGE_BUNDLE_ID="com.example.MessagesBridge" \
MESSAGES_BRIDGE_NOTARY_PROFILE="messages-bridge-notary" \
./scripts/package_release.sh
```

The release script verifies the app with Gatekeeper, creates a DMG with an Applications shortcut, notarizes the DMG, staples its ticket, and emits a SHA-256 checksum. See [Distribution](docs/DISTRIBUTION.md).

## Generic MCP configuration

Other MCP clients can launch the helper directly:

```json
{
  "mcpServers": {
    "messages-bridge": {
      "command": "/Applications/Messages Bridge.app/Contents/MacOS/MessagesBridgeMCP",
      "args": []
    }
  }
}
```

If the app is installed in `~/Applications`, use that path instead. The app can copy the correct configuration for its current location.

## Security and privacy

Messages Bridge has no networking or telemetry. Data passes from the app to the local MCP client over a Unix socket restricted to the signed-in user. Your chosen AI client may transmit tool results to its model provider, so its privacy terms still apply.

See [PRIVACY.md](PRIVACY.md) and [SECURITY.md](SECURITY.md) for the complete boundary and reporting guidance.

## License

MIT. See [LICENSE](LICENSE).
