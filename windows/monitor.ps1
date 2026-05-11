#Requires -Version 5.1
# monitor.ps1
# Clipboard monitor that detects sensitive keywords and redacts their values.
# Must run in STA mode for WinForms/Clipboard access; relaunches itself with -STA if needed.

param(
    [switch]$_StaRelaunch  # Internal flag to prevent infinite relaunch loops
)

# ---------------------------------------------------------------------------
# STA enforcement: WinForms and Clipboard APIs require Single-Threaded Apartment.
# The npm dev:win script launches without -STA, so we detect and relaunch here.
# ---------------------------------------------------------------------------
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    if ($_StaRelaunch) {
        # Guard: relaunch already attempted but still not STA — abort rather than loop.
        Write-Error "Failed to relaunch in STA mode. Exiting."
        exit 1
    }

    $scriptPath = $MyInvocation.MyCommand.Path
    if (-not $scriptPath) {
        Write-Error "Cannot determine script path for STA relaunch."
        exit 1
    }

    # Detect whether we are running under pwsh (PowerShell 7+) or powershell (5.1).
    # Use the same executable for the relaunch so the environment stays consistent.
    $hostExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }

    $relaunchArgs = @(
        '-ExecutionPolicy', 'Bypass',
        '-STA',
        '-File', $scriptPath,
        '-_StaRelaunch'
    )

    Start-Process -FilePath $hostExe -ArgumentList $relaunchArgs -NoNewWindow -Wait
    exit 0
}

# ---------------------------------------------------------------------------
# Add-Type guard: in a long-running dev session the types might already be loaded
# from a previous run in the same process.  This should not normally happen
# (each npm run starts a fresh process) but guard anyway to avoid a hard error.
# ---------------------------------------------------------------------------
if (-not ([System.Management.Automation.PSTypeName]'ClipAssistant.ClipboardMonitor').Type) {

Add-Type -ReferencedAssemblies @(
    'System.Windows.Forms',
    'System.Drawing',
    'System.Runtime.InteropServices'
) -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace ClipAssistant
{
    // -----------------------------------------------------------------------
    // ConfirmForm: a TopMost modal dialog that asks the user whether to
    // redact the matched clipboard content. We use a custom Form instead of
    // MessageBox because MessageBox does not reliably stay TopMost on Windows 11.
    // -----------------------------------------------------------------------
    public sealed class ConfirmForm : Form
    {
        private Button _replaceButton;
        private Button _cancelButton;
        private Label  _messageLabel;

        public ConfirmForm(string keywordsSummary)
        {
            // Window chrome settings
            this.Text            = "Clip Assistant";
            this.TopMost         = true;
            this.FormBorderStyle = FormBorderStyle.FixedDialog;
            this.MinimizeBox     = false;
            this.MaximizeBox     = false;
            this.ShowInTaskbar   = false;
            this.StartPosition   = FormStartPosition.CenterScreen;
            this.ClientSize      = new System.Drawing.Size(420, 130);

            // Message label — shows which keywords were detected, not the raw value
            _messageLabel = new Label();
            _messageLabel.Text     = "Detected sensitive keyword(s): " + keywordsSummary + "\nRedact value(s)?";
            _messageLabel.AutoSize = false;
            _messageLabel.Size     = new System.Drawing.Size(400, 50);
            _messageLabel.Location = new System.Drawing.Point(10, 15);

            // Replace button (AcceptButton)
            _replaceButton = new Button();
            _replaceButton.Text         = "Replace";
            _replaceButton.DialogResult = DialogResult.OK;
            _replaceButton.Size         = new System.Drawing.Size(90, 30);
            _replaceButton.Location     = new System.Drawing.Point(220, 80);

            // Cancel button (CancelButton)
            _cancelButton = new Button();
            _cancelButton.Text         = "Cancel";
            _cancelButton.DialogResult = DialogResult.Cancel;
            _cancelButton.Size         = new System.Drawing.Size(90, 30);
            _cancelButton.Location     = new System.Drawing.Point(320, 80);

            this.Controls.Add(_messageLabel);
            this.Controls.Add(_replaceButton);
            this.Controls.Add(_cancelButton);

            this.AcceptButton = _replaceButton;
            this.CancelButton = _cancelButton;
        }
    }

    // -----------------------------------------------------------------------
    // WarningForm: TopMost informational dialog shown when a blacklisted keyword
    // is detected but no k-v structure is present for automatic redaction
    // (e.g. a table column header).  The user is asked to review manually.
    // -----------------------------------------------------------------------
    public sealed class WarningForm : Form
    {
        public WarningForm(string keywordsSummary)
        {
            this.Text            = "Clip Assistant";
            this.TopMost         = true;
            this.FormBorderStyle = FormBorderStyle.FixedDialog;
            this.MinimizeBox     = false;
            this.MaximizeBox     = false;
            this.ShowInTaskbar   = false;
            this.StartPosition   = FormStartPosition.CenterScreen;
            this.ClientSize      = new System.Drawing.Size(440, 140);

            Label lbl = new Label();
            lbl.Text     = "Detected sensitive keyword(s): " + keywordsSummary +
                           "\nAutomatic redaction not possible. Please review before pasting.";
            lbl.AutoSize = false;
            lbl.Size     = new System.Drawing.Size(420, 60);
            lbl.Location = new System.Drawing.Point(10, 15);
            this.Controls.Add(lbl);

            Button okBtn = new Button();
            okBtn.Text         = "OK";
            okBtn.DialogResult = DialogResult.OK;
            okBtn.Size         = new System.Drawing.Size(90, 30);
            okBtn.Location     = new System.Drawing.Point(340, 90);
            this.Controls.Add(okBtn);

            this.AcceptButton = okBtn;
        }
    }

    // -----------------------------------------------------------------------
    // ClipboardMonitor: hidden NativeWindow that receives WM_CLIPBOARDUPDATE
    // via AddClipboardFormatListener and WM_HOTKEY for the Ctrl+Alt+Q shortcut.
    //
    // Anti-recursion strategy (two layers):
    //   1. unhook/rehook: RemoveClipboardFormatListener before SetText so our
    //      own write does not re-trigger WM_CLIPBOARDUPDATE.
    //   2. _dialogOpen flag: discard any WM_CLIPBOARDUPDATE that arrives while
    //      a dialog is already visible.  ShowDialog pumps its own message loop,
    //      so rapid clipboard changes by the user can still queue WM_CLIPBOARDUPDATE
    //      events that would otherwise stack up dialogs.
    // -----------------------------------------------------------------------
    public sealed class ClipboardMonitor : NativeWindow, IDisposable
    {
        // Win32 message constants
        private const int WM_CLIPBOARDUPDATE = 0x031D;
        private const int WM_HOTKEY          = 0x0312;

        // Hotkey identifier — arbitrary application-defined value
        private const int HOTKEY_ID = 0xB001;

        // Modifiers: MOD_CONTROL | MOD_ALT
        private const uint MOD_CONTROL_ALT = 0x0003;

        // Virtual-key code for Q
        private const uint VK_Q = 0x51;

        // Instance fields for blacklist-driven patterns and replacement token.
        // _kvPattern   matches keyword + separator + value (enables redaction).
        // _presencePattern matches keyword word-boundary only (fallback warning).
        private Regex  _kvPattern;
        private Regex  _presencePattern;
        private string _replacement;

        private bool _dialogOpen;
        private bool _disposed;

        // Raised when the user triggers exit via hotkey or tray menu
        public event EventHandler ExitRequested;

        // --------------------------------------------------------------------
        // P/Invoke declarations
        // --------------------------------------------------------------------
        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool AddClipboardFormatListener(IntPtr hwnd);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool RemoveClipboardFormatListener(IntPtr hwnd);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

        // --------------------------------------------------------------------
        // Constructor: accept keyword list and replacement token, build regex,
        // create the hidden window, register clipboard listener and global hotkey.
        // --------------------------------------------------------------------
        public ClipboardMonitor(string[] keywords, string replacement)
        {
            // Escape each keyword to handle regex metacharacters (e.g. "auth.token")
            string[] escaped = new string[keywords.Length];
            for (int i = 0; i < keywords.Length; i++)
                escaped[i] = Regex.Escape(keywords[i]);

            // k-v pattern: \b(kw1|kw2|...)("?\s*[:=]\s*"?(?:Bearer\s+|Basic\s+)?)([^",\s;&]+)
            // Group 1 = keyword, Group 2 = separator (optionally quoted + auth scheme prefix),
            // Group 3 = value (replaced). The double-quote in character class is represented
            // as "" inside a verbatim string literal: [^"",\s;&] means [^",\s;&].
            string kvPat = @"\b(" + string.Join("|", escaped) + @")(""?\s*[:=]\s*""?(?:Bearer\s+|Basic\s+)?)([^"",\s;&]+)";
            _kvPattern   = new Regex(kvPat, RegexOptions.IgnoreCase | RegexOptions.Compiled);

            // Presence pattern: \b(kw1|kw2|...)\b — fires when a keyword appears but
            // has no adjacent k-v structure, e.g. column headers in a table.
            string presencePat = @"\b(" + string.Join("|", escaped) + @")\b";
            _presencePattern = new Regex(presencePat, RegexOptions.IgnoreCase | RegexOptions.Compiled);

            _replacement = replacement;

            CreateHandle(new CreateParams());

            bool listenerAdded = AddClipboardFormatListener(this.Handle);
            if (!listenerAdded)
            {
                int err = Marshal.GetLastWin32Error();
                throw new InvalidOperationException(
                    string.Format("AddClipboardFormatListener failed (Win32 error {0}).", err));
            }

            // RegisterHotKey failure is non-fatal: the NotifyIcon exit remains available.
            bool hotkeyRegistered = RegisterHotKey(this.Handle, HOTKEY_ID, MOD_CONTROL_ALT, VK_Q);
            if (!hotkeyRegistered)
            {
                int err = Marshal.GetLastWin32Error();
                Console.Error.WriteLine(
                    string.Format(
                        "[ClipAssistant] Warning: RegisterHotKey (Ctrl+Alt+Q) failed " +
                        "(Win32 error {0}). Use tray icon to exit.", err));
            }
        }

        // --------------------------------------------------------------------
        // WndProc: message dispatch for clipboard and hotkey events.
        // --------------------------------------------------------------------
        protected override void WndProc(ref Message m)
        {
            switch (m.Msg)
            {
                case WM_CLIPBOARDUPDATE:
                    // Anti-recursion layer 2: drop events while dialog is open
                    if (!_dialogOpen)
                        HandleClipboard();
                    break;

                case WM_HOTKEY:
                    // Note: avoid C# 6 null-conditional operator (?.) — PowerShell 5.1's
                    // Add-Type uses a C# 5 compiler.
                    if (m.WParam.ToInt32() == HOTKEY_ID && ExitRequested != null)
                        ExitRequested(this, EventArgs.Empty);
                    break;
            }

            base.WndProc(ref m);
        }

        // --------------------------------------------------------------------
        // HandleClipboard: read clipboard text, then branch on match type.
        //
        // Branch 1 (k-v match): keyword followed by separator + value is found.
        //   Show ConfirmForm; on OK, redact values and write back to clipboard.
        //
        // Branch 2 (presence-only match): keyword exists but no k-v structure
        //   (e.g. table column headers). Show WarningForm for manual review.
        //   Branch 2 is only reached when Branch 1 produces zero matches, so
        //   mixed text that has both k-v hits and bare keywords only shows
        //   ConfirmForm — the two dialogs never stack.
        // --------------------------------------------------------------------
        private void HandleClipboard()
        {
            string text;
            try { text = Clipboard.GetText(); }
            catch (ExternalException) { return; }

            if (string.IsNullOrEmpty(text)) return;

            // --- Branch 1: k-v pattern matches → Replace dialog ---
            MatchCollection kvMatches = _kvPattern.Matches(text);
            if (kvMatches.Count > 0)
            {
                // Collect distinct keyword names (lowercase) for the dialog summary.
                // Avoid System.Linq — HashSet.CopyTo is available since .NET 2.0.
                HashSet<string> hits = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (Match m in kvMatches)
                    hits.Add(m.Groups[1].Value.ToLowerInvariant());
                string[] hitArr = new string[hits.Count];
                hits.CopyTo(hitArr);
                Array.Sort(hitArr, StringComparer.Ordinal);
                string summary = string.Join(", ", hitArr);

                _dialogOpen = true;
                try
                {
                    using (ConfirmForm dlg = new ConfirmForm(summary))
                    {
                        if (dlg.ShowDialog() == DialogResult.OK)
                        {
                            // Replace only group 3 (value); groups 1 and 2 are preserved.
                            // * has no special meaning in .NET replacement strings, no escape needed.
                            string redacted = _kvPattern.Replace(text, "$1$2" + _replacement);

                            // Anti-recursion layer 1: unhook before writing.
                            RemoveClipboardFormatListener(this.Handle);
                            try { Clipboard.SetText(redacted); }
                            catch (ExternalException) { }
                            finally { AddClipboardFormatListener(this.Handle); }
                        }
                    }
                }
                finally { _dialogOpen = false; }
                return;
            }

            // --- Branch 2: keyword present but no k-v structure → Warning only ---
            MatchCollection presenceMatches = _presencePattern.Matches(text);
            if (presenceMatches.Count > 0)
            {
                HashSet<string> hits = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (Match m in presenceMatches)
                    hits.Add(m.Groups[1].Value.ToLowerInvariant());
                string[] hitArr = new string[hits.Count];
                hits.CopyTo(hitArr);
                Array.Sort(hitArr, StringComparer.Ordinal);
                string summary = string.Join(", ", hitArr);

                _dialogOpen = true;
                try
                {
                    using (WarningForm wf = new WarningForm(summary))
                        wf.ShowDialog();
                }
                finally { _dialogOpen = false; }
            }
        }

        // --------------------------------------------------------------------
        // IDisposable: release Win32 resources in a safe, ordered sequence.
        // --------------------------------------------------------------------
        public void Dispose()
        {
            if (_disposed)
                return;

            _disposed = true;

            // Unregister hotkey first (non-fatal if it was never registered)
            if (this.Handle != IntPtr.Zero)
                UnregisterHotKey(this.Handle, HOTKEY_ID);

            // Remove clipboard listener before destroying the window
            if (this.Handle != IntPtr.Zero)
                RemoveClipboardFormatListener(this.Handle);

            // Destroy the native window handle
            DestroyHandle();
        }
    }

    // -----------------------------------------------------------------------
    // MonitorContext: ApplicationContext that wires the ClipboardMonitor to a
    // NotifyIcon so the user can exit via tray right-click or Ctrl+Alt+Q.
    // Accepts the keyword list and replacement token to forward to ClipboardMonitor.
    // -----------------------------------------------------------------------
    public sealed class MonitorContext : ApplicationContext
    {
        private ClipboardMonitor _monitor;
        private NotifyIcon       _tray;

        public MonitorContext(string[] keywords, string replacement)
        {
            // Build tray context menu
            var exitItem = new ToolStripMenuItem("Exit");
            exitItem.Click += (s, e) => ExitThread();

            var menu = new ContextMenuStrip();
            menu.Items.Add(exitItem);

            // Configure tray icon
            _tray              = new NotifyIcon();
            _tray.Icon         = System.Drawing.SystemIcons.Application;
            _tray.Text         = "Clip Assistant";
            _tray.ContextMenuStrip = menu;
            _tray.Visible      = true;

            // Create monitor; wire ExitRequested to ApplicationContext.ExitThread
            _monitor = new ClipboardMonitor(keywords, replacement);
            _monitor.ExitRequested += (s, e) => ExitThread();
        }

        // Override Dispose to guarantee ordered cleanup of both managed objects.
        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                // Hide tray icon immediately so it does not linger in the taskbar
                if (_tray != null)
                {
                    _tray.Visible = false;
                    _tray.Dispose();
                    _tray = null;
                }

                if (_monitor != null)
                {
                    _monitor.Dispose();
                    _monitor = null;
                }
            }

            base.Dispose(disposing);
        }
    }
}
'@

} # end Add-Type guard

# ---------------------------------------------------------------------------
# Load blacklist and replacement config files.
# Both files are expected in the same directory as this script ($PSScriptRoot).
# Defaults are used (with a warning) when a file is missing, empty, or all-comments.
# ---------------------------------------------------------------------------
$defaultKeywords    = @('host', 'password', 'pw', 'account', 'authorization')
$defaultReplacement = '***'

$blacklistPath    = Join-Path $PSScriptRoot 'blacklist.txt'
$replacementPath  = Join-Path $PSScriptRoot 'replacement.txt'

# --- blacklist.txt ---
if (Test-Path $blacklistPath) {
    $rawLines = Get-Content -Path $blacklistPath
    $seen     = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $keywords = [System.Collections.Generic.List[string]]::new()

    foreach ($line in $rawLines) {
        $trimmed = $line.Trim()
        # Skip blank lines and comment lines
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        # Case-insensitive deduplication, preserving first occurrence
        if ($seen.Add($trimmed)) {
            $keywords.Add($trimmed)
        }
    }

    if ($keywords.Count -eq 0) {
        Write-Warning "blacklist.txt contains no effective entries. Using built-in defaults: $($defaultKeywords -join ', ')"
        $keywords = [System.Collections.Generic.List[string]]$defaultKeywords
    }
} else {
    Write-Warning "blacklist.txt not found at '$blacklistPath'. Using built-in defaults: $($defaultKeywords -join ', ')"
    $keywords = [System.Collections.Generic.List[string]]$defaultKeywords
}

$keywordsArray = $keywords.ToArray()

# --- replacement.txt ---
if (Test-Path $replacementPath) {
    $replacementToken = (Get-Content -Path $replacementPath -Raw).Trim()
    if ($replacementToken -eq '') {
        Write-Warning "replacement.txt is empty. Using built-in default: '$defaultReplacement'"
        $replacementToken = $defaultReplacement
    }
} else {
    Write-Warning "replacement.txt not found at '$replacementPath'. Using built-in default: '$defaultReplacement'"
    $replacementToken = $defaultReplacement
}

# ---------------------------------------------------------------------------
# Entry point: run the WinForms message pump inside a try/finally so the tray
# icon is always hidden even if an unhandled exception escapes Application.Run.
# ---------------------------------------------------------------------------
$context = $null
try
{
    [System.Windows.Forms.Application]::EnableVisualStyles()
    [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

    $context = New-Object ClipAssistant.MonitorContext -ArgumentList ($keywordsArray, $replacementToken)

    # Blocks until ExitThread() is called (via hotkey or tray menu)
    [System.Windows.Forms.Application]::Run($context)
}
finally
{
    # Belt-and-suspenders: ensure the tray icon is removed even if Dispose was
    # not reached through the normal ApplicationContext disposal path.
    if ($context -ne $null)
    {
        $context.Dispose()
    }
}
