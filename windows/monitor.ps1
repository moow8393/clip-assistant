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
        # Guard: relaunch already attempted but still not STA ??abort rather than loop.
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
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
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

            // Message label ??shows which keywords were detected, not the raw value
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
    // SettingsForm: a non-TopMost dialog for managing the keyword blacklist and
    // replacement token.  On Save, writes blacklist.txt and replacement.txt to
    // the config directory and exposes the updated values via properties.
    // -----------------------------------------------------------------------
    public sealed class SettingsForm : Form
    {
        private ListBox  _keywordList;
        private TextBox  _newKeywordBox;
        private TextBox  _replacementBox;
        private Button   _addButton;
        private Button   _removeButton;
        private Button   _saveButton;
        private Button   _cancelButton;

        private string   _configDir;

        public string[]  UpdatedKeywords    { get; private set; }
        public string    UpdatedReplacement { get; private set; }

        public SettingsForm(string[] currentKeywords, string currentReplacement, string configDir)
        {
            _configDir = configDir;

            this.Text            = "Clip Assistant Settings";
            this.TopMost         = false;
            this.FormBorderStyle = FormBorderStyle.FixedDialog;
            this.MinimizeBox     = false;
            this.MaximizeBox     = false;
            this.ShowInTaskbar   = true;
            this.StartPosition   = FormStartPosition.CenterScreen;
            this.ClientSize      = new System.Drawing.Size(430, 340);

            // --- Labels ---
            Label kwLabel = new Label();
            kwLabel.Text     = "Monitored Keywords:";
            kwLabel.AutoSize = true;
            kwLabel.Location = new System.Drawing.Point(10, 12);
            this.Controls.Add(kwLabel);

            Label replLabel = new Label();
            replLabel.Text     = "Replacement text:";
            replLabel.AutoSize = true;
            replLabel.Location = new System.Drawing.Point(10, 248);
            this.Controls.Add(replLabel);

            Label newKwLabel = new Label();
            newKwLabel.Text     = "New keyword:";
            newKwLabel.AutoSize = true;
            newKwLabel.Location = new System.Drawing.Point(10, 178);
            this.Controls.Add(newKwLabel);

            // --- Keyword ListBox ---
            _keywordList = new ListBox();
            _keywordList.Location      = new System.Drawing.Point(10, 32);
            _keywordList.Size          = new System.Drawing.Size(410, 130);
            _keywordList.SelectionMode = SelectionMode.One;
            _keywordList.Sorted        = false;
            foreach (string kw in currentKeywords)
                _keywordList.Items.Add(kw);
            this.Controls.Add(_keywordList);

            // --- New keyword TextBox ---
            _newKeywordBox = new TextBox();
            _newKeywordBox.Location = new System.Drawing.Point(100, 175);
            _newKeywordBox.Size     = new System.Drawing.Size(220, 23);
            // Enter key triggers Add action ??avoids closing the form via AcceptButton
            _newKeywordBox.KeyDown += delegate(object s, KeyEventArgs e)
            {
                if (e.KeyCode == Keys.Enter)
                {
                    e.SuppressKeyPress = true;
                    AddKeyword();
                }
            };
            this.Controls.Add(_newKeywordBox);

            // --- Add button ---
            _addButton = new Button();
            _addButton.Text     = "Add";
            _addButton.Location = new System.Drawing.Point(330, 174);
            _addButton.Size     = new System.Drawing.Size(90, 25);
            _addButton.Click   += delegate(object s, EventArgs e) { AddKeyword(); };
            this.Controls.Add(_addButton);

            // --- Remove Selected button ---
            _removeButton = new Button();
            _removeButton.Text     = "Remove Selected";
            _removeButton.Location = new System.Drawing.Point(330, 207);
            _removeButton.Size     = new System.Drawing.Size(90, 25);
            _removeButton.Click   += delegate(object s, EventArgs e)
            {
                if (_keywordList.SelectedIndex >= 0)
                    _keywordList.Items.RemoveAt(_keywordList.SelectedIndex);
            };
            this.Controls.Add(_removeButton);

            // --- Replacement TextBox ---
            _replacementBox = new TextBox();
            _replacementBox.Location = new System.Drawing.Point(140, 245);
            _replacementBox.Size     = new System.Drawing.Size(150, 23);
            _replacementBox.Text     = currentReplacement;
            this.Controls.Add(_replacementBox);

            // --- Cancel button ---
            _cancelButton = new Button();
            _cancelButton.Text         = "Cancel";
            _cancelButton.DialogResult = DialogResult.Cancel;
            _cancelButton.Location     = new System.Drawing.Point(225, 295);
            _cancelButton.Size         = new System.Drawing.Size(90, 30);
            this.Controls.Add(_cancelButton);

            // --- Save button (no DialogResult ??validation runs first) ---
            _saveButton = new Button();
            _saveButton.Text     = "Save";
            _saveButton.Location = new System.Drawing.Point(325, 295);
            _saveButton.Size     = new System.Drawing.Size(90, 30);
            _saveButton.Click   += delegate(object s, EventArgs e) { SaveSettings(); };
            this.Controls.Add(_saveButton);

            // CancelButton closes on Esc; AcceptButton intentionally not set so
            // Enter in the form body does not accidentally trigger Save.
            this.CancelButton = _cancelButton;
        }

        // Adds the trimmed text from _newKeywordBox to the list if non-empty and not duplicate.
        private void AddKeyword()
        {
            string kw = _newKeywordBox.Text.Trim();
            if (kw.Length == 0)
                return;

            // Case-insensitive duplicate check
            foreach (object item in _keywordList.Items)
            {
                if (string.Compare(item.ToString(), kw, StringComparison.OrdinalIgnoreCase) == 0)
                    return;
            }

            _keywordList.Items.Add(kw);
            _newKeywordBox.Clear();
        }

        // Validates input, writes config files, and closes with OK.
        private void SaveSettings()
        {
            if (_keywordList.Items.Count == 0)
            {
                MessageBox.Show(
                    "At least one keyword is required.",
                    "Clip Assistant",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Warning);
                return;
            }

            string replacement = _replacementBox.Text.Trim();
            if (replacement.Length == 0)
                replacement = "***";

            // Collect keywords from ListBox
            string[] keywords = new string[_keywordList.Items.Count];
            for (int i = 0; i < _keywordList.Items.Count; i++)
                keywords[i] = _keywordList.Items[i].ToString();

            WriteConfigFiles(keywords, replacement);

            UpdatedKeywords    = keywords;
            UpdatedReplacement = replacement;
            this.DialogResult  = DialogResult.OK;
        }

        // Persists keyword list and replacement token to disk.
        // Uses UTF-8 without BOM to stay consistent with the existing config format.
        private void WriteConfigFiles(string[] keywords, string replacement)
        {
            // Write blacklist.txt ??preserve the comment header
            using (StreamWriter sw = new StreamWriter(
                Path.Combine(_configDir, "blacklist.txt"), false,
                new UTF8Encoding(false)))  // UTF-8 without BOM
            {
                sw.WriteLine("# One keyword per line. Case-insensitive. Lines starting with # are comments.");
                sw.WriteLine("# Examples of additional keywords to add: token, secret, api_key");
                foreach (string kw in _keywordList.Items)
                    sw.WriteLine(kw);
            }

            // Write replacement.txt
            File.WriteAllText(
                Path.Combine(_configDir, "replacement.txt"),
                replacement,
                new UTF8Encoding(false));
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

        // Hotkey identifier ??arbitrary application-defined value
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

        // _replacementForRegex is Replacement with "$" doubled to prevent
        // Regex.Replace from interpreting "$1" etc. as back-references.
        private string _replacementForRegex;

        private bool _dialogOpen;
        private bool _disposed;

        // Raised when the user triggers exit via hotkey or tray menu
        public event EventHandler ExitRequested;

        // Read-only snapshot of the current keyword list (updated by UpdateConfig).
        public string[] Keywords    { get; private set; }
        // Raw replacement token as entered by the user.
        public string   Replacement { get; private set; }
        // When true, WM_CLIPBOARDUPDATE events are silently ignored.
        public bool     Paused      { get; set; }

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
            Keywords    = (string[])keywords.Clone();
            Replacement = replacement;

            // Compute the regex-safe replacement string once and cache it.
            _replacementForRegex = replacement.Replace("$", "$$");

            BuildPatterns(keywords);

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
        // UpdateConfig: hot-reload keywords and replacement token without restart.
        // Called from the UI thread after SettingsForm closes with DialogResult.OK.
        // --------------------------------------------------------------------
        public void UpdateConfig(string[] keywords, string replacement)
        {
            Keywords             = (string[])keywords.Clone();
            Replacement          = replacement;
            _replacementForRegex = replacement.Replace("$", "$$");

            BuildPatterns(keywords);
        }

        // Shared helper: compiles both Regex objects from a keyword array.
        // C# 5 compatible ??no expression-bodied members or string interpolation.
        private void BuildPatterns(string[] keywords)
        {
            string[] escaped = new string[keywords.Length];
            for (int i = 0; i < keywords.Length; i++)
                escaped[i] = Regex.Escape(keywords[i]);

            // k-v pattern: \b(kw1|kw2|...)("?\s*[:=]\s*"?(?:Bearer\s+|Basic\s+)?)([^",\s;&]+)
            // Group 1 = keyword, Group 2 = separator (optionally quoted + auth scheme prefix),
            // Group 3 = value (replaced). The double-quote in character class is represented
            // as "" inside a verbatim string literal: [^"",\s;&] means [^",\s;&].
            string kvPat = @"\b(" + string.Join("|", escaped) +
                           @")(""?\s*[:=]\s*""?(?:Bearer\s+|Basic\s+)?)([^"",\s;&]+)";
            _kvPattern = new Regex(kvPat, RegexOptions.IgnoreCase | RegexOptions.Compiled);

            // Presence pattern: \b(kw1|kw2|...)\b ??fires when a keyword appears but
            // has no adjacent k-v structure, e.g. column headers in a table.
            string presencePat = @"\b(" + string.Join("|", escaped) + @")\b";
            _presencePattern = new Regex(presencePat, RegexOptions.IgnoreCase | RegexOptions.Compiled);
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
                    // Note: avoid C# 6 null-conditional operator (?.) ??PowerShell 5.1's
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
        //   ConfirmForm ??the two dialogs never stack.
        // --------------------------------------------------------------------
        private void HandleClipboard()
        {
            // Paused flag: silently ignore clipboard events when monitoring is suspended.
            if (Paused) return;

            string text;
            try { text = Clipboard.GetText(); }
            catch (ExternalException) { return; }

            if (string.IsNullOrEmpty(text)) return;

            // --- Branch 1: k-v pattern matches ??Replace dialog ---
            MatchCollection kvMatches = _kvPattern.Matches(text);
            if (kvMatches.Count > 0)
            {
                // Collect distinct keyword names (lowercase) for the dialog summary.
                // Avoid System.Linq ??HashSet.CopyTo is available since .NET 2.0.
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
                            // _replacementForRegex has "$" doubled to prevent back-reference
                            // interpretation by Regex.Replace.
                            string redacted = _kvPattern.Replace(text, "$1$2" + _replacementForRegex);

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

            // --- Branch 2: keyword present but no k-v structure ??Warning only ---
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
    // NotifyIcon with Pause/Resume and Settings tray menu items.
    // -----------------------------------------------------------------------
    public sealed class MonitorContext : ApplicationContext
    {
        private ClipboardMonitor  _monitor;
        private NotifyIcon        _tray;
        private ToolStripMenuItem _pauseMenuItem;
        private string            _configDir;

        public MonitorContext(string[] keywords, string replacement, string configDir)
        {
            _configDir = configDir;

            // --- Pause/Resume toggle menu item ---
            _pauseMenuItem        = new ToolStripMenuItem("Pause Monitoring");
            _pauseMenuItem.Click += new EventHandler(OnPauseToggle);

            // --- Settings menu item ---
            var settingsItem = new ToolStripMenuItem("Settings...");
            settingsItem.Click += new EventHandler(OnSettings);

            // --- Exit menu item ---
            var exitItem = new ToolStripMenuItem("Exit");
            exitItem.Click += delegate(object s, EventArgs e) { ExitThread(); };

            // Build menu with separators between the three logical groups
            var menu = new ContextMenuStrip();
            menu.Items.Add(_pauseMenuItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(settingsItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(exitItem);

            // Configure tray icon
            _tray                   = new NotifyIcon();
            _tray.Icon              = System.Drawing.SystemIcons.Application;
            _tray.Text              = "Clip Assistant - Active";
            _tray.ContextMenuStrip  = menu;
            _tray.Visible           = true;
            // Double-click also opens Settings for quick access
            _tray.DoubleClick      += new EventHandler(OnSettings);

            // Create monitor; wire ExitRequested to ApplicationContext.ExitThread
            _monitor = new ClipboardMonitor(keywords, replacement);
            _monitor.ExitRequested += delegate(object s, EventArgs e) { ExitThread(); };
        }

        // Toggles the Paused state and updates the tray tooltip and menu label.
        private void OnPauseToggle(object sender, EventArgs e)
        {
            _monitor.Paused = !_monitor.Paused;
            if (_monitor.Paused)
            {
                _pauseMenuItem.Text = "Resume Monitoring";
                _tray.Text          = "Clip Assistant - Paused";
            }
            else
            {
                _pauseMenuItem.Text = "Pause Monitoring";
                _tray.Text          = "Clip Assistant - Active";
            }
        }

        // Opens SettingsForm and applies the updated config if the user saves.
        private void OnSettings(object sender, EventArgs e)
        {
            using (SettingsForm sf = new SettingsForm(_monitor.Keywords, _monitor.Replacement, _configDir))
            {
                if (sf.ShowDialog() == DialogResult.OK)
                    _monitor.UpdateConfig(sf.UpdatedKeywords, sf.UpdatedReplacement);
            }
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
$defaultKeywords = @('host', 'password', 'pw', 'account', 'authorization')
$defaultReplacement = '***'

$blacklistPath = Join-Path $PSScriptRoot 'blacklist.txt'
$replacementPath = Join-Path $PSScriptRoot 'replacement.txt'

# --- blacklist.txt ---
if (Test-Path $blacklistPath) {
    $rawLines = Get-Content -Path $blacklistPath
    $seen = [System.Collections.Generic.HashSet[string]]::new(
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
}
else {
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
}
else {
    Write-Warning "replacement.txt not found at '$replacementPath'. Using built-in default: '$defaultReplacement'"
    $replacementToken = $defaultReplacement
}

# ---------------------------------------------------------------------------
# Entry point: run the WinForms message pump inside a try/finally so the tray
# icon is always hidden even if an unhandled exception escapes Application.Run.
# ---------------------------------------------------------------------------
$context = $null
try {
    [System.Windows.Forms.Application]::EnableVisualStyles()
    [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

    $context = New-Object ClipAssistant.MonitorContext -ArgumentList ($keywordsArray, $replacementToken, $PSScriptRoot)

    # Blocks until ExitThread() is called (via hotkey or tray menu)
    [System.Windows.Forms.Application]::Run($context)
}
finally {
    # Belt-and-suspenders: ensure the tray icon is removed even if Dispose was
    # not reached through the normal ApplicationContext disposal path.
    if ($null -ne $context) {
        $context.Dispose()
    }
}

