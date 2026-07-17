import Foundation

/// SPEC v0.5 settings checkboxes: the persisted disable list
/// (the shell's `disabledProviders` defaults key, built-ins by id, custom by
/// config id). Core owns the pure model — filtering and toggle effects;
/// persistence and the window itself live in the shell.
public enum ProviderFilter {
    /// Groups without the disabled providers — feeds title segments, the menu
    /// model and the snapshot builder.
    public static func groups(_ groups: [ProviderGroup], disabled: Set<String>) -> [ProviderGroup] {
        disabled.isEmpty ? groups : groups.filter { !disabled.contains($0.provider) }
    }

    /// Limits without the disabled providers — feeds the notification desired-set.
    public static func limits(_ limits: [LimitEntry], disabled: Set<String>) -> [LimitEntry] {
        disabled.isEmpty ? limits : limits.filter { !disabled.contains($0.provider) }
    }
}

/// Effect of flipping a provider checkbox (check 34).
public struct ProviderToggleOutcome: Equatable {
    /// The new persisted `disabledProviders` set.
    public let disabled: Set<String>
    /// Providers to poll immediately — re-enabling refreshes exactly that one.
    public let immediatePoll: [String]
    /// Disabling requires an explicit reconcile right away: pending
    /// `reset|<id>|*` requests must go without waiting for a successful poll.
    public let reconcileNow: Bool

    public init(disabled: Set<String>, immediatePoll: [String], reconcileNow: Bool) {
        self.disabled = disabled
        self.immediatePoll = immediatePoll
        self.reconcileNow = reconcileNow
    }
}

public enum ProviderSettings {
    public static let disabledDefaultsKey = "disabledProviders"

    public static func setEnabled(
        _ enabled: Bool,
        provider: String,
        disabled: Set<String>
    ) -> ProviderToggleOutcome {
        var set = disabled
        if enabled {
            let wasDisabled = set.remove(provider) != nil
            return ProviderToggleOutcome(
                disabled: set,
                immediatePoll: wasDisabled ? [provider] : [],
                reconcileNow: false
            )
        }
        let changed = set.insert(provider).inserted
        return ProviderToggleOutcome(disabled: set, immediatePoll: [], reconcileNow: changed)
    }
}

/// Pure reconcile plan over pending notification identifiers, shared by the
/// shell Notifier and `checks`.
public enum NotificationReconciler {
    /// Pending `reset|`-prefixed identifiers that must be removed:
    /// - any identifier of a DISABLED provider (v0.5 — removable immediately,
    ///   even while that provider has no fresh desired set);
    /// - otherwise the v0.2/v0.4 rules: not in the desired set AND its provider
    ///   either reported this session (`removalScope`) or belongs to no
    ///   configured runtime at all (`knownProviders`).
    public static func removableResetIdentifiers(
        pending: [String],
        desired: Set<String>,
        removalScope: Set<String>,
        knownProviders: Set<String>,
        disabled: Set<String> = []
    ) -> [String] {
        pending.filter { identifier in
            guard identifier.hasPrefix("reset|") else { return false }
            let provider = NotificationPlanner.identifierProvider(identifier)
            if disabled.contains(provider) { return true }
            guard !desired.contains(identifier) else { return false }
            return removalScope.contains(provider) || !knownProviders.contains(provider)
        }
    }
}
