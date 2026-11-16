@echo off
REM ==========================================================================
REM  SQL Server performance check - every instance on this VM.
REM  Double-click: samples every instance every 60 s for 30 min (see $Config in
REM  Invoke-PerfCheck.ps1), then emails one report and saves it in Reports\.
REM  Command line / Task Scheduler:
REM    Run-PerfCheck.bat -SampleSec 30 -DurationMin 15 -Label LOADTEST1
REM    Run-PerfCheck.bat -Unattended -Label SCHEDULED
REM    Run-PerfCheck.bat -ResetCredential      (re-enter the SQL login password)
REM  Only 3 files, kept together: Run-PerfCheck.bat, Invoke-PerfCheck.ps1, PerfCheck.sql
REM ==========================================================================
setlocal
title SQL Server Performance Check
cd /d "%~dp0"
set "UNATTENDED="
echo %* | find /i "UNATTENDED" >nul && set "UNATTENDED=1"

if not exist "%~dp0Invoke-PerfCheck.ps1" (
    echo Invoke-PerfCheck.ps1 not found next to this file.
    if not defined UNATTENDED pause
    exit /b 3
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-PerfCheck.ps1" %*
set RC=%ERRORLEVEL%
REM 0 = OK, 1 = warnings, 2 = critical / failed instance, 3 = script error
if not defined UNATTENDED if "%RC%"=="3" pause
exit /b %RC%
