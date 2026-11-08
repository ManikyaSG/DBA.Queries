@echo off
REM ==========================================================================
REM  One-click SQL Server check for all instances on this VM.
REM  Double-click while logged in with the generic admin account, then choose:
REM    1 PRE     - snapshot stored on this VM + emailed (before a change)
REM    2 POST    - compared with PRE, emails SUCCESS or DIFFERENCES FOUND
REM    3 HEALTH  - health check report only
REM    4 CLEANUP - delete old snapshots / reports / logs (also done on every run)
REM  It starts the Secondary Logon service, asks for YOUR Windows account and
REM  runs as that account; instances it can't use are retried as the RDP account.
REM  Command line:  Run-PrePostCheck.bat -Phase HEALTH
REM                 Run-PrePostCheck.bat -Phase CLEANUP   (e.g. from Task Scheduler)
REM  Only 3 files, kept together in a folder your account can read and write:
REM    Run-PrePostCheck.bat, Invoke-PrePostCheck.ps1, HC_Snapshot.sql
REM ==========================================================================
setlocal
title SQL Server PRE-POST / Health Check
cd /d "%~dp0"

REM Cleanup only: no Secondary Logon / credentials needed
echo %* | find /i "CLEANUP" >nul && goto :run

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
        echo The script will still try, and falls back to your account from this window.
        timeout /t 10
    ) else (
        echo Secondary Logon service started.
    )
)

:run
if not exist "%~dp0Invoke-PrePostCheck.ps1" (
    echo Invoke-PrePostCheck.ps1 not found in %~dp0
    pause
    exit /b 1
)

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-PrePostCheck.ps1" %*
set RC=%ERRORLEVEL%
if not "%RC%"=="0" pause
endlocal & exit /b %RC%
