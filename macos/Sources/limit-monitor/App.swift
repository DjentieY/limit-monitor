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
    /// Config providers (v0.4): a typed state (key/config/bad-key/no-plan/
    /// blocked/info/fetch/parse) instead of the builtin ProviderHealth.
    case customState(ProviderState)
}

// Per-provider state: polling cadence, last data and health are fully isolated,
// so one provider failing or going stale never marks the other stale.
final class ProviderRuntime {
    let id: String
    let displayName: String
    let barPrefix: String
    let pollInterval: TimeInterval
    let fetch: () -> PollOutcome

    var active = false
    var inactiveMenuRow: String?
    var limits: [LimitEntry] = []
    var lastSuccess: Date?
    var health: ProviderHealth = .ok
    /// Last error/info state of a config provider — drives its RU error line.
    var customState: ProviderState?
    var polling = false

    init(
        id: String,
        displayName: String? = nil,
        barPrefix: String? = nil,
        pollInterval: TimeInterval,
        fetch: @escaping () -> PollOutcome
    ) {
        self.id = id
        self.displayName = displayName ?? Provider.displayName(id)
        self.barPrefix = barPrefix ?? Provider.titlePrefix(id)
        self.pollInterval = pollInterval
        self.fetch = fetch
    }

    convenience init(custom provider: ConfiguredProvider) {
        let poller = CustomProviderPoller(provider: provider)
        self.init(
            id: provider.id,
            displayName: provider.name,
            barPrefix: provider.titlePrefix,
            pollInterval: TimeInterval(provider.pollSeconds),
            fetch: poller.poll
        )
    }

    /// Stale threshold scales with the provider's own cadence: the v0.1
    /// 10-minute rule for the fast builtins (claude/codex/cursor stay at 600 s),
    /// 2 poll intervals for slower config providers — pollSeconds has no upper
    /// clamp, so a healthy 600+ s entry must not flash ⚠ on the tail of every
    /// cycle just because refreshUI redraws between its polls.
    var isStale: Bool {
        guard active else { return false }
        switch health {
        case .tokenExpired, .badCredentials: return true
        case .ok, .network, .parseError:
            guard let lastSuccess else { return health != .ok }
            return Date().timeIntervalSince(lastSuccess) > max(600, pollInterval * 2)
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
    private var timersByProvider: [String: Timer] = [:]
    private let notifier = Notifier()
    private let desktopCard = DesktopCard()
    private var settings: SettingsWindowController?
    private let pollQueue = DispatchQueue(
        label: "com.vladlaiho.limit-monitor.poll", attributes: .concurrent
    )

    // Display order: claude limits first, then codex, then cursor, then config
    // providers in providers.json file order. Cursor and config providers are
    // polled gently (300 s default) — balances/billing data move slowly.
    private let providers: [ProviderRuntime]
    /// Static disabled menu rows from providers.json: file parse/version error,
    /// chmod warning, per-entry config errors. Built once at launch.
    private let configRows: [String]
    /// `enabled: false` providers.json entries — listed in the settings window
    /// unchecked-and-disabled (v0.5), invisible everywhere else.
    private let configDisabledNames: [String]

    override init() {
        var runtimes = [
            ProviderRuntime(id: Provider.claude, pollInterval: 60, fetch: ClaudePoller.poll),
            ProviderRuntime(id: Provider.codex, pollInterval: 180, fetch: CodexPoller.poll),
            ProviderRuntime(id: Provider.cursor, pollInterval: 300, fetch: CursorPoller.poll),
        ]
        var rows: [String] = []
        var disabledNames: [String] = []
        switch ProvidersConfigLoader.load() {
        case .missing:
            break
        case .malformed:
            rows.append(ProvidersConfigFile.malformedMenuRow)
        case .unsupportedVersion:
            rows.append(ProvidersConfigFile.unsupportedVersionMenuRow)
        case .loaded(let config, _, let permissive):
            if permissive { rows.append(ProvidersConfigFile.permissiveMenuRow) }
            runtimes.append(contentsOf: config.providers.map { ProviderRuntime(custom: $0) })
            rows.append(contentsOf: config.errors.map(\.menuRow))
            disabledNames = config.disabledEntries.map(\.name)
        }
        providers = runtimes
        configRows = rows
        configDisabledNames = disabledNames
        super.init()
    }

    private let titleFont = NSFont.menuBarFont(ofSize: 0)
    private let menuFont = NSFont.menuFont(ofSize: 0)

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "notifyOnReset": true,
            DesktopCard.defaultsKey: false,
        ])
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
        syncTimers()
        refreshUI()
        pollAll()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// One repeating timer per ENABLED provider; a settings checkbox flip
    /// stops/starts polling immediately (SPEC v0.5).
    private func syncTimers() {
        let disabled = disabledProviders()
        for provider in providers {
            if disabled.contains(provider.id) {
                timersByProvider.removeValue(forKey: provider.id)?.invalidate()
            } else if timersByProvider[provider.id] == nil {
                let timer = Timer(timeInterval: provider.pollInterval, repeats: true) { [weak self] _ in
                    self?.poll(provider)
                }
                timer.tolerance = provider.pollInterval / 6
                RunLoop.main.add(timer, forMode: .common)
                timersByProvider[provider.id] = timer
            }
        }
    }

    @objc private func didWake() { pollAll() }
    @objc private func refreshNow() { pollAll() }

    private func pollAll() {
        for provider in enabledRuntimes() { poll(provider) }
    }

    private func poll(_ provider: ProviderRuntime) {
        if provider.polling || disabledProviders().contains(provider.id) { return }
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
            provider.customState = nil
        case .success(let limits):
            provider.active = true
            provider.inactiveMenuRow = nil
            provider.limits = limits
            provider.lastSuccess = Date()
            provider.health = .ok
            provider.customState = nil
        case .failure(let health):
            provider.active = true
            provider.inactiveMenuRow = nil
            provider.health = health
        case .customState(let state):
            if case .info = state {
                // Not a failure (openrouter credits denied to this key): the
                // provider has nothing to show — a disabled menu row, no bar group.
                provider.active = false
                provider.inactiveMenuRow = MenuText.stateRow(name: provider.displayName, state: state)
                provider.limits = []
                provider.lastSuccess = nil
                provider.health = .ok
                provider.customState = nil
            } else {
                // Error states keep the last data and the v0.2 ⚠ semantics.
                provider.active = true
                provider.inactiveMenuRow = nil
                provider.customState = state
                provider.health = Self.health(for: state)
            }
        }
        provider.polling = false
        // Replan only from data-bearing (successful) polls: a failed/inactive
        // launch poll must not wipe the previous session's pre-scheduled resets —
        // they have to fire even if the Mac is offline at the reset moment.
        if case .success = outcome { replanNotifications() }
        writeSnapshot()
        refreshUI()
    }

    private func disabledProviders() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: ProviderSettings.disabledDefaultsKey) ?? [])
    }

    // SPEC v0.5: after every poll cycle the merged model lands atomically in
    // ~/Library/Application Support/limit-monitor/widget-snapshot.json (numbers,
    // labels, ISO UTC times — never credentials; disabled providers excluded).
    private func writeSnapshot() {
        let groups = providers.filter(\.active).map {
            ProviderGroup(provider: $0.id, limits: $0.limits, stale: $0.isStale, titlePrefix: $0.barPrefix)
        }
        SnapshotStore.write(WidgetSnapshot.build(groups: groups, now: Date(), disabled: disabledProviders()))
    }

    private func replanNotifications() {
        let disabled = disabledProviders()
        let merged = ProviderFilter.limits(
            providers.filter(\.active).flatMap(\.limits), disabled: disabled
        )
        // A provider with no successful poll this session has an UNKNOWN desired
        // set: its pending requests and null-stamp exhausted keys are left alone
        // until it reports, so one provider's launch success cannot wipe another's.
        // Identifiers of providers absent from allIds (removed from providers.json)
        // have no runtime at all and are purged by the reconciler.
        let allIds = Set(providers.map(\.id))
        let reported = Set(providers.filter { $0.lastSuccess != nil }.map(\.id))
        let unreported = allIds.subtracting(reported)
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
            notifier.reconcileScheduled(
                plan.scheduled, removalScope: reported, knownProviders: allIds, disabled: disabled
            )
            for item in plan.immediate {
                notifier.deliverImmediate(item)
                notified[item.identifier] = true
            }
        } else {
            notifier.removeAllScheduledResets()
        }
        defaults.set(notified, forKey: "exhaustedNotified")
    }

    /// Staleness semantics of a config-provider state: transient fetch/parse
    /// failures behave like the builtin network/parse cases (⚠ only after the
    /// 10-min grace), persistent conditions (bad key, no plan, geo-block,
    /// config/key errors) show ⚠ immediately, like an expired token.
    private static func health(for state: ProviderState) -> ProviderHealth {
        switch state {
        case .ok, .info: return .ok
        case .fetchError: return .network
        case .parseError: return .parseError
        case .configError, .keyError, .badKey, .noPlan, .blocked: return .badCredentials
        }
    }

    private func refreshUI() {
        updateTitle()
        rebuildMenu()
        updateDesktopCard()
    }

    private func color(for level: Level) -> NSColor {
        UIStyle.color(for: level)
    }

    private func enabledRuntimes() -> [ProviderRuntime] {
        let disabled = disabledProviders()
        return providers.filter { !disabled.contains($0.id) }
    }

    private func activeProviders() -> [ProviderRuntime] {
        enabledRuntimes().filter(\.active)
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
        if enabledRuntimes().isEmpty {
            // Every provider unchecked in the settings — static brand title,
            // the menu (incl. Настройки…) stays reachable.
            append("LM")
        } else if active.isEmpty {
            append("⚠…")
        } else if active.count == 1, let provider = active.first {
            if provider.isStale { append("⚠") }
            if provider.limits.isEmpty { append("…") } else { appendSegments(provider.limits) }
        } else {
            for (index, provider) in active.enumerated() {
                if index > 0 { append(TitleFormatter.providerSeparator) }
                if provider.isStale { append("⚠") }
                append(provider.barPrefix)
                if provider.limits.isEmpty { append("…") } else { appendSegments(provider.limits) }
            }
        }
        button.attributedTitle = title
    }

    private func errorLine(for provider: ProviderRuntime, multi: Bool) -> String {
        if let state = provider.customState {
            return MenuText.stateRow(name: provider.displayName, state: state)
        }
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
        let disabled = disabledProviders()
        var addedRows = false

        for provider in providers {
            // Unchecked in the settings → no rows at all (SPEC v0.5).
            guard !disabled.contains(provider.id) else { continue }
            guard provider.active else {
                if let row = provider.inactiveMenuRow {
                    menu.addItem(disabledItem(row))
                    addedRows = true
                }
                continue
            }
            if multi {
                let name = provider.displayName
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
        for row in configRows {
            menu.addItem(disabledItem(row))
            addedRows = true
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

        let card = NSMenuItem(title: "Виджет на рабочем столе", action: #selector(toggleDesktopCard), keyEquivalent: "")
        card.target = self
        card.isEnabled = true
        card.state = UserDefaults.standard.bool(forKey: DesktopCard.defaultsKey) ? .on : .off
        menu.addItem(card)

        let settingsItem = NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.isEnabled = true
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выход", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.isEnabled = true
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    // MARK: - Toggles (shared by the menu checkmarks and the settings window)

    @objc private func toggleNotify() {
        setNotify(!UserDefaults.standard.bool(forKey: "notifyOnReset"))
    }

    private func setNotify(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "notifyOnReset")
        if enabled {
            pollAll()
        } else {
            notifier.removeAllScheduledResets()
        }
        rebuildMenu()
        settings?.refresh()
    }

    @objc private func toggleLoginItem() {
        guard isRunningInBundle else { return }
        setLoginItem(SMAppService.mainApp.status != .enabled)
    }

    private func setLoginItem(_ enabled: Bool) {
        guard isRunningInBundle else { return }
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            NSLog("SMAppService error: %@", error.localizedDescription)
        }
        rebuildMenu()
        settings?.refresh()
    }

    @objc private func toggleDesktopCard() {
        setDesktopCard(!UserDefaults.standard.bool(forKey: DesktopCard.defaultsKey))
    }

    private func setDesktopCard(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: DesktopCard.defaultsKey)
        updateDesktopCard()
        rebuildMenu()
        settings?.refresh()
    }

    // MARK: - Desktop card (SPEC v0.5)

    private func updateDesktopCard() {
        let cardProviders = activeProviders()
            .filter { !$0.limits.isEmpty }
            .map { DesktopCard.ProviderModel(name: $0.displayName, stale: $0.isStale, limits: $0.limits) }
        desktopCard.setVisible(
            UserDefaults.standard.bool(forKey: DesktopCard.defaultsKey),
            providers: cardProviders
        )
    }

    // MARK: - Settings window (SPEC v0.5)

    @objc private func openSettings() {
        if settings == nil {
            settings = SettingsWindowController(
                modelProvider: { [weak self] in
                    self?.settingsModel() ?? SettingsWindowController.Model(
                        providers: [], configPath: ProvidersConfigFile.path(), configExists: false,
                        notifyOn: true, loginOn: false, loginAvailable: false, desktopCardOn: false
                    )
                },
                handlers: SettingsWindowController.Handlers(
                    providerToggled: { [weak self] id, enabled in
                        self?.setProviderEnabled(id, enabled: enabled)
                    },
                    notifyToggled: { [weak self] on in self?.setNotify(on) },
                    loginToggled: { [weak self] on in self?.setLoginItem(on) },
                    desktopCardToggled: { [weak self] on in self?.setDesktopCard(on) },
                    revealConfig: {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: ProvidersConfigFile.path())]
                        )
                    }
                )
            )
        }
        settings?.show()
    }

    private func settingsModel() -> SettingsWindowController.Model {
        let disabled = disabledProviders()
        var rows: [SettingsWindowController.ProviderRow] = providers.map { runtime in
            SettingsWindowController.ProviderRow(
                id: runtime.id,
                title: runtime.displayName,
                checked: !disabled.contains(runtime.id),
                enabled: true,
                tooltip: nil
            )
        }
        rows.append(contentsOf: configDisabledNames.map { name in
            SettingsWindowController.ProviderRow(
                id: nil, title: name, checked: false, enabled: false,
                tooltip: "выключен в providers.json"
            )
        })
        let configPath = ProvidersConfigFile.path()
        let defaults = UserDefaults.standard
        return SettingsWindowController.Model(
            providers: rows,
            configPath: configPath,
            configExists: FileManager.default.fileExists(atPath: configPath),
            notifyOn: defaults.bool(forKey: "notifyOnReset"),
            loginOn: isRunningInBundle && SMAppService.mainApp.status == .enabled,
            loginAvailable: isRunningInBundle,
            desktopCardOn: defaults.bool(forKey: DesktopCard.defaultsKey)
        )
    }

    /// A checkbox flip applies IMMEDIATELY (SPEC v0.5): polling stops/starts,
    /// bar/menu/card/snapshot exclude the provider, its pending reset|<id>|*
    /// requests are reconciled away right now; re-enabling polls it at once.
    private func setProviderEnabled(_ id: String, enabled: Bool) {
        let outcome = ProviderSettings.setEnabled(enabled, provider: id, disabled: disabledProviders())
        UserDefaults.standard.set(
            Array(outcome.disabled).sorted(), forKey: ProviderSettings.disabledDefaultsKey
        )
        syncTimers()
        if outcome.reconcileNow {
            // Explicit reconcile on disable — complements the
            // replan-only-on-success rule; the disabled id is removable
            // unconditionally (NotificationReconciler, check 33).
            replanNotifications()
        }
        writeSnapshot()
        refreshUI()
        for pollID in outcome.immediatePoll {
            if let runtime = providers.first(where: { $0.id == pollID }) { poll(runtime) }
        }
        settings?.refresh()
    }
}
