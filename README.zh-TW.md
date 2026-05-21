# Clip Assistant

跨平台剪貼簿監控工具，自動偵測敏感關鍵字並在貼上前提示遮罩其值。

> For English documentation, see [README.md](README.md)

---

## 平台支援

| 平台 | 狀態 | 原始碼 |
|------|------|--------|
| Windows | ✅ 已實作 | [windows/src/](windows/src/) |
| iOS | 🚧 開發中 | — |

快速跳轉：
- [Windows — 使用說明](#windows--使用說明)
- [Windows — 開發說明](#windows--開發說明)
- [iOS — 開發說明](#ios--開發說明)

---

## 功能簡介

複製含有敏感鍵值對的文字（連線字串、log、設定檔片段）時，Clip Assistant 攔截剪貼簿事件，提示你在貼上前遮罩敏感值。

**範例：** 複製 `host: db.prod.internal, password: S3cr3t!` → 彈出對話框 → 點擊 **Replace** → 剪貼簿變為 `host: ***, password: ***`。

兩種偵測模式：
- **k-v 遮罩** — 關鍵字後接 `:` 或 `=` 且有值 → 自動替換
- **存在警告** — 偵測到關鍵字但無法解析鍵值結構（如表格標題）→ 警示手動確認

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
npm run test:win        # 執行 Pester 測試 tests/windows/
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
| [tests/windows/ClipAssistant.Tests.ps1](tests/windows/ClipAssistant.Tests.ps1) | Pester 測試套件 |
| [docs/windows-monitor.md](docs/windows-monitor.md) | 詳細設計文件 |

---

## iOS — 開發說明

> **狀態：尚未實作。**
> 本章節為 iOS 版本預留位置。

iOS 版本將實作相同概念，監控剪貼簿變更並提示使用者遮罩敏感值。

### 規劃方向

```
npm run info:ios        # 顯示：Please open ./ios/ClipAssistant.xcodeproj in Xcode (Mac Required)
```

實作細節（待開發後補充）：

- 平台：iOS 16+
- 語言：Swift 6 / SwiftUI
- 進入點：`ios/` 目錄
- 建置：需要 Xcode（Mac 環境）

---

## 已知限制

- 值含空格（如 `password: my secret`）— 僅遮罩第一個詞
- 純文字以外的剪貼簿格式（RTF、HTML、圖片）不處理；替換後剪貼簿降格為純文字
- `Ctrl+Alt+Q` 若被其他程式佔用，熱鍵註冊失敗，請改用托盤選單退出
- 中文關鍵字已支援；邊界採用 `(?<!\p{L})` / `(?!\p{L})`，ASCII 與中文關鍵字均可正確偵測與阻擋 substring

---

## 授權

ISC
