@echo off
REM ==========================================================================
REM  One-click PRE / POST change check for all SQL instances on this VM.
REM  Double-click while logged in with the generic admin account:
REM    - asks PRE or POST and the change ticket (pairs the two runs)
REM    - asks for YOUR Windows account (same one you use for SSMS
REM      "Run as different user") and runs the check as that account
REM    - PRE: stores a snapshot on this VM + emails it; POST: compares with PRE,
REM      emails SUCCESS or DIFFERENCES FOUND (Database Mail)
REM  Keep this file, Invoke-PrePostCheck.ps1 and HC_Snapshot.sql
REM  together in a folder your account can read, e.g. C:\DBA\PrePostCheck
REM ==========================================================================
setlocal
title SQL Server PRE-POST Change Check
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

if not exist "%~dp0Invoke-PrePostCheck.ps1" (
    echo Invoke-PrePostCheck.ps1 not found in %~dp0
    pause
    exit /b 1
)

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-PrePostCheck.ps1" %*
set RC=%ERRORLEVEL%
if not "%RC%"=="0" pause
endlocal & exit /b %RC%
