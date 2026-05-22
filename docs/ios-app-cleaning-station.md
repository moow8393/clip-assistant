# iOS ClipAssistant — App 清洗站開發文件

## 目錄

1. [功能範圍](#1-功能範圍)
2. [架構設計](#2-架構設計)
3. [剪貼簿讀取策略](#3-剪貼簿讀取策略)
4. [偵測邏輯](#4-偵測邏輯)
5. [防遞迴機制](#5-防遞迴機制)
6. [UI/UX 設計](#6-uiux-設計)
7. [設定持久化](#7-設定持久化)
8. [Info.plist 設定](#8-infoplist-設定)
9. [實作步驟（Sprint 分解）](#9-實作步驟sprint-分解)
10. [測試案例](#10-測試案例)
11. [已知限制](#11-已知限制)

---

## 1. 功能範圍

### 能做到什麼

- **前景自動偵測**：App 進入前景（`sceneDidBecomeActive`）時，自動讀取剪貼簿並執行 k-v 偵測，無需使用者手動按下任何按鈕
- **k-v 結構遮罩**：命中 `password: secret`、`host: 192.168.1.1`、`Authorization: Bearer eyJ...` 等格式時，提供確認 UI 並以替換 token（預設 `***`）寫回剪貼簿
- **Presence 警告**：偵測到關鍵字但無可自動遮罩的 k-v 結構時，顯示警告，要求使用者手動檢查
- **設定管理**：在 App 內新增 / 刪除監控關鍵字、修改替換 token、暫停偵測
- **歷史記錄**：保留最近 50 筆遮罩記錄（時間戳、命中關鍵字、前 N 字元預覽）
- **Dock 一鍵啟動**：將 App 置於 Dock，複製後快速切換完成清洗，再切回目標 App 貼上

### 不做什麼（明確排除）

- **不監聽背景剪貼簿**：App suspend 後不執行任何偵測，iOS Sandbox 不允許
- **不攔截系統 Command+V 或長按貼上**：這些操作直接走系統 `pasteboardd`，第三方 App 無法 hook
- **不自動切回目標 App**：iOS 不允許第三方 App 自動切換前景，使用者需自行切回
- **不處理圖片 / 檔案格式剪貼簿**：只處理純文字，行為與 Windows 版一致
- **不提供全域常駐保護**：保護邊界僅限「使用者主動開啟 App 並確認」的窗口

### 保護範圍的誠實說明

本方案屬於**使用者主動觸發的清洗工具**，而非透明攔截系統。若使用者在複製後跳過 App 直接貼上，本 App 無能力介入。設計目標是讓主動觸發的成本（開 App → 確認 → 切回貼上）降至最低，而非強制攔截。

---

## 2. 架構設計

### 單一 App Target

本方案不需要 Keyboard Extension，不需要 App Groups，不需要 Darwin Notification，亦不需要 NSFileCoordinator。相較於 `docs/ios-plan.md` 的 Keyboard Extension 方案，架構大幅簡化：

| 維度 | Keyboard Extension 方案 | App 清洗站方案 |
|---|---|---|
| Target 數量 | 2（Host App + Extension）| 1（單一 App）|
| App Groups | 必須 | 不需要 |
| Open Access 授權 | 必須（剪貼簿讀取）| 不需要 |
| 使用者操作步驟 | 4 步（切換輸入法 → 貼上按鈕 → 確認 → 切回）| 3 步（開 App → 確認 → 切回貼上）|
| 記憶體上限 | ~48 MB（Extension 限制）| ~200+ MB（主 App）|

### 專案目錄結構

```
ios/
├── ClipAssistant.xcodeproj/
│
└── ClipAssistant/                         # 單一 App target
    ├── App/
    │   ├── ClipAssistantApp.swift          # @main entry point, ScenePhase observer
    │   └── ContentView.swift               # TabView root
    │
    ├── Features/
    │   ├── Inspector/
    │   │   ├── ClipboardInspectorView.swift    # 主畫面：自動偵測結果
    │   │   ├── ClipboardInspectorViewModel.swift
    │   │   ├── ConfirmRedactView.swift          # kvMatch 確認 overlay
    │   │   └── PresenceWarningView.swift        # presenceMatch 警告 overlay
    │   │
    │   ├── Settings/
    │   │   ├── SettingsView.swift
    │   │   ├── SettingsViewModel.swift
    │   │   └── KeywordListView.swift
    │   │
    │   └── History/
    │       ├── HistoryView.swift
    │       └── HistoryViewModel.swift
    │
    ├── Core/
    │   ├── Detection/
    │   │   ├── ClipboardDetector.swift     # analyze(text:) -> DetectionResult
    │   │   └── PatternBuilder.swift        # Regex pattern construction
    │   │
    │   ├── Storage/
    │   │   ├── SettingsStore.swift         # UserDefaults persistence
    │   │   └── HistoryStore.swift          # JSON history in App container
    │   │
    │   └── Models/
    │       ├── AppSettings.swift           # Sendable settings model
    │       ├── DetectionResult.swift       # Sendable enum
    │       └── ClipboardEntry.swift        # Sendable history entry
    │
    └── Resources/
        ├── Assets.xcassets
        └── Localizable.strings
```

### 資料流

```
使用者在任意 App 複製含敏感資料的文字
    │
    ▼
使用者開啟 ClipAssistant（Dock 一鍵，或 App Switcher）
    │
    ▼
ScenePhase 變為 .active
    │
    └─ ClipboardInspectorViewModel.onBecomeActive()
           │
           ├─ 讀取 UIPasteboard.general.changeCount
           ├─ 若 changeCount 與上次相同且非首次啟動 → 顯示快取結果，不重新偵測
           └─ 若 changeCount 有變化 → 讀取 UIPasteboard.general.string
                  │
                  ├─ 設定 isPaused == true → 顯示「監控已暫停」狀態
                  │
                  └─ ClipboardDetector.analyze(text:)
                         │
                         ├─ .kvMatch(keywords, redactedText)
                         │     → 顯示 ConfirmRedactView
                         │     │     使用者按「取代剪貼簿」:
                         │     │         isAppWriting = true
                         │     │         UIPasteboard.general.string = redactedText
                         │     │         isAppWriting = false
                         │     │         HistoryStore.append(entry)
                         │     │         → 顯示「已取代，請切回目標 App 貼上」確認畫面
                         │     └─     使用者按「略過」: 關閉 overlay，保留原始剪貼簿
                         │
                         ├─ .presenceMatch(keywords)
                         │     → 顯示 PresenceWarningView
                         │     └─     使用者按「了解」: 關閉 overlay，保留原始剪貼簿
                         │
                         └─ .noMatch
                               → 顯示「剪貼簿內容安全」綠色狀態

使用者切回目標 App，以任意方式貼上（Command+V / 長按貼上 / 任意方式）
```

### ScenePhase 觸發時機說明

| 觸發情境 | ScenePhase 轉換 | 是否重新偵測 |
|---|---|---|
| App 冷啟動 | `nil` → `.active` | 是 |
| 從 App Switcher 切回 | `.background` → `.inactive` → `.active` | 是（若 changeCount 有變） |
| 在 App 內部頁面切換 | 維持 `.active` | 否 |
| 按 Home 鍵 / 切換其他 App | `.active` → `.inactive` → `.background` | 不觸發偵測 |
| 系統鎖屏 | `.active` → `.inactive` → `.background` | 不觸發偵測 |

---

## 3. 剪貼簿讀取策略

### 核心原則

iOS 14+ 的 `UIPasteboard.general.string` 讀取規則：

- **App 前景且讀取行為可歸因於使用者操作**：系統不顯示橫幅（但定義模糊，Apple 保留判斷權）
- **App 前景但明確的程式碼觸發（非使用者手勢）**：iOS 14/15 會顯示黃色橫幅；iOS 16+ 使用 `PasteButton` 可完全規避
- **`sceneDidBecomeActive` 時讀取**：Apple 文件未明確說明此時機是否觸發橫幅；實務上 iOS 16+ 測試通常不觸發，但 iOS 14/15 可能觸發

### iOS 16+（Minimum Deployment Target）

本文件以 **iOS 16 為 Minimum Deployment Target**。

`sceneDidBecomeActive` 時讀取剪貼簿是本方案的核心策略。iOS 16 實機測試顯示，App 切換至前景時的 `UIPasteboard` 讀取行為通常不觸發隱私橫幅，因為系統將其歸類為使用者主動切換 App 的結果。若未來 Apple 調整此判斷邏輯，可降級為主動按鈕觸發。

```swift
// ClipAssistantApp.swift
import SwiftUI

@main
struct ClipAssistantApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// ContentView.swift
import SwiftUI

struct ContentView: View {
    @StateObject private var inspectorVM = ClipboardInspectorViewModel()

    var body: some View {
        TabView {
            ClipboardInspectorView(viewModel: inspectorVM)
                .tabItem { Label("檢查", systemImage: "doc.on.clipboard") }

            HistoryView()
                .tabItem { Label("記錄", systemImage: "clock") }

            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape") }
        }
        // ScenePhase observation at the App level ensures we catch every foreground transition
        .onChange(of: inspectorVM.scenePhase) { _, newPhase in
            if newPhase == .active {
                inspectorVM.onBecomeActive()
            }
        }
    }
}
```

```swift
// ClipboardInspectorViewModel.swift
import SwiftUI
import Combine

@MainActor
final class ClipboardInspectorViewModel: ObservableObject {
    @Environment(\.scenePhase) var scenePhase

    @Published var detectionResult: DetectionResult = .noMatch
    @Published var isAnalyzing: Bool = false
    @Published var lastKnownChangeCount: Int = -1

    // Anti-recursion: set to true while we write to pasteboard ourselves
    private var isAppWriting: Bool = false

    private let settingsStore = SettingsStore.shared
    private let historyStore = HistoryStore.shared

    func onBecomeActive() {
        // Skip if we just wrote to pasteboard (changeCount will have incremented by us)
        guard !isAppWriting else { return }

        let currentCount = UIPasteboard.general.changeCount

        // Skip re-analysis if clipboard hasn't changed since last foreground
        // Exception: always analyze on first activation (lastKnownChangeCount == -1)
        guard currentCount != lastKnownChangeCount || lastKnownChangeCount == -1 else { return }

        Task {
            await analyzeCurrentClipboard()
        }
    }

    private func analyzeCurrentClipboard() async {
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
        isAppWriting = true
        UIPasteboard.general.string = redactedText
        // changeCount increments synchronously; record it to skip on next activation
        lastKnownChangeCount = UIPasteboard.general.changeCount
        isAppWriting = false

        let entry = ClipboardEntry(
            timestamp: Date(),
            hitKeywords: hitKeywords,
            preview: String(redactedText.prefix(80))
        )
        historyStore.append(entry)

        detectionResult = .redacted
    }

    func skipRedact() {
        detectionResult = .noMatch
    }
}
```

### UIPasteboard.changedNotification（前景補充訂閱）

若使用者在 App 開啟狀態下複製新內容（不切換 App），`sceneDidBecomeActive` 不會再觸發。可選訂閱 `UIPasteboard.changedNotification` 作為補充：

```swift
// In ClipboardInspectorViewModel.init()
// This notification fires when clipboard changes while the app is in the foreground.
// It does NOT fire when the app is in the background.
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
```

### iOS 14/15 降級路徑（若未來需要放寬 Deployment Target）

若需支援 iOS 14/15，`sceneDidBecomeActive` 時的讀取可能觸發橫幅。降級策略：不自動讀取，改在主畫面顯示「點此檢查剪貼簿」按鈕，將讀取行為明確歸因為使用者手勢。UI 文案需告知使用者「系統會顯示通知橫幅，屬正常現象」。

```swift
// iOS 14/15 fallback — user-initiated read only
Button("檢查剪貼簿") {
    // User-initiated; iOS attributes this to user action, but banner may still appear
    // on iOS 14/15.
    Task { @MainActor in
        await viewModel.analyzeCurrentClipboard()
    }
}
```

---

## 4. 偵測邏輯

### Pattern 設計（移植自 Windows 版）

Windows 版 `BuildPatterns` 的兩個 Regex 直接移植至 Swift `NSRegularExpression`（ICU engine），pattern 語法完全相容。

**k-v pattern**：
```
(?<!\p{L})(KW1|KW2|...)("?\s*[:=]\s*"?(?:Bearer\s+|Basic\s+)?)([^",\s;&]+)
```

**presence pattern（fallback）**：
```
(?<!\p{L})(KW1|KW2|...)(?!\p{L})
```

### Models

```swift
// Models/DetectionResult.swift
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

// Models/AppSettings.swift
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

// Models/ClipboardEntry.swift
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
```

### PatternBuilder

```swift
// Core/Detection/PatternBuilder.swift
import Foundation

/// Builds NSRegularExpression patterns equivalent to Windows ClipboardMonitor.BuildPatterns().
/// Uses (?<!\p{L}) / (?!\p{L}) instead of \b to support CJK keywords, as \b in ICU
/// regex (like .NET) does not transition at Unicode letter boundaries for non-ASCII chars.
public struct PatternBuilder {

    /// Group 1 = keyword, Group 2 = separator (includes optional auth scheme prefix),
    /// Group 3 = value (the only group replaced during redaction).
    public static func buildKVPattern(keywords: [String]) throws -> NSRegularExpression {
        let escaped = keywords.map { NSRegularExpression.escapedPattern(for: $0) }
        let alternation = escaped.joined(separator: "|")
        // Double-escaped raw string: \p{L} is a Unicode property escape supported by ICU.
        let pattern = "(?<!\\p{L})(\(alternation))(\"?\\s*[:=]\\s*\"?(?:Bearer\\s+|Basic\\s+)?)([^\",\\s;&]+)"
        return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// Presence pattern fires only when kvPattern has zero matches.
    public static func buildPresencePattern(keywords: [String]) throws -> NSRegularExpression {
        let escaped = keywords.map { NSRegularExpression.escapedPattern(for: $0) }
        let alternation = escaped.joined(separator: "|")
        let pattern = "(?<!\\p{L})(\(alternation))(?!\\p{L})"
        return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}
```

### ClipboardDetector

```swift
// Core/Detection/ClipboardDetector.swift
import Foundation

/// Thread-safe detector; all state is immutable after init.
/// Conforms to Sendable because NSRegularExpression is thread-safe for concurrent reads
/// once compiled, and the replacement string is an immutable String.
public final class ClipboardDetector: Sendable {

    private let kvRegex: NSRegularExpression
    private let presenceRegex: NSRegularExpression

    // "$" is escaped to "$$" so NSRegularExpression.stringByReplacingMatches does not
    // interpret "$1"-style back-references in the user-supplied replacement token.
    // This mirrors Windows: _replacementForRegex = replacement.Replace("$", "$$")
    private let escapedReplacement: String

    public init(keywords: [String], replacement: String) throws {
        guard !keywords.isEmpty else {
            throw DetectorError.emptyKeywords
        }
        self.kvRegex = try PatternBuilder.buildKVPattern(keywords: keywords)
        self.presenceRegex = try PatternBuilder.buildPresencePattern(keywords: keywords)
        self.escapedReplacement = replacement.replacingOccurrences(of: "$", with: "$$")
    }

    public func analyze(text: String) -> DetectionResult {
        let fullRange = NSRange(text.startIndex..., in: text)

        // Branch 1: k-v match — redaction is possible
        let kvMatches = kvRegex.matches(in: text, range: fullRange)
        if !kvMatches.isEmpty {
            let hitKeywords = extractUniqueKeywords(from: kvMatches, in: text, groupIndex: 1)
            // $1 = keyword (group 1), $2 = separator (group 2), escapedReplacement = masked value
            let redacted = kvRegex.stringByReplacingMatches(
                in: text,
                range: fullRange,
                withTemplate: "$1$2\(escapedReplacement)"
            )
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
```

### CJK 關鍵字邊界處理

`\b` 在 ICU regex（與 .NET 相同）為 ASCII word boundary，對 Unicode 字母（包含 CJK）無效。`(?<!\p{L})` / `(?!\p{L})` 是正確替代：

| 測試輸入 | 前一字元 | `(?<!\p{L})` | 結果 |
|---|---|---|---|
| `test密碼=secret` | `t`（`\p{L}`）| 不滿足 | 不命中（正確）|
| ` 密碼: S3cr3t` | 空格（非 `\p{L}`）| 滿足 | 命中（正確）|
| 行首 `密碼: S3cr3t` | 無字元 | 滿足 | 命中（正確）|
| `mypassword_field=test` | `y`（`\p{L}`）| 不滿足 | 不命中（正確）|

### `$` 字元的 escape 處理

`NSRegularExpression.stringByReplacingMatches(withTemplate:)` 中，`$1`、`$2` 為 back-reference 語法。使用者自定義的替換 token 若包含 `$`（如 `$REDACTED`），須在使用前將 `$` 替換為 `$$`：

```swift
// Before using as template:
let escapedReplacement = userToken.replacingOccurrences(of: "$", with: "$$")
// withTemplate: "$1$2\(escapedReplacement)"
// If userToken = "$REDACTED", template becomes "$1$2$$REDACTED"
// which renders as: keyword + separator + $REDACTED
```

---

## 5. 防遞迴機制

### 問題描述

App 執行 `UIPasteboard.general.string = redactedText` 時，`changeCount` 遞增，`UIPasteboard.changedNotification` 觸發。若 App 此時仍在前景且訂閱了該通知，會觸發二次偵測（偵測 App 自己剛寫入的遮罩後文字）。

### 雙層防遞迴設計

```
Layer 1 — isAppWriting flag
    App 即將寫入剪貼簿前設為 true
    changedNotification / onBecomeActive 讀取到 true 時直接 return
    寫入完成後立即設為 false（同一個 synchronous call stack）

Layer 2 — changeCount 記錄
    寫入後立即讀取最新的 changeCount 存入 lastKnownChangeCount
    下次 onBecomeActive 時，若 changeCount 未變 → 不重新偵測
    即使 isAppWriting 在多執行緒下有微小競態，changeCount 仍會阻擋二次偵測
```

### Swift 實作

```swift
// In ClipboardInspectorViewModel

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
```

### 為何不需要 unhook/rehook

Windows 版使用 `RemoveClipboardFormatListener` → `SetText` → `AddClipboardFormatListener` 的 unhook/rehook 機制，因為 `WM_CLIPBOARDUPDATE` 是系統訊息，無法在寫入前確保不被 post。

iOS 上不存在此問題：沒有持續背景監聽，只有在 App 前景時才收到 `UIPasteboard.changedNotification`，且寫入與通知處理都在 Main Actor 的串行執行中，`isAppWriting` flag 足以防止重入。

---

## 6. UI/UX 設計

### 主畫面：Clipboard Inspector

App 進入前景時自動顯示偵測結果，不需要使用者點選任何按鈕。

#### 狀態機

```
.noMatch ──────────────────► 綠色安全狀態
.presenceMatch(keywords) ──► 警告狀態（PresenceWarningView overlay）
.kvMatch(keywords, text) ──► 確認狀態（ConfirmRedactView overlay）
.redacted ──────────────────► 成功狀態（帶「切回目標 App 貼上」提示）
```

#### SwiftUI 實作

```swift
// Features/Inspector/ClipboardInspectorView.swift
import SwiftUI

struct ClipboardInspectorView: View {
    @ObservedObject var viewModel: ClipboardInspectorViewModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ZStack {
                mainContent
                overlayContent
            }
            .navigationTitle("剪貼簿檢查")
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    viewModel.onBecomeActive()
                }
            }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        VStack(spacing: 24) {
            if viewModel.isAnalyzing {
                ProgressView("正在分析剪貼簿...")
                    .padding()
            } else {
                switch viewModel.detectionResult {
                case .noMatch:
                    SafeStatusView()

                case .redacted:
                    RedactedSuccessView {
                        viewModel.skipRedact()
                    }

                case .presenceMatch, .kvMatch:
                    // Handled by overlay
                    EmptyView()
                }
            }
            Spacer()
        }
        .padding()
    }

    @ViewBuilder
    private var overlayContent: some View {
        switch viewModel.detectionResult {
        case .kvMatch(let keywords, let redactedText):
            ConfirmRedactView(
                keywords: keywords,
                redactedText: redactedText,
                onConfirm: {
                    viewModel.confirmRedact(
                        redactedText: redactedText,
                        hitKeywords: keywords
                    )
                },
                onSkip: { viewModel.skipRedact() }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))

        case .presenceMatch(let keywords):
            PresenceWarningView(
                keywords: keywords,
                onDismiss: { viewModel.skipRedact() }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))

        default:
            EmptyView()
        }
    }
}
```

#### 各狀態 UI 說明

**noMatch — 安全狀態：**
```
[綠色 checkmark 圖示]
剪貼簿內容安全
目前無偵測到敏感關鍵字
[上次偵測時間：HH:mm]
```

**kvMatch — 確認遮罩 Overlay（全螢幕遮蓋）：**
```
[橙色警告圖示]
偵測到敏感關鍵字
命中關鍵字：password, host

遮罩預覽（前 200 字元）：
──────────────────────
Host: ***
Password: ***
──────────────────────

[取代剪貼簿]   ← 主要按鈕（藍色）
[略過]          ← 次要按鈕（灰色）
```

**presenceMatch — 警告 Overlay：**
```
[紅色警告圖示]
包含敏感關鍵字，但無法自動遮罩
命中關鍵字：pw

無法偵測到 key: value 格式。
請手動檢查後再貼上。

[了解]   ← 按鈕
```

**redacted — 成功狀態：**
```
[藍色 lock 圖示]
遮罩完成
剪貼簿已取代為遮罩後內容

請切回目標 App，以任意方式貼上。
（Command+V / 長按 → 貼上 均有效）

[完成]   ← 清除至 noMatch 狀態
```

#### ConfirmRedactView

```swift
// Features/Inspector/ConfirmRedactView.swift
import SwiftUI

struct ConfirmRedactView: View {
    let keywords: [String]
    let redactedText: String
    let onConfirm: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("偵測到敏感關鍵字", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.headline)

            Text("命中關鍵字：\(keywords.joined(separator: ", "))")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("遮罩預覽")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ScrollView {
                    Text(String(redactedText.prefix(200)))
                        .font(.system(.body, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 12) {
                Button(action: onSkip) {
                    Text("略過")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(action: onConfirm) {
                    Text("取代剪貼簿")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
        .padding()
    }
}
```

### 設定頁面（Settings）

```swift
// Features/Settings/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("監控關鍵字") {
                    KeywordListView(viewModel: viewModel)
                }

                Section("替換 Token") {
                    TextField("預設：***", text: $viewModel.replacementToken)
                        .autocorrectionDisabled()
                }

                Section("監控狀態") {
                    Toggle("暫停監控", isOn: $viewModel.isPaused)
                }
            }
            .navigationTitle("設定")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") { viewModel.save() }
                        .disabled(!viewModel.hasUnsavedChanges)
                }
            }
        }
    }
}
```

### 歷史記錄（History）

```swift
// Features/History/HistoryView.swift
import SwiftUI

struct HistoryView: View {
    @StateObject private var viewModel = HistoryViewModel()

    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.hitKeywords.joined(separator: ", "))
                                .font(.headline)
                            Spacer()
                            Text(entry.timestamp, style: .time)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.preview)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("遮罩記錄")
            .overlay {
                if viewModel.entries.isEmpty {
                    ContentUnavailableView(
                        "尚無記錄",
                        systemImage: "clock.badge.checkmark",
                        description: Text("成功遮罩的剪貼簿內容會顯示在此")
                    )
                }
            }
        }
        .task { await viewModel.load() }
    }
}
```

---

## 7. 設定持久化

使用標準 `UserDefaults`（不需要 App Groups，因為不存在跨 process 的資料共享需求）。

```swift
// Core/Storage/SettingsStore.swift
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
```

```swift
// Core/Storage/HistoryStore.swift
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
```

### SettingsViewModel

```swift
// Features/Settings/SettingsViewModel.swift
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
```

---

## 8. Info.plist 設定

### 必要欄位

```xml
<!-- Clipboard access description (iOS 14+).
     Displayed when the system determines a clipboard access explanation is needed. -->
<key>NSPasteboardUsageDescription</key>
<string>ClipAssistant 在您切回 App 時自動讀取剪貼簿，偵測敏感關鍵字並提供遮罩選項。</string>
```

### 無需額外 entitlements

由於本方案是單一 App Target，不需要：
- App Groups entitlement（無跨 process 資料共享）
- Keychain Sharing（無跨 process 憑證共享）
- Network（無網路存取）
- Push Notifications（無推播需求）

### 完整設定清單

| 設定項 | 值 | 說明 |
|---|---|---|
| `NSPasteboardUsageDescription` | 說明字串 | iOS 14+ 必填 |
| `UIApplicationSceneManifest` | 預設 Scene 設定 | SwiftUI App 需要 |
| `ITSAppUsesNonExemptEncryption` | `false` | App Store 上架需要聲明 |
| `MinimumOSVersion` | `16.0` | 使用 `PasteButton` 及 iOS 16 API |

---

## 9. 實作步驟（Sprint 分解）

### S0：Xcode 專案建立與基礎設定（前置，無依賴）

- **S0-1** 建立 Xcode 專案：`ios/ClipAssistant.xcodeproj`，Deployment Target iOS 16，SwiftUI Life Cycle，Bundle ID `com.yourcompany.clipassistant`
- **S0-2** Build Settings：`SWIFT_STRICT_CONCURRENCY = complete`，`SWIFT_VERSION = 6`
- **S0-3** 建立目錄結構：`App/`、`Features/Inspector/`、`Features/Settings/`、`Features/History/`、`Core/Detection/`、`Core/Storage/`、`Core/Models/`
- **S0-4** Info.plist：加入 `NSPasteboardUsageDescription`
- **S0-5** 加入 XCTest target，命名為 `ClipAssistantTests`

### S1：偵測核心邏輯（依賴 S0）

- **S1-1** `AppSettings.swift`、`DetectionResult.swift`、`ClipboardEntry.swift`：定義 `Sendable` 資料模型
- **S1-2** `PatternBuilder.swift`：移植 Windows `BuildPatterns` 邏輯，兩種 pattern 均支援 CJK
- **S1-3** `ClipboardDetector.swift`：`analyze(text:) -> DetectionResult`，含 `$` escape 處理
- **S1-4** `ClipAssistantTests/DetectorTests.swift`：對應 Windows 版 8 個測試案例（詳見第 10 章），XCTest
- **S1-5** 執行 `swift build -Xswiftc -strict-concurrency=complete`，確認無 Swift 6 警告

### S2：主畫面 UI（依賴 S1-1 ~ S1-3）

- **S2-1** `ClipboardInspectorViewModel.swift`：ScenePhase 觀察、changeCount 比對、防遞迴 flag
- **S2-2** `ClipboardInspectorView.swift`：狀態機 UI，四種狀態（noMatch / kvMatch / presenceMatch / redacted）
- **S2-3** `ConfirmRedactView.swift`：k-v 確認 overlay，含遮罩預覽
- **S2-4** `PresenceWarningView.swift`：presence 警告 overlay
- **S2-5** `UIPasteboard.changedNotification` 訂閱（前景補充偵測）
- **S2-6** 連接 `HistoryStore.append` 於確認遮罩後呼叫

### S3：設定頁面（依賴 S1-1）

- **S3-1** `SettingsStore.swift`：`UserDefaults.standard` 讀寫
- **S3-2** `SettingsViewModel.swift`：關鍵字 CRUD、replacement token、pause toggle
- **S3-3** `SettingsView.swift`：`Form` 結構，關鍵字清單（swipe-to-delete）+ 新增欄位
- **S3-4** `KeywordListView.swift`：抽離關鍵字清單元件

### S4：歷史記錄（依賴 S1-1、S2-6）

- **S4-1** `HistoryStore.swift`：JSON 讀寫，最多 50 筆，`actor` 隔離
- **S4-2** `HistoryViewModel.swift`：非同步載入
- **S4-3** `HistoryView.swift`：`List` 顯示，空狀態 `ContentUnavailableView`

### S5：整合測試與驗證（依賴所有 Sprint）

- **S5-1** 實機驗證完整路徑：複製敏感文字 → 開啟 App → 自動偵測 → 取代剪貼簿 → 切回目標 App 貼上
- **S5-2** 驗證防遞迴：取代後二次啟動 App，確認不誤偵測遮罩後的文字
- **S5-3** 驗證 Pause：設定頁開啟暫停 → 切換至其他 App 複製敏感文字 → 切回 → 確認顯示「監控已暫停」且不顯示偵測結果
- **S5-4** 驗證 Settings 即時生效：新增關鍵字後切換至其他 App 複製含新關鍵字文字 → 切回 → 確認新關鍵字命中
- **S5-5** 記憶體驗證：Xcode Instruments → Allocations，確認峰值符合預期（主 App 限制遠高於 Extension，但仍應避免記憶體洩漏）
- **S5-6** Swift 6 并行驗證：Build Settings `SWIFT_STRICT_CONCURRENCY = complete`，確認 zero warnings

---

## 10. 測試案例

以下 8 個測試案例對應 Windows 版 `docs/windows-monitor.md` § 7 的驗證案例，以 XCTest 形式在 `ClipAssistantTests/DetectorTests.swift` 中實作。測試只驗證 `ClipboardDetector` 的邏輯，不需要 UI 或實際剪貼簿讀取。

```swift
// ClipAssistantTests/DetectorTests.swift
import XCTest
@testable import ClipAssistant

final class DetectorTests: XCTestCase {

    private func makeDetector(
        keywords: [String] = ["host", "password", "pw", "account", "authorization"],
        replacement: String = "***"
    ) throws -> ClipboardDetector {
        try ClipboardDetector(keywords: keywords, replacement: replacement)
    }

    // -----------------------------------------------------------------------
    // Test 1 — Format 1a: multi-line plain-text k-v
    // -----------------------------------------------------------------------
    func test1_format1a_multilineKV() throws {
        let text = """
        Employee Info:
        Name: John Smith
        Department: Engineering
        PW: MyP@ssw0rd
        Email: john.smith@company.com
        """
        let detector = try makeDetector()
        guard case .kvMatch(let keywords, let redacted) = detector.analyze(text: text) else {
            XCTFail("Expected kvMatch")
            return
        }
        XCTAssertEqual(keywords, ["pw"])
        XCTAssertTrue(redacted.contains("PW: ***"))
        XCTAssertFalse(redacted.contains("MyP@ssw0rd"))
    }

    // -----------------------------------------------------------------------
    // Test 2 — Format 1b: JSON-style quoted k-v
    // -----------------------------------------------------------------------
    func test2_format1b_jsonQuotedKV() throws {
        let text = """
        "Name": "John Smith"
        "Department": "Engineering"
        "PW": "MyP@ssw0rd"
        "Email": "john.smith@company.com"
        """
        let detector = try makeDetector()
        guard case .kvMatch(let keywords, let redacted) = detector.analyze(text: text) else {
            XCTFail("Expected kvMatch")
            return
        }
        XCTAssertEqual(keywords, ["pw"])
        // Group 2 absorbs the leading quote in the separator, so result is "PW": "***"
        // The trailing " is outside group 3 and is preserved
        XCTAssertTrue(redacted.contains("\"PW\": \"***\""))
        XCTAssertFalse(redacted.contains("MyP@ssw0rd"))
    }

    // -----------------------------------------------------------------------
    // Test 3 — Format 2: multi-line with trailing commas
    // -----------------------------------------------------------------------
    func test3_format2_trailingCommas() throws {
        let text = """
        Name: John Smith,
        Department: Engineering,
        PW: MyP@ssw0rd,
        Address: 123 Main Street,
        Email: john.smith@company.com,
        """
        let detector = try makeDetector()
        guard case .kvMatch(let keywords, let redacted) = detector.analyze(text: text) else {
            XCTFail("Expected kvMatch")
            return
        }
        XCTAssertEqual(keywords, ["pw"])
        // Comma is a group-3 terminator, so "MyP@ssw0rd" is replaced, trailing comma preserved
        XCTAssertTrue(redacted.contains("PW: ***,"))
        XCTAssertFalse(redacted.contains("MyP@ssw0rd"))
    }

    // -----------------------------------------------------------------------
    // Test 4 — Format 3: single-line comma-delimited
    // -----------------------------------------------------------------------
    func test4_format3_singleLineCSV() throws {
        let text = "Name: John Smith,PW: MyP@ssw0rd,Department: Engineering,Address: 123 Main St"
        let detector = try makeDetector()
        guard case .kvMatch(let keywords, let redacted) = detector.analyze(text: text) else {
            XCTFail("Expected kvMatch")
            return
        }
        XCTAssertEqual(keywords, ["pw"])
        XCTAssertTrue(redacted.contains("PW: ***"))
        XCTAssertFalse(redacted.contains("MyP@ssw0rd"))
    }

    // -----------------------------------------------------------------------
    // Test 5 — Log with Bearer Token and multiple keywords
    // -----------------------------------------------------------------------
    func test5_logWithBearerTokenMultiKeyword() throws {
        let text = """
        2024-01-15 10:23:45 INFO [api-gateway] Request started
        method: POST
        path: /api/v1/users
        Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.signature
        host: api.internal.company.com
        status: 200
        """
        let detector = try makeDetector()
        guard case .kvMatch(let keywords, let redacted) = detector.analyze(text: text) else {
            XCTFail("Expected kvMatch")
            return
        }
        XCTAssertEqual(keywords, ["authorization", "host"])
        // Bearer scheme prefix is absorbed into group 2, token body is group 3
        XCTAssertTrue(redacted.contains("Authorization: Bearer ***"))
        XCTAssertTrue(redacted.contains("host: ***"))
        XCTAssertFalse(redacted.contains("eyJhbGci"))
        XCTAssertFalse(redacted.contains("api.internal.company.com"))
    }

    // -----------------------------------------------------------------------
    // Test 6 — Format 4 table: presence match only, no redaction
    // -----------------------------------------------------------------------
    func test6_format4_tablePresenceOnly() throws {
        let text = """
        Employee Report 2024-01
        Name       PW          Address
        John       MyP@ssw0rd  123 Main St
        Jane       S3cr3t!     456 Oak Ave
        """
        let detector = try makeDetector()
        guard case .presenceMatch(let keywords) = detector.analyze(text: text) else {
            XCTFail("Expected presenceMatch — table headers have no k-v separator structure")
            return
        }
        XCTAssertEqual(keywords, ["pw"])
    }

    // -----------------------------------------------------------------------
    // Test 7 — Negative: word boundary blocks substring matches
    // -----------------------------------------------------------------------
    func test7_negative_wordBoundaryBlocks() throws {
        let text = """
        hostname=webserver01
        mypassword_field=test
        accountType=premium
        """
        let detector = try makeDetector()
        // "hostname" starts with "host" but preceded by nothing — however "hostname" has
        // no separator after "host"; the full word is matched. Let's verify actual behavior:
        // "hostname=webserver01": "host" is followed by "name" (\p{L}), so (?!\p{L}) blocks it.
        // "mypassword_field=test": "m" precedes "password", so (?<!\p{L}) blocks it.
        // "accountType=premium": "account" preceded by nothing but "Type" follows (\p{L}),
        //   so (?!\p{L}) blocks presence; for k-v, "accountType=" is not matched because
        //   after "account" comes "T" which is \p{L}, blocking the lookahead.
        XCTAssertEqual(detector.analyze(text: text), .noMatch)
    }

    // -----------------------------------------------------------------------
    // Test 8 — Real-world mix: connection string + error message
    // -----------------------------------------------------------------------
    func test8_realWorldConnectionStringPlusError() throws {
        let text = """
        Connection Failed - Debug Info:
        Host: db.internal.company.com,
        Account: service_account_prod,
        Password: Db$3cr3tP@ss,
        Port: 5432,
        Database: production_db

        Last error: FATAL: password authentication failed for user "service_account_prod"
        """
        let detector = try makeDetector()
        guard case .kvMatch(let keywords, let redacted) = detector.analyze(text: text) else {
            XCTFail("Expected kvMatch")
            return
        }
        // "password authentication" has no separator after "password", so that line
        // does not produce a k-v match — presence pattern would catch it but k-v wins first.
        XCTAssertEqual(keywords, ["account", "host", "password"])
        XCTAssertTrue(redacted.contains("Host: ***"))
        XCTAssertTrue(redacted.contains("Account: ***"))
        XCTAssertTrue(redacted.contains("Password: ***"))
        // "password authentication failed" line: no k-v separator, so "password" in that
        // line is not replaced — this is the same behavior as Windows version
        XCTAssertTrue(redacted.contains("password authentication failed"))
        XCTAssertFalse(redacted.contains("db.internal.company.com"))
        XCTAssertFalse(redacted.contains("service_account_prod,"))   // comma-terminated line
        XCTAssertFalse(redacted.contains("Db$3cr3tP@ss"))
    }

    // -----------------------------------------------------------------------
    // Test 9 — $ in replacement token (back-reference escape)
    // -----------------------------------------------------------------------
    func test9_dollarSignInReplacement() throws {
        let text = "password: secret123"
        let detector = try ClipboardDetector(keywords: ["password"], replacement: "$REDACTED")
        guard case .kvMatch(_, let redacted) = detector.analyze(text: text) else {
            XCTFail("Expected kvMatch")
            return
        }
        // If $ is not escaped, "$R" would be interpreted as back-reference to group R (invalid),
        // resulting in empty string or crash. Correct output: "password: $REDACTED"
        XCTAssertTrue(redacted.contains("password: $REDACTED"))
    }

    // -----------------------------------------------------------------------
    // Test 10 — CJK keyword boundary
    // -----------------------------------------------------------------------
    func test10_cjkKeywordBoundary() throws {
        let hit = " 密碼: S3cr3t!"
        let miss = "test密碼=secret"

        let detector = try ClipboardDetector(keywords: ["密碼"], replacement: "***")

        guard case .kvMatch = detector.analyze(text: hit) else {
            XCTFail("Expected kvMatch for CJK keyword with valid separator")
            return
        }
        XCTAssertEqual(detector.analyze(text: miss), .noMatch)
    }
}
```

### iOS App 清洗站情境下的驗證方式

上述 Unit Tests 驗證偵測邏輯。整合驗證步驟（搭配 S5 Sprint）：

| 測試案例 | 驗證方式 |
|---|---|
| 測試 1 ~ 5（kvMatch）| 複製對應文字 → 切換至 ClipAssistant → 確認顯示 ConfirmRedactView，命中關鍵字與 Windows 版一致 → 點「取代剪貼簿」→ 切回任意文字編輯 App 貼上，確認 `***` 存在 |
| 測試 6（presenceMatch）| 複製 table 文字 → 切換至 ClipAssistant → 確認顯示 PresenceWarningView，不提供取代按鈕 |
| 測試 7（Negative）| 複製 `hostname=webserver01` 等文字 → 切換至 ClipAssistant → 確認顯示「剪貼簿內容安全」狀態，無任何 overlay |
| 測試 8（混合）| 複製連線字串 → 切換 → 確認三個關鍵字均命中，`password authentication` 那行不被替換 |

---

## 11. 已知限制

### 11.1 保護範圍：使用者主動觸發才有效

本 App 的保護邊界是「使用者複製後主動開啟 App，確認遮罩，再切回貼上」。若使用者跳過 App 直接從任意 App 貼上剪貼簿，本 App 無能力攔截。這是 iOS Sandbox 的根本設計，無任何 workaround。

Windows 版提供事件驅動的透明監聽（`AddClipboardFormatListener`）；iOS 版提供的是工具式清洗流程。兩者保護強度不同，需在 App 說明中誠實告知使用者。

### 11.2 App Suspend 期間無偵測能力

App 切換至背景後，`UIPasteboard.changedNotification` 停止接收，沒有任何 Background Task API 可以週期性監聽剪貼簿。若使用者在 App suspend 期間複製了新的敏感資料，App 無法感知，直到下次切回前景才偵測。

### 11.3 iOS 14/15 的隱私橫幅（若需降級支援）

若 Deployment Target 放寬至 iOS 14/15，`sceneDidBecomeActive` 時讀取 `UIPasteboard.general.string` 可能觸發系統黃色橫幅（「某 App 貼上了來自 XXX 的內容」）。此橫幅無法透過任何 API 關閉，屬系統強制行為。

推薦解法：維持 iOS 16 為 Minimum Deployment Target，或在 iOS 14/15 上改為按鈕觸發讀取，同時在 UI 告知使用者橫幅為正常現象。

### 11.4 值含空格的截斷限制（與 Windows 版相同）

Group 3 的值以逗號、whitespace、分號、`&` 為終止邊界。`password: my secret` 只遮罩 `my`，`secret` 保留。此為兩平台一致的已知限制，設計取捨：支援空格邊界會使 false positive 率急遽上升（幾乎所有英文句子都會被截斷）。

### 11.5 CJK 邊界的特殊 edge case

`(?<!\p{L})` / `(?!\p{L})` 正確處理 CJK 關鍵字，但有一個 edge case：若關鍵字與值之間連接的字元是非 `\p{L}` 的 Unicode 字元（如全形標點 `：`），group 2 的 `[:=]` 無法匹配全形冒號。需要支援全形分隔符的使用者應在關鍵字清單中另行處理，或在 `PatternBuilder` 中加入全形字元的 alternation（v1 不實作）。

### 11.6 剪貼簿只含純文字

本 App 只讀取 `UIPasteboard.general.string`，不處理圖片、URL、`NSAttributedString` 等其他格式。若使用者從 Safari 複製一段帶格式文字，純文字部分正常偵測，格式部分不影響（寫回遮罩後的純文字會覆蓋所有格式）。此行為與 Windows 版 `Clipboard.GetText()` / `SetText()` 一致，為已知設計取捨。

### 11.7 `sceneDidBecomeActive` 的橫幅行為不保證

Apple 文件未明確保證 `sceneDidBecomeActive` 時的剪貼簿讀取「永遠不觸發橫幅」。未來 iOS 版本可能調整此判斷邏輯。若發生此情況，降級策略是改為在主畫面顯示「點此檢查」按鈕（使用者手勢明確觸發，橫幅觸發概率極低）。

### 11.8 changeCount 比對的 TOCTOU 窗口

`lastKnownChangeCount` 在讀取 `changeCount` 後、讀取 `string` 前存在極小的時間窗口，此期間若另一個 App 改變剪貼簿，讀取到的 `string` 可能與記錄的 `changeCount` 對應的內容不同。此窗口在正常使用下影響可接受，不影響安全性（遮罩行為是使用者確認後才執行）。

### 11.9 無全域熱鍵機制

iOS 不提供系統級全域熱鍵。Windows 版的 `Ctrl+Alt+Q` 無對應設計。暫停 / 恢復功能由設定頁面的 Toggle 控制。若需要快速暫停，可考慮 Home Screen Widget（v2 計劃）。
