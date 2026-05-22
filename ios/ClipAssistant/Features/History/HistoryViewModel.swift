import SwiftUI

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var entries: [ClipboardEntry] = []
    private let store = HistoryStore.shared

    func load() async {
        entries = await store.loadAll()
    }

    // Synchronous wrapper so toolbar button actions don't need Task { await } inline,
    // which causes Swift 6 actor isolation ambiguity inside @ToolbarContentBuilder.
    func clearEntries() {
        entries = []
        Task { await store.clear() }
    }
}
