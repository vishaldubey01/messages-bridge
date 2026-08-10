import AppKit
import Foundation

enum HarnessKind: Int, CaseIterable, Hashable {
    case codex
    case claudeCode

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        }
    }

    var executableName: String {
        switch self {
        case .codex: return "codex"
        case .claudeCode: return "claude"
        }
    }
}

enum HarnessConnectionState {
    case missingHarness
    case available
    case needsUpdate
    case connected
    case error
}

struct HarnessStatus {
    let state: HarnessConnectionState
    let detail: String
}

private struct ProcessResult {
    let status: Int32
    let output: String
}

final class HarnessIntegrationManager {
    let helperURL: URL

    init() {
        helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/MessagesBridgeMCP")
            .standardizedFileURL
    }

    func status(for harness: HarnessKind) -> HarnessStatus {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            return HarnessStatus(state: .error, detail: "The bundled MCP helper is missing.")
        }
        guard let executable = executableURL(named: harness.executableName) else {
            return HarnessStatus(state: .missingHarness, detail: "\(harness.displayName) is not installed.")
        }

        switch harness {
        case .codex:
            let result = run(executable, arguments: ["mcp", "get", "messages-bridge", "--json"])
            guard result.status == 0 else {
                return HarnessStatus(state: .available, detail: "Ready to connect for this user.")
            }
            guard let data = result.output.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let transport = object["transport"] as? [String: Any],
                  let command = transport["command"] as? String else {
                return HarnessStatus(state: .needsUpdate, detail: "Connected with an older configuration.")
            }
            return pathsMatch(command, helperURL.path)
                ? HarnessStatus(state: .connected, detail: "Connected for Codex desktop, CLI, and IDE.")
                : HarnessStatus(state: .needsUpdate, detail: "Update the existing MCP connection.")

        case .claudeCode:
            let result = run(executable, arguments: ["mcp", "get", "messages-bridge"])
            guard result.status == 0 else {
                return HarnessStatus(state: .available, detail: "Ready to connect at user scope.")
            }
            return result.output.contains(helperURL.path)
                ? HarnessStatus(state: .connected, detail: "Connected for every Claude Code project.")
                : HarnessStatus(state: .needsUpdate, detail: "Update the existing user-scope connection.")
        }
    }

    func connect(_ harness: HarnessKind) -> Result<String, Error> {
        guard let executable = executableURL(named: harness.executableName) else {
            return .failure(IntegrationFailure("\(harness.displayName) is not installed or its CLI could not be found."))
        }
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            return .failure(IntegrationFailure("The bundled MCP helper is missing."))
        }

        let existing: ProcessResult
        let removeArguments: [String]
        let addArguments: [String]
        switch harness {
        case .codex:
            existing = run(executable, arguments: ["mcp", "get", "messages-bridge", "--json"])
            removeArguments = ["mcp", "remove", "messages-bridge"]
            addArguments = ["mcp", "add", "messages-bridge", "--", helperURL.path]
        case .claudeCode:
            existing = run(executable, arguments: ["mcp", "get", "messages-bridge"])
            removeArguments = ["mcp", "remove", "messages-bridge", "--scope", "user"]
            addArguments = ["mcp", "add", "--scope", "user", "--transport", "stdio", "messages-bridge", "--", helperURL.path]
        }

        if existing.status == 0 {
            let removal = run(executable, arguments: removeArguments)
            guard removal.status == 0 else {
                return .failure(IntegrationFailure(cleanOutput(removal.output, fallback: "Could not replace the existing connection.")))
            }
        }

        let addition = run(executable, arguments: addArguments)
        guard addition.status == 0 else {
            return .failure(IntegrationFailure(cleanOutput(addition.output, fallback: "Could not add the MCP connection.")))
        }
        return .success("\(harness.displayName) is connected to Messages Bridge.")
    }

    func genericConfiguration() -> String {
        let object: [String: Any] = [
            "mcpServers": [
                "messages-bridge": [
                    "command": helperURL.path,
                    "args": [],
                ],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func executableURL(named name: String) -> URL? {
        var candidates: [URL] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent(name)
            })
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates.append(contentsOf: [
            home.appendingPathComponent(".local/bin/\(name)"),
            home.appendingPathComponent(".npm-global/bin/\(name)"),
            URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"),
            URL(fileURLWithPath: "/usr/local/bin/\(name)"),
            URL(fileURLWithPath: "/usr/bin/\(name)"),
        ])
        var seen = Set<String>()
        return candidates.first {
            seen.insert($0.standardizedFileURL.path).inserted
                && FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private func run(_ executable: URL, arguments: [String]) -> ProcessResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return ProcessResult(status: process.terminationStatus, output: String(data: data, encoding: .utf8) ?? "")
        } catch {
            return ProcessResult(status: -1, output: error.localizedDescription)
        }
    }

    private func pathsMatch(_ left: String, _ right: String) -> Bool {
        URL(fileURLWithPath: left).standardizedFileURL.path
            == URL(fileURLWithPath: right).standardizedFileURL.path
    }

    private func cleanOutput(_ output: String, fallback: String) -> String {
        let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }
}

private struct IntegrationFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct IntegrationRow {
    let statusLabel: NSTextField
    let actionButton: NSButton
}

private final class LegacyIntegrationsWindowController: NSWindowController {
    private let manager = HarnessIntegrationManager()
    private var rows: [HarnessKind: IntegrationRow] = [:]
    private var connectAllButton: NSButton!
    private var refreshButton: NSButton!
    private var operationInProgress = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 350),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Messages Bridge Integrations"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildInterface()
    }

    required init?(coder: NSCoder) { nil }

    func showAndRefresh() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        refresh()
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }

        let title = NSTextField(labelWithString: "Connect your AI tools")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString: "Messages Bridge keeps macOS permissions in this app. Each integration only receives the bounded MCP tools you enable here.")
        explanation.textColor = .secondaryLabelColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(explanation)

        for harness in HarnessKind.allCases {
            stack.addArrangedSubview(makeRow(for: harness))
        }

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 8
        let copyButton = NSButton(title: "Copy MCP Configuration", target: self, action: #selector(copyConfiguration))
        copyButton.bezelStyle = .rounded
        refreshButton = NSButton(title: "Check Again", target: self, action: #selector(refreshPressed))
        refreshButton.bezelStyle = .rounded
        connectAllButton = NSButton(title: "Connect All Detected", target: self, action: #selector(connectAll))
        connectAllButton.bezelStyle = .rounded
        connectAllButton.keyEquivalent = "\r"
        footer.addArrangedSubview(copyButton)
        footer.addArrangedSubview(refreshButton)
        footer.addArrangedSubview(connectAllButton)
        stack.addArrangedSubview(footer)

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 25),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func makeRow(for harness: HarnessKind) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.borderColor = .separatorColor
        box.borderWidth = 1
        box.cornerRadius = 8
        box.contentViewMargins = NSSize(width: 14, height: 12)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 66).isActive = true
        box.widthAnchor.constraint(equalToConstant: 504).isActive = true

        let name = NSTextField(labelWithString: harness.displayName)
        name.font = .systemFont(ofSize: 14, weight: .medium)
        let status = NSTextField(labelWithString: "Checking…")
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        let labels = NSStackView(views: [name, status])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3

        let button = NSButton(title: "Checking…", target: self, action: #selector(connectOne(_:)))
        button.bezelStyle = .rounded
        button.tag = harness.rawValue
        button.isEnabled = false

        let row = NSStackView(views: [labels, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(row)
        if let boxContent = box.contentView {
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: boxContent.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: boxContent.trailingAnchor),
                row.topAnchor.constraint(equalTo: boxContent.topAnchor),
                row.bottomAnchor.constraint(equalTo: boxContent.bottomAnchor),
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            ])
        }
        rows[harness] = IntegrationRow(statusLabel: status, actionButton: button)
        return box
    }

    @objc private func refreshPressed() { refresh() }

    private func refresh() {
        guard !operationInProgress else { return }
        setBusy(true)
        DispatchQueue.global(qos: .userInitiated).async { [manager] in
            var statuses: [HarnessKind: HarnessStatus] = [:]
            for harness in HarnessKind.allCases { statuses[harness] = manager.status(for: harness) }
            DispatchQueue.main.async { [weak self] in
                self?.apply(statuses)
                self?.setBusy(false)
            }
        }
    }

    private func apply(_ statuses: [HarnessKind: HarnessStatus]) {
        var connectableCount = 0
        for harness in HarnessKind.allCases {
            guard let row = rows[harness], let status = statuses[harness] else { continue }
            row.statusLabel.stringValue = status.detail
            switch status.state {
            case .missingHarness:
                row.actionButton.title = "Not Installed"
                row.actionButton.isEnabled = false
            case .available:
                row.actionButton.title = "Connect"
                row.actionButton.isEnabled = true
                connectableCount += 1
            case .needsUpdate:
                row.actionButton.title = "Update"
                row.actionButton.isEnabled = true
                connectableCount += 1
            case .connected:
                row.actionButton.title = "Connected"
                row.actionButton.isEnabled = false
            case .error:
                row.actionButton.title = "Retry"
                row.actionButton.isEnabled = true
            }
        }
        connectAllButton.isEnabled = connectableCount > 0
    }

    @objc private func connectOne(_ sender: NSButton) {
        guard let harness = HarnessKind(rawValue: sender.tag) else { return }
        connect([harness])
    }

    @objc private func connectAll() {
        let targets = HarnessKind.allCases.filter { rows[$0]?.actionButton.isEnabled == true }
        connect(targets)
    }

    private func connect(_ targets: [HarnessKind]) {
        guard !targets.isEmpty, !operationInProgress else { return }
        setBusy(true)
        DispatchQueue.global(qos: .userInitiated).async { [manager] in
            var failures: [String] = []
            for target in targets {
                if case let .failure(error) = manager.connect(target) {
                    failures.append("\(target.displayName): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.setBusy(false)
                if failures.isEmpty {
                    self?.refresh()
                } else {
                    self?.showError(failures.joined(separator: "\n\n"))
                    self?.refresh()
                }
            }
        }
    }

    private func setBusy(_ busy: Bool) {
        operationInProgress = busy
        refreshButton?.isEnabled = !busy
        for row in rows.values {
            row.actionButton.isEnabled = !busy && row.actionButton.title != "Connected" && row.actionButton.title != "Not Installed"
            if busy { row.statusLabel.stringValue = "Checking…" }
        }
        let actionableTitles: Set<String> = ["Connect", "Update", "Retry"]
        connectAllButton?.isEnabled = !busy && rows.values.contains {
            actionableTitles.contains($0.actionButton.title)
        }
    }

    @objc private func copyConfiguration() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(manager.genericConfiguration(), forType: .string)
        let alert = NSAlert()
        alert.messageText = "MCP configuration copied"
        alert.informativeText = "Paste it into any local MCP client that accepts a standard mcpServers configuration."
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window!)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "An integration could not be connected"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) }
    }
}
