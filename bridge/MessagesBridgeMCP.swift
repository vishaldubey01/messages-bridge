import Darwin
import Foundation

private let serverName = "messages-bridge"
private let serverVersion = "0.2.0"
private let maximumBridgeResponseBytes = 32 * 1024 * 1024

private func objectSchema(
    properties: [String: Any] = [:],
    required: [String] = []
) -> [String: Any] {
    var schema: [String: Any] = [
        "type": "object",
        "properties": properties,
        "additionalProperties": false,
    ]
    if !required.isEmpty { schema["required"] = required }
    return schema
}

private func stringProperty(
    _ description: String,
    minimum: Int = 1,
    maximum: Int
) -> [String: Any] {
    [
        "type": "string",
        "minLength": minimum,
        "maxLength": maximum,
        "description": description,
    ]
}

private func integerProperty(
    _ description: String,
    minimum: Int,
    maximum: Int,
    default defaultValue: Int
) -> [String: Any] {
    [
        "type": "integer",
        "minimum": minimum,
        "maximum": maximum,
        "default": defaultValue,
        "description": description,
    ]
}

private func tool(
    name: String,
    title: String,
    description: String,
    schema: [String: Any],
    readOnly: Bool,
    idempotent: Bool,
    openWorld: Bool
) -> [String: Any] {
    [
        "name": name,
        "description": description,
        "inputSchema": schema,
        "annotations": [
            "title": title,
            "readOnlyHint": readOnly,
            "destructiveHint": false,
            "idempotentHint": idempotent,
            "openWorldHint": openWorld,
        ],
    ]
}

private let tools: [[String: Any]] = [
    tool(
        name: "messages_bridge_status",
        title: "Check Messages Bridge",
        description: "Check whether the local Messages Bridge app is running and can open the Messages database read-only, including Contacts access, sending policy, and Messages Automation access. Does not read message content or send anything.",
        schema: objectSchema(),
        readOnly: true,
        idempotent: true,
        openWorld: false
    ),
    tool(
        name: "messages_read_thread",
        title: "Read a Messages thread",
        description: "Read one named Apple Messages conversation from the local database. Returns message text and attachment metadata. This tool does not send, edit, or delete.",
        schema: objectSchema(
            properties: [
                "name": stringProperty("Exact or unambiguous Contacts name, for example Riley Brown.", maximum: 200),
                "since_days": integerProperty("Read no earlier than this many days ago.", minimum: 1, maximum: 3650, default: 30),
                "limit": integerProperty("Maximum number of messages returned.", minimum: 1, maximum: 500, default: 100),
            ],
            required: ["name"]
        ),
        readOnly: true,
        idempotent: true,
        openWorld: false
    ),
    tool(
        name: "messages_list_groups",
        title: "List recent Messages groups",
        description: "List recent group conversations without reading message bodies. Returns an opaque group ID, display name, participants, and last activity.",
        schema: objectSchema(properties: [
            "since_days": integerProperty("List groups active within this many days.", minimum: 1, maximum: 3650, default: 30),
            "limit": integerProperty("Maximum number of group conversations returned.", minimum: 1, maximum: 100, default: 50),
        ]),
        readOnly: true,
        idempotent: true,
        openWorld: false
    ),
    tool(
        name: "messages_read_group",
        title: "Read a Messages group",
        description: "Read one group conversation selected by an opaque ID from messages_list_groups. Returns sender labels, message text, and attachment metadata. This tool does not send, edit, or delete.",
        schema: objectSchema(
            properties: [
                "group_id": stringProperty("Opaque group ID returned by messages_list_groups.", maximum: 512),
                "since_days": integerProperty("Read no earlier than this many days ago.", minimum: 1, maximum: 3650, default: 30),
                "limit": integerProperty("Maximum number of messages returned.", minimum: 1, maximum: 500, default: 100),
            ],
            required: ["group_id"]
        ),
        readOnly: true,
        idempotent: true,
        openWorld: false
    ),
    tool(
        name: "messages_read_attachment",
        title: "Read a Messages attachment",
        description: "Read one attachment after verifying it belongs to the named one-to-one conversation. Maximum size is 20 MB. Cannot access arbitrary paths.",
        schema: objectSchema(
            properties: [
                "name": stringProperty("The same Contacts name used to read the thread.", maximum: 200),
                "attachment_id": stringProperty("Opaque attachment ID returned by messages_read_thread.", maximum: 256),
            ],
            required: ["name", "attachment_id"]
        ),
        readOnly: true,
        idempotent: true,
        openWorld: false
    ),
    tool(
        name: "messages_read_group_attachment",
        title: "Read a Messages group attachment",
        description: "Read one attachment after verifying it belongs to the selected group conversation. Maximum size is 20 MB. Cannot access arbitrary paths.",
        schema: objectSchema(
            properties: [
                "group_id": stringProperty("Opaque group ID returned by messages_list_groups.", maximum: 512),
                "attachment_id": stringProperty("Opaque attachment ID returned by messages_read_group.", maximum: 256),
            ],
            required: ["group_id", "attachment_id"]
        ),
        readOnly: true,
        idempotent: true,
        openWorld: false
    ),
    tool(
        name: "messages_send_text",
        title: "Send a Messages text",
        description: "Send one text message to the most recently active one-to-one Messages conversation matching an exact or unambiguous Contacts name. This is a non-idempotent external side effect governed by the Messages Bridge sending policy. Never retry an uncertain send.",
        schema: objectSchema(
            properties: [
                "name": stringProperty("Exact or unambiguous Contacts name for the recipient.", maximum: 200),
                "text": stringProperty("Exact text to send, including intended line breaks.", maximum: 4000),
            ],
            required: ["name", "text"]
        ),
        readOnly: false,
        idempotent: false,
        openWorld: true
    ),
    tool(
        name: "messages_send_group_text",
        title: "Send a Messages group text",
        description: "Send one text message to a group selected by an opaque ID from messages_list_groups. This is a non-idempotent external side effect governed by the Messages Bridge sending policy. Never retry an uncertain send.",
        schema: objectSchema(
            properties: [
                "group_id": stringProperty("Opaque group ID returned by messages_list_groups.", maximum: 512),
                "text": stringProperty("Exact text to send, including intended line breaks.", maximum: 4000),
            ],
            required: ["group_id", "text"]
        ),
        readOnly: false,
        idempotent: false,
        openWorld: true
    ),
]

private func socketPath() -> String {
    ProcessInfo.processInfo.environment["MESSAGES_BRIDGE_SOCKET"]
        ?? "/tmp/messages-bridge-\(geteuid()).sock"
}

private func installedAppURL() -> URL? {
    if let override = ProcessInfo.processInfo.environment["MESSAGES_BRIDGE_APP"], !override.isEmpty {
        return URL(fileURLWithPath: override)
    }

    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let macOSDirectory = executable.deletingLastPathComponent()
    let contentsDirectory = macOSDirectory.deletingLastPathComponent()
    if macOSDirectory.lastPathComponent == "MacOS", contentsDirectory.lastPathComponent == "Contents" {
        let candidate = contentsDirectory.deletingLastPathComponent()
        if candidate.pathExtension == "app" { return candidate }
    }

    let candidates = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Messages Bridge.app"),
        URL(fileURLWithPath: "/Applications/Messages Bridge.app"),
    ]
    return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
}

private func launchBridge() {
    guard let appURL = installedAppURL(), FileManager.default.fileExists(atPath: appURL.path) else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-g", appURL.path]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
}

private func bridgeError(_ code: String, _ message: String) -> [String: Any] {
    ["ok": false, "error": code, "message": message]
}

private func bridgeCall(_ payload: [String: Any]) -> [String: Any] {
    guard JSONSerialization.isValidJSONObject(payload),
          var requestData = try? JSONSerialization.data(withJSONObject: payload) else {
        return bridgeError("invalid_request", "The MCP adapter could not encode the bridge request.")
    }
    requestData.append(0x0A)

    let path = socketPath()
    let deadline = Date().addingTimeInterval(4)
    var lastError = "No connection attempt completed."
    var client: Int32 = -1

    while Date() < deadline {
        if !FileManager.default.fileExists(atPath: path) { launchBridge() }
        let candidate = socket(AF_UNIX, SOCK_STREAM, 0)
        if candidate < 0 {
            lastError = String(cString: strerror(errno))
            break
        }

        var timeout = timeval(tv_sec: 180, tv_usec: 0)
        setsockopt(candidate, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(candidate, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let copied = path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
                    strlcpy(destination, source, 104)
                }
            }
        }
        guard copied < 104 else {
            close(candidate)
            return bridgeError("bridge_connection_failed", "The local socket path is too long.")
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(candidate, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 {
            client = candidate
            break
        }
        lastError = String(cString: strerror(errno))
        close(candidate)
        launchBridge()
        usleep(100_000)
    }

    guard client >= 0 else {
        let location = installedAppURL()?.path ?? "the Applications folder"
        return bridgeError("bridge_not_running", "Messages Bridge is unavailable at \(location). Last connection error: \(lastError)")
    }
    defer { close(client) }

    let sentAll = requestData.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return false }
        var sent = 0
        while sent < requestData.count {
            let count = Darwin.send(client, base.advanced(by: sent), requestData.count - sent, 0)
            if count <= 0 { return false }
            sent += count
        }
        return true
    }
    guard sentAll else {
        return bridgeError("bridge_connection_failed", String(cString: strerror(errno)))
    }

    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while response.count <= maximumBridgeResponseBytes {
        let count = recv(client, &buffer, buffer.count, 0)
        if count <= 0 { break }
        response.append(buffer, count: count)
        if response.contains(0x0A) { break }
    }
    guard response.count <= maximumBridgeResponseBytes else {
        return bridgeError("bridge_connection_failed", "The bridge response exceeded the 32 MB safety limit.")
    }
    guard let line = response.split(separator: 0x0A, maxSplits: 1).first,
          let result = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
        return bridgeError("bridge_connection_failed", "Messages Bridge returned an invalid response.")
    }
    return result
}

private func toolResult(_ result: [String: Any]) -> [String: Any] {
    let encoded = (try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    let text = String(data: encoded, encoding: .utf8) ?? "{}"
    return [
        "content": [["type": "text", "text": text]],
        "structuredContent": result,
        "isError": result["ok"] as? Bool != true,
    ]
}

private func attachmentToolResult(_ result: [String: Any]) -> [String: Any] {
    guard result["ok"] as? Bool == true else { return toolResult(result) }
    guard let base64 = result["dataBase64"] as? String, !base64.isEmpty else {
        return toolResult(bridgeError("invalid_attachment_response", "Attachment data was missing."))
    }
    var metadata = result
    metadata.removeValue(forKey: "dataBase64")
    let mimeType = (metadata["mimeType"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "application/octet-stream"
    metadata["mimeType"] = mimeType
    let encoded = (try? JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    let text = String(data: encoded, encoding: .utf8) ?? "{}"
    var content: [[String: Any]] = [["type": "text", "text": text]]
    if mimeType.hasPrefix("image/") {
        content.append(["type": "image", "data": base64, "mimeType": mimeType])
    } else if mimeType.hasPrefix("audio/") {
        content.append(["type": "audio", "data": base64, "mimeType": mimeType])
    } else {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let attachmentID = String(describing: metadata["attachmentID"] ?? "attachment").addingPercentEncoding(withAllowedCharacters: allowed) ?? "attachment"
        let filename = String(describing: metadata["name"] ?? "attachment").addingPercentEncoding(withAllowedCharacters: allowed) ?? "attachment"
        content.append([
            "type": "resource",
            "resource": [
                "uri": "messages-bridge://attachment/\(attachmentID)/\(filename)",
                "mimeType": mimeType,
                "blob": base64,
            ],
        ])
    }
    return ["content": content, "structuredContent": metadata, "isError": false]
}

private func trimmedString(_ arguments: [String: Any], _ key: String) -> String? {
    guard let value = arguments[key] as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func integer(_ arguments: [String: Any], _ key: String, default defaultValue: Int) -> Int {
    (arguments[key] as? NSNumber)?.intValue ?? defaultValue
}

private func callTool(name: String, arguments: [String: Any]) -> [String: Any] {
    switch name {
    case "messages_bridge_status":
        return toolResult(bridgeCall(["operation": "status"]))
    case "messages_read_thread":
        guard let name = trimmedString(arguments, "name") else {
            return toolResult(bridgeError("invalid_name", "A contact name is required."))
        }
        return toolResult(bridgeCall([
            "operation": "read_thread",
            "name": name,
            "sinceDays": integer(arguments, "since_days", default: 30),
            "limit": integer(arguments, "limit", default: 100),
        ]))
    case "messages_list_groups":
        return toolResult(bridgeCall([
            "operation": "list_groups",
            "sinceDays": integer(arguments, "since_days", default: 30),
            "limit": integer(arguments, "limit", default: 50),
        ]))
    case "messages_read_group":
        guard let groupID = trimmedString(arguments, "group_id") else {
            return toolResult(bridgeError("invalid_group_id", "A group ID is required."))
        }
        return toolResult(bridgeCall([
            "operation": "read_group",
            "groupID": groupID,
            "sinceDays": integer(arguments, "since_days", default: 30),
            "limit": integer(arguments, "limit", default: 100),
        ]))
    case "messages_read_attachment":
        guard let name = trimmedString(arguments, "name") else {
            return toolResult(bridgeError("invalid_name", "A contact name is required."))
        }
        guard let attachmentID = trimmedString(arguments, "attachment_id") else {
            return toolResult(bridgeError("invalid_attachment_id", "An attachment ID is required."))
        }
        return attachmentToolResult(bridgeCall([
            "operation": "read_attachment",
            "name": name,
            "attachmentID": attachmentID,
        ]))
    case "messages_read_group_attachment":
        guard let groupID = trimmedString(arguments, "group_id") else {
            return toolResult(bridgeError("invalid_group_id", "A group ID is required."))
        }
        guard let attachmentID = trimmedString(arguments, "attachment_id") else {
            return toolResult(bridgeError("invalid_attachment_id", "An attachment ID is required."))
        }
        return attachmentToolResult(bridgeCall([
            "operation": "read_group_attachment",
            "groupID": groupID,
            "attachmentID": attachmentID,
        ]))
    case "messages_send_text":
        guard let name = trimmedString(arguments, "name") else {
            return toolResult(bridgeError("invalid_name", "A contact name is required."))
        }
        guard let text = arguments["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return toolResult(bridgeError("invalid_text", "Message text is required."))
        }
        return toolResult(bridgeCall(["operation": "send_text", "name": name, "text": text]))
    case "messages_send_group_text":
        guard let groupID = trimmedString(arguments, "group_id") else {
            return toolResult(bridgeError("invalid_group_id", "A group ID is required."))
        }
        guard let text = arguments["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return toolResult(bridgeError("invalid_text", "Message text is required."))
        }
        return toolResult(bridgeCall(["operation": "send_group_text", "groupID": groupID, "text": text]))
    default:
        return toolResult(bridgeError("unknown_tool", "Unknown tool: \(name)"))
    }
}

private func response(for request: [String: Any]) -> [String: Any]? {
    guard let requestID = request["id"], !(requestID is NSNull) else { return nil }
    let method = request["method"] as? String ?? ""
    let result: [String: Any]
    switch method {
    case "initialize":
        let params = request["params"] as? [String: Any]
        let protocolVersion = params?["protocolVersion"] as? String ?? "2025-06-18"
        result = [
            "protocolVersion": protocolVersion,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": serverName, "version": serverVersion],
            "instructions": "Use the six bounded read tools and two controlled text-send tools. Reads use SQLite read-only mode. Sends are non-idempotent and obey the Messages Bridge menu policy; never retry an uncertain send.",
        ]
    case "ping":
        result = [:]
    case "tools/list":
        result = ["tools": tools]
    case "tools/call":
        let params = request["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        result = callTool(name: name, arguments: arguments)
    case "resources/list":
        result = ["resources": []]
    case "prompts/list":
        result = ["prompts": []]
    default:
        return [
            "jsonrpc": "2.0",
            "id": requestID,
            "error": ["code": -32601, "message": "Method not found: \(method)"],
        ]
    }
    return ["jsonrpc": "2.0", "id": requestID, "result": result]
}

private func writeJSONLine(_ object: [String: Any]) {
    guard JSONSerialization.isValidJSONObject(object),
          var data = try? JSONSerialization.data(withJSONObject: object) else { return }
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

signal(SIGPIPE, SIG_IGN)
while let line = readLine(strippingNewline: true) {
    guard let data = line.data(using: .utf8),
          let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        writeJSONLine([
            "jsonrpc": "2.0",
            "id": NSNull(),
            "error": ["code": -32700, "message": "Invalid JSON"],
        ])
        continue
    }
    if let reply = response(for: request) { writeJSONLine(reply) }
}
