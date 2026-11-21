@echo off
REM ==========================================================================
REM  SQL Server health & performance check - for a SQL Agent job (CmdExec step).
REM  Runs Invoke-PerfCheck.ps1 unattended and turns its exit code into one the
REM  job step understands (Agent treats only exit code 0 as success).
REM
REM  Invoke-PerfCheck.ps1 exit codes:
REM    0 OK   1 warnings   2 critical findings / an instance not reachable
REM    3 script error      4 email not sent
REM  Mapped here:
REM    0, 1, 2 -> 0  (the check ran and the email went out; findings are in the email)
REM    3, 4    -> unchanged (the job step fails: job history + Agent operator alert)
REM  To make CRITICAL findings fail the job as well, change SUCCESS_MAX to 1.
REM
REM  Examples (command of the job step):
REM    cmd.exe /c ""C:\DBA\PerfCheck\Run-PerfCheck-Agent.bat" -PrimaryOnly -Label SCHEDULED"
REM    cmd.exe /c ""C:\DBA\PerfCheck\Run-PerfCheck-Agent.bat" -PrimaryOnly -NoPerf -Label HC"
REM  Don't pass -Unattended: this file adds it.
REM ==========================================================================
setlocal
set "SUCCESS_MAX=2"
cd /d "%~dp0"

if not exist "%~dp0Invoke-PerfCheck.ps1" (
    echo Invoke-PerfCheck.ps1 not found next to this file.
    exit /b 3
)

powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0Invoke-PerfCheck.ps1" -Unattended %*
set RC=%ERRORLEVEL%
echo.
echo Invoke-PerfCheck.ps1 exit code: %RC%  (0 OK, 1 warnings, 2 critical / instance not reachable, 3 script error, 4 email not sent)
if %RC% LEQ %SUCCESS_MAX% (
    echo Job step result: success - see the email and the Reports / Logs folders next to this file.
    exit /b 0
)
echo Job step result: FAILED with exit code %RC% - see the log in the Logs folder next to this file.
exit /b %RC%
