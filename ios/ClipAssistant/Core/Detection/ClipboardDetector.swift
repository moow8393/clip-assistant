import Foundation

// NSRegularExpression is thread-safe for concurrent reads after compilation,
// but lacks a Swift Sendable annotation — @unchecked is safe here.
public final class ClipboardDetector: @unchecked Sendable {

    private let kvRegex: NSRegularExpression
    private let presenceRegex: NSRegularExpression
    private let replacement: String

    public init(keywords: [String], replacement: String) throws {
        guard !keywords.isEmpty else {
            throw DetectorError.emptyKeywords
        }
        self.kvRegex = try PatternBuilder.buildKVPattern(keywords: keywords)
        self.presenceRegex = try PatternBuilder.buildPresencePattern(keywords: keywords)
        self.replacement = replacement
    }

    public func analyze(text: String) -> DetectionResult {
        let fullRange = NSRange(text.startIndex..., in: text)

        // Branch 1: k-v match — redaction is possible
        let kvMatches = kvRegex.matches(in: text, range: fullRange)
        if !kvMatches.isEmpty {
            let hitKeywords = extractUniqueKeywords(from: kvMatches, in: text, groupIndex: 1)
            let redacted = applyKVReplacement(matches: kvMatches, in: text)
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

    // Rebuilds the string by iterating matches in order, preserving group 1 (keyword)
    // and group 2 (separator), substituting group 3 (value) with the raw replacement token.
    // Using manual iteration avoids NSRegularExpression template $ back-reference ambiguity.
    private func applyKVReplacement(matches: [NSTextCheckingResult], in text: String) -> String {
        var result = ""
        var lastEnd = text.startIndex

        for match in matches {
            guard let fullRange = Range(match.range, in: text),
                  let group1Range = Range(match.range(at: 1), in: text),
                  let group2Range = Range(match.range(at: 2), in: text) else { continue }

            result += text[lastEnd..<fullRange.lowerBound]
            result += text[group1Range]
            result += text[group2Range]
            result += replacement
            lastEnd = fullRange.upperBound
        }

        result += text[lastEnd...]
        return result
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
