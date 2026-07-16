import Foundation
import ClaudeLimitsCore

enum CheckMode {
    static func run() -> Int32 {
        print("claude-limits --check (e2e smoke test)")
        guard let loaded = CredentialsProvider.load() else {
            print("ERROR: credentials not found (keychain \"Claude Code-credentials\" + ~/.claude/.credentials.json)")
            return 1
        }
        let now = Date()
        print("credentials: \(loaded.source)")
        if loaded.creds.isExpired(now: now) {
            print("WARNING: access token expired — open Claude Code to refresh it")
        } else if let expiresAt = loaded.creds.expiresAt {
            print("token: valid for another \(Int(expiresAt.timeIntervalSince(now) / 60)) min")
        } else {
            print("token: present (no expiresAt)")
        }

        print("GET \(endpointDescription()) ...")
        switch UsageFetcher.fetchSync(token: loaded.creds.accessToken) {
        case .failure(let error):
            print("ERROR: fetch failed: \(error.describe)")
            return 1
        case .success(let limits):
            printTable(limits, now: now)
            print("")
            print("menu rows:")
            for limit in limits {
                print("  ● \(MenuText.infoRow(for: limit, now: now))")
            }
            print("")
            print("title: \(TitleFormatter.plainTitle(for: limits, stale: false))")
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
            print("")
            print("OK")
            return 0
        }
    }

    private static func endpointDescription() -> String {
        UsageFetcher.endpoint.absoluteString
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
