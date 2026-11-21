/*******************************************************************************
 File    : CreateAgentJob_PerfCheck.sql   (automation/perf-check)
 Purpose : Creates (or updates in place) a SQL Agent job that runs the PowerShell
           health & performance check through Run-PerfCheck-Agent.bat, so the run
           has Agent job history, a schedule and failure alerts.
           Typical use: ONE job on ONE instance (the coordinator) checks every
           instance on every VM listed in servers.txt and emails one message with
           one report file per VM (-PrimaryOnly: only primary / standalone instances).
 Needs   : the perf-check folder copied to @ScriptFolder on THIS server:
             Run-PerfCheck-Agent.bat, Invoke-PerfCheck.ps1, PerfCheck.sql, servers.txt
           PowerShell allowed on this server. Run this script as sysadmin.

 Who the step runs as (CmdExec):
   @ProxyName = NULL -> the SQL Server Agent service account. It needs, on every
                        instance it checks: either Windows login + the permissions of
                        the SETUP block in PerfCheck.sql, or read access to the saved
                        SQL login file (PerfCheck.cred, see CredentialReaders).
   @ProxyName = 'x'  -> an Agent proxy that runs as a Windows (domain) account, e.g. a
                        DBA service account that already has the SQL permissions on
                        all instances. Recommended. One-time setup (example):
       USE master;
       CREATE CREDENTIAL [PerfCheckCred] WITH IDENTITY = N'DOMAIN\svc_sqlperf', SECRET = N'<password>';
       USE msdb;
       EXEC dbo.sp_add_proxy @proxy_name = N'PerfCheckProxy', @credential_name = N'PerfCheckCred', @enabled = 1;
       EXEC dbo.sp_grant_proxy_to_subsystem @proxy_name = N'PerfCheckProxy', @subsystem_name = N'CmdExec';
   With a SQL login, Database Mail can attach only ONE report (as a query result):
   for one email with several VM files use Windows authentication (-WindowsAuth, or
   the SQL login not saved) and an instance on THIS server for Database Mail, or set
   SmtpServer in Invoke-PerfCheck.ps1.

 Job step exit code: Run-PerfCheck-Agent.bat returns 0 when the check ran and the
 email went out (OK, warnings or critical findings) and fails the step on a script
 error (3) or when no email could be sent (4). Full log: Logs\ next to the script;
 the last step output: AgentJobStep_output.txt in @ScriptFolder.
*******************************************************************************/
USE [msdb];
GO
DECLARE
    @JobName         sysname        = N'DBA - Health & Performance Check (all VMs)',
    @ScriptFolder    nvarchar(260)  = N'C:\DBA\PerfCheck',          -- folder with Run-PerfCheck-Agent.bat on THIS server (no trailing \)
    @Arguments       nvarchar(1000) = N'-PrimaryOnly -Label SCHEDULED',
                                    -- passed to Invoke-PerfCheck.ps1, e.g. add -SampleSec 60 -DurationMin 30, -NoPerf, -WindowsAuth
                                    -- (don't add -Unattended: the .bat adds it)
    @ProxyName       sysname        = NULL,                         -- Agent proxy (Windows account) for the CmdExec step; NULL = Agent service account
    @Schedule        varchar(10)    = 'DAILY',                      -- DAILY | WEEKLY | ONCE | NONE (no schedule, run on demand)
    @StartTime       char(5)        = '06:00',                      -- HH:mm, server local time
    @WeekDays        varchar(60)    = 'Mon,Wed,Fri',                -- WEEKLY only
    @OnceDate        date           = NULL,                         -- ONCE only, e.g. '2026-11-25'
    @JobOwner        sysname        = NULL,                         -- NULL = sa (found by SID). Without a proxy the owner must be sysadmin.
    @NotifyOperator  sysname        = NULL,                         -- optional Agent operator emailed when the JOB fails
    @UpdateExisting  bit            = 1;                            -- 1 = update the existing job in place (history kept); 0 = stop if it exists

/*---------------------------------------------------------------------------*/
DECLARE @jobId uniqueidentifier, @cmd nvarchar(2000), @outFile nvarchar(400), @freqType int, @freqInterval int = 0, @recur int = 0,
        @startTimeInt int, @startDate int = CONVERT(int, CONVERT(char(8), GETDATE(), 112)), @schedName sysname;

SET @ScriptFolder = RTRIM(@ScriptFolder);
IF RIGHT(@ScriptFolder, 1) = N'\' SET @ScriptFolder = LEFT(@ScriptFolder, LEN(@ScriptFolder) - 1);
IF @Arguments LIKE N'%-Unattended%'
BEGIN RAISERROR(N'Remove -Unattended from @Arguments: Run-PerfCheck-Agent.bat adds it.', 16, 1); RETURN; END;
IF @StartTime NOT LIKE '[0-2][0-9]:[0-5][0-9]'
BEGIN RAISERROR(N'@StartTime must be HH:mm.', 16, 1); RETURN; END;
SET @startTimeInt = CAST(REPLACE(@StartTime, ':', '') AS int) * 100;
SET @Schedule = UPPER(@Schedule);
IF @Schedule NOT IN ('DAILY', 'WEEKLY', 'ONCE', 'NONE')
BEGIN RAISERROR(N'@Schedule must be DAILY, WEEKLY, ONCE or NONE.', 16, 1); RETURN; END;
IF @Schedule = 'ONCE' AND @OnceDate IS NULL
BEGIN RAISERROR(N'@OnceDate is required for @Schedule = ONCE.', 16, 1); RETURN; END;
IF @ProxyName IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dbo.sysproxies WHERE name = @ProxyName)
    BEGIN RAISERROR(N'Agent proxy %s not found (see the header for how to create it).', 16, 1, @ProxyName); RETURN; END;
    IF NOT EXISTS (SELECT 1 FROM dbo.sysproxies AS p
                   JOIN dbo.sysproxysubsystem AS ps ON ps.proxy_id = p.proxy_id
                   JOIN dbo.syssubsystems AS s ON s.subsystem_id = ps.subsystem_id
                   WHERE p.name = @ProxyName AND s.subsystem = N'CmdExec')
    BEGIN RAISERROR(N'Agent proxy %s is not granted the CmdExec subsystem: EXEC msdb.dbo.sp_grant_proxy_to_subsystem @proxy_name = N''%s'', @subsystem_name = N''CmdExec'';', 16, 1, @ProxyName, @ProxyName); RETURN; END;
END;

-- cmd.exe /c ""<folder>\Run-PerfCheck-Agent.bat" <arguments>"   (outer quotes: paths with spaces)
SET @cmd = N'cmd.exe /c ""' + @ScriptFolder + N'\Run-PerfCheck-Agent.bat" ' + ISNULL(@Arguments, N'') + N'"';
SET @outFile = @ScriptFolder + N'\AgentJobStep_output.txt';

IF NOT EXISTS (SELECT 1 FROM dbo.syscategories WHERE name = N'Database Maintenance' AND category_class = 1)
    EXEC dbo.sp_add_category @class = N'JOB', @type = N'LOCAL', @name = N'Database Maintenance';

DECLARE @existed bit = 0, @stepId int, @schedId int,
        @desc nvarchar(512) = N'Health check + performance window of the instances in servers.txt, one report per VM, one email (Invoke-PerfCheck.ps1, automation/perf-check).';
SELECT @jobId = job_id FROM dbo.sysjobs WHERE name = @JobName;
IF @jobId IS NOT NULL
BEGIN
    -- update in place: job history is kept; the step and schedules are rebuilt from the parameters above
    IF @UpdateExisting = 0 BEGIN RAISERROR(N'Job %s already exists (set @UpdateExisting = 1 to update it).', 16, 1, @JobName); RETURN; END;
    SET @existed = 1;
    EXEC dbo.sp_update_job @job_id = @jobId, @enabled = 1, @category_name = N'Database Maintenance', @description = @desc,
         @notify_level_eventlog = 2, @notify_level_email = 0, @start_step_id = 1;
    WHILE EXISTS (SELECT 1 FROM dbo.sysjobsteps WHERE job_id = @jobId)
    BEGIN
        SELECT @stepId = MAX(step_id) FROM dbo.sysjobsteps WHERE job_id = @jobId;
        EXEC dbo.sp_delete_jobstep @job_id = @jobId, @step_id = @stepId;
    END;
    WHILE EXISTS (SELECT 1 FROM dbo.sysjobschedules WHERE job_id = @jobId)
    BEGIN
        SELECT @schedId = MIN(schedule_id) FROM dbo.sysjobschedules WHERE job_id = @jobId;
        EXEC dbo.sp_detach_schedule @job_id = @jobId, @schedule_id = @schedId, @delete_unused_schedule = 1;
    END;
END
ELSE
    EXEC dbo.sp_add_job
         @job_name = @JobName, @enabled = 1, @category_name = N'Database Maintenance', @description = @desc,
         @owner_login_name = @JobOwner, @notify_level_eventlog = 2, @notify_level_email = 0, @job_id = @jobId OUTPUT;
DECLARE @owner sysname = ISNULL(@JobOwner, SUSER_SNAME(0x01));
EXEC dbo.sp_update_job @job_id = @jobId, @owner_login_name = @owner;
IF @NotifyOperator IS NOT NULL
    EXEC dbo.sp_update_job @job_id = @jobId, @notify_level_email = 2, @notify_email_operator_name = @NotifyOperator;

EXEC dbo.sp_add_jobstep
     @job_id = @jobId, @step_id = 1, @step_name = N'Health & performance check (PowerShell)', @subsystem = N'CmdExec',
     @command = @cmd, @cmdexec_success_code = 0, @proxy_name = @ProxyName,
     @output_file_name = @outFile, @flags = 0,     -- 0 = overwrite the output file each run
     @on_success_action = 1, @on_fail_action = 2, @retry_attempts = 0;

IF @Schedule <> 'NONE'
BEGIN
    SET @freqType = CASE @Schedule WHEN 'DAILY' THEN 4 WHEN 'WEEKLY' THEN 8 ELSE 1 END;
    IF @Schedule = 'DAILY' SET @freqInterval = 1;
    IF @Schedule = 'WEEKLY'
    BEGIN
        SET @freqInterval = CASE WHEN @WeekDays LIKE '%Sun%' THEN 1 ELSE 0 END + CASE WHEN @WeekDays LIKE '%Mon%' THEN 2 ELSE 0 END
                          + CASE WHEN @WeekDays LIKE '%Tue%' THEN 4 ELSE 0 END + CASE WHEN @WeekDays LIKE '%Wed%' THEN 8 ELSE 0 END
                          + CASE WHEN @WeekDays LIKE '%Thu%' THEN 16 ELSE 0 END + CASE WHEN @WeekDays LIKE '%Fri%' THEN 32 ELSE 0 END
                          + CASE WHEN @WeekDays LIKE '%Sat%' THEN 64 ELSE 0 END;
        SET @recur = 1;
        IF @freqInterval = 0 BEGIN RAISERROR(N'@WeekDays has no valid day (Mon,Tue,Wed,Thu,Fri,Sat,Sun).', 16, 1); RETURN; END;
    END;
    IF @Schedule = 'ONCE' SET @startDate = CONVERT(int, CONVERT(char(8), @OnceDate, 112));
    SET @schedName = @JobName + N' - ' + @Schedule + N' ' + @StartTime;
    EXEC dbo.sp_add_jobschedule
         @job_id = @jobId, @name = @schedName, @enabled = 1, @freq_type = @freqType, @freq_interval = @freqInterval,
         @freq_recurrence_factor = @recur, @active_start_date = @startDate, @active_start_time = @startTimeInt;
END;

IF NOT EXISTS (SELECT 1 FROM dbo.sysjobservers WHERE job_id = @jobId)
    EXEC dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)';

PRINT CASE WHEN @existed = 1 THEN N'Job updated (history kept): ' ELSE N'Job created: ' END + @JobName + N' (' + CASE WHEN @Schedule = 'NONE' THEN N'no schedule' ELSE @Schedule + N' at ' + @StartTime
      + CASE WHEN @Schedule = 'WEEKLY' THEN N' on ' + @WeekDays WHEN @Schedule = 'ONCE' THEN N' on ' + CONVERT(nvarchar(10), @OnceDate, 120) ELSE N'' END END + N').';
PRINT N'Runs as : ' + ISNULL(N'proxy ' + @ProxyName, N'the SQL Server Agent service account');
PRINT N'Command : ' + @cmd;
PRINT N'Output  : ' + @outFile;
PRINT N'Run it now: EXEC msdb.dbo.sp_start_job @job_name = N''' + REPLACE(@JobName, N'''', N'''''') + N''';';
GO
