// Program.cs — ClipAssistant standalone executable
// Extracted from monitor.ps1. Targets .NET Framework 4.x / C# 5 (csc.exe v4.8).
// Uses /target:winexe so no console window appears on double-click.

using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace ClipAssistant
{
    // -----------------------------------------------------------------------
    // ConfirmForm: TopMost modal dialog for redaction confirmation.
    // Custom Form instead of MessageBox to guarantee TopMost on Windows 11.
    // -----------------------------------------------------------------------
    public sealed class ConfirmForm : Form
    {
        private Button _replaceButton;
        private Button _cancelButton;
        private Label  _messageLabel;

        public ConfirmForm(string keywordsSummary)
        {
            this.Text            = "Clip Assistant";
            this.TopMost         = true;
            this.FormBorderStyle = FormBorderStyle.FixedDialog;
            this.MinimizeBox     = false;
            this.MaximizeBox     = false;
            this.ShowInTaskbar   = false;
            this.StartPosition   = FormStartPosition.CenterScreen;
            this.ClientSize      = new Size(420, 130);

            _messageLabel = new Label();
            _messageLabel.Text     = "Detected sensitive keyword(s): " + keywordsSummary + "\nRedact value(s)?";
            _messageLabel.AutoSize = false;
            _messageLabel.Size     = new Size(400, 50);
            _messageLabel.Location = new Point(10, 15);

            _replaceButton = new Button();
            _replaceButton.Text         = "Replace";
            _replaceButton.DialogResult = DialogResult.OK;
            _replaceButton.Size         = new Size(90, 30);
            _replaceButton.Location     = new Point(220, 80);

            _cancelButton = new Button();
            _cancelButton.Text         = "Cancel";
            _cancelButton.DialogResult = DialogResult.Cancel;
            _cancelButton.Size         = new Size(90, 30);
            _cancelButton.Location     = new Point(320, 80);

            this.Controls.Add(_messageLabel);
            this.Controls.Add(_replaceButton);
            this.Controls.Add(_cancelButton);

            this.AcceptButton = _replaceButton;
            this.CancelButton = _cancelButton;
        }
    }

    // -----------------------------------------------------------------------
    // WarningForm: TopMost informational dialog when a keyword is present but
    // no k-v structure exists for automatic redaction (e.g. table headers).
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
            this.ClientSize      = new Size(440, 140);

            Label lbl = new Label();
            lbl.Text     = "Detected sensitive keyword(s): " + keywordsSummary +
                           "\nAutomatic redaction not possible. Please review before pasting.";
            lbl.AutoSize = false;
            lbl.Size     = new Size(420, 60);
            lbl.Location = new Point(10, 15);
            this.Controls.Add(lbl);

            Button okBtn = new Button();
            okBtn.Text         = "OK";
            okBtn.DialogResult = DialogResult.OK;
            okBtn.Size         = new Size(90, 30);
            okBtn.Location     = new Point(340, 90);
            this.Controls.Add(okBtn);

            this.AcceptButton = okBtn;
        }
    }

    // -----------------------------------------------------------------------
    // SettingsForm: non-TopMost dialog for managing keywords and replacement token.
    // On Save, writes blacklist.txt and replacement.txt to the config directory
    // and exposes updated values via properties.
    // -----------------------------------------------------------------------
    public sealed class SettingsForm : Form
    {
        private ListBox  _keywordList;
        private TextBox  _newKeywordBox;
        private TextBox  _replacementBox;
        private string   _configDir;

        public string[] UpdatedKeywords    { get; private set; }
        public string   UpdatedReplacement { get; private set; }

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
            this.ClientSize      = new Size(430, 340);

            Label kwLabel = new Label();
            kwLabel.Text     = "Monitored Keywords:";
            kwLabel.AutoSize = true;
            kwLabel.Location = new Point(10, 12);
            this.Controls.Add(kwLabel);

            Label replLabel = new Label();
            replLabel.Text     = "Replacement text:";
            replLabel.AutoSize = true;
            replLabel.Location = new Point(10, 248);
            this.Controls.Add(replLabel);

            Label newKwLabel = new Label();
            newKwLabel.Text     = "New keyword:";
            newKwLabel.AutoSize = true;
            newKwLabel.Location = new Point(10, 178);
            this.Controls.Add(newKwLabel);

            _keywordList = new ListBox();
            _keywordList.Location      = new Point(10, 32);
            _keywordList.Size          = new Size(410, 130);
            _keywordList.SelectionMode = SelectionMode.One;
            _keywordList.Sorted        = false;
            foreach (string kw in currentKeywords)
                _keywordList.Items.Add(kw);
            this.Controls.Add(_keywordList);

            _newKeywordBox = new TextBox();
            _newKeywordBox.Location = new Point(100, 175);
            _newKeywordBox.Size     = new Size(220, 23);
            // Enter in the new-keyword box triggers Add without closing the form.
            _newKeywordBox.KeyDown += delegate(object s, KeyEventArgs e)
            {
                if (e.KeyCode == Keys.Enter)
                {
                    e.SuppressKeyPress = true;
                    AddKeyword();
                }
            };
            this.Controls.Add(_newKeywordBox);

            Button addButton = new Button();
            addButton.Text     = "Add";
            addButton.Location = new Point(330, 174);
            addButton.Size     = new Size(90, 25);
            addButton.Click   += delegate(object s, EventArgs e) { AddKeyword(); };
            this.Controls.Add(addButton);

            Button removeButton = new Button();
            removeButton.Text     = "Remove Selected";
            removeButton.Location = new Point(330, 207);
            removeButton.Size     = new Size(90, 25);
            removeButton.Click   += delegate(object s, EventArgs e)
            {
                if (_keywordList.SelectedIndex >= 0)
                    _keywordList.Items.RemoveAt(_keywordList.SelectedIndex);
            };
            this.Controls.Add(removeButton);

            _replacementBox = new TextBox();
            _replacementBox.Location = new Point(140, 245);
            _replacementBox.Size     = new Size(150, 23);
            _replacementBox.Text     = currentReplacement;
            this.Controls.Add(_replacementBox);

            Button cancelButton = new Button();
            cancelButton.Text         = "Cancel";
            cancelButton.DialogResult = DialogResult.Cancel;
            cancelButton.Location     = new Point(225, 295);
            cancelButton.Size         = new Size(90, 30);
            this.Controls.Add(cancelButton);

            // Save button has no DialogResult; validation fires first.
            Button saveButton = new Button();
            saveButton.Text     = "Save";
            saveButton.Location = new Point(325, 295);
            saveButton.Size     = new Size(90, 30);
            saveButton.Click   += delegate(object s, EventArgs e) { SaveSettings(); };
            this.Controls.Add(saveButton);

            // CancelButton closes on Esc; AcceptButton intentionally unset so
            // Enter in the form body does not accidentally trigger Save.
            this.CancelButton = cancelButton;
        }

        // Adds trimmed text from _newKeywordBox to the list (case-insensitive dedup).
        private void AddKeyword()
        {
            string kw = _newKeywordBox.Text.Trim();
            if (kw.Length == 0) return;

            foreach (object item in _keywordList.Items)
            {
                if (string.Compare(item.ToString(), kw, StringComparison.OrdinalIgnoreCase) == 0)
                    return;
            }

            _keywordList.Items.Add(kw);
            _newKeywordBox.Clear();
        }

        // Validates, writes config files, exposes updated values, closes with OK.
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

            string[] keywords = new string[_keywordList.Items.Count];
            for (int i = 0; i < _keywordList.Items.Count; i++)
                keywords[i] = _keywordList.Items[i].ToString();

            WriteConfigFiles(keywords, replacement);

            UpdatedKeywords    = keywords;
            UpdatedReplacement = replacement;
            this.DialogResult  = DialogResult.OK;
        }

        // Persists keyword list and replacement token. UTF-8 without BOM.
        private void WriteConfigFiles(string[] keywords, string replacement)
        {
            UTF8Encoding utf8NoBom = new UTF8Encoding(false);

            using (StreamWriter sw = new StreamWriter(
                Path.Combine(_configDir, "blacklist.txt"), false, utf8NoBom))
            {
                sw.WriteLine("# One keyword per line. Case-insensitive. Lines starting with # are comments.");
                sw.WriteLine("# Examples of additional keywords to add: token, secret, api_key");
                foreach (string kw in keywords)
                    sw.WriteLine(kw);
            }

            File.WriteAllText(
                Path.Combine(_configDir, "replacement.txt"),
                replacement,
                utf8NoBom);
        }
    }

    // -----------------------------------------------------------------------
    // ClipboardMonitor: hidden NativeWindow that receives WM_CLIPBOARDUPDATE
    // via AddClipboardFormatListener and WM_HOTKEY for Ctrl+Alt+Q.
    //
    // Anti-recursion strategy:
    //   Layer 1 — unhook/rehook: RemoveClipboardFormatListener before Clipboard.SetText
    //             so our own write does not re-trigger WM_CLIPBOARDUPDATE.
    //   Layer 2 — _dialogOpen flag: discard events while a dialog is visible.
    //             ShowDialog pumps its own message loop, so rapid clipboard changes
    //             can still queue WM_CLIPBOARDUPDATE events that would stack dialogs.
    // -----------------------------------------------------------------------
    public sealed class ClipboardMonitor : NativeWindow, IDisposable
    {
        private const int  WM_CLIPBOARDUPDATE = 0x031D;
        private const int  WM_HOTKEY          = 0x0312;
        private const int  HOTKEY_ID          = 0xB001;
        private const uint MOD_CONTROL_ALT    = 0x0003;   // MOD_CONTROL | MOD_ALT
        private const uint VK_Q               = 0x51;

        // _kvPattern       — keyword + separator + value → enables redaction
        // _presencePattern — keyword word-boundary only  → warning fallback
        private Regex  _kvPattern;
        private Regex  _presencePattern;

        // "$" doubled so Regex.Replace does not interpret "$1" as back-reference.
        private string _replacementForRegex;

        private bool _dialogOpen;
        private bool _disposed;

        public event EventHandler ExitRequested;

        public string[] Keywords    { get; private set; }
        public string   Replacement { get; private set; }
        /// <summary>When true, WM_CLIPBOARDUPDATE events are silently ignored.</summary>
        public bool     Paused      { get; set; }

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

        public ClipboardMonitor(string[] keywords, string replacement)
        {
            Keywords    = (string[])keywords.Clone();
            Replacement = replacement;
            _replacementForRegex = replacement.Replace("$", "$$");
            BuildPatterns(keywords);

            CreateHandle(new CreateParams());

            bool listenerAdded = AddClipboardFormatListener(this.Handle);
            if (!listenerAdded)
                throw new InvalidOperationException(
                    string.Format(
                        "AddClipboardFormatListener failed (Win32 error {0}).",
                        Marshal.GetLastWin32Error()));

            // RegisterHotKey failure is non-fatal; tray Exit menu remains available.
            bool hotkeyRegistered = RegisterHotKey(this.Handle, HOTKEY_ID, MOD_CONTROL_ALT, VK_Q);
            if (!hotkeyRegistered)
                Console.Error.WriteLine(
                    string.Format(
                        "[ClipAssistant] Warning: RegisterHotKey (Ctrl+Alt+Q) failed " +
                        "(Win32 error {0}). Use tray icon to exit.",
                        Marshal.GetLastWin32Error()));
        }

        /// <summary>Hot-reload keywords/replacement without restart. Call from UI thread.</summary>
        public void UpdateConfig(string[] keywords, string replacement)
        {
            Keywords             = (string[])keywords.Clone();
            Replacement          = replacement;
            _replacementForRegex = replacement.Replace("$", "$$");
            BuildPatterns(keywords);
        }

        // Compiles both Regex patterns from the keyword array.
        private void BuildPatterns(string[] keywords)
        {
            string[] escaped = new string[keywords.Length];
            for (int i = 0; i < keywords.Length; i++)
                escaped[i] = Regex.Escape(keywords[i]);

            string alt = string.Join("|", escaped);

            // Group 1 = keyword, Group 2 = separator (optional quotes + auth scheme prefix),
            // Group 3 = value (the only part replaced).
            // (?<!\p{L}) / (?!\p{L}): Unicode-aware boundary so CJK keywords match;
            // \b fails for CJK because those chars are \W in .NET, giving no \w/\W transition.
            string kvPat = @"(?<!\p{L})(" + alt +
                           @")(""?\s*[:=]\s*""?(?:Bearer\s+|Basic\s+)?)([^"",\s;&]+)";
            _kvPattern = new Regex(kvPat, RegexOptions.IgnoreCase | RegexOptions.Compiled);

            // Presence pattern: keyword at Unicode letter boundary.
            string presencePat = @"(?<!\p{L})(" + alt + @")(?!\p{L})";
            _presencePattern = new Regex(presencePat, RegexOptions.IgnoreCase | RegexOptions.Compiled);
        }

        protected override void WndProc(ref Message m)
        {
            switch (m.Msg)
            {
                case WM_CLIPBOARDUPDATE:
                    // Layer 2 anti-recursion: drop events while a dialog is open.
                    if (!_dialogOpen)
                        HandleClipboard();
                    break;

                case WM_HOTKEY:
                    if (m.WParam.ToInt32() == HOTKEY_ID && ExitRequested != null)
                        ExitRequested(this, EventArgs.Empty);
                    break;
            }
            base.WndProc(ref m);
        }

        // Branch 1: k-v match  → ConfirmForm → redact on OK
        // Branch 2: keyword present but no k-v → WarningForm (manual review)
        // Branches are mutually exclusive; they never stack.
        private void HandleClipboard()
        {
            if (Paused) return;

            string text;
            try   { text = Clipboard.GetText(); }
            catch (ExternalException) { return; }

            if (string.IsNullOrEmpty(text)) return;

            // --- Branch 1 ---
            MatchCollection kvMatches = _kvPattern.Matches(text);
            if (kvMatches.Count > 0)
            {
                HashSet<string> hits = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (Match match in kvMatches)
                    hits.Add(match.Groups[1].Value.ToLowerInvariant());
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
                            string redacted = _kvPattern.Replace(text, "$1$2" + _replacementForRegex);

                            // Layer 1 anti-recursion: unhook before writing to clipboard.
                            RemoveClipboardFormatListener(this.Handle);
                            try   { Clipboard.SetText(redacted); }
                            catch (ExternalException) { }
                            finally { AddClipboardFormatListener(this.Handle); }
                        }
                    }
                }
                finally { _dialogOpen = false; }
                return;
            }

            // --- Branch 2 ---
            MatchCollection presenceMatches = _presencePattern.Matches(text);
            if (presenceMatches.Count > 0)
            {
                HashSet<string> hits = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (Match match in presenceMatches)
                    hits.Add(match.Groups[1].Value.ToLowerInvariant());
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

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;

            if (this.Handle != IntPtr.Zero)
            {
                UnregisterHotKey(this.Handle, HOTKEY_ID);
                RemoveClipboardFormatListener(this.Handle);
            }
            DestroyHandle();
        }
    }

    // -----------------------------------------------------------------------
    // MonitorContext: ApplicationContext wiring ClipboardMonitor to a NotifyIcon
    // with Pause/Resume, Settings, and Exit tray menu items.
    // -----------------------------------------------------------------------
    public sealed class MonitorContext : ApplicationContext
    {
        private ClipboardMonitor  _monitor;
        private NotifyIcon        _tray;
        private Icon              _trayIcon;
        private ToolStripMenuItem _pauseMenuItem;
        private string            _configDir;

        public MonitorContext(string[] keywords, string replacement, string configDir)
        {
            _configDir = configDir;

            _pauseMenuItem       = new ToolStripMenuItem("Pause Monitoring");
            _pauseMenuItem.Click += new EventHandler(OnPauseToggle);

            ToolStripMenuItem settingsItem = new ToolStripMenuItem("Settings...");
            settingsItem.Click += new EventHandler(OnSettings);

            ToolStripMenuItem exitItem = new ToolStripMenuItem("Exit");
            exitItem.Click += delegate(object s, EventArgs e) { ExitThread(); };

            ContextMenuStrip menu = new ContextMenuStrip();
            menu.Items.Add(_pauseMenuItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(settingsItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(exitItem);

            _trayIcon           = CreateLockIcon();
            _tray               = new NotifyIcon();
            _tray.Icon          = _trayIcon;
            _tray.Text          = "Clip Assistant - Active";
            _tray.ContextMenuStrip = menu;
            _tray.Visible       = true;
            // Double-click also opens Settings for quick access.
            _tray.DoubleClick  += new EventHandler(OnSettings);

            _monitor = new ClipboardMonitor(keywords, replacement);
            _monitor.ExitRequested += delegate(object s, EventArgs e) { ExitThread(); };
        }

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

        private void OnSettings(object sender, EventArgs e)
        {
            using (SettingsForm sf = new SettingsForm(_monitor.Keywords, _monitor.Replacement, _configDir))
            {
                if (sf.ShowDialog() == DialogResult.OK)
                    _monitor.UpdateConfig(sf.UpdatedKeywords, sf.UpdatedReplacement);
            }
        }

        // Needed to release the HICON returned by Bitmap.GetHicon().
        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DestroyIcon(IntPtr hIcon);

        // Draws a 16x16 padlock icon at runtime: blue background, white shackle + body, blue keyhole.
        // Avoids shipping an external .ico file.
        private static Icon CreateLockIcon()
        {
            Color blue = Color.FromArgb(255, 41, 128, 185);

            using (Bitmap bmp = new Bitmap(16, 16))
            {
                using (Graphics g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.Clear(Color.Transparent);

                    using (SolidBrush bg = new SolidBrush(blue))
                        g.FillRectangle(bg, 0, 0, 16, 16);

                    using (SolidBrush body = new SolidBrush(Color.White))
                        g.FillRectangle(body, 3, 9, 10, 6);

                    using (GraphicsPath path = new GraphicsPath())
                    {
                        path.AddLine(5, 9, 5, 6);
                        path.AddArc(5, 2, 5, 8, 180, 180);
                        path.AddLine(10, 6, 10, 9);

                        using (Pen pen = new Pen(Color.White, 2.0f))
                        {
                            pen.LineJoin = LineJoin.Round;
                            g.DrawPath(pen, path);
                        }
                    }

                    using (SolidBrush hole = new SolidBrush(blue))
                    {
                        g.FillEllipse(hole, 6, 10, 4, 3);
                        g.FillRectangle(hole, 7, 12, 2, 2);
                    }
                }

                IntPtr hIcon = bmp.GetHicon();
                Icon icon = (Icon)Icon.FromHandle(hIcon).Clone();
                DestroyIcon(hIcon);
                return icon;
            }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                if (_tray != null)
                {
                    _tray.Visible = false;
                    _tray.Dispose();
                    _tray = null;
                }

                if (_trayIcon != null)
                {
                    _trayIcon.Dispose();
                    _trayIcon = null;
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

    // -----------------------------------------------------------------------
    // Program: application entry point.
    // [STAThread] is required for WinForms / Clipboard APIs — replaces the
    // PowerShell -STA relaunch workaround in monitor.ps1.
    //
    // Config files (blacklist.txt, replacement.txt) are resolved relative to
    // the exe's directory (AppDomain.CurrentDomain.BaseDirectory) so the exe
    // can be placed anywhere as long as the two text files accompany it.
    // -----------------------------------------------------------------------
    internal static class Program
    {
        private static readonly string[] DefaultKeywords    = { "host", "password", "pw", "account", "authorization" };
        private const           string   DefaultReplacement = "***";

        [STAThread]
        private static void Main()
        {
            string baseDir = AppDomain.CurrentDomain.BaseDirectory;

            string[] keywords    = LoadKeywords(baseDir);
            string   replacement = LoadReplacement(baseDir);

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            MonitorContext context = null;
            try
            {
                context = new MonitorContext(keywords, replacement, baseDir);
                Application.Run(context);
            }
            finally
            {
                // Belt-and-suspenders: ensure tray icon is removed even if an
                // unhandled exception escapes Application.Run.
                if (context != null)
                    context.Dispose();
            }
        }

        // Parses blacklist.txt: skips blanks and # comments, case-insensitive dedup.
        // Falls back to DefaultKeywords when file is missing or yields no entries.
        private static string[] LoadKeywords(string baseDir)
        {
            string path = Path.Combine(baseDir, "blacklist.txt");

            if (File.Exists(path))
            {
                HashSet<string> seen     = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                List<string>    keywords = new List<string>();

                foreach (string raw in File.ReadAllLines(path, Encoding.UTF8))
                {
                    string line = raw.Trim();
                    if (line.Length == 0 || line.StartsWith("#")) continue;
                    if (seen.Add(line))
                        keywords.Add(line);
                }

                if (keywords.Count > 0)
                    return keywords.ToArray();

                Console.Error.WriteLine(
                    "[ClipAssistant] Warning: blacklist.txt has no effective entries. " +
                    "Using defaults: " + string.Join(", ", DefaultKeywords));
            }
            else
            {
                Console.Error.WriteLine(
                    "[ClipAssistant] Warning: blacklist.txt not found at '" + path + "'. " +
                    "Using defaults: " + string.Join(", ", DefaultKeywords));
            }

            return (string[])DefaultKeywords.Clone();
        }

        // Reads replacement.txt (trimmed). Falls back to DefaultReplacement when
        // file is missing or empty.
        private static string LoadReplacement(string baseDir)
        {
            string path = Path.Combine(baseDir, "replacement.txt");

            if (File.Exists(path))
            {
                string token = File.ReadAllText(path, Encoding.UTF8).Trim();
                if (token.Length > 0)
                    return token;

                Console.Error.WriteLine(
                    "[ClipAssistant] Warning: replacement.txt is empty. Using default: '" +
                    DefaultReplacement + "'");
            }
            else
            {
                Console.Error.WriteLine(
                    "[ClipAssistant] Warning: replacement.txt not found at '" + path + "'. Using default: '" +
                    DefaultReplacement + "'");
            }

            return DefaultReplacement;
        }
    }
}
