import AppKit
import LimitMonitorCore

// Settings window (SPEC v0.5): one reusable NSWindow, fixed width ~380, not
// resizable. Section «Провайдеры» — a checkbox per known provider (built-ins
// always; providers.json entries by name, config-disabled ones shown
// unchecked-and-disabled) + the config-path hint line; section «Общие» —
// two-way mirrors of the menu toggles. Plain AppKit, no SwiftUI. The content
// view is constructed from a Model so --ui-smoke can build it headlessly.
final class SettingsWindowController: NSObject {
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
    }

    struct Handlers {
        var providerToggled: (String, Bool) -> Void = { _, _ in }
        var notifyToggled: (Bool) -> Void = { _ in }
        var loginToggled: (Bool) -> Void = { _ in }
        var desktopCardToggled: (Bool) -> Void = { _ in }
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
        window.title = "Limit Monitor — настройки"
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.setContentSize(content.frame.size)
        window.center()
        return window
    }

    // MARK: - Content view (also constructed headlessly by --ui-smoke)

    func makeContentView() -> NSView {
        providerButtons = []
        let model = modelProvider()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(sectionLabel("Провайдеры"))
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
        stack.addArrangedSubview(sectionLabel("Общие"))

        let notify = NSButton(
            checkboxWithTitle: "Уведомления о лимитах",
            target: self, action: #selector(notifyToggled(_:))
        )
        notify.state = model.notifyOn ? .on : .off
        notifyButton = notify
        stack.addArrangedSubview(notify)

        let login = NSButton(
            checkboxWithTitle: "Запускать при входе",
            target: self, action: #selector(loginToggled(_:))
        )
        login.state = model.loginOn ? .on : .off
        login.isEnabled = model.loginAvailable
        if !model.loginAvailable {
            login.toolTip = "доступно только из установленного Limit Monitor.app"
        }
        loginButton = login
        stack.addArrangedSubview(login)

        let card = NSButton(
            checkboxWithTitle: "Виджет на рабочем столе",
            target: self, action: #selector(cardToggled(_:))
        )
        card.state = model.desktopCardOn ? .on : .off
        cardButton = card
        stack.addArrangedSubview(card)

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

        let reveal = NSButton(title: "Показать в Finder", target: self, action: #selector(revealTapped(_:)))
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
}
