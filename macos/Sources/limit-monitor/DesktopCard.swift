import AppKit
import LimitMonitorCore

// Desktop card (SPEC v0.5) — the ad-hoc-compatible "widget": a non-activating
// borderless NSPanel just above the desktop icons (below normal windows),
// draggable by its background, rebuilt after every poll from the same merged
// model as the menu. No WidgetKit, no .appex — per research/widget.md the
// real widget path is blocked by the chronod identity gate under ad-hoc
// signing. Toggle: UserDefaults `desktopCard`, default OFF.
final class DesktopCard {
    struct ProviderModel {
        let name: String
        let stale: Bool
        let limits: [LimitEntry]
    }

    static let defaultsKey = "desktopCard"
    private static let originKey = "cardOrigin"
    static let contentWidth: CGFloat = 260
    private static let margin: CGFloat = 16

    private var panel: NSPanel?
    private var moveObserver: NSObjectProtocol?
    private var settingFrame = false

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    }

    /// Called from every refreshUI pass: shows/rebuilds or hides the card.
    func setVisible(_ visible: Bool, providers: [ProviderModel], now: Date = Date()) {
        guard visible else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        rebuild(panel: panel, providers: providers, now: now)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    // MARK: - Panel

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        // Above the desktop icons, below normal windows; visible on every
        // Space without Mission Control flicker (research/widget.md risk table).
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .none
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            guard let self, !self.settingFrame, let frame = self.panel?.frame else { return }
            // Persist the TOP-left corner so content-height changes never walk
            // the card down the screen between rebuilds.
            UserDefaults.standard.set(
                [Double(frame.origin.x), Double(frame.maxY)], forKey: Self.originKey
            )
        }
        return panel
    }

    private func rebuild(panel: NSPanel, providers: [ProviderModel], now: Date) {
        let content = Self.makeContentView(providers: providers, now: now)
        let size = content.frame.size
        panel.contentView = content
        settingFrame = true
        panel.setFrame(NSRect(origin: origin(for: size), size: size), display: true)
        settingFrame = false
    }

    /// Persisted [x, topY], clamped into the visible frame; default — top-right
    /// of the main screen with 16 px margins.
    private func origin(for size: NSSize) -> NSPoint {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = visible.maxX - size.width - Self.margin
        var topY = visible.maxY - Self.margin
        if let saved = UserDefaults.standard.array(forKey: Self.originKey) as? [Double], saved.count == 2 {
            x = CGFloat(saved[0])
            topY = CGFloat(saved[1])
        }
        x = min(max(x, visible.minX), max(visible.minX, visible.maxX - size.width))
        topY = min(max(topY, visible.minY + size.height), visible.maxY)
        return NSPoint(x: x, y: topY - size.height)
    }

    // MARK: - Content view (also constructed headlessly by --ui-smoke)

    static func makeContentView(providers: [ProviderModel], now: Date) -> NSView {
        // Root keeps a concrete frame (translates mask stays on) — see the
        // settings window builder; only the inner stack uses autolayout.
        let effect = NSVisualEffectView(frame: .zero)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        if providers.isEmpty {
            let empty = NSTextField(labelWithString: "Limit Monitor: нет данных")
            empty.font = rowFont
            empty.textColor = .secondaryLabelColor
            stack.addArrangedSubview(empty)
        }
        for (index, provider) in providers.enumerated() {
            if index > 0 { stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!) }
            stack.addArrangedSubview(header(for: provider))
            stack.addArrangedSubview(grid(for: provider.limits, now: now))
        }

        effect.addSubview(stack)
        let inset: CGFloat = 12
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: inset),
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: inset),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: contentWidth - inset * 2),
        ])
        effect.frame = NSRect(
            x: 0, y: 0,
            width: contentWidth,
            height: stack.fittingSize.height + inset * 2
        )
        return effect
    }

    private static let rowFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    private static let valueFont = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.smallSystemFontSize, weight: .regular
    )

    private static func header(for provider: ProviderModel) -> NSTextField {
        let label = NSTextField(
            labelWithString: provider.stale ? "⚠ \(provider.name)" : provider.name
        )
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        return label
    }

    private static func grid(for limits: [LimitEntry], now: Date) -> NSGridView {
        let rows: [[NSView]] = limits.map { limit in
            let dot = NSTextField(labelWithString: "●")
            dot.font = rowFont
            dot.textColor = UIStyle.color(for: limit.level)

            let label = NSTextField(labelWithString: Labels.menuLabel(for: limit))
            label.font = rowFont
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let value = NSTextField(
                labelWithString: limit.balanceText ?? (limit.unlimited ? "∞" : "\(limit.percent)%")
            )
            value.font = valueFont
            value.alignment = .right

            let reset = NSTextField(labelWithString: limit.resetsAt.map {
                "до \(TimeFormat.compact($0, now: now))"
            } ?? "")
            reset.font = rowFont
            reset.textColor = .secondaryLabelColor

            return [dot, label, value, reset]
        }
        let grid = NSGridView(views: rows)
        grid.columnSpacing = 6
        grid.rowSpacing = 2
        grid.translatesAutoresizingMaskIntoConstraints = false
        if grid.numberOfColumns > 2 { grid.column(at: 2).xPlacement = .trailing }
        grid.widthAnchor.constraint(equalToConstant: contentWidth - 24).isActive = true
        return grid
    }
}

/// Level → NSColor mapping shared by the status item, the menu and the card.
enum UIStyle {
    static func color(for level: Level) -> NSColor {
        switch level {
        case .green: return .systemGreen
        case .yellow: return .systemYellow
        case .orange: return .systemOrange
        case .red: return .systemRed
        }
    }
}
