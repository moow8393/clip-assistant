import Foundation

public struct ClipboardEntry: Sendable, Codable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let hitKeywords: [String]
    public let preview: String   // first 80 chars of redacted text

    public init(timestamp: Date, hitKeywords: [String], preview: String) {
        self.id = UUID()
        self.timestamp = timestamp
        self.hitKeywords = hitKeywords
        self.preview = preview
    }
}
