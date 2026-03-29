@echo off
setlocal
powershell.exe -ExecutionPolicy Bypass -File "%~dp0scripts\claude-cowork-fix.ps1" -Status
pause
