import Foundation

enum CursorMCPConfigurationState: Equatable {
    case available
    case connected
    case needsUpdate
}

struct CursorMCPConfigurationStore {
    let fileURL: URL
    private let launcherPath = "/usr/bin/env"

    func state(expectedCommand: String) throws -> CursorMCPConfigurationState {
        let root = try loadRoot()
        guard let serversValue = root["mcpServers"] else { return .available }
        guard let servers = serversValue as? [String: Any] else {
            throw CursorMCPConfigurationError("Cursor's mcpServers value is not a JSON object.")
        }
        guard let entryValue = servers["messages-bridge"] else { return .available }
        guard let entry = entryValue as? [String: Any],
              let command = entry["command"] as? String else {
            return .needsUpdate
        }

        let arguments = entry["args"] as? [String]
        guard let arguments = arguments, arguments.count == 1 else { return .needsUpdate }
        return pathsMatch(command, launcherPath)
            && pathsMatch(arguments[0], expectedCommand)
            ? .connected
            : .needsUpdate
    }

    func install(command: String) throws {
        var root = try loadRoot()
        var servers: [String: Any]
        if let serversValue = root["mcpServers"] {
            guard let existingServers = serversValue as? [String: Any] else {
                throw CursorMCPConfigurationError("Cursor's mcpServers value is not a JSON object.")
            }
            servers = existingServers
        } else {
            servers = [:]
        }

        servers["messages-bridge"] = [
            "command": launcherPath,
            "args": [command],
        ]
        root["mcpServers"] = servers

        guard JSONSerialization.isValidJSONObject(root) else {
            throw CursorMCPConfigurationError("Cursor's MCP configuration contains unsupported JSON values.")
        }
        var data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private func loadRoot() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [:] }
        do {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CursorMCPConfigurationError("Cursor's MCP configuration is not a JSON object.")
            }
            return root
        } catch let error as CursorMCPConfigurationError {
            throw error
        } catch {
            throw CursorMCPConfigurationError(
                "Cursor's MCP configuration is not valid JSON: \(error.localizedDescription)"
            )
        }
    }

    private func pathsMatch(_ left: String, _ right: String) -> Bool {
        URL(fileURLWithPath: left).standardizedFileURL.path
            == URL(fileURLWithPath: right).standardizedFileURL.path
    }
}

struct CursorMCPConfigurationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
