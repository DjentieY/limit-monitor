import Foundation

// Code catalog (SPEC v0.6): each user-facing string has an EN and a RU
// production selected by an exhaustive `switch (lang, self)` — "every key has EN
// AND RU" is a compile-time guarantee. No `.strings`/`.lproj`, no `Bundle.module`
// (fragile for a CLT-only, ad-hoc-signed SPM build), no `Localizable` protocol
// (never used polymorphically). Heavily-branched composites (`Labels.*`,
// `TimeFormat.*`) stay functions taking `lang` and pull leaf fragments from here.
//
// EN is the default arm; RU arms preserve the EXACT existing wording. Neutral
// tokens (level names, `N%`, `$23.45`, `∞`, window labels, bar prefixes, the
// `Limit Monitor` brand) are NOT localized and never appear here.

/// Menu info-row value lines (`MenuText.infoRow`).
public enum MenuStr {
    case unlimited(label: String)
    case balanceRemaining(label: String, balance: String)
    case balanceExhausted(label: String)
    case percentWithReset(label: String, percent: Int, reset: String)
    case percentBare(label: String, percent: Int)
    case exhaustedWithReset(label: String, reset: String)
    case exhaustedBare(label: String)

    public func text(_ lang: Language) -> String {
        switch (lang, self) {
        case let (.en, .unlimited(l)):              return "\(l): unlimited"
        case let (.ru, .unlimited(l)):              return "\(l): безлимит"
        case let (.en, .balanceRemaining(l, b)):    return "\(l): \(b) left"
        case let (.ru, .balanceRemaining(l, b)):    return "\(l): осталось \(b)"
        case let (.en, .balanceExhausted(l)):       return "\(l): balance exhausted"
        case let (.ru, .balanceExhausted(l)):       return "\(l): баланс исчерпан"
        case let (.en, .percentWithReset(l, p, r)): return "\(l): \(p)% · resets \(r)"
        case let (.ru, .percentWithReset(l, p, r)): return "\(l): \(p)% · сброс \(r)"
        case let (.en, .percentBare(l, p)):         return "\(l): \(p)%"
        case let (.ru, .percentBare(l, p)):         return "\(l): \(p)%"
        case let (.en, .exhaustedWithReset(l, r)):  return "\(l): exhausted · resumes \(r)"
        case let (.ru, .exhaustedWithReset(l, r)):  return "\(l): исчерпан · возобновится \(r)"
        case let (.en, .exhaustedBare(l)):          return "\(l): exhausted"
        case let (.ru, .exhaustedBare(l)):          return "\(l): исчерпан"
        }
    }
}

/// Notification body fragments (`NotificationPlanner.plan`).
public enum NotifStr {
    case remaining(balance: String)
    case resumeAt(relative: String, absolute: String)
    case resumeUnknown

    public func text(_ lang: Language) -> String {
        switch (lang, self) {
        case let (.en, .remaining(b)):       return "\(b) left."
        case let (.ru, .remaining(b)):       return "Осталось \(b)."
        case let (.en, .resumeAt(rel, abs)): return "Resumes \(rel) (\(abs))."
        case let (.ru, .resumeAt(rel, abs)): return "Возобновится \(rel) (\(abs))."
        case (.en, .resumeUnknown):          return "Reset time unknown."
        case (.ru, .resumeUnknown):          return "Время возобновления неизвестно."
        }
    }
}

/// `--status` human-table chrome + row reset column + the missing-snapshot hint
/// (`StatusCommand`). Level words live in `StatusCommand.levelWord` (unknown
/// levels pass through, which an exhaustive enum can't model).
public enum StatusStr {
    case updatedPrefix
    case staleSuffix
    case noData
    case resets(reset: String)
    case exhaustedResumes(reset: String)
    case exhaustedBare
    case missingSnapshot

    public func text(_ lang: Language) -> String {
        switch (lang, self) {
        case (.en, .updatedPrefix):           return "Updated:"
        case (.ru, .updatedPrefix):           return "Обновлено:"
        case (.en, .staleSuffix):             return "(stale)"
        case (.ru, .staleSuffix):             return "(устарело)"
        case (.en, .noData):                  return "no data for any provider"
        case (.ru, .noData):                  return "нет данных ни по одному провайдеру"
        case let (.en, .resets(r)):           return "resets \(r)"
        case let (.ru, .resets(r)):           return "сброс \(r)"
        case let (.en, .exhaustedResumes(r)): return "exhausted · resumes \(r)"
        case let (.ru, .exhaustedResumes(r)): return "исчерпан · возобновится \(r)"
        case (.en, .exhaustedBare):           return "exhausted"
        case (.ru, .exhaustedBare):           return "исчерпан"
        case (.en, .missingSnapshot):
            return "snapshot unavailable — run Limit Monitor or limit-monitor --check"
        case (.ru, .missingSnapshot):
            return "снапшот недоступен — запусти Limit Monitor или limit-monitor --check"
        }
    }
}

/// Per-provider state rows surfaced in the menu / `--check`. The token-expired
/// and inactive atoms belong to the built-in providers (shell `App` pollers); the
/// name-prefixed cases render a config provider's `ProviderState`
/// (`MenuText.stateRow`) or a built-in error line. The inner `message` is already
/// produced in the process's language by the adapters.
public enum StateStr {
    case claudeTokenExpired
    case codexTokenExpired
    case cursorTokenExpired
    // Built-in inactive/error rows composed by the shell pollers (App.swift).
    case claudeNoCredentials
    case codexApiKeyMode
    case codexNoAccessToken
    case cursorInactive
    case cursorBadToken
    case builtinBadCredentials(name: String)
    case builtinApiError(name: String)
    case builtinNoNetwork(name: String)
    case configError(name: String, reason: String)
    case message(name: String, message: String)
    case noPlan(name: String)
    case blocked(name: String)
    case parseError(name: String, message: String)

    public func text(_ lang: Language) -> String {
        switch (lang, self) {
        case (.en, .claudeTokenExpired):    return "Token expired — open Claude Code"
        case (.ru, .claudeTokenExpired):    return "Токен истёк — открой Claude Code"
        case (.en, .codexTokenExpired):     return "Codex token expired — run codex"
        case (.ru, .codexTokenExpired):     return "Токен Codex истёк — запусти codex"
        case (.en, .cursorTokenExpired):    return "Cursor token expired — open Cursor"
        case (.ru, .cursorTokenExpired):    return "Токен Cursor истёк — открой Cursor"
        case (.en, .claudeNoCredentials):   return "Claude: no credentials — open Claude Code"
        case (.ru, .claudeNoCredentials):   return "Claude: нет учётных данных — открой Claude Code"
        case (.en, .codexApiKeyMode):       return "Codex: API-key mode — no plan limits"
        case (.ru, .codexApiKeyMode):       return "Codex: API-key режим — план-лимитов нет"
        case (.en, .codexNoAccessToken):    return "Codex: auth.json without tokens.access_token"
        case (.ru, .codexNoAccessToken):    return "Codex: auth.json без tokens.access_token"
        case (.en, .cursorInactive):        return "cursor: inactive (no Cursor)"
        case (.ru, .cursorInactive):        return "cursor: неактивен (нет Cursor)"
        case (.en, .cursorBadToken):        return "Cursor token not parsed — re-login to Cursor"
        case (.ru, .cursorBadToken):        return "Токен Cursor не разобран — перелогинься в Cursor"
        case let (.en, .builtinBadCredentials(n)): return "\(n): credentials not parsed"
        case let (.ru, .builtinBadCredentials(n)): return "\(n): учётные данные не разобраны"
        case let (.en, .builtinApiError(n)): return "\(n): API response error"
        case let (.ru, .builtinApiError(n)): return "\(n): ошибка ответа API"
        case let (.en, .builtinNoNetwork(n)): return "\(n): no network"
        case let (.ru, .builtinNoNetwork(n)): return "\(n): нет сети"
        case let (.en, .configError(n, r)): return "\(n): config error — \(r)"
        case let (.ru, .configError(n, r)): return "\(n): ошибка конфига — \(r)"
        case let (.en, .message(n, m)):     return "\(n): \(m)"
        case let (.ru, .message(n, m)):     return "\(n): \(m)"
        case let (.en, .noPlan(n)):         return "\(n): no Coding Plan (PAYG key)"
        case let (.ru, .noPlan(n)):         return "\(n): нет Coding Plan (PAYG-ключ)"
        case let (.en, .blocked(n)):        return "\(n) unavailable (geo-block)"
        case let (.ru, .blocked(n)):        return "\(n) недоступен (гео-блокировка)"
        case let (.en, .parseError(n, m)):  return "\(n): parse error — \(m)"
        case let (.ru, .parseError(n, m)):  return "\(n): ошибка разбора — \(m)"
        }
    }
}

/// providers.json diagnostics (`ProvidersConfig`). `entryError` mirrors a config
/// entry's `menuRow`; the parse `reason` inside it is now keyed via
/// `ConfigReason` (SPEC v0.7), so a malformed config renders wholly in the
/// resolved language.
public enum ConfigStr {
    case missingCheck
    case malformed
    case unsupportedVersion
    case permissive
    case entryError(name: String, reason: String)

    public func text(_ lang: Language) -> String {
        switch (lang, self) {
        case (.en, .missingCheck):
            return "custom: no ~/.config/limit-monitor/providers.json"
        case (.ru, .missingCheck):
            return "custom: нет ~/.config/limit-monitor/providers.json"
        case (.en, .malformed):          return "providers.json: parse error"
        case (.ru, .malformed):          return "providers.json: ошибка разбора"
        case (.en, .unsupportedVersion): return "providers.json: unsupported version (need 1)"
        case (.ru, .unsupportedVersion): return "providers.json: неподдерживаемая версия (нужна 1)"
        case (.en, .permissive):         return "providers.json is group/other-readable (chmod 600)"
        case (.ru, .permissive):         return "providers.json доступен другим (chmod 600)"
        case let (.en, .entryError(n, r)): return "\(n): config error — \(r)"
        case let (.ru, .entryError(n, r)): return "\(n): ошибка конфига — \(r)"
        }
    }
}

/// Keyed providers.json per-entry parse reasons (SPEC v0.7). Stored inside
/// `ConfigEntryError` and rendered through the `ConfigStr.entryError` frame in
/// the resolved language — this closes the v0.6 mixed EN/RU config path so
/// `--check` is 0-Cyrillic on EVERY path. RU arms are byte-identical to the
/// pre-v0.7 hardcoded strings.
public enum ConfigReason: Equatable {
    case notObject
    case invalidID
    case reservedID
    case duplicateID
    case unknownKind(String)
    case keyNeedsExactlyOne
    case invalidHost
    case requestURLMissing
    case requestMethodGETOnly
    case extractNeedsBalanceOrPercent

    public func text(_ lang: Language) -> String {
        switch (lang, self) {
        case (.en, .notObject):        return "entry is not an object"
        case (.ru, .notObject):        return "запись не объект"
        case (.en, .invalidID):        return "invalid id (need slug [a-z0-9-], no |)"
        case (.ru, .invalidID):        return "недопустимый id (нужен слаг [a-z0-9-], без |)"
        case (.en, .reservedID):       return "id is reserved"
        case (.ru, .reservedID):       return "id зарезервирован"
        case (.en, .duplicateID):      return "duplicate id"
        case (.ru, .duplicateID):      return "дублирующийся id"
        case let (.en, .unknownKind(k)): return "unknown kind: \(k)"
        case let (.ru, .unknownKind(k)): return "неизвестный kind: \(k)"
        case (.en, .keyNeedsExactlyOne): return "key: need exactly one of literal/env/command"
        case (.ru, .keyNeedsExactlyOne): return "key: нужен ровно один из literal/env/command"
        case (.en, .invalidHost):      return "host: intl or cn"
        case (.ru, .invalidHost):      return "host: intl или cn"
        case (.en, .requestURLMissing): return "request.url missing"
        case (.ru, .requestURLMissing): return "request.url отсутствует"
        case (.en, .requestMethodGETOnly): return "request.method: GET only"
        case (.ru, .requestMethodGETOnly): return "request.method: только GET"
        case (.en, .extractNeedsBalanceOrPercent): return "extract: need balance or percentUsed"
        case (.ru, .extractNeedsBalanceOrPercent): return "extract: нужен balance или percentUsed"
        }
    }
}

/// Curated network-error rows for config providers (`CustomProviderFetcher`).
/// Short and value-free — they can never echo a URL/header carrying the key.
public enum NetErrStr {
    case timeout
    case notConnected
    case hostNotFound
    case hostUnreachable
    case tls
    case badURL
    case emptyResponse
    case generic
    case genericCode(Int)

    public func text(_ lang: Language) -> String {
        switch (lang, self) {
        case (.en, .timeout):             return "timeout"
        case (.ru, .timeout):             return "таймаут"
        case (.en, .notConnected):        return "no connection"
        case (.ru, .notConnected):        return "нет соединения"
        case (.en, .hostNotFound):        return "host not found"
        case (.ru, .hostNotFound):        return "хост не найден"
        case (.en, .hostUnreachable):     return "host unreachable"
        case (.ru, .hostUnreachable):     return "хост недоступен"
        case (.en, .tls):                 return "TLS error"
        case (.ru, .tls):                 return "TLS-ошибка"
        case (.en, .badURL):              return "invalid URL"
        case (.ru, .badURL):              return "некорректный URL"
        case (.en, .emptyResponse):       return "empty response"
        case (.ru, .emptyResponse):       return "пустой ответ"
        case (.en, .generic):             return "network error"
        case (.ru, .generic):             return "сетевая ошибка"
        case let (.en, .genericCode(c)):  return "network error (code \(c))"
        case let (.ru, .genericCode(c)):  return "сетевая ошибка (код \(c))"
        }
    }
}

/// Menu items and settings-window chrome (`App`, `SettingsWindow`). The
/// `Limit Monitor` brand in `settingsTitle` is a proper noun and stays neutral.
public enum ChromeStr {
    case refreshNow
    case notifications
    case launchAtLogin
    case desktopCard
    case settings
    case quit
    case settingsTitle
    case providersSection
    case generalSection
    /// Separators section (SPEC v0.7): section header, the two field labels and
    /// the reset button. The separator glyphs themselves are neutral (never here).
    case separatorsSection
    case betweenProviders
    case betweenLimits
    case separatorsReset
    case showInFinder
    case disabledInConfigTooltip
    case loginUnavailableTooltip
    case updated
    case noNetwork
    case dataFrom
    case loading
    case noData
    /// Desktop-card empty-state row; the `Limit Monitor` brand is neutral.
    case cardNoData
    /// Desktop-card reset column (`до 12:30` / `until 12:30`).
    case cardReset(time: String)

    public func text(_ lang: Language) -> String {
        switch (lang, self) {
        case (.en, .refreshNow):              return "Refresh now"
        case (.ru, .refreshNow):              return "Обновить сейчас"
        case (.en, .notifications):           return "Limit notifications"
        case (.ru, .notifications):           return "Уведомления о лимитах"
        case (.en, .launchAtLogin):           return "Launch at login"
        case (.ru, .launchAtLogin):           return "Запускать при входе"
        case (.en, .desktopCard):             return "Desktop widget"
        case (.ru, .desktopCard):             return "Виджет на рабочем столе"
        case (.en, .settings):                return "Settings…"
        case (.ru, .settings):                return "Настройки…"
        case (.en, .quit):                    return "Quit"
        case (.ru, .quit):                    return "Выход"
        case (.en, .settingsTitle):           return "Limit Monitor — Settings"
        case (.ru, .settingsTitle):           return "Limit Monitor — настройки"
        case (.en, .providersSection):        return "Providers"
        case (.ru, .providersSection):        return "Провайдеры"
        case (.en, .generalSection):          return "General"
        case (.ru, .generalSection):          return "Общие"
        case (.en, .separatorsSection):       return "Separators"
        case (.ru, .separatorsSection):       return "Разделители"
        case (.en, .betweenProviders):        return "Between providers"
        case (.ru, .betweenProviders):        return "Между провайдерами"
        case (.en, .betweenLimits):           return "Between limits"
        case (.ru, .betweenLimits):           return "Между лимитами"
        case (.en, .separatorsReset):         return "Reset"
        case (.ru, .separatorsReset):         return "Сбросить"
        case (.en, .showInFinder):            return "Show in Finder"
        case (.ru, .showInFinder):            return "Показать в Finder"
        case (.en, .disabledInConfigTooltip): return "disabled in providers.json"
        case (.ru, .disabledInConfigTooltip): return "выключен в providers.json"
        case (.en, .loginUnavailableTooltip): return "available only from the installed Limit Monitor.app"
        case (.ru, .loginUnavailableTooltip): return "доступно только из установленного Limit Monitor.app"
        case (.en, .updated):                 return "Updated:"
        case (.ru, .updated):                 return "Обновлено:"
        case (.en, .noNetwork):               return "No network"
        case (.ru, .noNetwork):               return "Нет сети"
        case (.en, .dataFrom):                return "data from"
        case (.ru, .dataFrom):                return "данные от"
        case (.en, .loading):                 return "Loading…"
        case (.ru, .loading):                 return "Загрузка…"
        case (.en, .noData):                  return "No data"
        case (.ru, .noData):                  return "Нет данных"
        case (.en, .cardNoData):              return "Limit Monitor: no data"
        case (.ru, .cardNoData):              return "Limit Monitor: нет данных"
        case let (.en, .cardReset(t)):        return "until \(t)"
        case let (.ru, .cardReset(t)):        return "до \(t)"
        }
    }
}
