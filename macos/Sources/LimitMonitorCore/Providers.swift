import Foundation

public enum Provider {
    public static let claude = "claude"
    public static let codex = "codex"
    public static let cursor = "cursor"

    /// Display order for merged titles/menus: claude first, then codex (then cursor in v0.3).
    /// Config providers (v0.4) come after, in providers.json file order.
    public static let displayOrder = [claude, codex, cursor]

    /// Builtin providers with dedicated adapters/labels; anything else is a
    /// config provider id from providers.json.
    public static func isBuiltin(_ provider: String) -> Bool {
        provider == claude || provider == codex || provider == cursor
    }

    public static func displayName(_ provider: String) -> String {
        switch provider {
        case claude: return "Claude"
        case codex: return "Codex"
        case cursor: return "Cursor"
        default: return provider.prefix(1).uppercased() + provider.dropFirst()
        }
    }

    public static func titlePrefix(_ provider: String) -> String {
        switch provider {
        case claude: return "Cl·"
        case codex: return "Cx·"
        case cursor: return "Cu·"
        default: return "\(displayName(provider).prefix(2))·"
        }
    }

    public static func sortIndex(_ provider: String) -> Int {
        displayOrder.firstIndex(of: provider) ?? displayOrder.count
    }
}
