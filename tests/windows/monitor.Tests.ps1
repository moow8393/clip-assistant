#Requires -Version 5.1
# monitor.Tests.ps1
# Pester 5 tests for monitor.ps1.
# Covers: (1) config-file loading logic, (2) regex pattern behaviour,
# (3) SettingsForm disk-write and dedup behaviour (STA runspace).
#
# All helper functions are defined inside a top-level BeforeAll block so
# Pester 5's scoping rules make them visible to every Describe / It block.

BeforeAll {

    # -------------------------------------------------------------------------
    # Returns the raw C# source embedded in monitor.ps1 (the Add-Type here-string).
    # -------------------------------------------------------------------------
    function Get-MonitorCSharpSource {
        $monitorScript = Join-Path $PSScriptRoot '..\..\windows\monitor.ps1'
        $content = Get-Content -Path $monitorScript -Raw
        # Extract the here-string body between @' ... '@
        if ($content -match "(?s)Add-Type.*?@'(.+?)'@") {
            return $Matches[1]
        }
        throw "Could not extract C# source from monitor.ps1"
    }

    # -------------------------------------------------------------------------
    # Reproduces the config-loading block from monitor.ps1 as a testable function.
    # Accepts explicit file paths so tests can use $TestDrive without dot-sourcing
    # the full script (which would attempt to start the WinForms message pump).
    # Returns a hashtable: KeywordsArray, ReplacementToken, Warnings.
    # -------------------------------------------------------------------------
    function Invoke-ConfigLoad {
        param(
            [string]$BlacklistPath,
            [string]$ReplacementPath
        )

        $defaultKeywords    = @('host', 'password', 'pw', 'account', 'authorization')
        $defaultReplacement = '***'
        $warnings           = [System.Collections.Generic.List[string]]::new()

        # --- blacklist.txt ---
        if (Test-Path $BlacklistPath) {
            $rawLines = Get-Content -Path $BlacklistPath
            $seen     = [System.Collections.Generic.HashSet[string]]::new(
                            [System.StringComparer]::OrdinalIgnoreCase)
            $kwList   = [System.Collections.Generic.List[string]]::new()

            foreach ($line in $rawLines) {
                $trimmed = $line.Trim()
                if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
                if ($seen.Add($trimmed)) {
                    $kwList.Add($trimmed)
                }
            }

            if ($kwList.Count -eq 0) {
                $warnings.Add("blacklist.txt contains no effective entries. Using built-in defaults: $($defaultKeywords -join ', ')")
                $kwList = [System.Collections.Generic.List[string]]$defaultKeywords
            }
        }
        else {
            $warnings.Add("blacklist.txt not found at '$BlacklistPath'. Using built-in defaults: $($defaultKeywords -join ', ')")
            $kwList = [System.Collections.Generic.List[string]]$defaultKeywords
        }

        $keywordsArray = $kwList.ToArray()

        # --- replacement.txt ---
        if (Test-Path $ReplacementPath) {
            $replacementToken = (Get-Content -Path $ReplacementPath -Raw).Trim()
            if ($replacementToken -eq '') {
                $warnings.Add("replacement.txt is empty. Using built-in default: '$defaultReplacement'")
                $replacementToken = $defaultReplacement
            }
        }
        else {
            $warnings.Add("replacement.txt not found at '$ReplacementPath'. Using built-in default: '$defaultReplacement'")
            $replacementToken = $defaultReplacement
        }

        return @{
            KeywordsArray    = $keywordsArray
            ReplacementToken = $replacementToken
            Warnings         = $warnings
        }
    }

    # -------------------------------------------------------------------------
    # Build the same regex patterns that ClipboardMonitor.BuildPatterns() produces,
    # entirely in PowerShell/pure-.NET so no Win32 API is touched.
    # -------------------------------------------------------------------------
    function Build-KvPattern {
        param([string[]]$Keywords)
        $escaped = $Keywords | ForEach-Object { [regex]::Escape($_) }
        $alt     = $escaped -join '|'
        # Mirrors the C# verbatim pattern: [^"",\s;&]+ == [^",\s;&]+
        # In PowerShell double-quoted strings, backtick-escape the double quote.
        $pat = '\b(' + $alt + ')("?\s*[:=]\s*"?(?:Bearer\s+|Basic\s+)?)([^",\s;&]+)'
        return [regex]::new($pat, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }

    function Build-PresencePattern {
        param([string[]]$Keywords)
        $escaped = $Keywords | ForEach-Object { [regex]::Escape($_) }
        $alt     = $escaped -join '|'
        $pat = '\b(' + $alt + ')\b'
        return [regex]::new($pat, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }

    # -------------------------------------------------------------------------
    # Runs a script block inside a dedicated STA runspace.
    # $TestDriveValue is pre-set as a session-state variable so the caller's
    # ScriptBlock can reference $TestDrive directly.
    # Type loading is done in a separate prior invocation on the same runspace
    # so the compiled types are available when the test body runs.
    # -------------------------------------------------------------------------
    function Invoke-InStaRunspace {
        param(
            [scriptblock]$ScriptBlock,
            [string]$TestDriveValue
        )

        $csSource = Get-MonitorCSharpSource

        # Build an InitialSessionState that pre-populates $TestDrive.
        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $varEntry = New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry(
            'TestDrive', $TestDriveValue, 'Config directory for this test')
        $iss.Variables.Add($varEntry)

        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
        $rs.ApartmentState = 'STA'
        $rs.Open()

        try {
            # Step 1 – load C# types (done once per runspace lifetime).
            $psLoad = [System.Management.Automation.PowerShell]::Create()
            $psLoad.Runspace = $rs
            [void]$psLoad.AddScript({
                param($src)
                if (-not ([System.Management.Automation.PSTypeName]'ClipAssistant.SettingsForm').Type) {
                    Add-Type -ReferencedAssemblies @(
                        'System.Windows.Forms',
                        'System.Drawing',
                        'System.Runtime.InteropServices'
                    ) -TypeDefinition $src
                }
            })
            [void]$psLoad.AddArgument($csSource)
            [void]$psLoad.Invoke()
            if ($psLoad.HadErrors) {
                throw ($psLoad.Streams.Error | ForEach-Object { $_.ToString() }) -join "`n"
            }

            # Step 2 – execute the test body; $TestDrive is already in session state.
            $psRun = [System.Management.Automation.PowerShell]::Create()
            $psRun.Runspace = $rs
            [void]$psRun.AddScript($ScriptBlock)
            $result = $psRun.Invoke()

            if ($psRun.HadErrors) {
                throw ($psRun.Streams.Error | ForEach-Object { $_.ToString() }) -join "`n"
            }

            return $result
        }
        finally {
            $rs.Close()
            $rs.Dispose()
        }
    }

    # Shared keyword list for all regex tests (matches monitor.ps1 built-in defaults)
    $script:TestKeywords = @('host', 'password', 'pw', 'account', 'authorization')
}

# ===========================================================================
# Describe 1 – Config file loading logic
# ===========================================================================
Describe 'Config file loading' {

    Context 'blacklist.txt - normal content' {
        It 'loads keywords correctly when file exists with valid entries' {
            $bl = Join-Path $TestDrive 'blacklist.txt'
            Set-Content -Path $bl -Encoding utf8 -Value @"
# comment line
host
password
pw
"@
            $result = Invoke-ConfigLoad -BlacklistPath $bl -ReplacementPath (Join-Path $TestDrive 'nope.txt')
            $result.KeywordsArray                                          | Should -Be @('host', 'password', 'pw')
            $result.Warnings | Where-Object { $_ -match 'blacklist' }     | Should -BeNullOrEmpty
        }
    }

    Context 'blacklist.txt - all blank or comment lines' {
        It 'falls back to built-in defaults and emits a warning' {
            $bl = Join-Path $TestDrive 'blacklist_empty.txt'
            Set-Content -Path $bl -Encoding utf8 -Value @"
# this is a comment

# another comment
"@
            $result = Invoke-ConfigLoad -BlacklistPath $bl -ReplacementPath (Join-Path $TestDrive 'nope.txt')
            $result.KeywordsArray | Should -Be @('host', 'password', 'pw', 'account', 'authorization')
            $result.Warnings      | Should -Not -BeNullOrEmpty
            $result.Warnings[0]   | Should -Match 'no effective entries'
        }
    }

    Context 'blacklist.txt - file missing' {
        It 'falls back to built-in defaults and emits a warning' {
            $result = Invoke-ConfigLoad `
                -BlacklistPath   (Join-Path $TestDrive 'does_not_exist.txt') `
                -ReplacementPath (Join-Path $TestDrive 'nope.txt')

            $result.KeywordsArray | Should -Be @('host', 'password', 'pw', 'account', 'authorization')
            $result.Warnings      | Should -Not -BeNullOrEmpty
            $result.Warnings[0]   | Should -Match 'not found'
        }
    }

    Context 'blacklist.txt - duplicate keywords (case-insensitive)' {
        It 'keeps only the first occurrence of each keyword' {
            $bl = Join-Path $TestDrive 'blacklist_dup.txt'
            Set-Content -Path $bl -Encoding utf8 -Value @"
password
PASSWORD
Password
host
HOST
"@
            $result = Invoke-ConfigLoad -BlacklistPath $bl -ReplacementPath (Join-Path $TestDrive 'nope.txt')
            $result.KeywordsArray | Should -Be @('password', 'host')
        }
    }

    Context 'replacement.txt - normal content' {
        It 'reads the replacement token from file' {
            $rp = Join-Path $TestDrive 'replacement.txt'
            Set-Content -Path $rp -Encoding utf8 -Value '[REDACTED]'

            $result = Invoke-ConfigLoad `
                -BlacklistPath   (Join-Path $TestDrive 'nope_bl.txt') `
                -ReplacementPath $rp

            $result.ReplacementToken                                         | Should -Be '[REDACTED]'
            $result.Warnings | Where-Object { $_ -match 'replacement' }     | Should -BeNullOrEmpty
        }
    }

    Context 'replacement.txt - file is empty' {
        It 'falls back to *** and emits a warning' {
            $rp = Join-Path $TestDrive 'replacement_empty.txt'
            # Write a file with only whitespace so .Trim() returns ''
            [System.IO.File]::WriteAllText($rp, '   ', [System.Text.Encoding]::UTF8)

            $result = Invoke-ConfigLoad `
                -BlacklistPath   (Join-Path $TestDrive 'nope_bl2.txt') `
                -ReplacementPath $rp

            $result.ReplacementToken                                               | Should -Be '***'
            $result.Warnings | Where-Object { $_ -match 'replacement.txt is empty' } | Should -Not -BeNullOrEmpty
        }
    }

    Context 'replacement.txt - file missing' {
        It 'falls back to *** and emits a warning' {
            $result = Invoke-ConfigLoad `
                -BlacklistPath   (Join-Path $TestDrive 'nope_bl3.txt') `
                -ReplacementPath (Join-Path $TestDrive 'nope_rp.txt')

            $result.ReplacementToken                                                    | Should -Be '***'
            $result.Warnings | Where-Object { $_ -match 'replacement.txt not found' }  | Should -Not -BeNullOrEmpty
        }
    }
}

# ===========================================================================
# Describe 2 – Regex pattern behaviour (pure .NET Regex, no Win32)
# ===========================================================================
Describe 'Regex pattern - k-v matching' {

    BeforeAll {
        $script:KvRegex = Build-KvPattern -Keywords $script:TestKeywords
    }

    Context 'should match - value captured in Group 3' {

        It '"PW: MyP@ssw0rd" - matches and captures the value' {
            $m = $script:KvRegex.Match('PW: MyP@ssw0rd')
            $m.Success         | Should -Be $true
            $m.Groups[3].Value | Should -Be 'MyP@ssw0rd'
        }

        It '"PW": "MyP@ssw0rd" - JSON quoting - matches and captures value' {
            $m = $script:KvRegex.Match('"PW": "MyP@ssw0rd"')
            $m.Success         | Should -Be $true
            $m.Groups[3].Value | Should -Be 'MyP@ssw0rd'
        }

        It '"PW: MyP@ssw0rd," - trailing comma is boundary, value captured correctly' {
            $m = $script:KvRegex.Match('PW: MyP@ssw0rd,')
            $m.Success         | Should -Be $true
            $m.Groups[3].Value | Should -Be 'MyP@ssw0rd'
        }

        It '"Name: John,PW: MyP@ssw0rd,Department: Eng" - matches on pw keyword' {
            $m = $script:KvRegex.Match('Name: John,PW: MyP@ssw0rd,Department: Eng')
            $m.Success                       | Should -Be $true
            $m.Groups[1].Value.ToLower()     | Should -Be 'pw'
            $m.Groups[3].Value               | Should -Be 'MyP@ssw0rd'
        }

        It '"Authorization: Bearer eyJtoken123" - Bearer prefix consumed in Group 2, token in Group 3' {
            $m = $script:KvRegex.Match('Authorization: Bearer eyJtoken123')
            $m.Success                       | Should -Be $true
            $m.Groups[1].Value               | Should -Be 'Authorization'
            $m.Groups[3].Value               | Should -Be 'eyJtoken123'
        }

        It '"host: 192.168.1.1" - matches host keyword with colon separator' {
            $m = $script:KvRegex.Match('host: 192.168.1.1')
            $m.Success         | Should -Be $true
            $m.Groups[1].Value | Should -Be 'host'
            $m.Groups[3].Value | Should -Be '192.168.1.1'
        }

        It '"password=secret" - matches with equals separator' {
            $m = $script:KvRegex.Match('password=secret')
            $m.Success         | Should -Be $true
            $m.Groups[1].Value | Should -Be 'password'
            $m.Groups[3].Value | Should -Be 'secret'
        }
    }

    Context 'should NOT match - word boundary protection' {

        It '"hostname=webserver01" - "host" is a prefix inside a longer word, no match' {
            $m = $script:KvRegex.Match('hostname=webserver01')
            $m.Success | Should -Be $false
        }

        It '"mypassword_field=test" - "password" preceded by word char, no match' {
            $m = $script:KvRegex.Match('mypassword_field=test')
            $m.Success | Should -Be $false
        }

        It '"accountType=premium" - "account" is a prefix inside a longer word, no match' {
            $m = $script:KvRegex.Match('accountType=premium')
            $m.Success | Should -Be $false
        }
    }
}

Describe 'Regex pattern - presence-only matching (no k-v structure)' {

    BeforeAll {
        $script:PresenceRegex = Build-PresencePattern -Keywords $script:TestKeywords
    }

    Context 'should match bare keyword in plain text' {

        It 'multi-line table text "Name PW Address\nJohn 123 xxx" matches pw' {
            $text = "Name PW Address`nJohn 123 xxx"
            $m    = $script:PresenceRegex.Match($text)
            $m.Success                   | Should -Be $true
            $m.Groups[1].Value.ToLower() | Should -Be 'pw'
        }

        It '"Employee Report\nName PW Address" matches pw in header row' {
            $text = "Employee Report`nName PW Address"
            $m    = $script:PresenceRegex.Match($text)
            $m.Success                   | Should -Be $true
            $m.Groups[1].Value.ToLower() | Should -Be 'pw'
        }
    }
}

# ===========================================================================
# Describe 3 – SettingsForm disk-write and dedup behaviour (STA runspace)
# ===========================================================================
Describe 'SettingsForm - disk write and dedup' {

    BeforeAll {
        # Pre-load C# types in the outer (MTA) runspace as well so the
        # Get-MonitorCSharpSource call can be validated early.
        # ClipboardMonitor and MonitorContext constructors are NOT called here
        # (they require a real HWND / Win32 environment).
        if (-not ([System.Management.Automation.PSTypeName]'ClipAssistant.SettingsForm').Type) {
            $src = Get-MonitorCSharpSource
            Add-Type -ReferencedAssemblies @(
                'System.Windows.Forms',
                'System.Drawing',
                'System.Runtime.InteropServices'
            ) -TypeDefinition $src
        }
    }

    Context 'WriteConfigFiles - blacklist.txt' {

        It 'written file contains the comment header' {
            $configDir = Join-Path $TestDrive 'cfg_header'
            [System.IO.Directory]::CreateDirectory($configDir) | Out-Null

            # The STA runspace only performs the write; file is read in the outer scope
            # to avoid PowerShell.Invoke() enumerating the raw string char-by-char.
            Invoke-InStaRunspace -TestDriveValue $configDir -ScriptBlock {
                $form = New-Object ClipAssistant.SettingsForm(
                    @('host', 'password'),
                    '***',
                    $TestDrive
                )
                $mi = $form.GetType().GetMethod(
                    'WriteConfigFiles',
                    [System.Reflection.BindingFlags]'NonPublic,Instance'
                )
                [void]$mi.Invoke($form, @([string[]]@('host', 'password'), '***'))
            } | Out-Null

            $content = Get-Content -Path (Join-Path $configDir 'blacklist.txt') -Raw
            $content | Should -Match '# One keyword per line'
            $content | Should -Match 'host'
            $content | Should -Match 'password'
        }

        It 'written blacklist.txt lists exactly the supplied keywords (non-comment lines)' {
            $configDir = Join-Path $TestDrive 'cfg_keywords'
            [System.IO.Directory]::CreateDirectory($configDir) | Out-Null

            Invoke-InStaRunspace -TestDriveValue $configDir -ScriptBlock {
                $form = New-Object ClipAssistant.SettingsForm(
                    @('alpha', 'beta', 'gamma'),
                    '[REDACTED]',
                    $TestDrive
                )
                $mi = $form.GetType().GetMethod(
                    'WriteConfigFiles',
                    [System.Reflection.BindingFlags]'NonPublic,Instance'
                )
                [void]$mi.Invoke($form, @([string[]]@('alpha', 'beta', 'gamma'), '[REDACTED]'))
            } | Out-Null

            $lines = Get-Content -Path (Join-Path $configDir 'blacklist.txt') |
                        Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne '' }
            $lines | Should -Be @('alpha', 'beta', 'gamma')
        }
    }

    Context 'WriteConfigFiles - replacement.txt' {

        It 'written replacement.txt contains the exact replacement token' {
            $configDir = Join-Path $TestDrive 'cfg_repl'
            [System.IO.Directory]::CreateDirectory($configDir) | Out-Null

            Invoke-InStaRunspace -TestDriveValue $configDir -ScriptBlock {
                $form = New-Object ClipAssistant.SettingsForm(
                    @('host'),
                    '[MASKED]',
                    $TestDrive
                )
                $mi = $form.GetType().GetMethod(
                    'WriteConfigFiles',
                    [System.Reflection.BindingFlags]'NonPublic,Instance'
                )
                [void]$mi.Invoke($form, @([string[]]@('host'), '[MASKED]'))
            } | Out-Null

            $token = Get-Content -Path (Join-Path $configDir 'replacement.txt') -Raw
            $token | Should -Be '[MASKED]'
        }
    }

    Context 'AddKeyword - case-insensitive deduplication' {

        It 'does not add a duplicate keyword with different casing' {
            $configDir = Join-Path $TestDrive 'cfg_dedup'
            [System.IO.Directory]::CreateDirectory($configDir) | Out-Null

            $result = Invoke-InStaRunspace -TestDriveValue $configDir -ScriptBlock {
                $form = New-Object ClipAssistant.SettingsForm(
                    @('password'),
                    '***',
                    $TestDrive
                )

                # Set _newKeywordBox.Text to a case variant of an existing keyword
                $tbField = $form.GetType().GetField(
                    '_newKeywordBox',
                    [System.Reflection.BindingFlags]'NonPublic,Instance'
                )
                $tb = $tbField.GetValue($form)
                $tb.Text = 'PASSWORD'

                $mi = $form.GetType().GetMethod(
                    'AddKeyword',
                    [System.Reflection.BindingFlags]'NonPublic,Instance'
                )
                [void]$mi.Invoke($form, $null)

                $lbField = $form.GetType().GetField(
                    '_keywordList',
                    [System.Reflection.BindingFlags]'NonPublic,Instance'
                )
                $lb = $lbField.GetValue($form)
                $lb.Items.Count
            }

            # Duplicate must be rejected; count stays at 1
            $result[0] | Should -Be 1
        }

        It 'adds a genuinely new keyword' {
            $configDir = Join-Path $TestDrive 'cfg_newkw'
            [System.IO.Directory]::CreateDirectory($configDir) | Out-Null

            $result = Invoke-InStaRunspace -TestDriveValue $configDir -ScriptBlock {
                $form = New-Object ClipAssistant.SettingsForm(
                    @('password'),
                    '***',
                    $TestDrive
                )

                $tbField = $form.GetType().GetField(
                    '_newKeywordBox',
                    [System.Reflection.BindingFlags]'NonPublic,Instance'
                )
                $tb = $tbField.GetValue($form)
                $tb.Text = 'token'

                $mi = $form.GetType().GetMethod(
                    'AddKeyword',
                    [System.Reflection.BindingFlags]'NonPublic,Instance'
                )
                [void]$mi.Invoke($form, $null)

                $lbField = $form.GetType().GetField(
                    '_keywordList',
                    [System.Reflection.BindingFlags]'NonPublic,Instance'
                )
                $lb = $lbField.GetValue($form)
                $lb.Items.Count
            }

            # Should now be 2: 'password' + 'token'
            $result[0] | Should -Be 2
        }
    }
}
