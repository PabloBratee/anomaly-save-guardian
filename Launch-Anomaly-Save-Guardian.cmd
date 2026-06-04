@echo off
REM Fallback / troubleshooting launcher for Anomaly Save Guardian.
REM For normal use, prefer Start-Anomaly-Save-Guardian.vbs (no console window).
REM Finds its own folder (%~dp0) so it works no matter where you put the files.
REM Uses a per-run ExecutionPolicy bypass; it does NOT change your system policy.
start "" /b powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0stalker-gamma-backup-ui.ps1"
