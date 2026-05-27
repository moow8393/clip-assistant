# Clip Assistant

A cross-platform clipboard monitor that detects sensitive keywords and offers to redact their values before you paste. Automatic background detection is available on Windows only.

> 中文說明請見 [README.zh-TW.md](README.zh-TW.md)

---

## Platform Support

| Platform | Status | Source |
|----------|--------|--------|
| Windows  | ✅ Available | [windows/src/](windows/src/) |
| iOS      | ⏸ On hold | [ios/ClipAssistant/](ios/ClipAssistant/) |

Jump to the platform you're working on:
- [Windows — User Guide](#windows--user-guide)
- [Windows — Developer Guide](#windows--developer-guide)
- [iOS — Developer Guide](#ios--developer-guide) *(on hold)*

---

## What It Does

![Demo](images/demo.gif)

When you copy text that contains sensitive key-value pairs — connection strings, log lines, config snippets — Clip Assistant intercepts the clipboard event and prompts you to redact the values before pasting.

**Example:** Copy `host: db.prod.internal, password: S3cr3t!` → a dialog appears → click **Replace** → clipboard becomes `host: ***, password: ***`.

Two detection modes:
- **k-v redaction** — keyword followed by `:` or `=` and a value → offers automatic replacement
- **Presence warning** — keyword detected but no parseable value structure (e.g. table headers) → warns you to review manually

---

## Quick Verification Examples

Copy each input below and trigger detection to confirm the tool works as expected.

### k-v Redaction — connection string

```
Host: db.prod.internal, Password: S3cr3tP@ss, Account: service_user
```

Expected output: `Host: ***, Password: ***, Account: ***`
Keywords `host`, `password`, and `account` are detected; their values are replaced. The keys and separators are preserved.

### k-v Redaction — HTTP log with Bearer token

```
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.sig
host: api.internal.company.com
```

Expected output: `Authorization: Bearer ***` and `host: ***`
The `Bearer` scheme prefix is treated as part of the separator and preserved; only the token value is redacted.

### k-v Redaction — JSON object

```json
{
  "name": "John Smith",
  "password": "MyP@ssw0rd",
  "email": "john.smith@company.com"
}
```

Expected output: `"password": "***"`
Quoted keys and values are supported. The leading `"` of the value is absorbed into the separator, and the trailing `"` is left intact, preserving valid JSON structure.

### Presence Warning — table header

```
Name       PW          Address
John       MyP@ssw0rd  123 Main St
Jane       S3cr3t!     456 Oak Ave
```

Expected: a **warning** (not redaction). The keyword `pw` appears in a column header with no `:` or `=` separator, so the tool cannot safely identify which value to replace. You are warned to review manually.

### No Match — word boundary protection

```
hostname=webserver01
mypassword_field=test
```

Expected: **no alert**. `hostname` contains `host` but is followed by a letter (`n`), so the boundary guard blocks the match. Same for `mypassword` preceded by `my`.

### CJK Keywords

Configure `密碼` as a keyword, then copy:

```
密碼: S3cr3t!
```

Expected output: `密碼: ***`
CJK keywords use Unicode letter lookbehind/lookahead instead of `\b`, so `test密碼=secret` correctly produces no match while ` 密碼: S3cr3t!` is redacted.

---

## Windows — User Guide

### Requirements

- Windows Vista or later (Windows 11 recommended)
- [Node.js](https://nodejs.org/) (for build scripts)
- .NET Framework 4.x (ships with Windows; provides `csc.exe`)

### Installation

```powershell
git clone <repo-url>
cd clip-assistant
npm run build:win       # compiles ClipAssistant.exe
npm run setup:win       # creates a desktop shortcut (run once)
```

### Daily Use

Double-click `windows/ClipAssistant.exe` directly, or use the desktop shortcut created by `npm run setup:win`. A blue padlock icon appears in the system tray — the app is now monitoring your clipboard silently.

| Action | How |
|--------|-----|
| Pause monitoring | Right-click tray → **Pause Monitoring** |
| Resume monitoring | Right-click tray → **Resume Monitoring** |
| Edit keywords / replacement | Right-click tray → **Settings…** (or double-click the icon) |
| Exit | Right-click tray → **Exit**, or press **Ctrl+Alt+Q** |

Settings changes take effect immediately — no restart needed.

### Configuration Files

Both files live next to `ClipAssistant.exe` (i.e. `windows/`). You can edit them directly or use the Settings dialog.

**`blacklist.txt`** — one keyword per line, case-insensitive, lines starting with `#` are comments.

```
# Default keywords
host
password
pw
account
authorization
```

**`replacement.txt`** — the token that replaces redacted values. Default: `***`

```
***
```

If either file is missing or empty, the built-in defaults are used automatically.

---

## Windows — Developer Guide

### Architecture Overview

The Windows implementation is a single-file C# 5 / .NET Framework 4.x WinForms app compiled with `csc.exe` into a no-console `winexe` binary.

```
Program (entry point)
  └─ MonitorContext (ApplicationContext)
       ├─ NotifyIcon  — system tray icon, tray menu (Pause / Settings / Exit)
       └─ ClipboardMonitor (NativeWindow)
            ├─ AddClipboardFormatListener  — receives WM_CLIPBOARDUPDATE
            ├─ RegisterHotKey              — Ctrl+Alt+Q exit shortcut
            ├─ _kvPattern (Regex)          — keyword + separator + value
            └─ _presencePattern (Regex)    — keyword word-boundary fallback
```

Key classes in [windows/src/Program.cs](windows/src/Program.cs):

| Class | Role |
|-------|------|
| `ClipboardMonitor` | Hidden `NativeWindow`; handles `WM_CLIPBOARDUPDATE` and `WM_HOTKEY` |
| `MonitorContext` | `ApplicationContext` wiring monitor → tray icon → menu |
| `ConfirmForm` | TopMost modal — prompts user to replace detected k-v values |
| `WarningForm` | TopMost informational — fires when keyword is present but no k-v structure |
| `SettingsForm` | Non-TopMost settings dialog; writes `blacklist.txt` + `replacement.txt` |
| `Program` | `[STAThread]` entry point; loads config files, runs message loop |

**Anti-recursion (two layers)**

Writing to the clipboard triggers another `WM_CLIPBOARDUPDATE`. Two guards prevent infinite loops:

1. **Unhook/rehook** — `RemoveClipboardFormatListener` before `Clipboard.SetText`, then `AddClipboardFormatListener` after. The write is invisible to the monitor.
2. **`_dialogOpen` flag** — `ShowDialog` pumps its own message loop, so rapid copies can queue events. The flag drops those queued events to prevent dialog stacking.

**Regex patterns**

k-v pattern (simplified):
```
(?<!\p{L})(keyword1|keyword2|...)("?\s*[:=]\s*"?(?:Bearer\s+|Basic\s+)?)([^",\s;&]+)
```
Groups: `$1` = keyword, `$2` = separator (preserved), `$3` = value (replaced with token).

Presence pattern (fallback):
```
(?<!\p{L})(keyword1|keyword2|...)(?!\p{L})
```

`(?<!\p{L})` / `(?!\p{L})` are Unicode-aware letter lookbehind/lookahead. They replace `\b` to support CJK keywords — `\b` in .NET is ASCII-only and fails to match CJK characters at non-word boundaries. Both ASCII and CJK keywords benefit from substring protection (e.g. `test密碼=secret` does not match keyword `密碼`).

### Build & Test

```powershell
npm run build:win       # compile → windows/ClipAssistant.exe
npm run test:win        # run Pester tests in tests/windows/
```

The exe is a build artifact and is excluded from version control (`.gitignore`). After cloning, always run `build:win` first.

**Compiler constraint:** `csc.exe` from .NET Framework 4.x targets **C# 5**. Avoid C# 6+ syntax (null-conditional `?.`, string interpolation `$"..."`, expression-bodied members).

### Key Files

| Path | Description |
|------|-------------|
| [windows/src/Program.cs](windows/src/Program.cs) | Entire Windows implementation (~730 lines) |
| [windows/blacklist.txt](windows/blacklist.txt) | Keyword list loaded at startup |
| [windows/replacement.txt](windows/replacement.txt) | Replacement token |
| [windows/create-shortcut.ps1](windows/create-shortcut.ps1) | Desktop shortcut creation script |
| [tests/windows/ClipAssistant.Tests.ps1](tests/windows/ClipAssistant.Tests.ps1) | Pester test suite |
| [docs/windows-monitor.md](docs/windows-monitor.md) | In-depth design document |

---

## iOS — Developer Guide

> **Status: on hold.** The core logic and CI are complete, but real-device testing has been deferred due to testing cost (requires an Apple Developer account or a 7-day Sideloadly refresh cycle). The code is preserved for future resumption.

### Architecture Overview

```
ClipAssistantApp (@main)
  └─ ContentView (TabView)
       ├─ ClipboardInspectorView  — Tab 1: detect & redact
       │    └─ ClipboardInspectorViewModel (@MainActor)
       │         ├─ UIPasteboard.changedNotification  — foreground clipboard change
       │         ├─ ScenePhase.active                 — app foregrounded
       │         ├─ ClipboardDetector                 — regex detection (Swift 6 Sendable)
       │         └─ HistoryStore                      — append redaction record
       ├─ HistoryView             — Tab 2: redaction log
       │    └─ HistoryViewModel (@MainActor)
       └─ SettingsView            — Tab 3: keywords & replacement token
            └─ SettingsViewModel (@MainActor)
```

### Why There Is No Automatic Detection

Windows can receive `WM_CLIPBOARDUPDATE` silently in the background — no user interaction required. iOS has no equivalent:

- Background processes cannot read `UIPasteboard` without triggering a system privacy banner (iOS 14+)
- `UIPasteboard.changedNotification` is only delivered while the app is in the foreground
- Apple's App Store sandbox prohibits the background clipboard entitlement for third-party apps

As a result, detection is intentionally **foreground-only**: triggered by `ScenePhase.active` (app foregrounded) and `UIPasteboard.changedNotification` (clipboard changed while already in foreground).

### Build & Test

Tests run on GitHub Actions (macOS-15, Xcode 16.4, iPhone 16 simulator):

```
.github/workflows/ios.yml
  ├─ test      — xcodebuild test on iOS Simulator (every push/PR)
  └─ build-ipa — produces unsigned IPA artifact (push to main only, after tests pass)
```

To build locally you need a Mac with Xcode 16+:

```bash
xcodebuild test \
  -project ios/ClipAssistant.xcodeproj \
  -scheme ClipAssistant \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

### Key Files

| Path | Description |
|------|-------------|
| [ios/ClipAssistant/App/](ios/ClipAssistant/App/) | App entry point and root `ContentView` |
| [ios/ClipAssistant/Core/Detection/](ios/ClipAssistant/Core/Detection/) | `ClipboardDetector`, `PatternBuilder` — shared regex logic |
| [ios/ClipAssistant/Core/Storage/](ios/ClipAssistant/Core/Storage/) | `HistoryStore`, `SettingsStore` — JSON persistence via `FileManager` |
| [ios/ClipAssistant/Features/](ios/ClipAssistant/Features/) | `Inspector`, `History`, `Settings` — SwiftUI views and view models |
| [ios/ClipAssistantTests/DetectorTests.swift](ios/ClipAssistantTests/DetectorTests.swift) | 10 unit tests covering regex, CJK boundary, `$` escape |
| [docs/ios-app-cleaning-station.md](docs/ios-app-cleaning-station.md) | Design document |

---

## Known Limitations

- Values containing spaces (`password: my secret`) — only the first word is redacted
- Clipboard formats beyond plain text (RTF, HTML, images) are not processed; replacing a value downgrades the clipboard to plain text
- `Ctrl+Alt+Q` hotkey registration may fail if another app has claimed it — use the tray menu to exit
- CJK keywords are supported; the boundary guard uses `(?<!\p{L})` / `(?!\p{L})` so both ASCII and Chinese keywords work correctly

---

## License

ISC
