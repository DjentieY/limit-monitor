import Foundation
import LimitMonitorCore

// e2e smoke test: a section per provider; exit 0 iff every ACTIVE provider
// fetched and parsed successfully (an inactive provider is not a failure).
// Never prints tokens, account ids or any credential material.
enum CheckMode {
    private enum SectionResult {
        case success([LimitEntry])
        case inactive(String)
        case failed
    }

    static func run() -> Int32 {
        print("limit-monitor --check (e2e smoke test)")
        let now = Date()
        var failed = false
        var groups: [ProviderGroup] = []

        print("")
        print("== claude ==")
        switch runClaude(now: now) {
        case .success(let limits):
            groups.append(ProviderGroup(provider: Provider.claude, limits: limits, stale: false))
        case .inactive(let reason):
            print("claude: неактивен (\(reason))")
        case .failed:
            failed = true
        }

        print("")
        print("== codex ==")
        switch runCodex(now: now) {
        case .success(let limits):
            groups.append(ProviderGroup(provider: Provider.codex, limits: limits, stale: false))
        case .inactive(let reason):
            print("codex: неактивен (\(reason))")
        case .failed:
            failed = true
        }

        print("")
        print("== cursor ==")
        switch runCursor(now: now) {
        case .success(let limits):
            groups.append(ProviderGroup(provider: Provider.cursor, limits: limits, stale: false))
        case .inactive(let reason):
            print("cursor: неактивен (\(reason))")
        case .failed:
            failed = true
        }

        print("")
        if !groups.isEmpty {
            print("merged title: \(TitleFormatter.plainTitle(groups: groups))")
            print("")
        }
        print(failed ? "FAILED" : "OK")
        return failed ? 1 : 0
    }

    // MARK: - Claude

    private static func runClaude(now: Date) -> SectionResult {
        guard let loaded = CredentialsProvider.load() else {
            return .inactive("нет учётных данных Claude Code: ни Keychain, ни ~/.claude/.credentials.json")
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
            return .inactive("нет \(path)")
        case .apiKeyOnly:
            return .inactive("API-key режим — план-лимитов нет")
        case .unreadable(let path):
            return .inactive("\(path) без tokens.access_token")
        case .oauth(let auth, let path):
            print("credentials: \(path)")
            if let lastRefresh = auth.lastRefresh {
                print("last_refresh: \(age(from: lastRefresh, to: now)) назад")
            } else {
                print("last_refresh: отсутствует")
            }
            print(auth.accountID == nil
                ? "account id: не найден — заголовок ChatGPT-Account-Id не отправляется"
                : "account id: найден (значение не печатается)")
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
            return .inactive("нет Cursor")
        case .queryFailed:
            return .inactive("state.vscdb сейчас недоступна (sqlite3 busy/lock) — повтори позже")
        case .badToken(let path, let segments):
            print("credentials: \(path)")
            print("token: найден (\(segmentsWord(segments)), значение не печатается), sub НЕ извлечён — cookie не собрать")
            print("ERROR: токен не разобран — обнови/перелогинь Cursor")
            return .failed
        case .ok(let cookie, let path, let segments):
            print("credentials: \(path)")
            print("token: JWT, \(segmentsWord(segments)), sub найден (значения не печатаются)")
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
        let mod10 = count % 10
        let mod100 = count % 100
        let word: String
        if mod10 == 1, mod100 != 11 {
            word = "сегмент"
        } else if (2...4).contains(mod10), !(12...14).contains(mod100) {
            word = "сегмента"
        } else {
            word = "сегментов"
        }
        return "\(count) \(word)"
    }

    // MARK: - Shared report

    private static func printProviderReport(_ limits: [LimitEntry], now: Date) {
        printTable(limits, now: now)
        print("")
        print("menu rows:")
        for limit in limits {
            print("  ● \(MenuText.infoRow(for: limit, now: now))")
        }
        print("")
        print("title group: \(TitleFormatter.plainTitle(for: limits, stale: false))")
        print("")
        let plan = NotificationPlanner.plan(limits: limits, now: now, alreadyNotified: [:])
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
        let header = [pad("kind", 16), pad("percent", 8), pad("level", 7), pad("resets (local)", 18), "label"]
        print("  " + header.joined())
        for limit in limits {
            let resets = limit.resetsAt.map(localStamp) ?? "—"
            let row = [
                pad(limit.kind, 16),
                pad("\(limit.percent)%", 8),
                pad(limit.level.name, 7),
                pad(resets, 18),
                Labels.menuLabel(for: limit),
            ]
            print("  " + row.joined())
        }
    }

    private static func age(from past: Date, to now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(past) / 60))
        if minutes < 60 { return "\(minutes) мин" }
        if minutes < 48 * 60 { return "\(minutes / 60) ч" }
        return "\(minutes / 1440) дн"
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
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
