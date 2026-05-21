#Requires -Version 5.1
# Run once to create a desktop shortcut that launches Clip Assistant with no visible window.
# Usage: powershell -ExecutionPolicy Bypass -File .\windows\create-shortcut.ps1

$exePath      = Join-Path $PSScriptRoot 'ClipAssistant.exe'
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Clip Assistant.lnk'

$wsh = New-Object -ComObject WScript.Shell
$lnk = $wsh.CreateShortcut($shortcutPath)
$lnk.TargetPath       = $exePath
$lnk.WorkingDirectory = $PSScriptRoot
$lnk.Description      = 'Clip Assistant - Clipboard monitor'
$lnk.Save()

Write-Host "Shortcut created: $shortcutPath"
