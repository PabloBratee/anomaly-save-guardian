@echo off
REM Portable double-click launcher for the STALKER GAMMA Save Backup app.
REM Finds its own folder (%~dp0) so it works no matter where you put the files.
REM Uses a per-run ExecutionPolicy bypass; it does NOT change your system policy.
start "" /b powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0stalker-gamma-backup-ui.ps1"
