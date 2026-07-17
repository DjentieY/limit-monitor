import Foundation

/// Outcome of parsing one config-provider response. Pure data — no networking.
public enum AdapterResult: Equatable {
    case entries([LimitEntry])
    /// openrouter only: /key has no per-key limit → the caller must fetch /credits.
    case needsCredits
    case state(ProviderState)
}

/// Builds LimitEntry values for config providers (provider = config id,
/// providerName = config display name, no scope segment).
public enum ConfigEntryFactory {
    public static func percentEntry(
        provider: ConfiguredProvider,
        percent: Int,
        kind: String = "custom",
        windowMinutes: Int? = nil,
        windowLabel: String? = nil,
        resetsAt: Date? = nil,
        menuOnly: Bool = false,
        okFlag: Bool? = nil
    ) -> LimitEntry {
        // Config providers have no window label unless one is derivable: an
        // explicit label wins, windowMinutes feed the shared 5h/7d rules, and
        // everything else renders label-less (`●37%`), never the raw kind.
        let resolvedWindowLabel = windowLabel ?? (windowMinutes == nil ? "" : nil)
        var entry = LimitEntry(
            provider: provider.id,
            kind: kind,
            percent: percent,
            resetsAt: resetsAt,
            windowMinutes: windowMinutes,
            isActive: true,
            providerName: provider.name,
            windowLabel: resolvedWindowLabel,
            menuOnly: menuOnly
        )
        if okFlag == false {
            entry.levelOverride = .red
            entry.exhaustedOverride = true
        }
        return entry
    }

    public static func balanceEntry(
        provider: ConfiguredProvider,
        remaining: Decimal,
        currency: String,
        okFlag: Bool? = nil
    ) -> LimitEntry {
        let (level, exhausted) = BalanceLevels.evaluate(
            remaining: remaining,
            thresholds: provider.thresholds,
            okFlag: okFlag
        )
        return LimitEntry(
            provider: provider.id,
            kind: "custom",
            percent: 0,
            isActive: true,
            providerName: provider.name,
            windowLabel: "",
            balanceText: BalanceFormat.text(remaining, currency: currency),
            levelOverride: level,
            exhaustedOverride: exhausted
        )
    }
}

private func jsonObject(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func authFailure(_ httpStatus: Int) -> Bool {
    httpStatus == 401 || httpStatus == 403
}

private func httpSuccess(_ httpStatus: Int) -> Bool {
    (200..<300).contains(httpStatus)
}

// MARK: - OpenRouter (research/providers.md §1)

public enum OpenRouterAdapter {
    /// RU geo-block body, same on every endpoint. NOT a bad key.
    static func isBlockedBody(_ root: [String: Any]) -> Bool {
        guard JSONPath.bool(root["success"]) == false,
              let error = root["error"] as? String else { return false }
        return error.lowercased().contains("access denied")
    }

    /// GET /api/v1/key. `data.limit` set → ONE percent entry with a window label
    /// from `limit_reset`; `limit` null → the caller falls back to /credits.
    /// All numeric fields are nullable. NEVER print `data.label` (echoes the key).
    public static func parseKey(data: Data, httpStatus: Int, provider: ConfiguredProvider) -> AdapterResult {
        let root = jsonObject(data)
        if let root, isBlockedBody(root) { return .state(.blocked) }
        if authFailure(httpStatus) {
            // research §1 risk (2): a 401/403 whose body is not JSON is a
            // Cloudflare HTML challenge (transient WAF noise) — a real
            // OpenRouter bad key answers with a JSON error envelope. Map to a
            // fetch error (v0.2 grace applies), not to badCredentials.
            guard root != nil else { return .state(.fetchError("HTTP \(httpStatus) (не-JSON ответ)")) }
            return .state(.badKey("ключ отклонён"))
        }
        guard httpSuccess(httpStatus) else { return .state(.fetchError("HTTP \(httpStatus)")) }
        guard let payload = root?["data"] as? [String: Any] else {
            return .state(.parseError("нет data в ответе /key"))
        }
        guard let limit = JSONPath.decimal(payload["limit"]), limit > 0,
              let remaining = JSONPath.decimal(payload["limit_remaining"]) else {
            return .needsCredits
        }
        let percent = JSONPath.roundedInt((limit - remaining) / limit * 100)
        let windowLabel: String
        switch payload["limit_reset"] as? String {
        case "daily": windowLabel = "1d"
        case "weekly": windowLabel = "7d"
        case "monthly": windowLabel = "1m"
        default: windowLabel = ""
        }
        // No reset instant is available from /key → no reset notification (resetsAt nil).
        return .entries([ConfigEntryFactory.percentEntry(
            provider: provider,
            percent: percent,
            windowLabel: windowLabel
        )])
    }

    /// GET /api/v1/credits. Balance = total_credits - total_usage (Decimal),
    /// preferring the optional `data.remaining_balance`. 401/403 → info state,
    /// not a failure (the key simply cannot see credits).
    public static func parseCredits(data: Data, httpStatus: Int, provider: ConfiguredProvider) -> AdapterResult {
        let root = jsonObject(data)
        if let root, isBlockedBody(root) { return .state(.blocked) }
        if authFailure(httpStatus) { return .state(.info("баланс недоступен этому ключу")) }
        guard httpSuccess(httpStatus) else { return .state(.fetchError("HTTP \(httpStatus)")) }
        guard let payload = root?["data"] as? [String: Any] else {
            return .state(.parseError("нет data в ответе /credits"))
        }
        let balance: Decimal
        if let remaining = JSONPath.decimal(payload["remaining_balance"]) {
            balance = remaining
        } else if let credits = JSONPath.decimal(payload["total_credits"]),
                  let usage = JSONPath.decimal(payload["total_usage"]) {
            balance = credits - usage
        } else {
            return .state(.parseError("нет total_credits/total_usage"))
        }
        return .entries([ConfigEntryFactory.balanceEntry(
            provider: provider,
            remaining: balance,
            currency: "USD"
        )])
    }
}

// MARK: - DeepSeek (§2: amounts are decimal STRINGS; prefer the USD entry)

public enum DeepSeekAdapter {
    public static func parse(data: Data, httpStatus: Int, provider: ConfiguredProvider) -> AdapterResult {
        if authFailure(httpStatus) { return .state(.badKey("ключ отклонён")) }
        guard httpSuccess(httpStatus) else { return .state(.fetchError("HTTP \(httpStatus)")) }
        guard let root = jsonObject(data) else { return .state(.parseError("не JSON")) }
        let infos = (root["balance_infos"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        let chosen = infos.first { ($0["currency"] as? String)?.uppercased() == "USD" } ?? infos.first
        guard let info = chosen, let amount = JSONPath.decimal(info["total_balance"]) else {
            return .state(.parseError("нет balance_infos.total_balance"))
        }
        return .entries([ConfigEntryFactory.balanceEntry(
            provider: provider,
            remaining: amount,
            currency: (info["currency"] as? String) ?? "USD",
            okFlag: JSONPath.bool(root["is_available"])
        )])
    }
}

// MARK: - Moonshot Kimi (§3: envelope; currency by host; regional keys)

public enum MoonshotAdapter {
    public static func parse(data: Data, httpStatus: Int, provider: ConfiguredProvider) -> AdapterResult {
        let root = jsonObject(data)
        if let error = root?["error"] as? [String: Any] {
            if error["type"] as? String == "invalid_authentication_error" {
                return .state(.badKey("ключ отклонён (нужен platform-ключ этого региона)"))
            }
            return .state(.parseError((error["type"] as? String) ?? "ошибка API"))
        }
        if authFailure(httpStatus) { return .state(.badKey("ключ отклонён")) }
        guard httpSuccess(httpStatus) else { return .state(.fetchError("HTTP \(httpStatus)")) }
        guard let payload = root?["data"] as? [String: Any],
              let amount = JSONPath.decimal(payload["available_balance"]) else {
            return .state(.parseError("нет data.available_balance"))
        }
        return .entries([ConfigEntryFactory.balanceEntry(
            provider: provider,
            remaining: amount,
            currency: provider.host == .cn ? "CNY" : "USD"
        )])
    }
}

// MARK: - Zhipu GLM (§4: errors arrive as HTTP 200; percentage is percent USED)

public enum ZhipuAdapter {
    public static func parse(data: Data, httpStatus: Int, provider: ConfiguredProvider) -> AdapterResult {
        let root = jsonObject(data)
        // Error envelope first — zhipu errors come with HTTP 200.
        if let root, JSONPath.bool(root["success"]) == false {
            let code = JSONPath.int(root["code"])
            if code == 1001 { return .state(.badKey("ключ отклонён")) }
            if code == 500, ((root["msg"] as? String) ?? "").lowercased().contains("coding plan") {
                return .state(.noPlan)
            }
            return .state(.parseError("code \(code.map(String.init) ?? "—")"))
        }
        if authFailure(httpStatus) { return .state(.badKey("ключ отклонён")) }
        guard httpSuccess(httpStatus) else { return .state(.fetchError("HTTP \(httpStatus)")) }
        guard let payload = root?["data"] as? [String: Any],
              let rawLimits = payload["limits"] as? [Any] else {
            return .state(.parseError("нет data.limits"))
        }
        var entries: [LimitEntry] = []
        for rawItem in rawLimits {
            guard let item = rawItem as? [String: Any] else { continue }
            // Old revisions use `name` instead of `type`.
            let type = (item["type"] as? String) ?? (item["name"] as? String)
            // TRAP (§4): `usage` = LIMIT and `currentValue` = used — only
            // `percentage` (percent USED) is consumed.
            guard let percentage = JSONPath.decimal(item["percentage"]) else { continue }
            let percent = JSONPath.roundedInt(percentage)
            let unit = JSONPath.int(item["unit"])
            let number = JSONPath.int(item["number"])
            let minutes = windowMinutes(unit: unit, number: number)
            let resetsAt = JSONPath.decimal(item["nextResetTime"]).map {
                Date(timeIntervalSince1970: NSDecimalNumber(decimal: $0).doubleValue / 1000)
            }
            switch type {
            case "TOKENS_LIMIT":
                var monthLabel: String?
                if unit == 5, let number { monthLabel = "\(number)m" }
                entries.append(ConfigEntryFactory.percentEntry(
                    provider: provider,
                    percent: percent,
                    kind: minutes.map { "window_\($0)m" } ?? "custom",
                    windowMinutes: minutes,
                    windowLabel: monthLabel,
                    resetsAt: resetsAt
                ))
            case "TIME_LIMIT":
                // Поиск/MCP counter: menu-only, excluded from the bar.
                entries.append(ConfigEntryFactory.percentEntry(
                    provider: provider,
                    percent: percent,
                    kind: "time_limit",
                    windowMinutes: minutes,
                    windowLabel: "",
                    resetsAt: resetsAt,
                    menuOnly: true
                ))
            default:
                continue
            }
        }
        return .entries(entries)
    }

    private static func windowMinutes(unit: Int?, number: Int?) -> Int? {
        guard let unit, let number else { return nil }
        switch unit {
        case 3: return number * 60
        case 4: return number * 1440
        case 5: return number * 43200
        case 6: return number * 10080
        default: return nil
        }
    }
}

// MARK: - Generic engine (generic-http + expanded siliconflow/novita presets)

public enum GenericAdapter {
    public static func parse(data: Data, httpStatus: Int, provider: ConfiguredProvider) -> AdapterResult {
        if authFailure(httpStatus) { return .state(.badKey("ключ отклонён")) }
        guard httpSuccess(httpStatus) else { return .state(.fetchError("HTTP \(httpStatus)")) }
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            return .state(.parseError("не JSON"))
        }
        guard let extract = provider.extract else {
            return .state(.configError("extract не задан"))
        }
        let okFlag = extract.okFlagPath.flatMap { JSONPath.bool(at: $0, in: root) }
        let currency = provider.display?.currency ?? "USD"

        // Display-mode resolution: percentUsed → percent-mode; balance+limit
        // (limit > 0) → percent-mode on used share; balance alone → balance-mode.
        if let percentPath = extract.percentUsedPath {
            guard let used = JSONPath.decimal(at: percentPath, in: root) else {
                return .state(.parseError("нет поля \(percentPath)"))
            }
            return .entries([ConfigEntryFactory.percentEntry(
                provider: provider,
                percent: JSONPath.roundedInt(used),
                okFlag: okFlag
            )])
        }
        guard let balanceSpec = extract.balance else {
            return .state(.configError("extract: нужен balance или percentUsed"))
        }
        guard let balance = balanceSpec.resolve(in: root) else {
            return .state(.parseError("нет поля \(balanceSpec.path)"))
        }
        if let limitSpec = extract.limit, let limit = limitSpec.resolve(in: root), limit > 0 {
            let percent = JSONPath.roundedInt((limit - balance) / limit * 100)
            return .entries([ConfigEntryFactory.percentEntry(
                provider: provider,
                percent: percent,
                okFlag: okFlag
            )])
        }
        return .entries([ConfigEntryFactory.balanceEntry(
            provider: provider,
            remaining: balance,
            currency: currency,
            okFlag: okFlag
        )])
    }
}
