import AppKit
import ServiceManagement
import LimitMonitorCore

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

enum ProviderHealth {
    case ok
    case tokenExpired
    case badCredentials
    case network
    case parseError
}

enum PollOutcome {
    case inactive(menuRow: String?)
    case success([LimitEntry])
    case failure(ProviderHealth)
}

// Per-provider state: polling cadence, last data and health are fully isolated,
// so one provider failing or going stale never marks the other stale.
final class ProviderRuntime {
    let id: String
    let pollInterval: TimeInterval
    let fetch: () -> PollOutcome

    var active = false
    var inactiveMenuRow: String?
    var limits: [LimitEntry] = []
    var lastSuccess: Date?
    var health: ProviderHealth = .ok
    var polling = false

    init(id: String, pollInterval: TimeInterval, fetch: @escaping () -> PollOutcome) {
        self.id = id
        self.pollInterval = pollInterval
        self.fetch = fetch
    }

    var isStale: Bool {
        guard active else { return false }
        switch health {
        case .tokenExpired, .badCredentials: return true
        case .ok, .network, .parseError:
            guard let lastSuccess else { return health != .ok }
            return Date().timeIntervalSince(lastSuccess) > 600
        }
    }
}

enum ClaudePoller {
    static func poll() -> PollOutcome {
        guard let loaded = CredentialsProvider.load() else {
            return .inactive(menuRow: "Claude: нет учётных данных — открой Claude Code")
        }
        if loaded.creds.isExpired() { return .failure(.tokenExpired) }
        switch UsageFetcher.fetchSync(token: loaded.creds.accessToken) {
        case .success(let limits): return .success(limits)
        case .failure(.tokenExpired): return .failure(.tokenExpired)
        case .failure: return .failure(.network)
        }
    }
}

enum CodexPoller {
    static func poll() -> PollOutcome {
        switch CodexCredentialsProvider.load() {
        case .missing:
            return .inactive(menuRow: nil)
        case .apiKeyOnly:
            return .inactive(menuRow: "Codex: API-key режим — план-лимитов нет")
        case .unreadable:
            return .inactive(menuRow: "Codex: auth.json без tokens.access_token")
        case .oauth(let auth, _):
            switch CodexUsageFetcher.fetchSync(auth: auth).result {
            case .success(let limits): return .success(limits)
            case .failure(.tokenExpired): return .failure(.tokenExpired)
            case .failure(.parseFailure): return .failure(.parseError)
            case .failure: return .failure(.network)
            }
        }
    }
}

enum CursorPoller {
    static func poll() -> PollOutcome {
        // Re-read the token from the DB on every poll — Cursor rotates it.
        switch CursorCredentialsProvider.load() {
        case .missing, .emptyToken:
            return .inactive(menuRow: "cursor: неактивен (нет Cursor)")
        case .queryFailed:
            // Transient sqlite busy/lock is not "нет Cursor": keep last data,
            // show the per-provider ⚠; the 300 s cadence self-heals it.
            return .failure(.network)
        case .badToken:
            return .failure(.badCredentials)
        case .ok(let cookie, _, _):
            switch CursorUsageFetcher.fetchSync(cookie: cookie) {
            case .success(let limits): return .success(limits)
            case .failure(.tokenExpired): return .failure(.tokenExpired)
            case .failure(.parseFailure): return .failure(.parseError)
            case .failure: return .failure(.network)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var timers: [Timer] = []
    private let notifier = Notifier()
    private let pollQueue = DispatchQueue(
        label: "com.vladlaiho.limit-monitor.poll", attributes: .concurrent
    )

    // Display order: claude limits first, then codex, then cursor. Cursor is
    // polled gently (300 s) — billing-cycle data moves slowly.
    private let providers: [ProviderRuntime] = [
        ProviderRuntime(id: Provider.claude, pollInterval: 60, fetch: ClaudePoller.poll),
        ProviderRuntime(id: Provider.codex, pollInterval: 180, fetch: CodexPoller.poll),
        ProviderRuntime(id: Provider.cursor, pollInterval: 300, fetch: CursorPoller.poll),
    ]

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
        startTimers()
        refreshUI()
        pollAll()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func startTimers() {
        for provider in providers {
            let timer = Timer(timeInterval: provider.pollInterval, repeats: true) { [weak self] _ in
                self?.poll(provider)
            }
            timer.tolerance = provider.pollInterval / 6
            RunLoop.main.add(timer, forMode: .common)
            timers.append(timer)
        }
    }

    @objc private func didWake() { pollAll() }
    @objc private func refreshNow() { pollAll() }

    private func pollAll() {
        for provider in providers { poll(provider) }
    }

    private func poll(_ provider: ProviderRuntime) {
        if provider.polling { return }
        provider.polling = true
        pollQueue.async { [weak self] in
            let outcome = provider.fetch()
            DispatchQueue.main.async { self?.apply(outcome, to: provider) }
        }
    }

    private func apply(_ outcome: PollOutcome, to provider: ProviderRuntime) {
        switch outcome {
        case .inactive(let menuRow):
            provider.active = false
            provider.inactiveMenuRow = menuRow
            provider.limits = []
            provider.lastSuccess = nil
            provider.health = .ok
        case .success(let limits):
            provider.active = true
            provider.inactiveMenuRow = nil
            provider.limits = limits
            provider.lastSuccess = Date()
            provider.health = .ok
        case .failure(let health):
            provider.active = true
            provider.inactiveMenuRow = nil
            provider.health = health
        }
        provider.polling = false
        // Replan only from data-bearing (successful) polls: a failed/inactive
        // launch poll must not wipe the previous session's pre-scheduled resets —
        // they have to fire even if the Mac is offline at the reset moment.
        if case .success = outcome { replanNotifications() }
        refreshUI()
    }

    private func replanNotifications() {
        let merged = providers.filter(\.active).flatMap(\.limits)
        // A provider with no successful poll this session has an UNKNOWN desired
        // set: its pending requests and null-stamp exhausted keys are left alone
        // until it reports, so one provider's launch success cannot wipe another's.
        let reported = Set(providers.filter { $0.lastSuccess != nil }.map(\.id))
        let unreported = Set(providers.map(\.id)).subtracting(reported)
        let defaults = UserDefaults.standard
        let enabled = defaults.bool(forKey: "notifyOnReset")
        let already = (defaults.dictionary(forKey: "exhaustedNotified") as? [String: Bool]) ?? [:]
        let plan = NotificationPlanner.plan(limits: merged, now: Date(), alreadyNotified: already)
        var notified = plan.prunedNotified
        for (key, value) in already where notified[key] == nil {
            guard unreported.contains(NotificationPlanner.identifierProvider(key)),
                  NotificationPlanner.identifierStampDate(key) == nil else { continue }
            notified[key] = value
        }
        if enabled {
            notifier.reconcileScheduled(plan.scheduled, removalScope: reported)
            for item in plan.immediate {
                notifier.deliverImmediate(item)
                notified[item.identifier] = true
            }
        } else {
            notifier.removeAllScheduledResets()
        }
        defaults.set(notified, forKey: "exhaustedNotified")
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

    private func activeProviders() -> [ProviderRuntime] {
        providers.filter(\.active)
    }

    private func updateTitle() {
        guard let button = statusItem?.button else { return }
        let title = NSMutableAttributedString()
        func append(_ string: String, color: NSColor? = nil) {
            var attributes: [NSAttributedString.Key: Any] = [.font: titleFont]
            if let color { attributes[.foregroundColor] = color }
            title.append(NSAttributedString(string: string, attributes: attributes))
        }
        func appendSegments(_ limits: [LimitEntry]) {
            for (index, segment) in TitleFormatter.segments(for: limits).enumerated() {
                if index > 0 { append(TitleFormatter.separator) }
                if segment.dotless {
                    append(segment.text, color: color(for: segment.level))
                } else {
                    append(segment.pre)
                    append("●", color: color(for: segment.level))
                    append(segment.post)
                }
            }
        }
        let active = activeProviders()
        if active.isEmpty {
            append("⚠…")
        } else if active.count == 1, let provider = active.first {
            if provider.isStale { append("⚠") }
            if provider.limits.isEmpty { append("…") } else { appendSegments(provider.limits) }
        } else {
            for (index, provider) in active.enumerated() {
                if index > 0 { append(TitleFormatter.providerSeparator) }
                if provider.isStale { append("⚠") }
                append(Provider.titlePrefix(provider.id))
                if provider.limits.isEmpty { append("…") } else { appendSegments(provider.limits) }
            }
        }
        button.attributedTitle = title
    }

    private func errorLine(for provider: ProviderRuntime, multi: Bool) -> String {
        switch provider.health {
        case .ok:
            return ""
        case .tokenExpired:
            switch provider.id {
            case Provider.codex: return "Токен Codex истёк — запусти codex"
            case Provider.cursor: return "Токен Cursor истёк — открой Cursor"
            default: return "Токен истёк — открой Claude Code"
            }
        case .badCredentials:
            switch provider.id {
            case Provider.cursor: return "Токен Cursor не разобран — перелогинься в Cursor"
            default: return "\(Provider.displayName(provider.id)): учётные данные не разобраны"
            }
        case .network:
            let prefix = multi ? "\(Provider.displayName(provider.id)): нет сети" : "Нет сети"
            guard let lastSuccess = provider.lastSuccess else { return prefix }
            return "\(prefix) · данные от \(TimeFormat.clock(lastSuccess))"
        case .parseError:
            return "\(Provider.displayName(provider.id)): ошибка ответа API"
        }
    }

    private func statusLine() -> String {
        let active = activeProviders()
        if active.count == 1, let provider = active.first, provider.health != .ok {
            return errorLine(for: provider, multi: false)
        }
        let lastSuccess = active.compactMap(\.lastSuccess).max()
        if let lastSuccess { return "Обновлено: \(TimeFormat.clock(lastSuccess))" }
        return active.isEmpty ? "Нет данных" : "Загрузка…"
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let now = Date()
        let multi = activeProviders().count > 1
        var addedRows = false

        for provider in providers {
            guard provider.active else {
                if let row = provider.inactiveMenuRow {
                    menu.addItem(disabledItem(row))
                    addedRows = true
                }
                continue
            }
            if multi {
                let name = Provider.displayName(provider.id)
                let header = disabledItem(name)
                header.attributedTitle = NSAttributedString(
                    string: name,
                    attributes: [.font: NSFont.boldSystemFont(ofSize: menuFont.pointSize)]
                )
                menu.addItem(header)
                addedRows = true
            }
            for limit in provider.limits {
                let text = MenuText.infoRow(for: limit, now: now)
                let item = disabledItem("● \(text)")
                let attributed = NSMutableAttributedString()
                attributed.append(NSAttributedString(
                    string: "● ",
                    attributes: [.font: menuFont, .foregroundColor: color(for: limit.level)]
                ))
                attributed.append(NSAttributedString(string: text, attributes: [.font: menuFont]))
                item.attributedTitle = attributed
                menu.addItem(item)
                addedRows = true
            }
            if multi {
                if provider.limits.isEmpty, provider.health == .ok {
                    menu.addItem(disabledItem("Загрузка…"))
                    addedRows = true
                }
                if provider.health != .ok {
                    menu.addItem(disabledItem(errorLine(for: provider, multi: true)))
                    addedRows = true
                }
            }
        }
        if addedRows { menu.addItem(.separator()) }

        menu.addItem(disabledItem(statusLine()))

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
            pollAll()
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
