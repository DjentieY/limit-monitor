import Foundation

/// UI language seam (SPEC v0.6). EN is the default; RU is selected only when the
/// user's TOP preferred language is Russian. Pure and injectable so `checks` can
/// drive both locales deterministically regardless of the CI machine's locale.
/// Core LOGIC never resolves this internally — the shell resolves ONE value per
/// process at launch and threads it down; only the default argument reads the
/// process locale. Foundation-only (legal in Core).
public enum Language: String, CaseIterable, Sendable {
    case en
    case ru

    /// EN default; `.ru` iff `preferred.first` (the ordered UI-language list,
    /// NOT region) has prefix `ru`. Uses `preferredLanguages`, not
    /// `Locale.current.language` — a RU user in an en_US region reads RU UI.
    public static func resolve(preferred: [String] = Locale.preferredLanguages) -> Language {
        let tag = preferred.first?.lowercased() ?? "en"
        return tag.hasPrefix("ru") ? .ru : .en
    }
}
