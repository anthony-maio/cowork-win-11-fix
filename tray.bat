@echo off
setlocal
start "" powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0scripts\tray-monitor.ps1"
