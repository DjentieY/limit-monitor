import Foundation
import LimitMonitorCore

/// Fetch/parse pipeline shared by the app poller and --check: primary request →
/// builtin/generic adapter → openrouter /credits fallback when /key has no
/// per-key limit. Never logs requests or bodies (they may embed the key).
enum CustomProviderEngine {
    struct StepLog {
        /// Display-safe URL: builtin endpoints are static, generic/preset URLs
        /// are the config TEMPLATE (`${KEY}` unsubstituted) with the query
        /// collapsed to `?…` — neither a `${KEY}` substitution nor a literal
        /// key hardcoded in the URL query can leak through --check output.
        let url: String
        let httpStatus: Int?
        let networkError: String?
    }

    struct Outcome {
        /// `.needsCredits` is resolved internally and never escapes.
        let result: AdapterResult
        let steps: [StepLog]
    }

    static func run(provider: ConfiguredProvider, key: String, _ lang: Language) -> Outcome {
        guard let request = ConfigRequestBuilder.primary(for: provider, key: key) else {
            let reason = lang == .en ? "request not set" : "request не задан"
            return Outcome(result: .state(.configError(reason)), steps: [])
        }
        var steps: [StepLog] = []
        let primary = CustomProviderFetcher.fetchSync(request, lang)
        steps.append(StepLog(
            url: displayURL(for: provider),
            httpStatus: primary.httpStatus,
            networkError: primary.networkError
        ))
        guard primary.networkError == nil, let status = primary.httpStatus, let data = primary.data else {
            return Outcome(result: .state(.fetchError(primary.networkError ?? NetErrStr.emptyResponse.text(lang))), steps: steps)
        }
        var result = parse(provider: provider, data: data, httpStatus: status, lang)
        if case .needsCredits = result {
            // openrouter two-step: /key carries no per-key limit → balance from /credits.
            let creditsRequest = ConfigRequestBuilder.openRouterCredits(key: key)
            let credits = CustomProviderFetcher.fetchSync(creditsRequest, lang)
            steps.append(StepLog(
                url: creditsRequest.url,
                httpStatus: credits.httpStatus,
                networkError: credits.networkError
            ))
            guard credits.networkError == nil, let creditsStatus = credits.httpStatus,
                  let creditsData = credits.data else {
                return Outcome(result: .state(.fetchError(credits.networkError ?? NetErrStr.emptyResponse.text(lang))), steps: steps)
            }
            result = OpenRouterAdapter.parseCredits(
                data: creditsData, httpStatus: creditsStatus, provider: provider, lang
            )
        }
        return Outcome(result: result, steps: steps)
    }

    static func parse(provider: ConfiguredProvider, data: Data, httpStatus: Int, _ lang: Language) -> AdapterResult {
        switch provider.kind {
        case .openrouter:
            return OpenRouterAdapter.parseKey(data: data, httpStatus: httpStatus, provider: provider, lang)
        case .deepseek:
            return DeepSeekAdapter.parse(data: data, httpStatus: httpStatus, provider: provider, lang)
        case .moonshot:
            return MoonshotAdapter.parse(data: data, httpStatus: httpStatus, provider: provider, lang)
        case .zhipu:
            return ZhipuAdapter.parse(data: data, httpStatus: httpStatus, provider: provider, lang)
        case .siliconflow, .novita, .genericHTTP:
            return GenericAdapter.parse(data: data, httpStatus: httpStatus, provider: provider, lang)
        }
    }

    static func displayURL(for provider: ConfiguredProvider) -> String {
        if provider.usesGenericAdapter {
            return ConfigRequestBuilder.redactedDisplayURL(provider.request?.url ?? "—")
        }
        return ConfigRequestBuilder.primary(for: provider, key: "${KEY}")?.url ?? "—"
    }
}

/// One config provider = one independent runtime (v0.2 isolation rules). The
/// key source is re-resolved on EVERY poll.
struct CustomProviderPoller {
    let provider: ConfiguredProvider

    func poll() -> PollOutcome {
        let key: String
        switch KeyResolver.resolve(provider.key, appLanguage) {
        case .failure(let reason):
            return .customState(.keyError(reason))
        case .key(let value):
            key = value
        }
        switch CustomProviderEngine.run(provider: provider, key: key, appLanguage).result {
        case .entries(let entries):
            return .success(entries)
        case .needsCredits:
            return .customState(.parseError(appLanguage == .en ? "no /credits data" : "нет данных /credits"))
        case .state(.ok):
            return .success([])
        case .state(let state):
            return .customState(state)
        }
    }
}
