---
name: messages-bridge
description: List recent or unread Apple Messages, read direct and group iMessage conversations and attachments, or send direct and group text messages, through the local Messages Bridge sidecar. Use when the user asks Codex to inspect their Messages inbox, find unread texts, list conversations, read, summarize, search, answer questions about, or send a message on this Mac.
---

# Messages Bridge

Use only the Messages Bridge MCP tools. Never query `~/Library/Messages`, invoke `sqlite3`, open attachment paths directly, or operate the Messages UI as a fallback.

If the Messages Bridge tools are unavailable, ask the user to open **Messages Bridge > Setup…** and connect Codex. Do not attempt to install or imitate the bridge from the agent session.

1. Call `messages_bridge_status` when setup or availability is uncertain.
2. For unread or inbox-wide requests, call `messages_list_unread` with the requested `since_days`. Results are newest first and remain unread. Follow `nextCursor` while `hasMore` is true when the user needs the complete result set.
3. To enumerate recent direct and group chats without reading their bodies, call `messages_list_conversations`. Use its resolved names, participants, last activity, and unread counts rather than inferring conversations from activity in named threads.
4. For a direct chat, call `messages_read_thread` with the exact contact `name` and the narrowest reasonable `since_days` and `limit`. If the response has `hasMore: true` and more history is needed, call it again with the returned `nextCursor`. Continue page by page; the page-size limit is not a conversation-history cap.
5. For a group chat, call `messages_list_groups` with a narrow `since_days` and `limit`, select the exact group by its returned name or participants, then call `messages_read_group` with its opaque `group_id`. Follow `nextCursor` while `hasMore` is true when the user needs older history.
6. For direct-chat attachments, call `messages_read_attachment` with the same contact `name` and an `attachment_id` returned by `messages_read_thread` or `messages_list_unread`.
7. For group attachments, call `messages_read_group_attachment` with the selected `group_id` and an `attachment_id` returned by `messages_read_group` or `messages_list_unread`.
8. Send a direct text only when the user clearly requests the send and the intended text is established. Call `messages_send_text` with the exact Contacts `name` and exact `text`.
9. Send a group text only after selecting the exact group through `messages_list_groups` or `messages_list_conversations`. Call `messages_send_group_text` with its opaque `group_id` and exact `text`.
10. Treat a send as non-idempotent. Never retry after a timeout, connection loss, or uncertain response; report the uncertainty instead.
11. If reads or sends are disabled, a native confirmation is cancelled, or a contact, group, or attachment cannot be resolved unambiguously, report that result without broadening the query automatically.

Reads run without per-request dialogs while **Reading: On** is selected in the Messages Bridge menu. macOS Contacts access is a one-time system grant for the installed app identity.

Sending follows the native menu mode: **Off**, **Ask Before Sending**, or **Send Automatically**. The first send also requires a one-time macOS Automation grant for Messages. Do not add a confirmation step when the user already gave a clear send instruction; the selected native and harness policies control whether another approval is required.

Treat the eight read tools as read-only. Listing unread messages does not mark them read. Attachments must belong to the selected direct or group conversation. Unsupported image formats are returned as locally converted JPEGs. PDFs, videos, and other non-inline files up to 20 MB retain their original resource bytes and may also include a JPEG preview; larger previewable files return metadata and the preview without embedding the original. The two send tools can create external side effects but cannot edit, delete, run arbitrary SQL, or access arbitrary file paths.
