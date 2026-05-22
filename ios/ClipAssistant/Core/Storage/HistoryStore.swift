import Foundation

/// Persists clipboard redaction history as JSON in the app's Documents directory.
/// Maximum 50 entries; oldest entries are dropped when the limit is exceeded.
public actor HistoryStore {
    public static let shared = HistoryStore()

    private let maxEntries = 50

    private var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("clip_history.json")
    }

    public func append(_ entry: ClipboardEntry) {
        var entries = loadAll()
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    public func loadAll() -> [ClipboardEntry] {
        guard
            let data = try? Data(contentsOf: fileURL),
            let entries = try? JSONDecoder().decode([ClipboardEntry].self, from: data)
        else {
            return []
        }
        return entries
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
