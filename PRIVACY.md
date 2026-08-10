# Privacy

Messages Bridge is designed as a local permission boundary.

## Data the app can access

When the corresponding macOS permissions are granted, the app can access:

- The local Apple Messages database in SQLite read-only mode
- Attachments belonging to a conversation selected through the bridge
- Contacts identifiers used to resolve requested names and group participants
- The Messages app through Apple Events, only for sending text messages

## Data the app sends

Messages Bridge contains no network client, analytics, advertising, crash reporting, or telemetry. It sends requested results only to a local MCP process over a same-user Unix socket.

The MCP client or AI harness may transmit those results to a remote model provider. Review the privacy and data-control settings of the harness you connect. Messages Bridge cannot control what a connected client does after receiving a requested result.

## Retention

Messages Bridge does not create a second message database or retain message contents. It stores only local preferences such as whether reads are enabled and the selected sending policy.

## Sending

The Sending mode defaults to **Off**. **Ask Before Sending** presents a native confirmation for every send. **Send Automatically** must be explicitly enabled and can be turned off from the menu at any time.
