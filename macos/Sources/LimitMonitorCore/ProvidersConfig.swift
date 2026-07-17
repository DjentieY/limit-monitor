import Foundation

/// Key source descriptor. Core only models WHERE the key comes from; the actual
/// env lookup / `/bin/sh -c` execution lives in the shell layer. Values are never
/// stored here beyond the literal case and must never be logged or printed.
public enum KeySource: Equatable {
    case literal(String)
    case env(String)
    case command(String)

    /// For --check / menus: names the SOURCE, never the value.
    public var sourceDescription: String {
        switch self {
        case .literal: return "literal"
        case .env(let name): return "env \(name)"
        case .command: return "command"
        }
    }
}

public enum KeyResolutionStrings {
    // RU constants preserved for the shell's current callers (KeyResolver); the
    // localized accessor below is the seam the shell threads `lang` through.
    public static let commandFailed = "ключ: команда не выполнилась"
    public static let envUnset = "ключ: переменная окружения не задана"
    public static let empty = "ключ: пустое значение"

    public enum Reason { case commandFailed, envUnset, empty }

    public static func text(_ reason: Reason, _ lang: Language) -> String {
        switch (lang, reason) {
        case (.ru, .commandFailed): return commandFailed
        case (.en, .commandFailed): return "key: command failed"
        case (.ru, .envUnset):      return envUnset
        case (.en, .envUnset):      return "key: env var not set"
        case (.ru, .empty):         return empty
        case (.en, .empty):         return "key: empty value"
        }
    }
}

public enum ConfigProviderKind: String, Equatable {
    case openrouter
    case deepseek
    case moonshot
    case zhipu
    case siliconflow
    case novita
    case genericHTTP = "generic-http"
}

public enum ProviderHost: String, Equatable {
    case intl
    case cn
}

public struct ProviderThresholds: Equatable {
    public var warn: Decimal
    public var critical: Decimal

    public init(warn: Decimal = 5, critical: Decimal = 1) {
        self.warn = warn
        self.critical = critical
    }
}

public struct GenericRequest: Equatable {
    public var url: String
    public var headers: [String: String]
    public var timeoutSeconds: Double

    public init(url: String, headers: [String: String] = [:], timeoutSeconds: Double = 15) {
        self.url = url
        self.headers = headers
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct FieldSpec: Equatable {
    public var path: String
    public var scale: Decimal
    public var clampMin: Decimal?

    public init(path: String, scale: Decimal = 1, clampMin: Decimal? = nil) {
        self.path = path
        self.scale = scale
        self.clampMin = clampMin
    }

    public func resolve(in root: Any) -> Decimal? {
        guard let raw = JSONPath.decimal(at: path, in: root) else { return nil }
        var value = raw * scale
        if let clampMin, value < clampMin { value = clampMin }
        return value
    }
}

public struct GenericExtract: Equatable {
    public var balance: FieldSpec?
    public var limit: FieldSpec?
    public var percentUsedPath: String?
    public var okFlagPath: String?

    public init(
        balance: FieldSpec? = nil,
        limit: FieldSpec? = nil,
        percentUsedPath: String? = nil,
        okFlagPath: String? = nil
    ) {
        self.balance = balance
        self.limit = limit
        self.percentUsedPath = percentUsedPath
        self.okFlagPath = okFlagPath
    }
}

public struct GenericDisplay: Equatable {
    public var currency: String

    public init(currency: String = "USD") {
        self.currency = currency
    }
}

public struct ConfiguredProvider: Equatable {
    public var id: String
    public var name: String
    public var label: String
    public var kind: ConfigProviderKind
    public var host: ProviderHost
    public var key: KeySource
    public var pollSeconds: Int
    public var thresholds: ProviderThresholds
    public var request: GenericRequest?
    public var extract: GenericExtract?
    public var display: GenericDisplay?

    public init(
        id: String,
        name: String,
        label: String,
        kind: ConfigProviderKind,
        host: ProviderHost = .intl,
        key: KeySource,
        pollSeconds: Int = 300,
        thresholds: ProviderThresholds = ProviderThresholds(),
        request: GenericRequest? = nil,
        extract: GenericExtract? = nil,
        display: GenericDisplay? = nil
    ) {
        self.id = id
        self.name = name
        self.label = label
        self.kind = kind
        self.host = host
        self.key = key
        self.pollSeconds = pollSeconds
        self.thresholds = thresholds
        self.request = request
        self.extract = extract
        self.display = display
    }

    /// Bar group prefix for multi-provider titles (v0.2 rule): `OR·`, `GLM·`.
    public var titlePrefix: String { label + "·" }

    /// Presets and generic-http are parsed by the generic engine.
    public var usesGenericAdapter: Bool {
        kind == .genericHTTP || kind == .siliconflow || kind == .novita
    }
}

public struct ConfigEntryError: Equatable {
    public var id: String?
    public var name: String
    /// Keyed reason (SPEC v0.7) so the whole config-error row renders in the
    /// resolved language — no more mixed EN frame + RU reason.
    public var reason: ConfigReason

    public init(id: String?, name: String, reason: ConfigReason) {
        self.id = id
        self.name = name
        self.reason = reason
    }

    /// Localized disabled menu / `--check` row:
    /// `<name>: config error — <reason>` / `<name>: ошибка конфига — <reason>`.
    public func menuRow(_ lang: Language) -> String {
        ConfigStr.entryError(name: name, reason: reason.text(lang)).text(lang)
    }
}

/// An `enabled: false` entry: skipped by the runtime entirely, but the
/// settings window (v0.5) still lists it — unchecked and non-toggleable,
/// with the «выключен в providers.json» tooltip.
public struct ConfigDisabledEntry: Equatable {
    public var id: String?
    public var name: String

    public init(id: String?, name: String) {
        self.id = id
        self.name = name
    }
}

public struct ProvidersConfig: Equatable {
    public var defaultPollSeconds: Int
    public var providers: [ConfiguredProvider]
    public var errors: [ConfigEntryError]
    /// `enabled: false` entries in file order (settings window rows, v0.5).
    public var disabledEntries: [ConfigDisabledEntry]

    public init(
        defaultPollSeconds: Int,
        providers: [ConfiguredProvider],
        errors: [ConfigEntryError],
        disabledEntries: [ConfigDisabledEntry] = []
    ) {
        self.defaultPollSeconds = defaultPollSeconds
        self.providers = providers
        self.errors = errors
        self.disabledEntries = disabledEntries
    }
}

/// File location + shared UI strings for the config feature.
public enum ProvidersConfigFile {
    public static let envOverride = "LIMIT_MONITOR_PROVIDERS"

    public static func path(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> String {
        if let override = environment[envOverride], !override.isEmpty { return override }
        return home + "/.config/limit-monitor/providers.json"
    }

    // RU aliases routed through ConfigStr (single source of truth). The shell
    // migrates to `ConfigStr.<case>.text(lang)` when it threads `lang` (Stage 3).
    public static let missingCheckLine = ConfigStr.missingCheck.text(.ru)
    public static let malformedMenuRow = ConfigStr.malformed.text(.ru)
    public static let unsupportedVersionMenuRow = ConfigStr.unsupportedVersion.text(.ru)
    public static let permissiveMenuRow = ConfigStr.permissive.text(.ru)

    /// Group/other-readable config may leak literal keys.
    public static func isPermissive(posixPermissions: Int) -> Bool {
        posixPermissions & 0o077 != 0
    }
}

public enum ProvidersConfigParser {
    public enum ParseResult: Equatable {
        case malformed
        case unsupportedVersion
        case parsed(ProvidersConfig)
    }

    private static let idAlphabet = Set("abcdefghijklmnopqrstuvwxyz0123456789-")

    public static func parse(data: Data) -> ParseResult {
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let root = any as? [String: Any] else { return .malformed }
        guard JSONPath.int(root["version"]) == 1 else { return .unsupportedVersion }

        let defaults = root["defaults"] as? [String: Any]
        let defaultPoll = JSONPath.int(defaults?["pollSeconds"]) ?? 300

        var providers: [ConfiguredProvider] = []
        var errors: [ConfigEntryError] = []
        var disabledEntries: [ConfigDisabledEntry] = []
        var seenIDs = Set<String>()

        for rawEntry in (root["providers"] as? [Any]) ?? [] {
            guard let entry = rawEntry as? [String: Any] else {
                errors.append(ConfigEntryError(id: nil, name: "?", reason: .notObject))
                continue
            }
            if JSONPath.bool(entry["enabled"]) == false {
                let id = entry["id"] as? String
                disabledEntries.append(ConfigDisabledEntry(
                    id: id, name: (entry["name"] as? String) ?? id ?? "?"
                ))
                continue
            }

            let idRaw = entry["id"] as? String
            let name = (entry["name"] as? String) ?? idRaw ?? "?"
            func fail(_ reason: ConfigReason) {
                errors.append(ConfigEntryError(id: idRaw, name: name, reason: reason))
            }

            guard let id = idRaw, isValidID(id) else {
                fail(.invalidID)
                continue
            }
            guard !Provider.isBuiltin(id) else {
                fail(.reservedID)
                continue
            }
            guard !seenIDs.contains(id) else {
                fail(.duplicateID)
                continue
            }
            guard let kindRaw = entry["kind"] as? String, let kind = ConfigProviderKind(rawValue: kindRaw) else {
                fail(.unknownKind((entry["kind"] as? String) ?? "—"))
                continue
            }
            guard let key = parseKey(entry["key"]) else {
                fail(.keyNeedsExactlyOne)
                continue
            }
            let host: ProviderHost
            if let hostRaw = entry["host"] as? String {
                guard let parsed = ProviderHost(rawValue: hostRaw) else {
                    fail(.invalidHost)
                    continue
                }
                host = parsed
            } else {
                host = .intl
            }

            let pollSeconds = max(60, JSONPath.int(entry["pollSeconds"]) ?? defaultPoll)
            let thresholds = parseThresholds(entry["thresholds"])
            let labelRaw = (entry["label"] as? String)?.trimmingCharacters(in: .whitespaces)
            let label = (labelRaw?.isEmpty == false ? String(labelRaw?.prefix(8) ?? "") : String(name.prefix(2)))

            var provider = ConfiguredProvider(
                id: id, name: name, label: label, kind: kind, host: host, key: key,
                pollSeconds: pollSeconds, thresholds: thresholds,
                request: parseRequest(entry["request"]),
                extract: parseExtract(entry["extract"]),
                display: parseDisplay(entry["display"])
            )

            if kind == .genericHTTP {
                guard let request = provider.request, !request.url.isEmpty else {
                    fail(.requestURLMissing)
                    continue
                }
                if let method = (entry["request"] as? [String: Any])?["method"] as? String,
                   method.uppercased() != "GET" {
                    fail(.requestMethodGETOnly)
                    continue
                }
                guard let extract = provider.extract,
                      extract.balance != nil || extract.percentUsedPath != nil else {
                    fail(.extractNeedsBalanceOrPercent)
                    continue
                }
            }
            expandPreset(&provider)

            seenIDs.insert(id)
            providers.append(provider)
        }

        return .parsed(ProvidersConfig(
            defaultPollSeconds: max(60, defaultPoll),
            providers: providers,
            errors: errors,
            disabledEntries: disabledEntries
        ))
    }

    private static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { idAlphabet.contains($0) }
    }

    private static func parseKey(_ any: Any?) -> KeySource? {
        guard let dict = any as? [String: Any] else { return nil }
        var sources: [KeySource] = []
        if let value = dict["literal"] as? String { sources.append(.literal(value)) }
        if let value = dict["env"] as? String { sources.append(.env(value)) }
        if let value = dict["command"] as? String { sources.append(.command(value)) }
        guard sources.count == 1 else { return nil }
        return sources[0]
    }

    private static func parseThresholds(_ any: Any?) -> ProviderThresholds {
        let dict = any as? [String: Any]
        return ProviderThresholds(
            warn: JSONPath.decimal(dict?["warn"]) ?? 5,
            critical: JSONPath.decimal(dict?["critical"]) ?? 1
        )
    }

    private static func parseRequest(_ any: Any?) -> GenericRequest? {
        guard let dict = any as? [String: Any], let url = dict["url"] as? String else { return nil }
        let headers = (dict["headers"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
        let timeout = (JSONPath.decimal(dict["timeoutSeconds"])).map { NSDecimalNumber(decimal: $0).doubleValue } ?? 15
        return GenericRequest(url: url, headers: headers, timeoutSeconds: timeout)
    }

    private static func parseExtract(_ any: Any?) -> GenericExtract? {
        guard let dict = any as? [String: Any] else { return nil }
        return GenericExtract(
            balance: parseFieldSpec(dict["balance"]),
            limit: parseFieldSpec(dict["limit"]),
            percentUsedPath: parsePath(dict["percentUsed"]),
            okFlagPath: parsePath(dict["okFlag"])
        )
    }

    private static func parseFieldSpec(_ any: Any?) -> FieldSpec? {
        guard let dict = any as? [String: Any], let path = dict["path"] as? String, !path.isEmpty else {
            return nil
        }
        return FieldSpec(
            path: path,
            scale: JSONPath.decimal(dict["scale"]) ?? 1,
            clampMin: JSONPath.decimal(dict["clampMin"])
        )
    }

    private static func parseDisplay(_ any: Any?) -> GenericDisplay? {
        guard let dict = any as? [String: Any] else { return nil }
        return GenericDisplay(currency: (dict["currency"] as? String) ?? "USD")
    }

    private static func parsePath(_ any: Any?) -> String? {
        if let string = any as? String { return string.isEmpty ? nil : string }
        guard let dict = any as? [String: Any], let path = dict["path"] as? String, !path.isEmpty else {
            return nil
        }
        return path
    }

    /// siliconflow / novita ship as internally expanded generic configs — the user
    /// supplies only key/host/thresholds.
    private static func expandPreset(_ provider: inout ConfiguredProvider) {
        switch provider.kind {
        case .siliconflow:
            let base = provider.host == .cn ? "https://api.siliconflow.cn" : "https://api.siliconflow.com"
            provider.request = GenericRequest(
                url: base + "/v1/user/info",
                headers: ["Authorization": "Bearer ${KEY}"],
                timeoutSeconds: provider.request?.timeoutSeconds ?? 15
            )
            provider.extract = GenericExtract(balance: FieldSpec(path: "data.totalBalance"))
            provider.display = GenericDisplay(currency: provider.host == .cn ? "CNY" : "USD")
        case .novita:
            provider.request = GenericRequest(
                url: "https://api.novita.ai/openapi/v1/billing/balance/detail",
                headers: ["Authorization": "Bearer ${KEY}", "Content-Type": "application/json"],
                timeoutSeconds: provider.request?.timeoutSeconds ?? 15
            )
            provider.extract = GenericExtract(balance: FieldSpec(
                path: "availableBalance",
                scale: Decimal(sign: .plus, exponent: -4, significand: 1)
            ))
            provider.display = GenericDisplay(currency: "USD")
        default:
            break
        }
    }
}
