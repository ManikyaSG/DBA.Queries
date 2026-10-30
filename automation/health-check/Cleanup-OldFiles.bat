@echo off
REM ==========================================================================
REM  Deletes Reports / Logs (and Snapshots, if present) files older than 48 hours in this folder.
REM  PRE snapshots without a POST are kept 7 days (see Cleanup-OldFiles.ps1).
REM  Double-click, or schedule it. Optional:  Cleanup-OldFiles.bat -Hours 72
REM  Preview only (deletes nothing):          Cleanup-OldFiles.bat -WhatIf
REM ==========================================================================
setlocal
cd /d "%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Cleanup-OldFiles.ps1" %*
if "%~1"=="" pause
endlocal
