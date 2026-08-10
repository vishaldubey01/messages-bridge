# Contributing

Bug reports and pull requests are welcome. Keep changes aligned with the core boundary: the native app owns macOS permissions, the MCP helper remains unprivileged, and every exposed operation is narrow and auditable.

Before opening a pull request:

```bash
swiftc -swift-version 5 -O \
  -framework AppKit \
  -framework Contacts \
  -framework CoreServices \
  -framework ScriptingBridge \
  -lsqlite3 \
  bridge/MessagesBridge.swift bridge/IntegrationsWindow.swift \
  -o /tmp/MessagesBridge

swiftc -swift-version 5 -O \
  bridge/MessagesBridgeMCP.swift \
  -o /tmp/MessagesBridgeMCP
```

Never include real message databases, attachments, contact identifiers, signing certificates, or notarization credentials in commits or test fixtures.
