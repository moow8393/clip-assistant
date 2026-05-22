import Foundation

/// Builds NSRegularExpression patterns equivalent to Windows ClipboardMonitor.BuildPatterns().
/// Uses (?<!\p{L}) / (?!\p{L}) instead of \b to support CJK keywords, as \b in ICU
/// regex (like .NET) does not transition at Unicode letter boundaries for non-ASCII chars.
public struct PatternBuilder {

    /// Group 1 = keyword, Group 2 = separator (includes optional auth scheme prefix),
    /// Group 3 = value (the only group replaced during redaction).
    public static func buildKVPattern(keywords: [String]) throws -> NSRegularExpression {
        let escaped = keywords.map { NSRegularExpression.escapedPattern(for: $0) }
        let alternation = escaped.joined(separator: "|")
        // Double-escaped raw string: \p{L} is a Unicode property escape supported by ICU.
        let pattern = "(?<!\\p{L})(\(alternation))(\"?\\s*[:=]\\s*\"?(?:Bearer\\s+|Basic\\s+)?)([^\",\\s;&]+)"
        return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// Presence pattern fires only when kvPattern has zero matches.
    public static func buildPresencePattern(keywords: [String]) throws -> NSRegularExpression {
        let escaped = keywords.map { NSRegularExpression.escapedPattern(for: $0) }
        let alternation = escaped.joined(separator: "|")
        let pattern = "(?<!\\p{L})(\(alternation))(?!\\p{L})"
        return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}
