@echo off
start "" powershell.exe -ExecutionPolicy Bypass -STA -WindowStyle Hidden -NonInteractive -File "%~dp0monitor.ps1"
