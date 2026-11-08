@echo off
REM ==========================================================================
REM  One-click HEALTH CHECK for all SQL instances on this VM (uses HC_Snapshot.sql).
REM  Double-click while logged in with the generic admin account:
REM    - asks for an optional label (Enter = DAILY)
REM    - asks for YOUR Windows account (same one you use for SSMS
REM      "Run as different user") and uses it for the SQL connections
REM      (falls back to the logged-in RDP account per instance if needed)
REM    - emails ONE combined health report for the VM (Database Mail),
REM      report attached; nothing is stored for comparison
REM  Keep this file, Invoke-PrePostCheck.ps1 and HC_Snapshot.sql
REM  together in a folder your account can read, e.g. C:\DBA\PrePostCheck
REM ==========================================================================
setlocal
title SQL Server Health Check
cd /d "%~dp0"

REM No "Run as different user" / Secondary Logon service needed: the script logs on
REM with your account itself and falls back to the RDP user if that account fails.

if not exist "%~dp0Invoke-PrePostCheck.ps1" (
    echo Invoke-PrePostCheck.ps1 not found in %~dp0
    pause
    exit /b 1
)

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-PrePostCheck.ps1" -Phase HEALTH %*
set RC=%ERRORLEVEL%
if not "%RC%"=="0" pause
endlocal & exit /b %RC%
