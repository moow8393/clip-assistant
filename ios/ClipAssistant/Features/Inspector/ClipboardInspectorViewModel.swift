import SwiftUI

@MainActor
final class ClipboardInspectorViewModel: ObservableObject {
    @Published var detectionResult: DetectionResult = .noMatch
    @Published var isAnalyzing: Bool = false

    // Tracks the changeCount from the last time we analyzed the clipboard.
    // -1 means first launch; analysis is always forced on first activation.
    private var lastKnownChangeCount: Int = -1

    // Anti-recursion Layer 1: set to true while we write to pasteboard ourselves.
    // changedNotification and onBecomeActive both check this flag and bail early.
    private var isAppWriting: Bool = false

    private let settingsStore = SettingsStore.shared
    private let historyStore = HistoryStore.shared

    init() {
        // Subscribe to changedNotification as a supplemental trigger.
        // This fires when the clipboard changes while the app is already in the foreground
        // (i.e., the user copies something without switching apps). It does NOT fire in background.
        NotificationCenter.default.addObserver(
            forName: UIPasteboard.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.isAppWriting else { return }
            Task { @MainActor in
                await self.analyzeCurrentClipboard()
            }
        }
    }

    /// Called by ClipboardInspectorView and ContentView when ScenePhase becomes .active.
    func onBecomeActive() {
        // Layer 1: skip if we triggered the clipboard change ourselves
        guard !isAppWriting else { return }

        let currentCount = UIPasteboard.general.changeCount

        // Skip re-analysis if clipboard hasn't changed since last foreground.
        // Exception: always analyze on first activation (lastKnownChangeCount == -1).
        guard currentCount != lastKnownChangeCount || lastKnownChangeCount == -1 else { return }

        Task {
            await analyzeCurrentClipboard()
        }
    }

    func analyzeCurrentClipboard() async {
        isAnalyzing = true
        defer { isAnalyzing = false }

        // Capture changeCount before reading content to detect TOCTOU race
        let countAtRead = UIPasteboard.general.changeCount

        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            detectionResult = .noMatch
            lastKnownChangeCount = countAtRead
            return
        }

        let settings = settingsStore.load()
        guard !settings.isPaused, !settings.keywords.isEmpty else {
            detectionResult = .noMatch
            lastKnownChangeCount = countAtRead
            return
        }

        do {
            let detector = try ClipboardDetector(
                keywords: settings.keywords,
                replacement: settings.replacementToken
            )
            let result = detector.analyze(text: text)
            detectionResult = result
            lastKnownChangeCount = countAtRead
        } catch {
            // Pattern build failure (malformed keywords) — treat as no match
            detectionResult = .noMatch
        }
    }

    func confirmRedact(redactedText: String, hitKeywords: [String]) {
        // Layer 1: block notification-triggered re-detection during our own write
        isAppWriting = true

        UIPasteboard.general.string = redactedText

        // Layer 2: record the changeCount resulting from our write.
        // changeCount increments synchronously on the same thread, so this read
        // immediately reflects the write above — no sleep or delay needed.
        lastKnownChangeCount = UIPasteboard.general.changeCount

        // Clear flag in the same synchronous block to minimise the window where
        // changedNotification could fire and see isAppWriting == true.
        isAppWriting = false

        let entry = ClipboardEntry(
            timestamp: Date(),
            hitKeywords: hitKeywords,
            preview: String(redactedText.prefix(80))
        )
        Task {
            await historyStore.append(entry)
        }
        detectionResult = .redacted
    }

    func skipRedact() {
        detectionResult = .noMatch
    }
}
