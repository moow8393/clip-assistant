# Clip Assistant

A cross-platform clipboard monitor that detects sensitive keywords and offers to redact their values before you paste.

> 中文說明請見 [README.zh-TW.md](README.zh-TW.md)

---

## Platform Support

| Platform | Status | Source |
|----------|--------|--------|
| Windows  | ✅ Available | [windows/src/](windows/src/) |
| iOS      | 🚧 Coming soon | — |

Jump to the platform you're working on:
- [Windows — User Guide](#windows--user-guide)
- [Windows — Developer Guide](#windows--developer-guide)
- [iOS — Developer Guide](#ios--developer-guide)

---

## What It Does

When you copy text that contains sensitive key-value pairs — connection strings, log lines, config snippets — Clip Assistant intercepts the clipboard event and prompts you to redact the values before pasting.

**Example:** Copy `host: db.prod.internal, password: S3cr3t!` → a dialog appears → click **Replace** → clipboard becomes `host: ***, password: ***`.

Two detection modes:
- **k-v redaction** — keyword followed by `:` or `=` and a value → offers automatic replacement
- **Presence warning** — keyword detected but no parseable value structure (e.g. table headers) → warns you to review manually

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
\b(keyword1|keyword2|...)("?\s*[:=]\s*"?(?:Bearer\s+|Basic\s+)?)([^",\s;&]+)
```
Groups: `$1` = keyword, `$2` = separator (preserved), `$3` = value (replaced with token).

Presence pattern (fallback):
```
\b(keyword1|keyword2|...)\b
```

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

> **Status: not yet implemented.**
> This section is a placeholder for the upcoming iOS version.

The iOS implementation will share the same concept — monitoring clipboard changes and prompting the user to redact sensitive values.

### Planned approach

```
npm run info:ios        # prints: "Please open ./ios/ClipAssistant.xcodeproj in Xcode (Mac Required)"
```

Implementation notes (to be filled in once development begins):

- Platform: iOS 16+
- Language: Swift 6 / SwiftUI
- Entry point: `ios/` directory
- Build: Xcode required (Mac only)

---

## Known Limitations

- Values containing spaces (`password: my secret`) — only the first word is redacted
- Clipboard formats beyond plain text (RTF, HTML, images) are not processed; replacing a value downgrades the clipboard to plain text
- `Ctrl+Alt+Q` hotkey registration may fail if another app has claimed it — use the tray menu to exit
- `\b` word boundary in .NET regex is ASCII-only; non-ASCII keywords may not match as expected

---

## License

ISC
