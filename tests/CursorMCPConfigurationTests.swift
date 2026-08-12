import Foundation

@main
struct CursorMCPConfigurationTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-mcp-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent(".cursor/mcp.json")
        let store = CursorMCPConfigurationStore(fileURL: fileURL)
        let helper = "/Applications/Messages Bridge.app/Contents/MacOS/MessagesBridgeMCP"

        let initialState = try store.state(expectedCommand: helper)
        precondition(initialState == .available)
        try store.install(command: helper)
        let connectedState = try store.state(expectedCommand: helper)
        precondition(connectedState == .connected)

        var root = try readObject(fileURL)
        var servers = root["mcpServers"] as! [String: Any]
        servers["revenuecat"] = [
            "url": "https://mcp.revenuecat.ai/mcp",
            "headers": ["X-Test": "preserved"],
        ]
        root["mcpServers"] = servers
        root["customRootSetting"] = true
        try writeObject(root, to: fileURL)

        try store.install(command: helper)
        root = try readObject(fileURL)
        servers = root["mcpServers"] as! [String: Any]
        let revenueCat = servers["revenuecat"] as! [String: Any]
        precondition(revenueCat["url"] as? String == "https://mcp.revenuecat.ai/mcp")
        precondition((revenueCat["headers"] as? [String: String])?["X-Test"] == "preserved")
        precondition(root["customRootSetting"] as? Bool == true)

        servers["messages-bridge"] = ["command": "/old/MessagesBridgeMCP", "args": []]
        root["mcpServers"] = servers
        try writeObject(root, to: fileURL)
        let updateState = try store.state(expectedCommand: helper)
        precondition(updateState == .needsUpdate)

        let invalidData = Data("{ this is not json".utf8)
        try invalidData.write(to: fileURL)
        do {
            try store.install(command: helper)
            preconditionFailure("Invalid JSON must not be overwritten.")
        } catch {
            let preservedData = try Data(contentsOf: fileURL)
            precondition(preservedData == invalidData)
        }

        print("Cursor MCP detection, merge preservation, updates, and invalid-config safety passed.")
    }

    private static func readObject(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    private static func writeObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
