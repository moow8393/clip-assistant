# Clip Assistant

跨平台剪貼簿監控工具，偵測敏感關鍵字並在貼上前提示遮罩其值。自動背景偵測功能僅限 Windows 版本。

> For English documentation, see [README.md](README.md)

---

## 平台支援

| 平台 | 狀態 | 原始碼 |
|------|------|--------|
| Windows | ✅ 已實作 | [windows/src/](windows/src/) |
| iOS | ⏸ 暫緩 | [ios/ClipAssistant/](ios/ClipAssistant/) |

快速跳轉：
- [Windows — 使用說明](#windows--使用說明)
- [Windows — 開發說明](#windows--開發說明)
- [iOS — 開發說明](#ios--開發說明)（暫緩）

---

## 功能簡介

![Demo](images/demo.gif)

複製含有敏感鍵值對的文字（連線字串、log、設定檔片段）時，Clip Assistant 攔截剪貼簿事件，提示你在貼上前遮罩敏感值。

**範例：** 複製 `host: db.prod.internal, password: S3cr3t!` → 彈出對話框 → 點擊 **Replace** → 剪貼簿變為 `host: ***, password: ***`。

兩種偵測模式：
- **k-v 遮罩** — 關鍵字後接 `:` 或 `=` 且有值 → 自動替換
- **存在警告** — 偵測到關鍵字但無法解析鍵值結構（如表格標題）→ 警示手動確認

---

## 快速驗證範例

將以下各輸入複製後觸發偵測，確認工具運作正常。

### k-v 遮罩 — 連線字串

```
Host: db.prod.internal, Password: S3cr3tP@ss, Account: service_user
```

預期輸出：`Host: ***, Password: ***, Account: ***`
`host`、`password`、`account` 同時命中；值被替換，鍵名與分隔符保留。

### k-v 遮罩 — HTTP log 含 Bearer Token

```
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.sig
host: api.internal.company.com
```

預期輸出：`Authorization: Bearer ***` 與 `host: ***`
`Bearer` scheme 前綴視為分隔符的一部分而保留，只有 token 值被遮罩。

### k-v 遮罩 — JSON 物件

```json
{
  "name": "John Smith",
  "password": "MyP@ssw0rd",
  "email": "john.smith@company.com"
}
```

預期輸出：`"password": "***"`
支援帶引號的鍵值格式。值前的 `"` 被吸收進分隔符，值後的 `"` 保留，維持合法的 JSON 結構。

### 存在警告 — 表格標題

```
Name       PW          Address
John       MyP@ssw0rd  123 Main St
Jane       S3cr3t!     456 Oak Ave
```

預期：**警告**（不遮罩）。`pw` 出現在欄位標題，後面沒有 `:` 或 `=` 分隔符，工具無法安全判斷要替換哪個值，因此改為警示，請手動確認。

### 無命中 — 詞界保護

```
hostname=webserver01
mypassword_field=test
```

預期：**無提示**。`hostname` 包含 `host`，但緊接著字母 `n`，詞界保護阻擋命中；`mypassword` 前面有字母 `my`，同樣被阻擋。

### CJK 關鍵字

將 `密碼` 設為關鍵字後複製：

```
密碼: S3cr3t!
```

預期輸出：`密碼: ***`
CJK 關鍵字使用 Unicode letter lookbehind/lookahead 取代 `\b`，因此 `test密碼=secret` 正確地**不**命中，而 ` 密碼: S3cr3t!` 會被遮罩。

---

## Windows — 使用說明

### 系統需求

- Windows Vista 以上（建議 Windows 11）
- [Node.js](https://nodejs.org/)（用於 build script）
- .NET Framework 4.x（Windows 內建，提供 `csc.exe`）

### 安裝

```powershell
git clone <repo-url>
cd clip-assistant
npm run build:win       # 編譯 ClipAssistant.exe
npm run setup:win       # 建立桌面捷徑（只需執行一次）
```

### 日常使用

直接雙擊 `windows/ClipAssistant.exe`，或使用桌面捷徑（`npm run setup:win` 建立）。系統列出現藍底鎖頭圖示，程式開始靜默監控剪貼簿。

| 操作 | 方式 |
|------|------|
| 暫停監控 | 右鍵托盤 → **Pause Monitoring** |
| 恢復監控 | 右鍵托盤 → **Resume Monitoring** |
| 修改關鍵字 / 替換字元 | 右鍵托盤 → **Settings…**（或雙擊圖示）|
| 退出 | 右鍵托盤 → **Exit**，或按 **Ctrl+Alt+Q** |

Settings 儲存後立即生效，不需重啟。

### 設定檔

兩個設定檔與 `ClipAssistant.exe` 放在同一目錄（`windows/`），可直接編輯或透過 Settings 對話框管理。

**`blacklist.txt`** — 每行一個關鍵字，不分大小寫，`#` 開頭為註解。

```
# 預設關鍵字
host
password
pw
account
authorization
```

**`replacement.txt`** — 遮罩後的替換字元，預設 `***`。

```
***
```

檔案缺失或為空時自動套用內建預設值。

---

## Windows — 開發說明

### 架構概覽

Windows 版本為單一 C# 5 / .NET Framework 4.x WinForms 應用程式，以 `csc.exe` 編譯為無 console 視窗的 `winexe` 執行檔。

```
Program（進入點）
  └─ MonitorContext（ApplicationContext）
       ├─ NotifyIcon  — 系統列圖示，托盤選單（Pause / Settings / Exit）
       └─ ClipboardMonitor（NativeWindow）
            ├─ AddClipboardFormatListener  — 接收 WM_CLIPBOARDUPDATE
            ├─ RegisterHotKey              — Ctrl+Alt+Q 退出快捷鍵
            ├─ _kvPattern (Regex)          — 關鍵字 + 分隔符 + 值
            └─ _presencePattern (Regex)    — 關鍵字邊界 fallback
```

[windows/src/Program.cs](windows/src/Program.cs) 中的主要類別：

| 類別 | 職責 |
|------|------|
| `ClipboardMonitor` | 隱藏 `NativeWindow`；處理 `WM_CLIPBOARDUPDATE` 與 `WM_HOTKEY` |
| `MonitorContext` | `ApplicationContext`，串接監控器、托盤圖示與選單 |
| `ConfirmForm` | TopMost modal，提示使用者替換偵測到的敏感值 |
| `WarningForm` | TopMost 通知，偵測到關鍵字但無 k-v 結構時顯示 |
| `SettingsForm` | 設定對話框；寫入 `blacklist.txt` + `replacement.txt` |
| `Program` | `[STAThread]` 進入點；載入設定檔，執行訊息迴圈 |

**防遞迴機制（雙層）**

寫入剪貼簿會觸發新的 `WM_CLIPBOARDUPDATE`，兩層保護避免無限迴圈：

1. **Unhook/rehook** — `SetText` 前先 `RemoveClipboardFormatListener`，寫入完成後再 `AddClipboardFormatListener`，讓自身寫入對監控器不可見。
2. **`_dialogOpen` 旗標** — `ShowDialog` 內部仍 pump 訊息迴圈，快速連續複製可能排隊多個事件；旗標確保這些事件被丟棄，不堆疊對話框。

**Regex 規則**

k-v pattern（簡化）：
```
(?<!\p{L})(keyword1|keyword2|...)("?\s*[:=]\s*"?(?:Bearer\s+|Basic\s+)?)([^",\s;&]+)
```
Group 1 = 關鍵字（保留），Group 2 = 分隔符（保留），Group 3 = 值（替換）。

Presence pattern（fallback）：
```
(?<!\p{L})(keyword1|keyword2|...)(?!\p{L})
```

`(?<!\p{L})` / `(?!\p{L})` 為 Unicode letter lookbehind/lookahead，取代原本的 `\b`。原因：.NET 的 `\b` 僅適用 ASCII，CJK 字元屬 `\W`，無 `\w/\W` 轉換，導致行首的中文關鍵字無法命中。新邊界同時保護 substring（如 `test密碼=secret` 不會命中關鍵字 `密碼`）。

### 建置與測試

```powershell
npm run build:win       # 編譯 → windows/ClipAssistant.exe
npm run test:win        # 執行 Pester 測試 windows/tests/
```

exe 為 build artifact，已加入 `.gitignore`。Clone 後務必先執行 `build:win`。

**編譯器限制：** 使用 .NET Framework 4.x 的 `csc.exe`，語言版本為 **C# 5**。請勿使用 C# 6+ 語法（null-conditional `?.`、字串插值 `$"..."`、expression-bodied members）。

### 關鍵檔案

| 路徑 | 說明 |
|------|------|
| [windows/src/Program.cs](windows/src/Program.cs) | Windows 完整實作（約 730 行）|
| [windows/blacklist.txt](windows/blacklist.txt) | 啟動時載入的關鍵字清單 |
| [windows/replacement.txt](windows/replacement.txt) | 替換字元 |
| [windows/create-shortcut.ps1](windows/create-shortcut.ps1) | 桌面捷徑建立腳本 |
| [windows/tests/ClipAssistant.Tests.ps1](windows/tests/ClipAssistant.Tests.ps1) | Pester 測試套件 |
| [docs/windows-monitor.md](docs/windows-monitor.md) | 詳細設計文件 |

---

## iOS — 開發說明

> **狀態：暫緩。** 核心邏輯與 CI 已完成，但真機測試因成本考量暫緩推進（需 Apple Developer 帳號或每 7 天重新簽署）。程式碼保留於 repo，待日後恢復開發。

### 架構概覽

```
ClipAssistantApp (@main)
  └─ ContentView（TabView）
       ├─ ClipboardInspectorView  — Tab 1：偵測與遮罩
       │    └─ ClipboardInspectorViewModel（@MainActor）
       │         ├─ UIPasteboard.changedNotification  — 前景剪貼簿變更
       │         ├─ ScenePhase.active                 — App 回到前景
       │         ├─ ClipboardDetector                 — Regex 偵測（Swift 6 Sendable）
       │         └─ HistoryStore                      — 寫入遮罩記錄
       ├─ HistoryView             — Tab 2：遮罩記錄
       │    └─ HistoryViewModel（@MainActor）
       └─ SettingsView            — Tab 3：關鍵字與替換字元
            └─ SettingsViewModel（@MainActor）
```

### 為什麼沒有自動偵測

Windows 可透過 `WM_CLIPBOARDUPDATE` 在背景靜默監控——不需要使用者介入。iOS 沒有對應機制：

- 背景 App 讀取 `UIPasteboard` 會觸發系統隱私橫幅（iOS 14+）
- `UIPasteboard.changedNotification` 只在 App 處於前景時發送
- App Store 沙盒不開放第三方 App 取得背景剪貼簿存取權

因此 iOS 版偵測設計為**前景觸發**：由 `ScenePhase.active`（App 切回前景）與 `UIPasteboard.changedNotification`（前景時剪貼簿變更）共同驅動。

### 建置與測試

測試在 GitHub Actions 執行（macOS-15、Xcode 16.4、iPhone 16 模擬器）：

```
.github/workflows/ios.yml
  ├─ test      — xcodebuild test on iOS Simulator（每次 push / PR）
  └─ build-ipa — 產出未簽署 IPA artifact（僅 push to main，測試通過後執行）
```

本機建置需要 Mac + Xcode 16+：

```bash
xcodebuild test \
  -project ios/ClipAssistant.xcodeproj \
  -scheme ClipAssistant \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

### 關鍵檔案

| 路徑 | 說明 |
|------|------|
| [ios/ClipAssistant/App/](ios/ClipAssistant/App/) | App 進入點與根 `ContentView` |
| [ios/ClipAssistant/Core/Detection/](ios/ClipAssistant/Core/Detection/) | `ClipboardDetector`、`PatternBuilder` — 共用 Regex 邏輯 |
| [ios/ClipAssistant/Core/Storage/](ios/ClipAssistant/Core/Storage/) | `HistoryStore`、`SettingsStore` — JSON 持久化（`FileManager`）|
| [ios/ClipAssistant/Features/](ios/ClipAssistant/Features/) | `Inspector`、`History`、`Settings` — SwiftUI 介面與 ViewModel |
| [ios/ClipAssistantTests/DetectorTests.swift](ios/ClipAssistantTests/DetectorTests.swift) | 10 個單元測試，涵蓋 Regex、CJK 邊界、`$` 跳脫 |
| [docs/ios-app-cleaning-station.md](docs/ios-app-cleaning-station.md) | 設計文件 |

---

## 已知限制

- 值含空格（如 `password: my secret`）— 僅遮罩第一個詞
- 純文字以外的剪貼簿格式（RTF、HTML、圖片）不處理；替換後剪貼簿降格為純文字
- `Ctrl+Alt+Q` 若被其他程式佔用，熱鍵註冊失敗，請改用托盤選單退出
- 中文關鍵字已支援；邊界採用 `(?<!\p{L})` / `(?!\p{L})`，ASCII 與中文關鍵字均可正確偵測與阻擋 substring

---

## 授權

ISC
