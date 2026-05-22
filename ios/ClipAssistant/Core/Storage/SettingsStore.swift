import Foundation

/// Persists app settings using standard UserDefaults.
/// No App Group is needed because there is only one process in this architecture.
public final class SettingsStore: Sendable {
    public static let shared = SettingsStore()

    private enum Key {
        static let settings = "clipassistant.settings.v1"
    }

    private init() {}

    public func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Key.settings)
    }

    public func load() -> AppSettings {
        guard
            let data = UserDefaults.standard.data(forKey: Key.settings),
            let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return .default
        }
        return settings
    }
}
