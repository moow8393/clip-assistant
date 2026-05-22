import SwiftUI

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var entries: [ClipboardEntry] = []
    private let store = HistoryStore.shared

    func load() async {
        entries = await store.loadAll()
    }

    func clear() async {
        await store.clear()
        entries = []
    }
}
