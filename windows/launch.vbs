' Clip Assistant Launcher
' Double-click to start Clip Assistant without a console window.
' To create a desktop shortcut: right-click this file -> Create shortcut -> move to Desktop.
Dim scriptDir, psFile, cmd
scriptDir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
psFile    = scriptDir & "monitor.ps1"
cmd       = "powershell.exe -ExecutionPolicy Bypass -STA -WindowStyle Hidden -NonInteractive -File """ & psFile & """"
CreateObject("WScript.Shell").Run cmd, 0, False
