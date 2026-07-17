import Foundation
import UserNotifications
import LimitMonitorCore

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let bundled = Bundle.main.bundlePath.hasSuffix(".app")
    private var warnedUnbundled = false

    private func ensureBundled() -> Bool {
        if bundled { return true }
        if !warnedUnbundled {
            FileHandle.standardError.write(Data(
                "limit-monitor: not inside a .app bundle — notifications disabled (dev mode)\n".utf8
            ))
            warnedUnbundled = true
        }
        return false
    }

    func requestAuthorizationAtStartup() {
        guard ensureBundled() else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// removalScope: providers whose desired set is known this session — only
    /// their stale requests may be removed. A provider that has not yet polled
    /// successfully keeps its previous-session schedule (it must fire on time
    /// even if that provider stays offline through the reset moment).
    /// knownProviders: the COMPLETE set of configured runtime ids — pending
    /// requests of a provider removed/renamed/disabled in providers.json belong
    /// to no runtime, so they are purged outright (otherwise a deleted entry's
    /// reset notification could fire weeks later).
    /// disabled: settings checkboxes (v0.5) — a disabled provider's pending
    /// requests are removable immediately, desired set or not.
    func reconcileScheduled(
        _ desired: [PlannedReset],
        removalScope: Set<String>,
        knownProviders: Set<String>,
        disabled: Set<String> = []
    ) {
        guard ensureBundled() else { return }
        let desiredById = Dictionary(desired.map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            let existing = Set(pending.map(\.identifier).filter { $0.hasPrefix("reset|") })
            let stale = NotificationReconciler.removableResetIdentifiers(
                pending: pending.map(\.identifier),
                desired: Set(desiredById.keys),
                removalScope: removalScope,
                knownProviders: knownProviders,
                disabled: disabled
            )
            if !stale.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: stale)
            }
            for (identifier, item) in desiredById where !existing.contains(identifier) {
                let content = UNMutableNotificationContent()
                content.title = item.title
                content.body = item.body
                content.sound = .default
                var utcCalendar = Calendar(identifier: .gregorian)
                utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
                var components = utcCalendar.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second],
                    from: item.fireDate
                )
                components.timeZone = utcCalendar.timeZone
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
            }
        }
    }

    func removeAllScheduledResets() {
        guard ensureBundled() else { return }
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            let identifiers = pending.map(\.identifier).filter { $0.hasPrefix("reset|") }
            if !identifiers.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: identifiers)
            }
        }
    }

    func deliverImmediate(_ item: PlannedExhaustion) {
        guard ensureBundled() else { return }
        let content = UNMutableNotificationContent()
        content.title = item.title
        content.body = item.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: item.identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
