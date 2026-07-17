import AppKit
import LimitMonitorCore

// Settings window (SPEC v0.5): one reusable NSWindow, fixed width ~380, not
// resizable. The "Providers" section — a checkbox per known provider (built-ins
// always; providers.json entries by name, config-disabled ones shown
// unchecked-and-disabled) + the config-path hint line; the "General" section —
// two-way mirrors of the menu toggles. Plain AppKit, no SwiftUI. Chrome strings
// are localized via ChromeStr(appLanguage) (SPEC v0.6). The content view is
// constructed from a Model so --ui-smoke can build it headlessly.
final class SettingsWindowController: NSObject, NSTextFieldDelegate {
    struct ProviderRow {
        /// nil → an `enabled: false` providers.json entry (not toggleable).
        let id: String?
        let title: String
        let checked: Bool
        let enabled: Bool
        let tooltip: String?
    }

    struct Model {
        var providers: [ProviderRow]
        var configPath: String
        var configExists: Bool
        var notifyOn: Bool
        var loginOn: Bool
        var loginAvailable: Bool
        var desktopCardOn: Bool
        /// SPEC v0.7: current bar separators (effective values), pre-filling the
        /// Separators fields. The FULL joiner string, spacing included.
        var providerSeparator: String
        var segmentSeparator: String
    }

    struct Handlers {
        var providerToggled: (String, Bool) -> Void = { _, _ in }
        var notifyToggled: (Bool) -> Void = { _ in }
        var loginToggled: (Bool) -> Void = { _ in }
        var desktopCardToggled: (Bool) -> Void = { _ in }
        /// SPEC v0.7: (providerSeparator, segmentSeparator) — persist + rebuild
        /// the title on end-of-editing.
        var separatorsChanged: (String, String) -> Void = { _, _ in }
        var separatorsReset: () -> Void = {}
        var revealConfig: () -> Void = {}
    }

    private static let windowWidth: CGFloat = 380
    private static let contentInset: CGFloat = 16

    private let modelProvider: () -> Model
    private let handlers: Handlers
    private var window: NSWindow?
    private var providerButtons: [(id: String, button: NSButton)] = []
    private var notifyButton: NSButton?
    private var loginButton: NSButton?
    private var cardButton: NSButton?
    private var revealButton: NSButton?
    private var providerSeparatorField: NSTextField?
    private var segmentSeparatorField: NSTextField?
    private var separatorPreview: NSTextField?

    init(modelProvider: @escaping () -> Model, handlers: Handlers) {
        self.modelProvider = modelProvider
        self.handlers = handlers
    }

    /// LSUIElement apps must activate explicitly before a window can become key.
    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Two-way sync: re-reads the model when a menu toggle (or another
    /// settings control) changes the underlying state.
    func refresh() {
        guard window != nil else { return }
        let model = modelProvider()
        for (id, button) in providerButtons {
            guard let row = model.providers.first(where: { $0.id == id }) else { continue }
            button.state = row.checked ? .on : .off
        }
        notifyButton?.state = model.notifyOn ? .on : .off
        loginButton?.state = model.loginOn ? .on : .off
        loginButton?.isEnabled = model.loginAvailable
        cardButton?.state = model.desktopCardOn ? .on : .off
        revealButton?.isEnabled = model.configExists
    }

    private func makeWindow() -> NSWindow {
        let content = makeContentView()
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: content.frame.size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = ChromeStr.settingsTitle.text(appLanguage)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.setContentSize(content.frame.size)
        window.center()
        return window
    }

    // MARK: - Content view (also constructed headlessly by --ui-smoke)

    func makeContentView() -> NSView {
        providerButtons = []
        providerSeparatorField = nil
        segmentSeparatorField = nil
        separatorPreview = nil
        let model = modelProvider()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(sectionLabel(ChromeStr.providersSection.text(appLanguage)))
        for row in model.providers {
            let button = NSButton(
                checkboxWithTitle: row.title,
                target: row.id == nil ? nil : self,
                action: row.id == nil ? nil : #selector(providerToggled(_:))
            )
            button.state = row.checked ? .on : .off
            button.isEnabled = row.enabled
            button.toolTip = row.tooltip
            if let id = row.id {
                button.identifier = NSUserInterfaceItemIdentifier(id)
                providerButtons.append((id: id, button: button))
            }
            stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(configHintRow(model: model))
        stack.setCustomSpacing(14, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 1])

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionLabel(ChromeStr.generalSection.text(appLanguage)))

        let notify = NSButton(
            checkboxWithTitle: ChromeStr.notifications.text(appLanguage),
            target: self, action: #selector(notifyToggled(_:))
        )
        notify.state = model.notifyOn ? .on : .off
        notifyButton = notify
        stack.addArrangedSubview(notify)

        let login = NSButton(
            checkboxWithTitle: ChromeStr.launchAtLogin.text(appLanguage),
            target: self, action: #selector(loginToggled(_:))
        )
        login.state = model.loginOn ? .on : .off
        login.isEnabled = model.loginAvailable
        if !model.loginAvailable {
            login.toolTip = ChromeStr.loginUnavailableTooltip.text(appLanguage)
        }
        loginButton = login
        stack.addArrangedSubview(login)

        let card = NSButton(
            checkboxWithTitle: ChromeStr.desktopCard.text(appLanguage),
            target: self, action: #selector(cardToggled(_:))
        )
        card.state = model.desktopCardOn ? .on : .off
        cardButton = card
        stack.addArrangedSubview(card)

        // SPEC v0.7: Separators section — two fields (full joiner strings, spacing
        // included), a live preview and a Reset button. Apply is on end-editing.
        stack.setCustomSpacing(14, after: card)
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionLabel(ChromeStr.separatorsSection.text(appLanguage)))

        let providerField = makeSeparatorField(current: model.providerSeparator)
        providerSeparatorField = providerField
        stack.addArrangedSubview(labeledField(ChromeStr.betweenProviders.text(appLanguage), field: providerField))

        let segmentField = makeSeparatorField(current: model.segmentSeparator)
        segmentSeparatorField = segmentField
        stack.addArrangedSubview(labeledField(ChromeStr.betweenLimits.text(appLanguage), field: segmentField))

        stack.addArrangedSubview(separatorPreviewRow(model: model))

        // Root keeps a concrete frame (translatesAutoresizingMaskIntoConstraints
        // stays true): an orphan autolayout root as a window contentView is
        // ambiguity-prone. Inner autolayout pins the stack to the top-left.
        let container = NSView(frame: .zero)
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: Self.windowWidth - Self.contentInset * 2),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.contentInset),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.contentInset),
        ])
        container.frame = NSRect(
            x: 0, y: 0,
            width: Self.windowWidth,
            height: stack.fittingSize.height + Self.contentInset * 2
        )
        return container
    }

    private func sectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        return label
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: Self.windowWidth - Self.contentInset * 2).isActive = true
        return box
    }

    private func configHintRow(model: Model) -> NSView {
        let path = NSTextField(labelWithString: (model.configPath as NSString).abbreviatingWithTildeInPath)
        path.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.toolTip = model.configPath
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let reveal = NSButton(title: ChromeStr.showInFinder.text(appLanguage), target: self, action: #selector(revealTapped(_:)))
        reveal.bezelStyle = .rounded
        reveal.controlSize = .small
        reveal.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        reveal.isEnabled = model.configExists
        revealButton = reveal

        let row = NSStackView(views: [path, reveal])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Self.windowWidth - Self.contentInset * 2).isActive = true
        return row
    }

    // MARK: - Separators (SPEC v0.7)

    private func makeSeparatorField(current: String) -> NSTextField {
        let field = NSTextField(string: current)
        field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        return field
    }

    /// Label + field on one row; the label column is fixed so the two fields align.
    private func labeledField(_ labelText: String, field: NSTextField) -> NSView {
        let label = NSTextField(labelWithString: labelText)
        label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Self.windowWidth - Self.contentInset * 2).isActive = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func separatorPreviewRow(model: Model) -> NSView {
        let preview = NSTextField(labelWithString: "")
        preview.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        preview.textColor = .secondaryLabelColor
        preview.lineBreakMode = .byTruncatingTail
        // Fill the row beside the Reset button (like the config-hint row) — no
        // fixed width, so the row's own width constraint stays satisfiable.
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        preview.setContentHuggingPriority(.defaultLow, for: .horizontal)
        separatorPreview = preview
        updatePreview(providerSep: model.providerSeparator, segmentSep: model.segmentSeparator)

        let reset = NSButton(
            title: ChromeStr.separatorsReset.text(appLanguage),
            target: self, action: #selector(separatorsResetTapped(_:))
        )
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        reset.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [preview, reset])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Self.windowWidth - Self.contentInset * 2).isActive = true
        return row
    }

    /// Two-provider example title with the current (normalized) field values, so
    /// the effect is visible before applying. Neutral glyphs only.
    private func updatePreview(providerSep: String, segmentSep: String) {
        let seg = TitleFormatter.normalizedSeparator(segmentSep, default: TitleFormatter.defaultSegmentSeparator)
        let prov = TitleFormatter.normalizedSeparator(providerSep, default: TitleFormatter.defaultProviderSeparator)
        separatorPreview?.stringValue =
            "Cl·5h●42%" + seg + "7d●29%" + prov + "Cx·5h●12%" + seg + "7d●40%"
    }

    private func refreshPreviewFromFields() {
        updatePreview(
            providerSep: providerSeparatorField?.stringValue ?? "",
            segmentSep: segmentSeparatorField?.stringValue ?? ""
        )
    }

    // MARK: - NSTextFieldDelegate (separators)

    /// Live preview as the user types.
    func controlTextDidChange(_ obj: Notification) {
        refreshPreviewFromFields()
    }

    /// Apply on focus loss or Enter: persist the FULL raw strings + rebuild title.
    func controlTextDidEndEditing(_ obj: Notification) {
        handlers.separatorsChanged(
            providerSeparatorField?.stringValue ?? "",
            segmentSeparatorField?.stringValue ?? ""
        )
    }

    // MARK: - Actions

    @objc private func providerToggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        handlers.providerToggled(id, sender.state == .on)
    }

    @objc private func notifyToggled(_ sender: NSButton) {
        handlers.notifyToggled(sender.state == .on)
    }

    @objc private func loginToggled(_ sender: NSButton) {
        handlers.loginToggled(sender.state == .on)
    }

    @objc private func cardToggled(_ sender: NSButton) {
        handlers.desktopCardToggled(sender.state == .on)
    }

    @objc private func revealTapped(_ sender: NSButton) {
        handlers.revealConfig()
    }

    /// Reset restores both defaults: repopulate the fields, refresh the preview
    /// and drop the overrides (the shell rebuilds the title).
    @objc private func separatorsResetTapped(_ sender: NSButton) {
        providerSeparatorField?.stringValue = TitleFormatter.defaultProviderSeparator
        segmentSeparatorField?.stringValue = TitleFormatter.defaultSegmentSeparator
        refreshPreviewFromFields()
        handlers.separatorsReset()
    }
}
