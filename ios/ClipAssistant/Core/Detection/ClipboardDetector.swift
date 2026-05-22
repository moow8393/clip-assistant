import Foundation

/// Thread-safe detector; all state is immutable after init.
/// Conforms to Sendable because NSRegularExpression is thread-safe for concurrent reads
/// once compiled, and the replacement string is an immutable String.
public final class ClipboardDetector: Sendable {

    private let kvRegex: NSRegularExpression
    private let presenceRegex: NSRegularExpression

    // "$" is escaped to "$$" so NSRegularExpression.stringByReplacingMatches does not
    // interpret "$1"-style back-references in the user-supplied replacement token.
    // This mirrors Windows: _replacementForRegex = replacement.Replace("$", "$$")
    private let escapedReplacement: String

    public init(keywords: [String], replacement: String) throws {
        guard !keywords.isEmpty else {
            throw DetectorError.emptyKeywords
        }
        self.kvRegex = try PatternBuilder.buildKVPattern(keywords: keywords)
        self.presenceRegex = try PatternBuilder.buildPresencePattern(keywords: keywords)
        self.escapedReplacement = replacement.replacingOccurrences(of: "$", with: "$$")
    }

    public func analyze(text: String) -> DetectionResult {
        let fullRange = NSRange(text.startIndex..., in: text)

        // Branch 1: k-v match — redaction is possible
        let kvMatches = kvRegex.matches(in: text, range: fullRange)
        if !kvMatches.isEmpty {
            let hitKeywords = extractUniqueKeywords(from: kvMatches, in: text, groupIndex: 1)
            // $1 = keyword (group 1), $2 = separator (group 2), escapedReplacement = masked value
            let redacted = kvRegex.stringByReplacingMatches(
                in: text,
                range: fullRange,
                withTemplate: "$1$2\(escapedReplacement)"
            )
            return .kvMatch(keywords: hitKeywords, redactedText: redacted)
        }

        // Branch 2: presence only — warning, no automatic redaction
        let presenceMatches = presenceRegex.matches(in: text, range: fullRange)
        if !presenceMatches.isEmpty {
            let hitKeywords = extractUniqueKeywords(from: presenceMatches, in: text, groupIndex: 1)
            return .presenceMatch(keywords: hitKeywords)
        }

        return .noMatch
    }

    private func extractUniqueKeywords(
        from matches: [NSTextCheckingResult],
        in text: String,
        groupIndex: Int
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for match in matches {
            guard let range = Range(match.range(at: groupIndex), in: text) else { continue }
            let kw = String(text[range]).lowercased()
            if seen.insert(kw).inserted {
                result.append(kw)
            }
        }
        // Sort for deterministic output (matches Windows Array.Sort with StringComparer.Ordinal)
        return result.sorted()
    }
}

public enum DetectorError: Error, Sendable {
    case emptyKeywords
    case invalidPattern(String)
}
