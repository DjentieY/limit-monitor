import Foundation

/// Unified per-provider state for config providers (v0.4). `ok` carries no
/// message; every other case maps to a RU menu/`--check` line via
/// `MenuText.stateRow(name:state:)`.
public enum ProviderState: Equatable {
    case ok
    /// Entry-level config validation failed (unknown kind, bad id, key shape...).
    case configError(String)
    /// Key resolution failed (command exited non-zero, env unset, empty value).
    case keyError(String)
    /// The endpoint rejected the key (HTTP 401/403 or an auth error envelope).
    case badKey(String)
    /// Zhipu code 500 + "coding plan": the key works but has no Coding Plan.
    case noPlan
    /// OpenRouter RU geo-block: `{"success":false,"error":"Access denied by security policy."}`.
    case blocked
    /// Informational, NOT a failure (OpenRouter /credits denied to this key).
    case info(String)
    case fetchError(String)
    case parseError(String)

    /// v0.4 `--check` exit contract: config-error, key-resolution failure,
    /// bad-key, no-plan, blocked and fetch/parse failures of an ENABLED provider
    /// fail the run; `ok` and the OpenRouter credits-denied info state do not.
    public var isCheckFailure: Bool {
        switch self {
        case .ok, .info: return false
        default: return true
        }
    }
}

/// Balance-mode levels over the REMAINING amount: > warn → green, <= warn →
/// orange, <= critical → red, <= 0 → red AND exhausted; `okFlag == false` →
/// red AND exhausted regardless of the amount.
public enum BalanceLevels {
    public static func evaluate(
        remaining: Decimal,
        thresholds: ProviderThresholds,
        okFlag: Bool?
    ) -> (level: Level, exhausted: Bool) {
        if okFlag == false { return (.red, true) }
        if remaining <= 0 { return (.red, true) }
        if remaining <= thresholds.critical { return (.red, false) }
        if remaining <= thresholds.warn { return (.orange, false) }
        return (.green, false)
    }
}
