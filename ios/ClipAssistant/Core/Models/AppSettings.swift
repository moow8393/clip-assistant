import Foundation

public struct AppSettings: Sendable, Codable {
    public var keywords: [String]
    public var replacementToken: String
    public var isPaused: Bool

    public static let defaultKeywords: [String] = [
        "host", "password", "pw", "account", "authorization"
    ]

    public static let `default` = AppSettings(
        keywords: defaultKeywords,
        replacementToken: "***",
        isPaused: false
    )
}
