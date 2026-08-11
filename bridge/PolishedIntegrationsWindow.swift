import AppKit
import Foundation

private final class RoundedSurfaceView: NSView {
    enum Style {
        case card
        case iconTile
    }

    private let style: Style

    init(style: Style, radius: CGFloat) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        updateColors()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        switch style {
        case .card:
            layer?.backgroundColor = isDark
                ? NSColor(calibratedWhite: 1, alpha: 0.075).cgColor
                : NSColor(calibratedWhite: 1, alpha: 0.72).cgColor
            layer?.borderColor = isDark
                ? NSColor(calibratedWhite: 1, alpha: 0.12).cgColor
                : NSColor(calibratedWhite: 0, alpha: 0.10).cgColor
            layer?.borderWidth = 0.75
        case .iconTile:
            layer?.backgroundColor = isDark
                ? NSColor(calibratedWhite: 0.94, alpha: 1).cgColor
                : NSColor(calibratedWhite: 0.08, alpha: 1).cgColor
            layer?.borderWidth = 0
        }
    }
}

private final class AdaptiveIdentityImageView: NSImageView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTint()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTint()
    }

    private func updateTint() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        contentTintColor = isDark
            ? NSColor(calibratedWhite: 0.08, alpha: 1)
            : .white
    }
}

private final class HarnessLogoImageView: NSImageView {
    private let harness: HarnessKind
    private let fallbackImage: NSImage?

    init(harness: HarnessKind, fallbackImage: NSImage?) {
        self.harness = harness
        self.fallbackImage = fallbackImage
        super.init(frame: .zero)
        imageScaling = .scaleProportionallyUpOrDown
        setAccessibilityLabel("\(harness.displayName) logo")
        updateImage()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateImage()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateImage()
    }

    private func updateImage() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let resourceName: String
        switch harness {
        case .codex:
            resourceName = isDark ? "CodexDark" : "CodexLight"
        case .claudeCode:
            resourceName = "ClaudeCode"
        }

        guard let url = Bundle.main.url(
            forResource: resourceName,
            withExtension: "png",
            subdirectory: "Integrations"
        ), let brandedImage = NSImage(contentsOf: url) else {
            image = fallbackImage
            contentTintColor = .labelColor
            return
        }

        image = brandedImage
        contentTintColor = nil
    }
}

private struct IntegrationRowPresentation {
    let detailLabel: NSTextField
    let actionButton: NSButton
    let stateStack: NSStackView
    let stateIcon: NSImageView
    let stateLabel: NSTextField
    let spinner: NSProgressIndicator
}

struct BridgeAccessState {
    let messagesReadable: Bool
    let contactsAuthorization: String

    var contactsReady: Bool { contactsAuthorization == "authorized" }
    var isReady: Bool { messagesReadable && contactsReady }
}

private struct AccessRowPresentation {
    let detailLabel: NSTextField
    let actionButton: NSButton
    let stateIcon: NSImageView
    let stateLabel: NSTextField
}

final class IntegrationsWindowController: NSWindowController, NSWindowDelegate {
    private let manager = HarnessIntegrationManager()
    private let accessStatusProvider: () -> BridgeAccessState
    private let contactsAccessRequester: (@escaping (Bool, String?) -> Void) -> Void
    private let fullDiskAccessSettingsOpener: () -> Void
    private let contactsSettingsOpener: () -> Void
    private var rows: [HarnessKind: IntegrationRowPresentation] = [:]
    private var latestStatuses: [HarnessKind: HarnessStatus] = [:]
    private var latestAccessState = BridgeAccessState(messagesReadable: false, contactsAuthorization: "notDetermined")
    private var messagesAccessRow: AccessRowPresentation!
    private var contactsAccessRow: AccessRowPresentation!
    private var connectAllButton: NSButton!
    private var refreshButton: NSButton!
    private var copyButton: NSButton!
    private var operationInProgress = false

    init(
        accessStatusProvider: @escaping () -> BridgeAccessState,
        contactsAccessRequester: @escaping (@escaping (Bool, String?) -> Void) -> Void,
        fullDiskAccessSettingsOpener: @escaping () -> Void,
        contactsSettingsOpener: @escaping () -> Void
    ) {
        self.accessStatusProvider = accessStatusProvider
        self.contactsAccessRequester = contactsAccessRequester
        self.fullDiskAccessSettingsOpener = fullDiskAccessSettingsOpener
        self.contactsSettingsOpener = contactsSettingsOpener
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 610),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Messages Bridge"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 540, height: 560)
        if ProcessInfo.processInfo.environment["MESSAGES_BRIDGE_APPEARANCE"] == "dark" {
            window.appearance = NSAppearance(named: .darkAqua)
        } else if ProcessInfo.processInfo.environment["MESSAGES_BRIDGE_APPEARANCE"] == "light" {
            window.appearance = NSAppearance(named: .aqua)
        }
        super.init(window: window)
        window.delegate = self
        buildInterface()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
        centerOnActiveScreen()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refresh()
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        guard window?.isVisible == true else { return }
        refresh()
    }

    func showAndRefresh() {
        centerOnActiveScreen()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        refresh()
    }

    private func centerOnActiveScreen() {
        guard let window else { return }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) })
            ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: visibleFrame.midX - window.frame.width / 2,
            y: visibleFrame.midY - window.frame.height / 2
        )
        window.setFrameOrigin(origin)
    }

    private func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }

    private func buildInterface() {
        guard let window else { return }
        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .active
        window.contentView = background

        let identityTile = RoundedSurfaceView(style: .iconTile, radius: 13)
        identityTile.translatesAutoresizingMaskIntoConstraints = false
        let identityImage = AdaptiveIdentityImageView()
        identityImage.image = symbol("bubble.left.and.bubble.right.fill", pointSize: 25, weight: .medium)
        identityImage.translatesAutoresizingMaskIntoConstraints = false
        identityTile.addSubview(identityImage)
        NSLayoutConstraint.activate([
            identityTile.widthAnchor.constraint(equalToConstant: 48),
            identityTile.heightAnchor.constraint(equalToConstant: 48),
            identityImage.centerXAnchor.constraint(equalTo: identityTile.centerXAnchor),
            identityImage.centerYAnchor.constraint(equalTo: identityTile.centerYAnchor),
            identityImage.widthAnchor.constraint(equalToConstant: 28),
            identityImage.heightAnchor.constraint(equalToConstant: 28),
        ])

        let title = NSTextField(labelWithString: "Messages Bridge")
        title.font = .systemFont(ofSize: 23, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: "Set up secure local access for your AI tools.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor

        let runningDot = NSImageView()
        runningDot.image = symbol("circle.fill", pointSize: 7, weight: .medium)
        runningDot.contentTintColor = .systemGreen
        let runningLabel = NSTextField(labelWithString: "Running locally")
        runningLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        runningLabel.textColor = .secondaryLabelColor
        let runningStack = NSStackView(views: [runningDot, runningLabel])
        runningStack.orientation = .horizontal
        runningStack.alignment = .centerY
        runningStack.spacing = 6

        let titleStack = NSStackView(views: [title, subtitle, runningStack])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 3
        let hero = NSStackView(views: [identityTile, titleStack])
        hero.orientation = .horizontal
        hero.alignment = .centerY
        hero.spacing = 14

        let accessLabel = NSTextField(labelWithString: "ACCESS")
        accessLabel.font = .systemFont(ofSize: 10.5, weight: .semibold)
        accessLabel.textColor = .tertiaryLabelColor
        let integrationsLabel = NSTextField(labelWithString: "INTEGRATIONS")
        integrationsLabel.font = .systemFont(ofSize: 10.5, weight: .semibold)
        integrationsLabel.textColor = .tertiaryLabelColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(hero)
        stack.setCustomSpacing(22, after: hero)
        stack.addArrangedSubview(accessLabel)
        stack.setCustomSpacing(8, after: accessLabel)
        let accessCard = makeAccessCard()
        stack.addArrangedSubview(accessCard)
        accessCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(22, after: accessCard)
        stack.addArrangedSubview(integrationsLabel)
        stack.setCustomSpacing(8, after: integrationsLabel)

        for harness in HarnessKind.allCases {
            let row = makeRow(for: harness)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let footer = makeFooter()
        stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 58),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: background.bottomAnchor, constant: -24),
        ])
    }

    private func makeAccessCard() -> NSView {
        let card = RoundedSurfaceView(style: .card, radius: 12)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.heightAnchor.constraint(equalToConstant: 116).isActive = true

        let messages = makeAccessRow(
            symbolName: "externaldrive.fill",
            title: "Messages history",
            detail: "Checking Full Disk Access…",
            actionTitle: "Open Settings",
            action: #selector(openFullDiskAccess)
        )
        messagesAccessRow = messages.presentation
        let contacts = makeAccessRow(
            symbolName: "person.crop.circle.fill",
            title: "Contacts",
            detail: "Checking name access…",
            actionTitle: "Allow",
            action: #selector(allowContacts)
        )
        contactsAccessRow = contacts.presentation

        let divider = NSBox()
        divider.boxType = .separator
        let content = NSStackView(views: [messages.view, divider, contacts.view])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 0
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 6),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -6),
            messages.view.widthAnchor.constraint(equalTo: content.widthAnchor),
            contacts.view.widthAnchor.constraint(equalTo: content.widthAnchor),
            messages.view.heightAnchor.constraint(equalToConstant: 51),
            contacts.view.heightAnchor.constraint(equalToConstant: 51),
            divider.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        return card
    }

    private func makeAccessRow(
        symbolName: String,
        title: String,
        detail: String,
        actionTitle: String,
        action: Selector
    ) -> (view: NSView, presentation: AccessRowPresentation) {
        let icon = NSImageView()
        icon.image = symbol(symbolName, pointSize: 17, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11.5)
        detailLabel.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        let stateIcon = NSImageView()
        stateIcon.translatesAutoresizingMaskIntoConstraints = false
        stateIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        stateIcon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let stateLabel = NSTextField(labelWithString: "Ready")
        stateLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let stateStack = NSStackView(views: [stateIcon, stateLabel])
        stateStack.orientation = .horizontal
        stateStack.alignment = .centerY
        stateStack.spacing = 5
        stateStack.isHidden = true

        let actionButton = NSButton(title: actionTitle, target: self, action: action)
        actionButton.bezelStyle = .rounded
        actionButton.font = .systemFont(ofSize: 12, weight: .medium)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [icon, labels, spacer, stateStack, actionButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 11
        return (
            row,
            AccessRowPresentation(
                detailLabel: detailLabel,
                actionButton: actionButton,
                stateIcon: stateIcon,
                stateLabel: stateLabel
            )
        )
    }

    private func makeRow(for harness: HarnessKind) -> NSView {
        let card = RoundedSurfaceView(style: .card, radius: 12)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.heightAnchor.constraint(equalToConstant: 76).isActive = true

        let symbolName = harness == .codex
            ? "chevron.left.forwardslash.chevron.right"
            : "terminal.fill"
        let harnessIcon = HarnessLogoImageView(
            harness: harness,
            fallbackImage: symbol(symbolName, pointSize: 17, weight: .medium)
        )
        harnessIcon.translatesAutoresizingMaskIntoConstraints = false

        // The official Codex artwork occupies about 80% of its PNG canvas, while
        // Claude's fills its canvas. Size the source canvases so both visible marks
        // land at the same 28-point optical footprint without shifting the labels.
        let iconSlot = NSView()
        iconSlot.translatesAutoresizingMaskIntoConstraints = false
        let sourceCanvasSize: CGFloat = harness == .codex ? 35 : 28
        iconSlot.addSubview(harnessIcon)
        NSLayoutConstraint.activate([
            iconSlot.widthAnchor.constraint(equalToConstant: 28),
            iconSlot.heightAnchor.constraint(equalToConstant: 35),
            harnessIcon.centerXAnchor.constraint(equalTo: iconSlot.centerXAnchor),
            harnessIcon.centerYAnchor.constraint(equalTo: iconSlot.centerYAnchor),
            harnessIcon.widthAnchor.constraint(equalToConstant: sourceCanvasSize),
            harnessIcon.heightAnchor.constraint(equalToConstant: sourceCanvasSize),
        ])

        let name = NSTextField(labelWithString: harness.displayName)
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        let detail = NSTextField(labelWithString: "Checking connection…")
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let labels = NSStackView(views: [name, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let actionButton = NSButton(title: "Connect", target: self, action: #selector(connectOne(_:)))
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .regular
        actionButton.font = .systemFont(ofSize: 12.5, weight: .medium)
        actionButton.tag = harness.rawValue
        actionButton.isHidden = true

        let stateIcon = NSImageView()
        stateIcon.translatesAutoresizingMaskIntoConstraints = false
        stateIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        stateIcon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let stateLabel = NSTextField(labelWithString: "Connected")
        stateLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let stateStack = NSStackView(views: [stateIcon, stateLabel])
        stateStack.orientation = .horizontal
        stateStack.alignment = .centerY
        stateStack.spacing = 5
        stateStack.isHidden = true

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.startAnimation(nil)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [iconSlot, labels, spacer, spinner, stateStack, actionButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 13
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 17),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            row.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            labels.widthAnchor.constraint(greaterThanOrEqualToConstant: 190),
            actionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
        ])

        rows[harness] = IntegrationRowPresentation(
            detailLabel: detail,
            actionButton: actionButton,
            stateStack: stateStack,
            stateIcon: stateIcon,
            stateLabel: stateLabel,
            spinner: spinner
        )
        return card
    }

    private func makeFooter() -> NSView {
        copyButton = NSButton(title: "Copy config", target: self, action: #selector(copyConfiguration))
        copyButton.bezelStyle = .inline
        copyButton.image = symbol("doc.on.doc", pointSize: 12, weight: .medium)
        copyButton.imagePosition = .imageLeading
        copyButton.font = .systemFont(ofSize: 12.5, weight: .medium)

        refreshButton = NSButton(image: symbol("arrow.clockwise", pointSize: 12, weight: .medium) ?? NSImage(), target: self, action: #selector(refreshPressed))
        refreshButton.bezelStyle = .inline
        refreshButton.toolTip = "Check connections again"

        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        let versionLabel = NSTextField(labelWithString: "Version \(shortVersion)")
        versionLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.toolTip = "Messages Bridge \(shortVersion), build \(buildVersion)"
        versionLabel.setAccessibilityLabel("Messages Bridge version \(shortVersion), build \(buildVersion)")

        connectAllButton = NSButton(title: "Connect available", target: self, action: #selector(connectAll))
        connectAllButton.bezelStyle = .rounded
        connectAllButton.controlSize = .large
        connectAllButton.font = .systemFont(ofSize: 13, weight: .semibold)
        connectAllButton.keyEquivalent = "\r"
        connectAllButton.isHidden = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [copyButton, refreshButton, versionLabel, spacer, connectAllButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        return footer
    }

    @objc private func refreshPressed() { refresh() }

    private func refresh() {
        guard !operationInProgress else { return }
        setBusy(true)
        let accessStatusProvider = self.accessStatusProvider
        DispatchQueue.global(qos: .userInitiated).async { [manager] in
            var statuses: [HarnessKind: HarnessStatus] = [:]
            for harness in HarnessKind.allCases { statuses[harness] = manager.status(for: harness) }
            let accessState = accessStatusProvider()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.latestStatuses = statuses
                self.latestAccessState = accessState
                self.setBusy(false)
                self.apply(accessState)
                self.apply(statuses)
            }
        }
    }

    private func apply(_ accessState: BridgeAccessState) {
        applyAccessRow(
            messagesAccessRow,
            ready: accessState.messagesReadable,
            readyDetail: "Full Disk Access is enabled.",
            missingDetail: "Full Disk Access is required to read Messages.",
            actionTitle: "Open Settings",
            readyLabel: "Enabled"
        )

        if accessState.contactsReady {
            applyAccessRow(
                contactsAccessRow,
                ready: true,
                readyDetail: "Contacts access is allowed.",
                missingDetail: "",
                actionTitle: "Allow",
                readyLabel: "Allowed"
            )
        } else {
            contactsAccessRow.stateIcon.isHidden = true
            contactsAccessRow.stateLabel.isHidden = true
            contactsAccessRow.actionButton.isHidden = false
            switch accessState.contactsAuthorization {
            case "notDetermined":
                contactsAccessRow.detailLabel.stringValue = "Allow once so names resolve correctly."
                contactsAccessRow.actionButton.title = "Allow"
            case "denied":
                contactsAccessRow.detailLabel.stringValue = "Turn Contacts on in System Settings."
                contactsAccessRow.actionButton.title = "Open Settings"
            case "restricted":
                contactsAccessRow.detailLabel.stringValue = "Contacts access is restricted on this Mac."
                contactsAccessRow.actionButton.isHidden = true
            default:
                contactsAccessRow.detailLabel.stringValue = "Contacts access needs attention."
                contactsAccessRow.actionButton.title = "Open Settings"
            }
        }
    }

    private func applyAccessRow(
        _ row: AccessRowPresentation,
        ready: Bool,
        readyDetail: String,
        missingDetail: String,
        actionTitle: String,
        readyLabel: String
    ) {
        row.detailLabel.stringValue = ready ? readyDetail : missingDetail
        row.actionButton.title = actionTitle
        row.actionButton.isHidden = ready
        row.stateIcon.isHidden = !ready
        row.stateLabel.isHidden = !ready
        row.stateIcon.image = symbol("checkmark.circle.fill", pointSize: 14, weight: .medium)
        row.stateIcon.contentTintColor = .systemGreen
        row.stateLabel.stringValue = readyLabel
        row.stateLabel.textColor = .systemGreen
    }

    private func apply(_ statuses: [HarnessKind: HarnessStatus]) {
        var connectableCount = 0
        for harness in HarnessKind.allCases {
            guard let row = rows[harness], let status = statuses[harness] else { continue }
            row.detailLabel.stringValue = status.detail
            row.spinner.stopAnimation(nil)
            row.spinner.isHidden = true
            row.actionButton.isHidden = true
            row.stateStack.isHidden = true

            switch status.state {
            case .missingHarness:
                showState(row, symbol: "minus.circle.fill", color: .tertiaryLabelColor, text: "Not installed")
            case .available:
                showAction(row, title: "Connect")
                connectableCount += 1
            case .needsUpdate:
                showAction(row, title: "Update")
                connectableCount += 1
            case .connected:
                showState(row, symbol: "checkmark.circle.fill", color: .systemGreen, text: "Connected")
            case .error:
                showAction(row, title: "Retry")
            }
        }
        let accessNeedsWork = !latestAccessState.isReady
        connectAllButton.title = accessNeedsWork ? "Finish setup" : "Connect available"
        connectAllButton.isHidden = connectableCount == 0 && !accessNeedsWork
        connectAllButton.isEnabled = connectableCount > 0 || accessNeedsWork
    }

    private func showState(_ row: IntegrationRowPresentation, symbol name: String, color: NSColor, text: String) {
        row.stateIcon.image = symbol(name, pointSize: 14, weight: .medium)
        row.stateIcon.contentTintColor = color
        row.stateLabel.stringValue = text
        row.stateLabel.textColor = color
        row.stateStack.isHidden = false
    }

    private func showAction(_ row: IntegrationRowPresentation, title: String) {
        row.actionButton.title = title
        row.actionButton.isEnabled = true
        row.actionButton.isHidden = false
    }

    @objc private func connectOne(_ sender: NSButton) {
        guard let harness = HarnessKind(rawValue: sender.tag) else { return }
        if latestStatuses[harness]?.state == .error {
            refresh()
        } else {
            connect([harness])
        }
    }

    @objc private func connectAll() {
        let targets = HarnessKind.allCases.filter {
            guard let state = latestStatuses[$0]?.state else { return false }
            return state == .available || state == .needsUpdate
        }
        finishSetup(connecting: targets)
    }

    @objc private func allowContacts() {
        guard !operationInProgress else { return }
        if latestAccessState.contactsAuthorization == "notDetermined" {
            setBusy(true)
            contactsAccessRequester { [weak self] granted, error in
                guard let self else { return }
                self.setBusy(false)
                if !granted, let error { self.showPermissionError(error) }
                self.refresh()
            }
        } else {
            contactsSettingsOpener()
        }
    }

    @objc private func openFullDiskAccess() {
        showFullDiskAccessGuide()
    }

    private func finishSetup(connecting targets: [HarnessKind]) {
        guard !operationInProgress else { return }
        requestContactsForSetupIfNeeded { [weak self] in
            guard let self else { return }
            self.connect(targets) { [weak self] in
                guard let self else { return }
                if !self.latestAccessState.messagesReadable {
                    self.showFullDiskAccessGuide()
                }
            }
        }
    }

    private func requestContactsForSetupIfNeeded(completion: @escaping () -> Void) {
        guard !latestAccessState.contactsReady else {
            completion()
            return
        }
        if latestAccessState.contactsAuthorization != "notDetermined" {
            contactsSettingsOpener()
            completion()
            return
        }
        setBusy(true)
        contactsAccessRequester { [weak self] granted, error in
            guard let self else { return }
            self.setBusy(false)
            guard granted else {
                self.showPermissionError(error ?? "Contacts access was not granted.")
                self.refresh()
                return
            }
            completion()
        }
    }

    private func connect(_ targets: [HarnessKind], completion: (() -> Void)? = nil) {
        guard !operationInProgress else { return }
        guard !targets.isEmpty else {
            completion?()
            refresh()
            return
        }
        setBusy(true)
        DispatchQueue.global(qos: .userInitiated).async { [manager] in
            var failures: [String] = []
            for target in targets {
                if case let .failure(error) = manager.connect(target) {
                    failures.append("\(target.displayName): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.setBusy(false)
                if failures.isEmpty {
                    self.refresh()
                } else {
                    self.showError(failures.joined(separator: "\n\n"))
                    self.refresh()
                }
                completion?()
            }
        }
    }

    private func setBusy(_ busy: Bool) {
        operationInProgress = busy
        refreshButton?.isEnabled = !busy
        connectAllButton?.isEnabled = !busy
        messagesAccessRow?.actionButton.isEnabled = !busy
        contactsAccessRow?.actionButton.isEnabled = !busy
        for row in rows.values {
            if busy {
                row.actionButton.isHidden = true
                row.stateStack.isHidden = true
                row.spinner.isHidden = false
                row.spinner.startAnimation(nil)
            } else {
                row.spinner.stopAnimation(nil)
                row.spinner.isHidden = true
            }
        }
    }

    @objc private func copyConfiguration() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(manager.genericConfiguration(), forType: .string)
        copyButton.title = "Copied"
        copyButton.image = symbol("checkmark", pointSize: 12, weight: .semibold)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copyButton.title = "Copy config"
            self?.copyButton.image = self?.symbol("doc.on.doc", pointSize: 12, weight: .medium)
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't connect an integration"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) }
    }

    private func showPermissionError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Contacts access was not enabled"
        alert.informativeText = message
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.contactsSettingsOpener() }
        }
    }

    private func showFullDiskAccessGuide() {
        let alert = NSAlert()
        alert.messageText = "Allow access to your Messages history"
        alert.informativeText = "macOS does not show a normal permission prompt for Messages history. In Full Disk Access, add or enable Messages Bridge, then return here and click refresh. You may need to reopen the app once."
        alert.addButton(withTitle: "Open Full Disk Access")
        alert.addButton(withTitle: "Not Now")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.fullDiskAccessSettingsOpener() }
        }
    }
}
