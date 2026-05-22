import Foundation

/// Mirrors the detection branches in Windows ClipboardMonitor.HandleClipboard().
/// - noMatch: clipboard is safe or pattern build failed
/// - presenceMatch: keyword found but no k-v structure; show warning only
/// - kvMatch: keyword + separator + value found; redaction is possible
/// - redacted: sentinel state after user confirmed redaction (drives UI transition)
public enum DetectionResult: Sendable, Equatable {
    case noMatch
    case presenceMatch(keywords: [String])
    case kvMatch(keywords: [String], redactedText: String)
    case redacted
}
