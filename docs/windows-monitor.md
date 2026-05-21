# Windows Clipboard Monitor — 設計文件

## 1. 概述

`windows/src/Program.cs` 是一個事件驅動的剪貼簿監聽應用程式，編譯為 `windows/ClipAssistant.exe`，用於偵測黑名單關鍵字並遮罩其值。

**啟動方式**

```
# 建置（需要 .NET Framework 4.x csc.exe）
npm run build:win

# 建立桌面捷徑（執行一次）
npm run setup:win

# 之後直接雙擊桌面捷徑或執行 exe
windows/ClipAssistant.exe
```

程式啟動後會在系統列顯示藍底鎖頭圖示（Tooltip：`Clip Assistant - Active`），靜默監聽剪貼簿，直到使用者透過熱鍵或系統列選單退出。

**使用情境**：貼出剪貼簿前自動遮罩敏感資訊（密碼、host、帳號等），避免含有 `password=secret` 或 `host: 192.168.1.1` 等敏感資料的文字被直接貼到其他工具。

---

## 2. 架構

### 類別圖

```
Program (internal, static)
  │  DefaultKeywords: string[]  { "host", "password", "pw", "account", "authorization" }
  │  DefaultReplacement: string "***"
  │
  ├─ [STAThread] Main():
  │       LoadKeywords(baseDir) → string[]
  │       LoadReplacement(baseDir) → string
  │       Application.Run(new MonitorContext(...))
  ├─ LoadKeywords(baseDir): parses blacklist.txt; skips blanks/#comments; case-insensitive dedup
  │       → falls back to DefaultKeywords when file missing or yields no entries
  └─ LoadReplacement(baseDir): reads replacement.txt (trimmed)
          → falls back to DefaultReplacement when file missing or empty

ClipboardMonitor : NativeWindow, IDisposable
  │  const WM_CLIPBOARDUPDATE  = 0x031D
  │  const WM_HOTKEY           = 0x0312
  │  const HOTKEY_ID           = 0xB001
  │  _kvPattern: Regex         (keyword + separator + value; enables redaction)
  │  _presencePattern: Regex   (keyword word-boundary only; fallback warning)
  │  _replacementForRegex: string  ("$" doubled to prevent back-reference in Regex.Replace)
  │  bool _dialogOpen
  │  bool Paused               (property; when true, WM_CLIPBOARDUPDATE events are ignored)
  │  string[] Keywords         (read-only snapshot; updated by UpdateConfig)
  │  string   Replacement      (raw replacement token; updated by UpdateConfig)
  │  event EventHandler ExitRequested
  │
  ├─ ctor(string[] keywords, string replacement):
  │       Clone keywords → Keywords/Replacement → _replacementForRegex
  │       → BuildPatterns → CreateHandle
  │       → AddClipboardFormatListener → RegisterHotKey
  ├─ BuildPatterns(string[] keywords): builds _kvPattern + _presencePattern
  ├─ UpdateConfig(string[] keywords, string replacement):
  │       hot-reload keywords and replacement; rebuilds both Regex objects
  ├─ WndProc: WM_CLIPBOARDUPDATE → HandleClipboard() (skipped when Paused)
  │           WM_HOTKEY          → ExitRequested (if not null)
  ├─ HandleClipboard:
  │     Paused = true → return immediately
  │     Branch 1 (_kvPattern matches):
  │       collect hit keywords → _dialogOpen=true → ConfirmForm.ShowDialog
  │       → (OK) redact via _kvPattern.Replace → unhook → SetText → rehook
  │     Branch 2 (_presencePattern matches, no k-v):
  │       collect hit keywords → _dialogOpen=true → WarningForm.ShowDialog
  └─ Dispose: UnregisterHotKey → RemoveClipboardFormatListener → DestroyHandle

ConfirmForm : Form
  │  TopMost=true, FixedDialog, ShowInTaskbar=false
  ├─ ctor(string keywordsSummary): label shows detected keyword names
  ├─ Replace 按鈕 → DialogResult.OK  (AcceptButton)
  └─ Cancel 按鈕  → DialogResult.Cancel (CancelButton)

WarningForm : Form
  │  TopMost=true, FixedDialog, ShowInTaskbar=false
  ├─ ctor(string keywordsSummary): informs user that automatic redaction is not possible
  └─ OK 按鈕 → DialogResult.OK (AcceptButton)

SettingsForm : Form
  │  TopMost=false, FixedDialog, ShowInTaskbar=true, CenterScreen
  │  ClientSize=(430,340)
  │  _keywordList: ListBox (SelectionMode.One, Sorted=false)
  │  _newKeywordBox: TextBox (Enter key triggers Add)
  │  _replacementBox: TextBox
  │  _configDir: string (path to write blacklist.txt + replacement.txt)
  │  UpdatedKeywords: string[]    (populated on Save)
  │  UpdatedReplacement: string   (populated on Save)
  ├─ ctor(string[] currentKeywords, string currentReplacement, string configDir)
  ├─ Add: trim + case-insensitive dedup → add to ListBox
  ├─ Remove Selected: removes currently selected ListBox item (no-op if none)
  ├─ Save: validate (≥1 keyword) → WriteConfigFiles → set Updated* → DialogResult.OK
  └─ WriteConfigFiles: blacklist.txt (UTF-8 no BOM, comment header) + replacement.txt

MonitorContext : ApplicationContext
  │  _monitor: ClipboardMonitor
  │  _tray: NotifyIcon
  │  _trayIcon: Icon             (GDI+ drawn 16x16 lock icon; disposed on exit)
  │  _pauseMenuItem: ToolStripMenuItem  (text toggles between Pause/Resume)
  │  _configDir: string
  ├─ ctor(string[] keywords, string replacement, string configDir)
  │     tray menu: [Pause Monitoring] ─── [Settings...] ─── [Exit]
  │     tray.DoubleClick → OnSettings
  │     tray.Text = "Clip Assistant - Active"
  ├─ CreateLockIcon(): draws 16x16 padlock (blue bg, white shackle+body, blue keyhole)
  ├─ OnPauseToggle: _monitor.Paused ↔ true/false; update menu text + tooltip
  ├─ OnSettings: show SettingsForm; on OK → _monitor.UpdateConfig(...)
  ├─ monitor.ExitRequested → ExitThread()
  └─ Dispose(bool): tray.Visible=false → tray.Dispose() → trayIcon.Dispose() → monitor.Dispose()
```

### 訊息流

```
[剪貼簿變更]
    │
    ▼
user32.dll 發送 WM_CLIPBOARDUPDATE (posted)
    │
    ▼
ClipboardMonitor.WndProc
    │
    ├─ _dialogOpen = true? → 丟棄
    │
    └─ HandleClipboard()
           │
           ├─ Paused = true? → return (無任何 dialog)
           ├─ Clipboard.GetText()  [ExternalException → return]
           ├─ string.IsNullOrEmpty → return
           │
           ├─ [Branch 1] _kvPattern.Matches(text).Count > 0
           │       ├─ 收集命中關鍵字 → 組合 summary 字串
           │       ├─ _dialogOpen = true
           │       ├─ ConfirmForm.ShowDialog(summary)
           │       │       ├─ Cancel → return
           │       │       └─ OK:
           │       │             redacted = _kvPattern.Replace(text, "$1$2" + _replacementForRegex)
           │       │             RemoveClipboardFormatListener
           │       │             Clipboard.SetText(redacted)
           │       │             AddClipboardFormatListener
           │       └─ _dialogOpen = false → return
           │
           └─ [Branch 2] _presencePattern.Matches(text).Count > 0
                   ├─ 收集命中關鍵字 → 組合 summary 字串
                   ├─ _dialogOpen = true
                   ├─ WarningForm.ShowDialog(summary)  [OK only, no redaction]
                   └─ _dialogOpen = false

[Ctrl+Alt+Q 或 tray Exit]
    │
    ▼
WM_HOTKEY / Click → ExitRequested → ApplicationContext.ExitThread()
    │
    ▼
Application.Run() 返回 → finally → context.Dispose()

[tray Pause Monitoring]
    │
    ▼
OnPauseToggle → _monitor.Paused = true → menu text = "Resume Monitoring"
              → _tray.Text = "Clip Assistant - Paused"

[tray Settings... 或 tray DoubleClick]
    │
    ▼
OnSettings → SettingsForm.ShowDialog()
    ├─ Cancel → 不做任何變更
    └─ OK → SettingsForm.WriteConfigFiles()（寫入 blacklist.txt + replacement.txt）
              → _monitor.UpdateConfig(keywords, replacement)
                    → Clone → Keywords / Replacement / _replacementForRegex
                    → BuildPatterns（重新編譯 Regex，立即生效）
```

### 進入點

`Program.Main()` — C# 原生進入點：

1. `[STAThread]` attribute 確保 STA 執行環境（WinForms / Clipboard 必要條件）
2. `LoadKeywords(baseDir)` — 讀取 `blacklist.txt`；缺失或為空則使用內建預設
3. `LoadReplacement(baseDir)` — 讀取 `replacement.txt`；缺失或為空則使用 `***`
4. `Application.Run(new MonitorContext(keywords, replacement, baseDir))` — 阻塞直到 `ExitThread()` 被呼叫
5. `finally` 區塊確保 `context.Dispose()` 清理資源

config 檔路徑以 `AppDomain.CurrentDomain.BaseDirectory` 解析，即 exe 所在目錄。

---

## 3. 防遞迴機制

替換剪貼簿內容本身會觸發新的 `WM_CLIPBOARDUPDATE`，若不加以防護會造成無限遞迴。本程式採用雙層保險：

### 第一層：unhook / rehook

```
RemoveClipboardFormatListener(Handle)
↓
Clipboard.SetText(regex.Replace(text, ...))   // 此寫入不會產生 WM_CLIPBOARDUPDATE（已 unhook）
↓
AddClipboardFormatListener(Handle)             // 恢復監聽
```

`WM_CLIPBOARDUPDATE` 是 *posted* 訊息（非 sent）。由於整個流程在單執行緒訊息迴圈中進行，unhook 後 Windows 不會再 post 新事件給本視窗，且本 handler 執行期間訊息迴圈無法處理其他訊息，因此 unhook → SetText → rehook 之間不會有殘留事件進入佇列。

### 第二層：`_dialogOpen` 旗標

`ShowDialog()` 雖然是 modal，但其內部仍會 pump 訊息迴圈。若使用者在對話框開啟期間再次複製包含敏感關鍵字的內容，`WM_CLIPBOARDUPDATE` 會被 post 並排隊，等到 `ShowDialog` 返回後處理。`_dialogOpen` 旗標確保這些排隊事件被丟棄，防止對話框堆疊。

**為何兩層都需要**：
- 第一層防止「程式自身寫入剪貼簿」觸發遞迴
- 第二層防止「使用者快速連續複製」堆疊多個對話框

---

## 4. 格式策略與遮罩規則

**只處理純文字（`Clipboard.GetText()`）**，原因如下：

- `GetText()` 涵蓋 `Text`、`UnicodeText`、`OemText` 三種純文字格式，足以涵蓋絕大多數使用情境
- 圖片、檔案清單、RTF、HTML 格式：`GetText()` 回傳空字串或無關內容，靜默忽略
- 替換時使用 `Clipboard.SetText(string)`，預設格式為 `UnicodeText`

**取捨說明**：若原始剪貼簿同時含有 RTF 或 HTML 格式，按下 Replace 後剪貼簿只剩純文字遮罩結果，RTF/HTML 格式版本會遺失。此為已知設計取捨，因為本工具的目的是遮罩敏感資料，不是保留原始排版。

### 遮罩規則

**k-v pattern**（動態組合，每次啟動從 `blacklist.txt` 讀取）：

```
\b(KW1|KW2|...)("?\s*[:=]\s*"?(?:Bearer\s+|Basic\s+)?)([^",\s;&]+)
```

- `(?i)` — `RegexOptions.IgnoreCase`：不分大小寫，`Password` 與 `PASSWORD` 皆命中
- `\b` — word boundary：防止 substring 誤命中（如 `mypassword` 不會被 `password` 規則命中）
- Group 1 `(KW1|KW2|...)` — 關鍵字本身
- Group 2 `("?\s*[:=]\s*"?(?:Bearer\s+|Basic\s+)?)` — 分隔符，可選前置 `"`、可選後置 `"`、可選 Auth scheme 前綴（`Bearer ` 或 `Basic `）
- Group 3 `([^",\s;&]+)` — 值，終止於雙引號、逗號、whitespace、分號、`&`
- 替換式 `$1$2{token}` — 僅置換值（group 3），保留關鍵字、分隔符與 Auth scheme 原樣
- 所有關鍵字在組合進 pattern 前以 `Regex.Escape` 處理

**Auth scheme 前綴處理**：Group 2 的 `(?:Bearer\s+|Basic\s+)?` 將 HTTP Authorization header 的 scheme 前綴吸入分隔符。例如 `Authorization: Bearer eyJ...` 中，group 2 捕獲 `: Bearer `，group 3 捕獲 token 本體，替換後保留 `Authorization: Bearer ***`，scheme 字樣不遺失。

**Presence pattern**（fallback，僅在 k-v pattern 無命中時觸發）：

```
\b(KW1|KW2|...)\b
```

偵測到關鍵字但無 k-v 結構時，顯示 WarningForm 提示使用者手動檢查。

**Format 4（table）處理**：表格型資料（如試算表貼上的純文字）關鍵字常出現在欄標題列，無分隔符結構，k-v pattern 不命中。此時 presence pattern 觸發 WarningForm，通知使用者該剪貼簿內容含敏感欄位名稱，需手動確認後再貼上。已知限制：若同一段文字同時有 k-v 命中與 table 關鍵字，Replace dialog 只處理 k-v 部分，table 欄位不另提示（v1 取捨，詳見 §6）。

**已知限制**：
- 值含空格（如 `password: my secret`）會在第一個空白截斷，僅遮罩 `my`
- 以上限制詳見 §6 注意事項

---

## 5. 生命週期

```
雙擊 ClipAssistant.exe（或桌面捷徑）
    │
    ▼
Windows 以 WinExe subsystem 啟動程序（無 console 視窗）
    │
    ▼
Program.Main()  ← [STAThread] 保證 STA 執行環境
    │
    ├─ LoadKeywords(baseDir)
    │     ├─ 檔不存在 / 為空 / 全為註解 → 內建預設 + Console.Error.WriteLine
    │     └─ 正常 → string[] keywords
    ├─ LoadReplacement(baseDir)
    │     ├─ 檔不存在 / 為空 → 內建預設 "***" + Console.Error.WriteLine
    │     └─ 正常 → string replacement
    ├─ Application.EnableVisualStyles()
    ├─ new MonitorContext(keywords, replacement, baseDir)
    │     ├─ CreateLockIcon() → 16x16 GDI+ 鎖頭圖示
    │     ├─ 建立 NotifyIcon（tray 圖示可見，Tooltip = "Clip Assistant - Active"）
    │     │     選單：[Pause Monitoring] ─── [Settings...] ─── [Exit]
    │     └─ new ClipboardMonitor(keywords, replacement)
    │           ├─ Clone keywords → Keywords / Replacement
    │           ├─ _replacementForRegex = replacement.Replace("$", "$$")
    │           ├─ BuildPatterns → _kvPattern + _presencePattern
    │           ├─ CreateHandle()
    │           ├─ AddClipboardFormatListener()
    │           └─ RegisterHotKey(Ctrl+Alt+Q)
    │
    └─ Application.Run()  ←── 阻塞於此，處理訊息迴圈

    [退出路徑 A：Ctrl+Alt+Q]
        WM_HOTKEY → ExitRequested → ExitThread() → Application.Run() 返回

    [退出路徑 B：tray Exit 選單]
        ToolStripMenuItem.Click → ExitThread() → Application.Run() 返回

    [Pause 路徑]
        tray → Pause Monitoring → OnPauseToggle
            → _monitor.Paused = true
            → _pauseMenuItem.Text = "Resume Monitoring"
            → _tray.Text = "Clip Assistant - Paused"
        (WM_CLIPBOARDUPDATE 到達時 HandleClipboard 立即 return，不顯示任何 dialog)
        tray → Resume Monitoring → OnPauseToggle
            → _monitor.Paused = false
            → 恢復正常監聽

    [Settings 路徑]
        tray → Settings... (或雙擊 tray 圖示) → OnSettings
            → SettingsForm.ShowDialog()
                ├─ Cancel → 不變更
                └─ OK → SettingsForm.WriteConfigFiles()（寫入 blacklist.txt + replacement.txt）
                       → _monitor.UpdateConfig(keywords, replacement)
                             → Clone → Keywords / Replacement / _replacementForRegex
                             → BuildPatterns（重新編譯 Regex，立即生效）

    Application.Run() 返回
        │
        └─ finally 區塊
              context.Dispose()
                ├─ tray.Visible = false  （移除系統列圖示）
                ├─ tray.Dispose()
                ├─ trayIcon.Dispose()
                └─ monitor.Dispose()
                      ├─ UnregisterHotKey()
                      ├─ RemoveClipboardFormatListener()
                      └─ DestroyHandle()
```

---

## 6. 注意事項 / Caveats

**STA 執行環境**
`Program.Main()` 標記 `[STAThread]`，WinForms 與 Clipboard API 所需的 STA 環境由 .NET runtime 在進入 `Main()` 前自動設定，無需任何額外處理。

**AddClipboardFormatListener 平台需求**
`AddClipboardFormatListener` 僅支援 Windows Vista（含）以上，XP 不支援。本程式目標為 Windows 11，此條件已滿足。

**WM_CLIPBOARDUPDATE 是 posted 訊息**
此訊息由 Windows 非同步 post 至視窗佇列（而非同步 send）。在單執行緒訊息迴圈中，unhook 後 Windows 不再 post 新事件，且 handler 執行期間佇列不被消化，因此 unhook → SetText → rehook 之間不存在殘留事件，第一層防遞迴機制是可靠的。

**ShowDialog 仍 pump 訊息**
Modal dialog 雖然阻止使用者與主視窗互動，但 `ShowDialog()` 內部有自己的訊息迴圈，因此 `WM_CLIPBOARDUPDATE` 在對話框開啟期間仍可被 post 並排隊。`_dialogOpen` 旗標（第二層防遞迴）正是為此而設。

**Clipboard.GetText() / SetText() 可能丟出 ExternalException**
當其他程式鎖定剪貼簿時，這兩個呼叫會丟出 `System.Runtime.InteropServices.ExternalException`（HRESULT `0x800401D0`，`CLIPBRD_E_CANT_OPEN`）。程式已在兩處以 try/catch 處理，失敗時靜默忽略該次事件。

**純文字替換的格式降級**
若原始剪貼簿包含多種格式（如從 Word 複製的 RTF + 純文字），`SetText()` 替換後剪貼簿只剩 UnicodeText 格式，RTF 等格式版本會遺失。此為已知設計取捨。

**Ctrl+Alt+Q 熱鍵衝突**
若 `Ctrl+Alt+Q` 已被其他程式（例如某些 IME 或遊戲軟體）佔用，`RegisterHotKey` 會回傳 `false`（Win32 error 1409）。程式會輸出 stderr 警告並繼續執行，此時可使用系統列圖示右鍵 → Exit 退出。HOTKEY_ID `0xB001` 為任意應用程式內部識別碼，無特別語意。

**NotifyIcon 殘影**
若未在退出前將 `NotifyIcon.Visible` 設為 `false`，圖示會殘留在系統列直到滑鼠移過該區域觸發刷新。`MonitorContext.Dispose()` 與 `Program.Main()` 的 `finally` 區塊均有設定 `Visible = false`。

**csc.exe 編譯器版本**
`npm run build:win` 使用 `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe`（.NET Framework 4.x），語言版本為 **C# 5**。任何 C# 6+ 語法（null-conditional `?.`、string interpolation `$"..."`、expression-bodied members）均無法編譯。`Program.cs` 已維持 C# 5 相容語法。

**ClipAssistant.exe 不進版控**
`ClipAssistant.exe` 是 build artifact，已加入 `.gitignore`。clone 後需執行 `npm run build:win` 產生 exe，再執行 `npm run setup:win` 建立桌面捷徑。

**設定檔載入時機**
啟動時讀取 `blacklist.txt` 與 `replacement.txt` 作為初始值（路徑為 exe 所在目錄）。啟動後可透過 tray → Settings… 即時修改，無須重啟。SettingsForm 的 Save 動作同步寫入磁碟並呼叫 `UpdateConfig`，新設定立即套用至 Regex。

**Replacement token 中的 `$` 字元**
`Regex.Replace` 的 replacement string 中 `$` 有特殊意義（back-reference，如 `$1`、`$2`）。replacement token 在使用前會透過 `.Replace("$", "$$")` 逸脫，儲存為 `_replacementForRegex`。使用者輸入 `$1` 也不會造成 back-reference 問題。

**Settings 儲存格式**
SettingsForm 的 Save 動作以 UTF-8 without BOM 寫入 `blacklist.txt`（含固定 comment header）與 `replacement.txt`，並同步更新記憶體中的 regex，無須重啟程式。

**Presence pattern 為 k-v 的 fallback**
`_presencePattern` 僅在 `_kvPattern` 完全無命中時觸發。若文字同時含有 k-v 命中的欄位與非 k-v 結構的關鍵字，程式只顯示 Replace dialog，不另顯示 WarningForm。

**關鍵字 escape**
所有關鍵字在組合進 regex pattern 前均以 `Regex.Escape` 處理。使用者在 `blacklist.txt` 中寫入 `auth.token`、`api[key]` 等含 regex 特殊字元的字串，不會破壞整體 pattern。

**value 邊界限制**
Group 3 的值終止於逗號、whitespace、分號、`&`。因此：
- `password: my secret` — 僅遮罩 `my`，`secret` 保留（空格為邊界）
- `pw="abc def"` — 遮罩 `"abc`，引號值目前不特別處理
- URL 編碼字串（如 `%20`）不解碼，以字面量匹配

**`\b` 與非 ASCII 關鍵字**
`\b` 在 .NET regex 預設下對 ASCII word character（`[a-zA-Z0-9_]`）定義邊界；若使用者在 `blacklist.txt` 中放入中文關鍵字，邊界判定可能不如預期。本工具預設關鍵字為英文，使用者自訂中文關鍵字時請自行驗證匹配行為。

---

## 7. 驗證方式

**啟動與退出**

- 雙擊 `ClipAssistant.exe` 或桌面捷徑，確認系統列出現藍底鎖頭圖示，Tooltip 顯示「Clip Assistant - Active」
- 按 `Ctrl+Alt+Q` 或右鍵系統列 → Exit，確認程式結束、圖示消失

**Settings 測試**

右鍵托盤 → Settings… → 在 New keyword 欄輸入 `secret` → 按 Add → 按 Save → 複製文字 `secret: abc` → 確認 Replace dialog 顯示 `secret` → 按 Replace → 貼上結果應為 `secret: ***`

**Pause 測試**

右鍵托盤 → Pause Monitoring → 確認 Tooltip 變為「Clip Assistant - Paused」、選單文字變為「Resume Monitoring」 → 複製 `PW: 123` → 確認無任何 dialog 彈出 → 右鍵 → Resume Monitoring → 複製 `PW: 123` → 確認 Replace dialog 再次出現

**Settings 即時生效**

Settings 儲存後不需重啟即可驗證：新關鍵字立即參與剪貼簿偵測。

---

以下 8 個功能測試案例可直接複製文字貼入任意程式觸發：

**測試 1 – 格式 1a 混合多欄位（多行純文字 k-v）**

複製下列文字：
```
Employee Info:
Name: John Smith
Department: Engineering
PW: MyP@ssw0rd
Email: john.smith@company.com
```
預期：Replace dialog 顯示 `pw`，按 Replace 後貼上結果為 `PW: ***`

**測試 2 – 格式 1b 混合多欄位（JSON 引號 k-v）**

複製下列文字：
```
"Name": "John Smith"
"Department": "Engineering"
"PW": "MyP@ssw0rd"
"Email": "john.smith@company.com"
```
預期：Replace dialog 顯示 `pw`，按 Replace 後貼上結果為 `"PW": "***"`（trailing `"` 保留）

**測試 3 – 格式 2 混合（多行尾端逗號）**

複製下列文字：
```
Name: John Smith,
Department: Engineering,
PW: MyP@ssw0rd,
Address: 123 Main Street,
Email: john.smith@company.com,
```
預期：Replace dialog 顯示 `pw`，按 Replace 後貼上結果為 `PW: ***,`

**測試 4 – 格式 3 混合（單行逗號串接）**

複製下列文字：
```
Name: John Smith,PW: MyP@ssw0rd,Department: Engineering,Address: 123 Main St
```
預期：Replace dialog 顯示 `pw`，按 Replace 後 PW 部分替換為 `***`

**測試 5 – Log 含 Bearer Token 與 host（多關鍵字 k-v）**

複製下列文字：
```
2024-01-15 10:23:45 INFO [api-gateway] Request started
method: POST
path: /api/v1/users
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.signature
host: api.internal.company.com
status: 200
```
預期：Replace dialog 顯示 `authorization, host`，按 Replace 後貼上結果為 `Authorization: Bearer ***`、`host: ***`

**測試 6 – 格式 4 table（Warning only）**

複製下列文字：
```
Employee Report 2024-01
Name       PW          Address
John       MyP@ssw0rd  123 Main St
Jane       S3cr3t!     456 Oak Ave
```
預期：Warning dialog 顯示 `pw`，按 OK 後剪貼簿內容不變（無替換）

**測試 7 – Negative：word boundary 阻擋（無對話框）**

複製下列文字：
```
hostname=webserver01
mypassword_field=test
accountType=premium
```
預期：無任何對話框彈出

**測試 8 – 實際情境混合（連線字串 + 錯誤訊息）**

複製下列文字：
```
Connection Failed - Debug Info:
Host: db.internal.company.com,
Account: service_account_prod,
Password: Db$3cr3tP@ss,
Port: 5432,
Database: production_db

Last error: FATAL: password authentication failed for user "service_account_prod"
```
預期：Replace dialog 顯示 `account, host, password`（`password authentication` 那行因無 `[:=]` 分隔符不觸發 k-v），按 Replace 後 `Host: ***`、`Account: ***`、`Password: ***`

---

**防堆疊驗證**

對話框開啟後（不關閉），再次複製含敏感關鍵字的文字；關閉現有對話框後確認不再彈出第二個對話框。

---

## 8. 安裝與使用

### 首次安裝

```powershell
# 1. clone repo
git clone <repo-url>
cd clip-assistant

# 2. 編譯 exe
npm run build:win

# 3. 建立桌面捷徑
npm run setup:win
```

### 日常啟動

雙擊桌面上的 **Clip Assistant** 捷徑，程式在背景執行，系統列出現藍底鎖頭圖示。

### 更新設定

啟動後，右鍵托盤圖示 → **Settings…** 即可新增 / 移除監控關鍵字或修改替換文字。設定儲存後立即生效，無須重啟。

### 重新編譯

修改 `windows/src/Program.cs` 後執行：

```
npm run build:win
```

`ClipAssistant.exe` 為 build artifact，不進版控（已加入 `.gitignore`）。

### 執行測試

```
npm run test:win
```
