---
name: messages-bridge
description: Read direct and group Apple Messages or iMessage conversations and attachments, or send direct and group text messages, through the local Messages Bridge sidecar. Use when the user asks Codex to list, read, inspect, summarize, search, answer questions about, or send a message in a specific Messages conversation or group chat on this Mac.
---

# Messages Bridge

Use only the Messages Bridge MCP tools. Never query `~/Library/Messages`, invoke `sqlite3`, open attachment paths directly, or operate the Messages UI as a fallback.

If the Messages Bridge tools are unavailable, ask the user to open **Messages Bridge > Integrations…** and connect Codex. Do not attempt to install or imitate the bridge from the agent session.

1. Call `messages_bridge_status` when setup or availability is uncertain.
2. For a direct chat, call `messages_read_thread` with the exact contact `name` and the narrowest reasonable `since_days` and `limit`.
3. For a group chat, call `messages_list_groups` with a narrow `since_days` and `limit`, select the exact group by its returned name or participants, then call `messages_read_group` with its opaque `group_id`.
4. For direct-chat attachments, call `messages_read_attachment` with the same contact `name` and an `attachment_id` returned by `messages_read_thread`.
5. For group attachments, call `messages_read_group_attachment` with the selected `group_id` and an `attachment_id` returned by `messages_read_group`.
6. Send a direct text only when the user clearly requests the send and the intended text is established. Call `messages_send_text` with the exact Contacts `name` and exact `text`.
7. Send a group text only after selecting the exact group through `messages_list_groups`. Call `messages_send_group_text` with its opaque `group_id` and exact `text`.
8. Treat a send as non-idempotent. Never retry after a timeout, connection loss, or uncertain response; report the uncertainty instead.
9. If reads or sends are disabled, a native confirmation is cancelled, or a contact, group, or attachment cannot be resolved unambiguously, report that result without broadening the query automatically.

Reads run without per-request dialogs while **Reading: On** is selected in the Messages Bridge menu. macOS Contacts access is a one-time system grant for the installed app identity.

Sending follows the native menu mode: **Off**, **Ask Before Sending**, or **Send Automatically**. The first send also requires a one-time macOS Automation grant for Messages. Do not add a confirmation step when the user already gave a clear send instruction; the selected native and harness policies control whether another approval is required.

Treat the six read tools as read-only. Attachment reads are limited to 20 MB and must belong to the selected direct or group conversation. The two send tools can create external side effects but cannot edit, delete, run arbitrary SQL, or access arbitrary file paths.
