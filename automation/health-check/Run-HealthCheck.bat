@echo off
REM ==========================================================================
REM  One-click SQL Server health check for all instances on this VM.
REM  Double-click while logged in with the generic admin account:
REM    - asks for label (PRE / POST / DAILY) and change ticket
REM    - asks for YOUR Windows account (same one you use for SSMS
REM      "Run as different user") and runs the check as that account
REM    - emails each instance's report via Database Mail and saves a copy
REM      in the Reports folder next to this file
REM  Keep this file, Invoke-HealthCheck.ps1 and 44_health_check_report_email.sql
REM  together in a folder your account can read, e.g. C:\DBA\HealthCheck
REM ==========================================================================
setlocal
title SQL Server Health Check
cd /d "%~dp0"

if not exist "%~dp0Invoke-HealthCheck.ps1" (
    echo Invoke-HealthCheck.ps1 not found in %~dp0
    pause
    exit /b 1
)

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-HealthCheck.ps1" %*
set RC=%ERRORLEVEL%
if not "%RC%"=="0" pause
endlocal & exit /b %RC%
