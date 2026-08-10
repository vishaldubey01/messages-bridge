# Messages Bridge

Messages Bridge is a small, native macOS menu-bar app that gives local MCP clients bounded access to Apple Messages. The app—not the AI harness—holds Full Disk Access, Contacts access, and permission to automate Messages.

It supports:

- Reading direct conversations and group chats
- Resolving participants through Contacts
- Reading attachments that belong to the selected conversation, up to 20 MB
- Sending direct and group text messages under an app-controlled policy
- One-click user-scope setup for Codex and Claude Code
- Standard local STDIO MCP configuration for other clients

Messages Bridge cannot edit or delete messages, execute arbitrary SQL, or read arbitrary files.

## Requirements

- macOS 13 or newer
- Messages configured on the Mac
- An MCP-capable local client such as Codex or Claude Code

## Install and connect

Public release downloads will be added to this repository's Releases page. Until then, build the app from source:

```bash
git clone https://github.com/vishaldubey01/messages-bridge.git
cd messages-bridge
./scripts/build_bridge.sh
open "$HOME/Applications/Messages Bridge.app"
```

On first launch:

1. Grant **Messages Bridge** Full Disk Access.
2. Grant Contacts access when requested.
3. Open **Messages Bridge > Integrations…**.
4. Connect Codex, Claude Code, or copy the generic MCP configuration.
5. Choose a Sending policy from the menu: **Off**, **Confirm Each Send**, or **Allow Sends Automatically**.

The bundled `MessagesBridgeMCP` executable starts the app in the background when necessary. A harness never needs Full Disk Access itself.

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

The Codex plugin in this repository is optional. It contributes usage instructions; the app's **Integrations…** window manages the actual user-level MCP connection.

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

To preserve a stable app identity across builds, provide a signing identity and bundle identifier:

```bash
MESSAGES_BRIDGE_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" \
MESSAGES_BRIDGE_BUNDLE_ID="com.example.MessagesBridge" \
./scripts/build_bridge.sh
```

Changing the signing identity or bundle identifier can cause macOS to request privacy permissions again.

To create a zipped release candidate:

```bash
MESSAGES_BRIDGE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
MESSAGES_BRIDGE_BUNDLE_ID="com.example.MessagesBridge" \
./scripts/package_release.sh
```

Public binaries should be Developer ID signed and notarized before distribution. See [Distribution](docs/DISTRIBUTION.md).

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
