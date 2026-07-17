import Foundation
import LimitMonitorCore

// e2e smoke test: a section per provider; exit 0 iff every ACTIVE provider
// fetched and parsed successfully (an inactive provider is not a failure).
// Never prints tokens, account ids or any credential material.
//
// SPEC v0.6: --check is ALWAYS English — the diagnostic/CI/agent surface, so a
// stable, locale-independent, greppable output. Every Core call is pinned to
// `.en`; the local console literals are English inline (no catalog entry). The
// output must contain NO Cyrillic.
enum CheckMode {
    private static let lang: Language = .en

    private enum SectionResult {
        case success([LimitEntry])
        case inactive(String)
        case failed
    }

    static func run() -> Int32 {
        print("limit-monitor --check (e2e smoke test)")
        let now = Date()
        // v0.5 settings checkboxes: a disabled provider is skipped, NOT a failure.
        let disabled = Set(
            UserDefaults.standard.stringArray(forKey: ProviderSettings.disabledDefaultsKey) ?? []
        )
        var failed = false
        var groups: [ProviderGroup] = []

        func runBuiltin(_ id: String, _ section: () -> SectionResult) {
            print("")
            print("== \(id) ==")
            if disabled.contains(id) {
                print("\(id): disabled in settings")
                return
            }
            switch section() {
            case .success(let limits):
                groups.append(ProviderGroup(provider: id, limits: limits, stale: false))
            case .inactive(let reason):
                print("\(id): inactive (\(reason))")
            case .failed:
                failed = true
            }
        }

        runBuiltin(Provider.claude) { runClaude(now: now) }
        runBuiltin(Provider.codex) { runCodex(now: now) }
        runBuiltin(Provider.cursor) { runCursor(now: now) }

        print("")
        print("== custom ==")
        if runCustomProviders(now: now, disabled: disabled, groups: &groups) { failed = true }

        print("")
        if !groups.isEmpty {
            print("merged title: \(TitleFormatter.plainTitle(groups: groups))")
            print("")
        }
        // v0.5: a successful --check leaves a fresh widget snapshot behind, so
        // agents can poll --status without the GUI (and without the network).
        if !failed {
            let snapshot = WidgetSnapshot.build(groups: groups, now: Date(), disabled: disabled)
            if SnapshotStore.write(snapshot) {
                print("snapshot: written \(SnapshotStore.fileURL.path)")
            } else {
                print("WARNING: snapshot not written (\(SnapshotStore.fileURL.path))")
            }
            print("")
        }
        print(failed ? "FAILED" : "OK")
        return failed ? 1 : 0
    }

    // MARK: - Custom providers (providers.json, v0.4)

    // Exit contract: config-error, key-resolution failure, bad-key, no-plan,
    // blocked and fetch/parse failures of an ENABLED provider fail the run;
    // a missing config file, enabled:false entries and the openrouter
    // credits-denied info state do not. Key VALUES are never printed — only
    // the source (env NAME / command / literal).
    private static func runCustomProviders(
        now: Date, disabled: Set<String>, groups: inout [ProviderGroup]
    ) -> Bool {
        switch ProvidersConfigLoader.load() {
        case .missing(let path):
            print(ProvidersConfigLoader.isDefaultPath(path)
                ? ConfigStr.missingCheck.text(lang)
                : "custom: no \(path)")
            return false
        case .malformed(let path):
            print("config: \(path)")
            print("ERROR: \(ConfigStr.malformed.text(lang))")
            return true
        case .unsupportedVersion(let path):
            print("config: \(path)")
            print("ERROR: \(ConfigStr.unsupportedVersion.text(lang))")
            return true
        case .loaded(let config, let path, let permissive):
            // SPEC v0.4: zero enabled entries → the same single line as a
            // missing file. Applies to the clean canonical case only — an env
            // override or a chmod warning keeps the diagnostic form.
            if config.providers.isEmpty, config.errors.isEmpty, !permissive,
               ProvidersConfigLoader.isDefaultPath(path) {
                print(ConfigStr.missingCheck.text(lang))
                return false
            }
            print("config: \(path)")
            if permissive {
                print("WARNING: \(ConfigStr.permissive.text(lang))")
            }
            var failed = false
            for error in config.errors {
                print("ERROR: \(ConfigStr.entryError(name: error.name, reason: error.reason).text(lang))")
                failed = true
            }
            if config.providers.isEmpty, config.errors.isEmpty {
                print("custom: no enabled providers")
            }
            for provider in config.providers {
                print("")
                if disabled.contains(provider.id) {
                    print("\(provider.id): disabled in settings")
                    continue
                }
                print("-- \(provider.name) (id \(provider.id), kind \(provider.kind.rawValue)) --")
                if runCustom(provider, now: now, groups: &groups) { failed = true }
            }
            return failed
        }
    }

    private static func runCustom(
        _ provider: ConfiguredProvider, now: Date, groups: inout [ProviderGroup]
    ) -> Bool {
        print("key source: \(provider.key.sourceDescription)")
        print("host: \(provider.host.rawValue) · poll: \(provider.pollSeconds) s")
        let key: String
        switch KeyResolver.resolve(provider.key, lang) {
        case .failure(let reason):
            print("ERROR: \(MenuText.stateRow(name: provider.name, state: .keyError(reason), lang))")
            return true
        case .key(let value):
            key = value
            print("key: resolved (value not printed)")
        }
        let outcome = CustomProviderEngine.run(provider: provider, key: key, lang)
        for step in outcome.steps {
            if let status = step.httpStatus {
                print("GET \(step.url) → HTTP \(status)")
            } else {
                print("GET \(step.url) → \(step.networkError ?? "no response")")
            }
        }
        switch outcome.result {
        case .entries(let limits):
            printProviderReport(limits, now: now)
            groups.append(ProviderGroup(
                provider: provider.id, limits: limits, stale: false,
                titlePrefix: provider.titlePrefix
            ))
            return false
        case .state(.info(let message)):
            // Informational, NOT a failure (openrouter /credits denied to this key).
            print("\(MenuText.stateRow(name: provider.name, state: .info(message), lang))")
            return false
        case .state(.ok), .needsCredits:
            print("ERROR: \(MenuText.stateRow(name: provider.name, state: .parseError("no data"), lang))")
            return true
        case .state(let state):
            print("ERROR: \(MenuText.stateRow(name: provider.name, state: state, lang))")
            return true
        }
    }

    // MARK: - Claude

    private static func runClaude(now: Date) -> SectionResult {
        guard let loaded = CredentialsProvider.load() else {
            return .inactive("no Claude Code credentials: neither Keychain nor ~/.claude/.credentials.json")
        }
        print("credentials: \(loaded.source)")
        if loaded.creds.isExpired(now: now) {
            print("WARNING: access token expired — open Claude Code to refresh it")
        } else if let expiresAt = loaded.creds.expiresAt {
            print("token: valid for another \(Int(expiresAt.timeIntervalSince(now) / 60)) min")
        } else {
            print("token: present (no expiresAt)")
        }
        print("GET \(UsageFetcher.endpoint.absoluteString) ...")
        switch UsageFetcher.fetchSync(token: loaded.creds.accessToken) {
        case .failure(let error):
            print("ERROR: fetch failed: \(error.describe)")
            return .failed
        case .success(let limits):
            printProviderReport(limits, now: now)
            return .success(limits)
        }
    }

    // MARK: - Codex

    private static func runCodex(now: Date) -> SectionResult {
        switch CodexCredentialsProvider.load() {
        case .missing(let path):
            return .inactive("no \(path)")
        case .apiKeyOnly:
            return .inactive("API-key mode — no plan limits")
        case .unreadable(let path):
            return .inactive("\(path) without tokens.access_token")
        case .oauth(let auth, let path):
            print("credentials: \(path)")
            if let lastRefresh = auth.lastRefresh {
                print("last_refresh: \(age(from: lastRefresh, to: now)) ago")
            } else {
                print("last_refresh: absent")
            }
            print(auth.accountID == nil
                ? "account id: not found — the ChatGPT-Account-Id header is not sent"
                : "account id: found (value not printed)")
            print("GET \(CodexUsageFetcher.primaryEndpoint.absoluteString) "
                + "(fallback: \(CodexUsageFetcher.fallbackEndpoint.path)) ...")
            let outcome = CodexUsageFetcher.fetchSync(auth: auth, now: now)
            print("endpoint used: \(outcome.endpoint)")
            switch outcome.result {
            case .failure(.parseFailure(let keyTree)):
                print("ERROR: codex response did not parse; JSON key tree (keys/array counts only):")
                print(keyTree)
                return .failed
            case .failure(let error):
                print("ERROR: fetch failed: \(error.describe)")
                return .failed
            case .success(let limits):
                printProviderReport(limits, now: now)
                return .success(limits)
            }
        }
    }

    // MARK: - Cursor

    // Creds diagnostics are SHAPE ONLY: never the token, the JWT sub, or the
    // assembled cookie — not even on failure paths.
    private static func runCursor(now: Date) -> SectionResult {
        switch CursorCredentialsProvider.load() {
        case .missing, .emptyToken:
            return .inactive("no Cursor")
        case .queryFailed:
            return .inactive("state.vscdb is currently unavailable (sqlite3 busy/lock) — retry later")
        case .badToken(let path, let segments):
            print("credentials: \(path)")
            print("token: found (\(segmentsWord(segments)), value not printed), sub NOT extracted — cannot assemble cookie")
            print("ERROR: token not parsed — update/re-login Cursor")
            return .failed
        case .ok(let cookie, let path, let segments):
            print("credentials: \(path)")
            print("token: JWT, \(segmentsWord(segments)), sub found (values not printed)")
            print("GET \(CursorUsageFetcher.endpoint.absoluteString) ...")
            switch CursorUsageFetcher.fetchSync(cookie: cookie) {
            case .failure(.parseFailure(let keyTree)):
                print("ERROR: cursor response did not parse; JSON key tree (keys/array counts only):")
                print(keyTree)
                return .failed
            case .failure(let error):
                print("ERROR: fetch failed: \(error.describe)")
                return .failed
            case .success(let limits):
                printProviderReport(limits, now: now)
                return .success(limits)
            }
        }
    }

    private static func segmentsWord(_ count: Int) -> String {
        "\(count) \(count == 1 ? "segment" : "segments")"
    }

    // MARK: - Shared report

    private static func printProviderReport(_ limits: [LimitEntry], now: Date) {
        printTable(limits, now: now)
        print("")
        print("menu rows:")
        for limit in limits {
            print("  ● \(MenuText.infoRow(for: limit, now: now, lang))")
        }
        print("")
        print("title group: \(TitleFormatter.plainTitle(for: limits, stale: false))")
        print("")
        let plan = NotificationPlanner.plan(limits: limits, now: now, alreadyNotified: [:], lang)
        print("planned reset notifications (\(plan.scheduled.count)):")
        for item in plan.scheduled {
            print("  \(item.identifier)")
            print("    fires \(localStamp(item.fireDate)) · \"\(item.title)\" — \"\(item.body)\"")
        }
        print("immediate exhaustion notifications (\(plan.immediate.count)):")
        for item in plan.immediate {
            print("  \(item.identifier)")
            print("    \"\(item.title)\" — \"\(item.body)\"")
        }
    }

    private static func printTable(_ limits: [LimitEntry], now: Date) {
        print("parsed limits (\(limits.count)):")
        let header = [pad("kind", 16), pad("value", 8), pad("level", 7), pad("resets (local)", 18), "label"]
        print("  " + header.joined())
        for limit in limits {
            let resets = limit.resetsAt.map(localStamp) ?? "—"
            // Balance-mode entries (v0.4) show the formatted remainder, not a percent.
            let value = limit.balanceText ?? (limit.unlimited ? "∞" : "\(limit.percent)%")
            let row = [
                pad(limit.kind, 16),
                pad(value, 8),
                pad(limit.level.name, 7),
                pad(resets, 18),
                Labels.menuLabel(for: limit, lang),
            ]
            print("  " + row.joined())
        }
    }

    private static func age(from past: Date, to now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(past) / 60))
        if minutes < 60 { return "\(minutes) min" }
        if minutes < 48 * 60 { return "\(minutes / 60) h" }
        return "\(minutes / 1440) d"
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd.MM HH:mm"
        return f
    }()

    private static func localStamp(_ date: Date) -> String {
        stampFormatter.string(from: date)
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }
}
