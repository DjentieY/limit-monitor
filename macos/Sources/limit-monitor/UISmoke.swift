import AppKit
import LimitMonitorCore

// Hidden dev flag --ui-smoke (not documented in README): headlessly construct
// the settings window content view AND the desktop card content view — no
// window is ordered front, no run loop is started. The agent-verifiable
// no-crash check for the v0.5 UI code paths.
enum UISmoke {
    static func run() -> Int32 {
        _ = NSApplication.shared

        let model = SettingsWindowController.Model(
            providers: [
                .init(id: Provider.claude, title: "Claude", checked: true, enabled: true, tooltip: nil),
                .init(id: Provider.codex, title: "Codex", checked: true, enabled: true, tooltip: nil),
                .init(id: Provider.cursor, title: "Cursor", checked: false, enabled: true, tooltip: nil),
                .init(id: "deepseek", title: "DeepSeek", checked: true, enabled: true, tooltip: nil),
                .init(id: nil, title: "Kimi", checked: false, enabled: false,
                      tooltip: "выключен в providers.json"),
            ],
            configPath: ProvidersConfigFile.path(),
            configExists: FileManager.default.fileExists(atPath: ProvidersConfigFile.path()),
            notifyOn: true,
            loginOn: false,
            loginAvailable: false,
            desktopCardOn: true
        )
        let controller = SettingsWindowController(
            modelProvider: { model }, handlers: SettingsWindowController.Handlers()
        )
        let settingsView = controller.makeContentView()
        settingsView.layoutSubtreeIfNeeded()
        guard settingsView.frame.height > 0 else {
            print("ui-smoke FAILED: settings view has zero height")
            return 1
        }

        let now = Date()
        let session = LimitEntry(
            kind: "session", percent: 9,
            resetsAt: now.addingTimeInterval(3600), isActive: true
        )
        let weekly = LimitEntry(
            kind: "weekly_all", percent: 52,
            resetsAt: now.addingTimeInterval(2 * 86400), isActive: true
        )
        let balance = LimitEntry(
            provider: "deepseek", kind: "custom", percent: 0,
            providerName: "DeepSeek", windowLabel: "", balanceText: "$23.45",
            levelOverride: .green, exhaustedOverride: false
        )
        let unlimited = LimitEntry(
            provider: Provider.cursor, kind: "cursor_unlimited", percent: 0, unlimited: true
        )
        let cardView = DesktopCard.makeContentView(providers: [
            .init(name: "Claude", stale: false, limits: [session, weekly]),
            .init(name: "Cursor", stale: false, limits: [unlimited]),
            .init(name: "DeepSeek", stale: true, limits: [balance]),
        ], now: now)
        cardView.layoutSubtreeIfNeeded()
        guard cardView.frame.height > 0 else {
            print("ui-smoke FAILED: desktop card view has zero height")
            return 1
        }
        _ = DesktopCard.makeContentView(providers: [], now: now)

        print("ui-smoke OK")
        return 0
    }
}
