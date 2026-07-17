import Foundation

/// Structure-only dump of a JSON document for remote debugging: keys and array
/// counts, depth-limited, NO values (values could embed account ids or tokens).
public enum JSONKeyTree {
    public static func describe(data: Data, maxDepth: Int = 3) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return "(not JSON)" }
        var lines: [String] = []
        append(object, name: "(root)", depth: 0, maxDepth: maxDepth, to: &lines)
        return lines.joined(separator: "\n")
    }

    private static func append(_ value: Any, name: String, depth: Int, maxDepth: Int, to lines: inout [String]) {
        let indent = String(repeating: "  ", count: depth)
        switch value {
        case let dict as [String: Any]:
            lines.append("\(indent)\(name) {}")
            guard depth < maxDepth else { return }
            for key in dict.keys.sorted() {
                if let child = dict[key] {
                    append(child, name: key, depth: depth + 1, maxDepth: maxDepth, to: &lines)
                }
            }
        case let array as [Any]:
            lines.append("\(indent)\(name) [\(array.count)]")
            if depth < maxDepth, let first = array.first {
                append(first, name: "[0]", depth: depth + 1, maxDepth: maxDepth, to: &lines)
            }
        default:
            lines.append("\(indent)\(name)")
        }
    }
}
