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

REM --- Make sure the Secondary Logon service (needed for "run as different user") is running ---
sc query seclogon | find /i "RUNNING" >nul
if errorlevel 1 (
    echo Secondary Logon service is not running - starting it...
    net session >nul 2>&1
    if errorlevel 1 (
        echo Administrator rights needed - approve the UAC prompt.
        powershell -NoProfile -Command "Start-Process cmd.exe -Verb RunAs -Wait -ArgumentList '/c sc config seclogon start= demand & net start seclogon & timeout /t 3'"
    ) else (
        sc config seclogon start= demand >nul
        net start seclogon
    )
    sc query seclogon | find /i "RUNNING" >nul
    if errorlevel 1 (
        echo.
        echo WARNING: Secondary Logon could not be started. Current configuration:
        sc qc seclogon
        sc query seclogon
        echo Check services.msc ^> Secondary Logon, or a Group Policy that disables it.
        pause
    ) else (
        echo Secondary Logon service started.
    )
)

if not exist "%~dp0Invoke-HealthCheck.ps1" (
    echo Invoke-HealthCheck.ps1 not found in %~dp0
    pause
    exit /b 1
)

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-HealthCheck.ps1" %*
set RC=%ERRORLEVEL%
if not "%RC%"=="0" pause
endlocal & exit /b %RC%
