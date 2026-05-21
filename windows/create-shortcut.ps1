#Requires -Version 5.1
# Run once to create a desktop shortcut that launches Clip Assistant with no visible window.
# Usage: powershell -ExecutionPolicy Bypass -File .\windows\create-shortcut.ps1

$monitorPath = Join-Path $PSScriptRoot 'monitor.ps1'
$psExe       = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$psArgs      = "-ExecutionPolicy Bypass -STA -WindowStyle Hidden -NonInteractive -File `"$monitorPath`""
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Clip Assistant.lnk'

$wsh = New-Object -ComObject WScript.Shell
$lnk = $wsh.CreateShortcut($shortcutPath)
$lnk.TargetPath   = $psExe
$lnk.Arguments    = $psArgs
$lnk.WindowStyle  = 7          # SW_SHOWMINNOACTIVE; overridden to hidden by -WindowStyle Hidden
$lnk.Description  = 'Clip Assistant - Clipboard monitor'
$lnk.WorkingDirectory = $PSScriptRoot
$lnk.Save()

Write-Host "Shortcut created: $shortcutPath"
