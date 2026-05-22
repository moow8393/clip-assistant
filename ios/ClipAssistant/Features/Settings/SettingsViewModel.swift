import SwiftUI

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var keywords: [String] = []
    @Published var replacementToken: String = "***"
    @Published var isPaused: Bool = false
    @Published var hasUnsavedChanges: Bool = false

    private let store = SettingsStore.shared
    private var savedState: AppSettings?

    init() {
        let settings = store.load()
        keywords = settings.keywords
        replacementToken = settings.replacementToken
        isPaused = settings.isPaused
        savedState = settings
    }

    func addKeyword(_ kw: String) {
        let trimmed = kw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !keywords.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return }
        keywords.append(trimmed)
        markDirty()
    }

    func removeKeyword(at offsets: IndexSet) {
        keywords.remove(atOffsets: offsets)
        markDirty()
    }

    func save() {
        guard !keywords.isEmpty else { return }
        let token = replacementToken.trimmingCharacters(in: .whitespaces)
        let effective = token.isEmpty ? "***" : token
        let settings = AppSettings(
            keywords: keywords,
            replacementToken: effective,
            isPaused: isPaused
        )
        store.save(settings)
        savedState = settings
        hasUnsavedChanges = false
    }

    private func markDirty() {
        hasUnsavedChanges = true
    }
}
