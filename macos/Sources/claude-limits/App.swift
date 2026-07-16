import AppKit
import ServiceManagement
import ClaudeLimitsCore

let isRunningInBundle = Bundle.main.bundlePath.hasSuffix(".app")

func runApp() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) {
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum Health {
        case ok
        case tokenExpired
        case noCredentials
        case network
    }

    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private let notifier = Notifier()
    private let pollQueue = DispatchQueue(label: "com.vladlaiho.claude-limits.poll")

    private var limits: [LimitEntry] = []
    private var lastSuccess: Date?
    private var health: Health = .ok
    private var polling = false

    private let titleFont = NSFont.menuBarFont(ofSize: 0)
    private let menuFont = NSFont.menuFont(ofSize: 0)

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["notifyOnReset": true])
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "…"
        statusItem = item
        notifier.requestAuthorizationAtStartup()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        startTimer()
        refreshUI()
        poll()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func startTimer() {
        let t = Timer(timeInterval: 60, target: self, selector: #selector(timerFired), userInfo: nil, repeats: true)
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc private func timerFired() { poll() }
    @objc private func didWake() { poll() }
    @objc private func refreshNow() { poll() }

    private func poll() {
        if polling { return }
        polling = true
        pollQueue.async { [weak self] in
            let loaded = CredentialsProvider.load()
            guard let creds = loaded?.creds else {
                DispatchQueue.main.async { self?.finishPoll(health: .noCredentials) }
                return
            }
            if creds.isExpired() {
                DispatchQueue.main.async { self?.finishPoll(health: .tokenExpired) }
                return
            }
            let result = UsageFetcher.fetchSync(token: creds.accessToken)
            DispatchQueue.main.async {
                switch result {
                case .success(let limits): self?.applySuccess(limits)
                case .failure(.tokenExpired): self?.finishPoll(health: .tokenExpired)
                case .failure: self?.finishPoll(health: .network)
                }
            }
        }
    }

    private func finishPoll(health: Health) {
        self.health = health
        polling = false
        refreshUI()
    }

    private func applySuccess(_ limits: [LimitEntry]) {
        self.limits = limits
        lastSuccess = Date()
        health = .ok
        polling = false

        let defaults = UserDefaults.standard
        let enabled = defaults.bool(forKey: "notifyOnReset")
        let already = (defaults.dictionary(forKey: "exhaustedNotified") as? [String: Bool]) ?? [:]
        let plan = NotificationPlanner.plan(limits: limits, now: Date(), alreadyNotified: already)
        var notified = plan.prunedNotified
        if enabled {
            notifier.reconcileScheduled(plan.scheduled)
            for item in plan.immediate {
                notifier.deliverImmediate(item)
                notified[item.identifier] = true
            }
        } else {
            notifier.removeAllScheduledResets()
        }
        defaults.set(notified, forKey: "exhaustedNotified")
        refreshUI()
    }

    private var isStale: Bool {
        switch health {
        case .tokenExpired, .noCredentials: return true
        case .ok, .network:
            guard let lastSuccess else { return health != .ok }
            return Date().timeIntervalSince(lastSuccess) > 600
        }
    }

    private func refreshUI() {
        updateTitle()
        rebuildMenu()
    }

    private func color(for level: Level) -> NSColor {
        switch level {
        case .green: return .systemGreen
        case .yellow: return .systemYellow
        case .orange: return .systemOrange
        case .red: return .systemRed
        }
    }

    private func updateTitle() {
        guard let button = statusItem?.button else { return }
        let segments = TitleFormatter.segments(for: limits)
        let stale = isStale
        guard !segments.isEmpty else {
            button.attributedTitle = NSAttributedString(
                string: stale ? "⚠…" : "…",
                attributes: [.font: titleFont]
            )
            return
        }
        let title = NSMutableAttributedString()
        if stale {
            title.append(NSAttributedString(string: "⚠", attributes: [.font: titleFont]))
        }
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                title.append(NSAttributedString(
                    string: TitleFormatter.separator, attributes: [.font: titleFont]
                ))
            }
            title.append(NSAttributedString(string: segment.pre, attributes: [.font: titleFont]))
            title.append(NSAttributedString(
                string: "●",
                attributes: [.font: titleFont, .foregroundColor: color(for: segment.level)]
            ))
            title.append(NSAttributedString(string: segment.post, attributes: [.font: titleFont]))
        }
        button.attributedTitle = title
    }

    private func statusLine() -> String {
        switch health {
        case .tokenExpired:
            return "Токен истёк — открой Claude Code"
        case .noCredentials:
            return "Нет учётных данных — открой Claude Code"
        case .network:
            guard let lastSuccess else { return "Нет сети" }
            return "Нет сети · данные от \(TimeFormat.clock(lastSuccess))"
        case .ok:
            guard let lastSuccess else { return "Загрузка…" }
            return "Обновлено: \(TimeFormat.clock(lastSuccess))"
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let now = Date()

        for limit in limits {
            let text = MenuText.infoRow(for: limit, now: now)
            let item = NSMenuItem(title: "● \(text)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            let attributed = NSMutableAttributedString()
            attributed.append(NSAttributedString(
                string: "● ",
                attributes: [.font: menuFont, .foregroundColor: color(for: limit.level)]
            ))
            attributed.append(NSAttributedString(string: text, attributes: [.font: menuFont]))
            item.attributedTitle = attributed
            menu.addItem(item)
        }
        if !limits.isEmpty { menu.addItem(.separator()) }

        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let refresh = NSMenuItem(title: "Обновить сейчас", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        refresh.isEnabled = true
        menu.addItem(refresh)

        let notify = NSMenuItem(title: "Уведомления о лимитах", action: #selector(toggleNotify), keyEquivalent: "")
        notify.target = self
        notify.isEnabled = true
        notify.state = UserDefaults.standard.bool(forKey: "notifyOnReset") ? .on : .off
        menu.addItem(notify)

        let login = NSMenuItem(title: "Запускать при входе", action: #selector(toggleLoginItem), keyEquivalent: "")
        if isRunningInBundle {
            login.target = self
            login.isEnabled = true
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            login.isEnabled = false
            login.state = .off
        }
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выход", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.isEnabled = true
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    @objc private func toggleNotify() {
        let defaults = UserDefaults.standard
        let enabled = !defaults.bool(forKey: "notifyOnReset")
        defaults.set(enabled, forKey: "notifyOnReset")
        if enabled {
            poll()
        } else {
            notifier.removeAllScheduledResets()
        }
        rebuildMenu()
    }

    @objc private func toggleLoginItem() {
        guard isRunningInBundle else { return }
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("SMAppService error: %@", error.localizedDescription)
        }
        rebuildMenu()
    }
}
