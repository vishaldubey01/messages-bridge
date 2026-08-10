# Security

## Boundary

Messages Bridge deliberately keeps broad macOS permissions out of AI harnesses:

- SQLite is opened with `SQLITE_OPEN_READONLY` and `PRAGMA query_only=ON`.
- The Unix socket accepts only clients with the same effective user ID.
- Requests are limited to 64 KB and responses to 32 MB.
- Attachment reads are limited to 20 MB and resolved beneath the Messages attachments directory.
- The bridge exposes fixed operations rather than arbitrary SQL, filesystem paths, shell commands, or AppleScript.
- Sending is controlled by an app-level policy and is treated as non-idempotent.

Any process running as the same macOS user can attempt to connect to the socket. Treat local code execution in the user account as trusted to the same extent as other desktop applications. Keep Sending set to **Off** or **Ask Before Sending** if that is not acceptable.

## Reporting a vulnerability

Once the repository is public, use GitHub's private vulnerability reporting feature under the repository's **Security** tab. Do not include sensitive message content, phone numbers, email addresses, or attachments in a public issue.

For non-sensitive bugs, open a normal GitHub issue with the macOS version, Messages Bridge version, and redacted reproduction steps.
