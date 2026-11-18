/*******************************************************************************
 File    : HealthPerfCheck_AgentJob.sql   (automation/perf-check-agent)
 Purpose : The health & performance check of automation/perf-check, in pure T-SQL,
           for servers where PowerShell can't be used. Runs as a SQL Agent job
           (or by hand) on ONE instance and emails one report via Database Mail.

 WHAT IT DOES (dbo.usp_DBA_HealthPerfCheck)
   1. Health check: instance & build, SQL / Windows uptime, services, vitals,
      databases (state, recovery, backups, CHECKDB, log use, AG role), Always On
      replicas / listeners (IP, DHCP) / databases, cluster & quorum, disks, failed
      job steps (24 h), severe error log entries, sp_configure, trace flags, linked
      servers, endpoints, certificates, XE sessions, SSIS catalog / projects /
      environments / failures, SSRS content / subscriptions, and the SSIS / SSRS /
      SSAS services on this server (state). NOT included: data/log file list, Agent
      job list, logins, server role members, SSAS databases (need PowerShell / MSOLAP).
   2. Performance window: a sample every @SampleSec seconds for @DurationMin
      minutes (WAITFOR loop): Batch Requests/sec, Transactions/sec (@PerfDatabases),
      compilations, user connections + connection pool usage, lock waits / wait
      time / timeouts / deadlocks / blocking, PLE, buffer cache hit ratio, memory
      grants pending, target vs total memory, wait stats per interval, file latency,
      log flush wait / bytes, tempdb space / version store / allocation contention,
      Always On queues / transaction delay / listener connections.
      Root cause with SPID + statement: head blockers (incl. idle sessions with an
      open transaction), problem sessions (blocked / I/O / log / memory / tempdb
      waits / long running), memory grants, tempdb users, every deadlock process
      (+ the graph XML), every query over @LongQuerySec s (XE), and the top 20
      queries of the window by duration / CPU / reads (plan cache, no Query Store).
   3. One email: summary + needs attention + head blockers + top problem sessions
      in the body, the FULL report attached as an .html file (query attachment).

 SERVER CHANGES during the window, always put back: 'blocked process threshold (s)'
 is set to @BlockedThresholdSec and the XE session DBA_PerfCheckJob is created. At
 the end both are reverted. If the job is stopped half-way, the original value is
 kept in dbo.DBA_PerfCheck_State and restored at the start of the next run.

 HOW TO USE
   PART 1 - run once (sysadmin): creates the table, two helper objects and the
            procedure in the database chosen on the USE line below (master by
            default; change it to your DBA database if you have one). Re-run
            it to upgrade: existing objects are ALTERed, nothing is dropped.
   PART 2 - set the parameters at its top and run it: creates the SQL Agent
            job + schedule, or updates the existing job in place (history kept).
   Test by hand first (short window, report returned as a grid instead of mailed):
       EXEC dbo.usp_DBA_HealthPerfCheck @SampleSec = 10, @DurationMin = 1, @SendEmail = 0;
   or mailed:
       EXEC dbo.usp_DBA_HealthPerfCheck @Recipients = N'dba-team@yourcompany.com', @SampleSec = 10, @DurationMin = 2;

 NEEDS: SQL Server 2016 SP1+ (any edition with Agent), Database Mail with a profile
 (scripts/45_database_mail_setup.sql makes it public/default and raises the
 attachment limit - the report is usually 0.3-3 MB). The job runs as its owner
 (sa by default) so it has all permissions; run by hand as a non-sysadmin and the
 parts it can't read are skipped with a warning.
 Tags    : [BOX] SQL Server 2016 SP1 - 2025 / Azure VM. Not for Azure SQL Database.
*******************************************************************************/

/*=============================================================================
  PART 1 - INSTALL (run once per instance; safe to re-run to upgrade)
=============================================================================*/
USE [master];   -- <== database for the procedure (master, or your DBA database)
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
IF OBJECT_ID(N'dbo.DBA_PerfCheck_State', N'U') IS NULL
    CREATE TABLE dbo.DBA_PerfCheck_State (
        id             int      NOT NULL CONSTRAINT PK_DBA_PerfCheck_State PRIMARY KEY,
        orig_threshold int      NOT NULL,
        changed_at     datetime NOT NULL CONSTRAINT DF_DBA_PerfCheck_State_at DEFAULT (GETDATE()),
        changed_by     sysname  NOT NULL CONSTRAINT DF_DBA_PerfCheck_State_by DEFAULT (SUSER_SNAME()));
GO
-- Objects are created once (as a stub) and then ALTERed: re-running this part upgrades them in place,
-- keeps their permissions, and nothing needs to be dropped or cleaned up first.
IF OBJECT_ID(N'dbo.fn_DBA_Html', N'FN') IS NULL
    EXEC (N'CREATE FUNCTION dbo.fn_DBA_Html (@v nvarchar(max)) RETURNS nvarchar(max) AS BEGIN RETURN @v; END;');
GO
-- HTML-encodes a value and removes control characters that are not valid in XML
ALTER FUNCTION dbo.fn_DBA_Html (@v nvarchar(max))
RETURNS nvarchar(max)
AS
BEGIN
    IF @v IS NULL RETURN N'';
    DECLARE @i int = 1;
    WHILE @i < 32
    BEGIN
        IF @i NOT IN (9, 10, 13) AND CHARINDEX(NCHAR(@i), @v COLLATE Latin1_General_BIN) > 0
            SET @v = REPLACE(@v COLLATE Latin1_General_BIN, NCHAR(@i), N' ');
        SET @i += 1;
    END;
    RETURN REPLACE(REPLACE(REPLACE(@v, N'&', N'&amp;'), N'<', N'&lt;'), N'>', N'&gt;');
END;
GO
IF OBJECT_ID(N'dbo.usp_DBA_HtmlTable', N'P') IS NULL
    EXEC (N'CREATE PROCEDURE dbo.usp_DBA_HtmlTable AS RETURN 0;');
GO
-- Renders any query as an HTML table: <h3>Title (rows)</h3><table>...</table>
-- @Query can read the caller's #temp tables. @OrderBy uses the query's column names.
-- A column named in @StatusColumn colours the row (CRITICAL red, WARNING yellow).
ALTER PROCEDURE dbo.usp_DBA_HtmlTable
    @Query        nvarchar(max),
    @Title        nvarchar(400),
    @OrderBy      nvarchar(2000) = N'(SELECT NULL)',
    @StatusColumn sysname        = NULL,
    @MaxRows      int            = 0,       -- 0 = all rows
    @SkipEmpty    bit            = 0,       -- 1 = return '' when there are no rows
    @Html         nvarchar(max)  OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @sql nvarchar(max) = REPLACE(REPLACE(N'SET NOCOUNT ON; SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON;
SELECT ROW_NUMBER() OVER (ORDER BY {ORDER}) AS _rn, q.* INTO #r FROM ({QUERY}) AS q;
DECLARE @n int = @@ROWCOUNT;
IF @n = 0
BEGIN
    SET @html = CASE WHEN @skip = 1 THEN N'''' ELSE N''<h3>'' + dbo.fn_DBA_Html(@title) + N'' (0)</h3><div style="color:#2e7d32">None</div>'' END;
    RETURN;
END;
DECLARE @hdr nvarchar(max) = N'''', @cells nvarchar(max) = N'''', @c sysname, @t int, @sql2 nvarchar(max), @rows nvarchar(max), @style nvarchar(max) = N''N'''''''''';
DECLARE col CURSOR LOCAL FAST_FORWARD FOR
    SELECT name, system_type_id FROM tempdb.sys.columns WHERE object_id = OBJECT_ID(N''tempdb..#r'') AND name NOT LIKE N''[_]%'' ORDER BY column_id;   -- columns starting with _ are hidden

OPEN col;
FETCH NEXT FROM col INTO @c, @t;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @hdr += N''<th>'' + dbo.fn_DBA_Html(@c) + N''</th>'';
    SET @cells += N'' + N''''<td>'''' + dbo.fn_DBA_Html(''
        + CASE WHEN @t IN (40, 42, 58, 61) THEN N''CONVERT(nvarchar(30), '' + QUOTENAME(@c) + N'', 120)''
               WHEN @t = 43 THEN N''CONVERT(nvarchar(40), '' + QUOTENAME(@c) + N'', 120)''
               ELSE N''CONVERT(nvarchar(max), '' + QUOTENAME(@c) + N'')'' END
        + N'') + N''''</td>'''''';
    IF @status IS NOT NULL AND @c = @status
        SET @style = N''CASE CONVERT(nvarchar(20), '' + QUOTENAME(@c) + N'') WHEN N''''CRITICAL'''' THEN N'''' style="background:#f8d7da"'''' WHEN N''''WARNING'''' THEN N'''' style="background:#fff3cd"'''' ELSE N'''''''' END'';
    FETCH NEXT FROM col INTO @c, @t;
END;
CLOSE col; DEALLOCATE col;
SET @sql2 = N''SELECT @rows = (SELECT N''''<tr'''' + '' + @style + N'' + N''''>'''''' + @cells + N'' + N''''</tr>''''
FROM #r WHERE @max = 0 OR _rn <= @max ORDER BY _rn FOR XML PATH(''''''''), TYPE).value(''''.'''', ''''nvarchar(max)'''');'';
EXEC sys.sp_executesql @sql2, N''@rows nvarchar(max) OUTPUT, @max int'', @rows OUTPUT, @max;
SET @html = N''<h3>'' + dbo.fn_DBA_Html(@title) + N'' ('' + CAST(@n AS nvarchar(10)) + N'')</h3><table><tr>'' + @hdr + N''</tr>'' + ISNULL(@rows, N'''') + N''</table>''
          + CASE WHEN @max > 0 AND @n > @max THEN N''<div style="color:#555">First '' + CAST(@max AS nvarchar(10)) + N'' of '' + CAST(@n AS nvarchar(10)) + N'' rows - all rows are in the attached report.</div>'' ELSE N'''' END;
', N'{ORDER}', @OrderBy), N'{QUERY}', @Query);
    SET @Html = N'';
    BEGIN TRY
        EXEC sys.sp_executesql @sql, N'@title nvarchar(400), @status sysname, @max int, @skip bit, @html nvarchar(max) OUTPUT',
             @Title, @StatusColumn, @MaxRows, @SkipEmpty, @Html OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Html = N'<h3>' + dbo.fn_DBA_Html(@Title) + N'</h3><div style="color:#a94442">Could not be read: ' + dbo.fn_DBA_Html(ERROR_MESSAGE()) + N'</div>';
    END CATCH;
END;
GO

IF OBJECT_ID(N'dbo.usp_DBA_HealthPerfCheck', N'P') IS NULL
    EXEC (N'CREATE PROCEDURE dbo.usp_DBA_HealthPerfCheck AS RETURN 0;');
GO
ALTER PROCEDURE dbo.usp_DBA_HealthPerfCheck
    @Recipients          nvarchar(max)  = NULL,       -- ; separated. Required when @SendEmail = 1
    @CopyRecipients      nvarchar(max)  = NULL,
    @MailProfile         sysname        = NULL,       -- NULL = default public profile, else the first profile
    @FromAddress         nvarchar(256)  = NULL,       -- NULL = the profile account's address
    @Label               nvarchar(50)   = N'SCHEDULED',
    @SampleSec           int            = 60,         -- seconds between samples
    @DurationMin         int            = 30,         -- length of the performance window
    @PerfDatabases       nvarchar(max)  = NULL,       -- e.g. N'MARS,CLR' for 'Trans/s'; NULL = all databases
    @BlockedThresholdSec int            = 5,          -- 'blocked process threshold' during the window
    @LongQuerySec        int            = 5,          -- capture queries running longer than this
    @TopQueries          bit            = 1,          -- top 20 queries of the window (plan cache)
    @BigGrantMB          int            = 1024,       -- list memory grants of at least this size (waiting ones always)
    @TempdbSessionMB     int            = 500,        -- list sessions using at least this much tempdb
    @PleMin              int            = 300,        -- thresholds for 'needs attention'
    @DataReadMs          int            = 20,
    @LogWriteMs          int            = 10,
    @AgSendQueueMB       int            = 100,
    @NoHealth            bit            = 0,          -- 1 = performance window only
    @NoPerf              bit            = 0,          -- 1 = health check only
    @AttachReport        bit            = 1,          -- attach the full report (.html); 0 = summary only
    @SendEmail           bit            = 1           -- 0 = return the report as a result set (testing in SSMS)
AS
BEGIN
SET NOCOUNT ON;
SET XACT_ABORT OFF;
-- XML methods need these (SQL Agent sessions run with some of them OFF)
SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET ANSI_PADDING ON; SET NUMERIC_ROUNDABORT OFF;

DECLARE @p_runStart datetime = GETDATE(), @p_err nvarchar(4000) = NULL, @p_notes nvarchar(max) = N'',
        @p_hFull nvarchar(max) = N'', @p_hShort nvarchar(max) = N'', @p_pFull nvarchar(max) = N'', @p_pShort nvarchar(max) = N'',
        @p_part nvarchar(max), @p_hCrit int = 0, @p_hWarn int = 0, @p_pCrit int = 0, @p_pWarn int = 0, @p_intervals int = 0;

IF @SendEmail = 1 AND NULLIF(LTRIM(@Recipients), N'') IS NULL
BEGIN
    RAISERROR(N'@Recipients is required when @SendEmail = 1.', 16, 1);
    RETURN;
END;
IF @SampleSec < 5 SET @SampleSec = 5;

BEGIN TRY

/*#############################################################################
  HEALTH CHECK
#############################################################################*/
IF @NoHealth = 0
BEGIN
    SET NOCOUNT ON;
    SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON;
    SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;

    /*=============================================================================
      THRESHOLDS (used for the "issues" section; same meaning as in script 44)
    =============================================================================*/
    DECLARE @LogBackupMaxMin    int = 60,
            @FullBackupMaxDays  int = 7,
            @DiffBackupMaxHours int = 26,
            @CheckDbMaxDays     int = 7,
            @DiskWarnPct        int = 15,
            @DiskCritPct        int = 10,
            @LogUsedWarnPct     int = 80,
            @FileFreeWarnPct    int = 10,
            @JobFailHours       int = 24,
            @ErrorLogHours      int = 24,
            @CertWarnDays       int = 30,
            @OpenTranWarnMin    int = 30,
            @BlockingWarnSec    int = 60;

    /*=============================================================================
      INTERNALS
    =============================================================================*/
    DECLARE @now datetime = GETDATE(),
            @is_mi bit = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 8 THEN 1 ELSE 0 END,
            @sql nvarchar(max), @dbn sysname;

    IF OBJECT_ID('tempdb..#issues')  IS NOT NULL DROP TABLE #issues;
    IF OBJECT_ID('tempdb..#inst')    IS NOT NULL DROP TABLE #inst;
    IF OBJECT_ID('tempdb..#svc')     IS NOT NULL DROP TABLE #svc;
    IF OBJECT_ID('tempdb..#vitals')  IS NOT NULL DROP TABLE #vitals;
    IF OBJECT_ID('tempdb..#db')      IS NOT NULL DROP TABLE #db;
    IF OBJECT_ID('tempdb..#agr')     IS NOT NULL DROP TABLE #agr;
    IF OBJECT_ID('tempdb..#agdb')    IS NOT NULL DROP TABLE #agdb;
    IF OBJECT_ID('tempdb..#cluster') IS NOT NULL DROP TABLE #cluster;
    IF OBJECT_ID('tempdb..#disk')    IS NOT NULL DROP TABLE #disk;
    IF OBJECT_ID('tempdb..#jobs')    IS NOT NULL DROP TABLE #jobs;
    IF OBJECT_ID('tempdb..#errlog')  IS NOT NULL DROP TABLE #errlog;
    IF OBJECT_ID('tempdb..#el')      IS NOT NULL DROP TABLE #el;

    CREATE TABLE #issues (severity varchar(10), area varchar(40), item nvarchar(300), detail nvarchar(2000));
    CREATE TABLE #inst   (seq int IDENTITY, property nvarchar(100), value nvarchar(4000));
    CREATE TABLE #svc    (servicename nvarchar(256), status_desc nvarchar(60), startup_type_desc nvarchar(60),
                          service_account nvarchar(256), last_startup_time datetimeoffset NULL, ifi nvarchar(1) NULL);
    CREATE TABLE #vitals (seq int IDENTITY, metric nvarchar(100), value nvarchar(400), status varchar(10));
    CREATE TABLE #disk   (volume nvarchar(256), label nvarchar(256), total_gb decimal(18,1), free_gb decimal(18,1), free_pct decimal(5,1), status varchar(10));
    CREATE TABLE #el     (LogDate datetime, ProcessInfo nvarchar(50), [Text] nvarchar(max));

    /*=============================================================================
      2. SERVICES (not available on MI)
    =============================================================================*/
    IF @is_mi = 0
    BEGIN
        INSERT #svc EXEC (N'SELECT servicename, status_desc, startup_type_desc, service_account, last_startup_time, instant_file_initialization_enabled FROM sys.dm_server_services;');
        INSERT #issues SELECT 'CRITICAL', 'Service', servicename, 'Status: ' + status_desc
        FROM #svc WHERE status_desc <> N'Running' AND startup_type_desc = N'Automatic';
    END;

    /*=============================================================================
      3. VITALS (CPU, memory, blocking, transactions, tempdb, errors)
    =============================================================================*/
    DECLARE @ticks bigint = (SELECT ms_ticks FROM sys.dm_os_sys_info),
            @cpu_avg int, @cpu_max int, @ple bigint, @grants bigint, @blocked int, @blocked_max_s int,
            @oldest_tran_min int, @tempdb_free_pct decimal(5,1), @users int;

    SELECT @cpu_avg = AVG(cpu), @cpu_max = MAX(cpu)
    FROM (SELECT TOP (30) 100 - x.r.value('(Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') AS cpu
          FROM sys.dm_os_ring_buffers rb CROSS APPLY (SELECT CAST(rb.record AS xml)) x(r)
          WHERE rb.ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR' AND rb.record LIKE N'%<SystemHealth>%'
          ORDER BY rb.[timestamp] DESC) AS c;
    SELECT @ple    = MIN(cntr_value) FROM sys.dm_os_performance_counters WHERE counter_name = N'Page life expectancy' AND object_name LIKE N'%Buffer Manager%';
    SELECT @grants = cntr_value      FROM sys.dm_os_performance_counters WHERE counter_name = N'Memory Grants Pending';
    SELECT @blocked = COUNT(*), @blocked_max_s = MAX(wait_time) / 1000 FROM sys.dm_exec_requests WHERE blocking_session_id > 0;
    SELECT @oldest_tran_min = MAX(DATEDIFF(MINUTE, at.transaction_begin_time, @now))
    FROM sys.dm_tran_active_transactions at JOIN sys.dm_tran_session_transactions st ON st.transaction_id = at.transaction_id
    JOIN sys.dm_exec_sessions s ON s.session_id = st.session_id WHERE s.is_user_process = 1;
    SELECT @tempdb_free_pct = CAST(100.0 * SUM(unallocated_extent_page_count) / NULLIF(SUM(total_page_count), 0) AS decimal(5,1)) FROM tempdb.sys.dm_db_file_space_usage;
    SELECT @users = COUNT(*) FROM sys.dm_exec_sessions WHERE is_user_process = 1;

    INSERT #vitals (metric, value, status) VALUES
     (N'CPU last 30 min (avg / max %)', CAST(ISNULL(@cpu_avg, 0) AS nvarchar(10)) + N' / ' + CAST(ISNULL(@cpu_max, 0) AS nvarchar(10)),
         CASE WHEN @cpu_avg >= 90 THEN 'CRITICAL' WHEN @cpu_avg >= 75 OR @cpu_max >= 95 THEN 'WARNING' ELSE 'OK' END),
     (N'Page life expectancy (s, lowest NUMA node)', CAST(@ple AS nvarchar(20)), CASE WHEN @ple < 300 THEN 'WARNING' ELSE 'OK' END),
     (N'Memory grants pending', CAST(@grants AS nvarchar(20)), CASE WHEN @grants > 0 THEN 'WARNING' ELSE 'OK' END),
     (N'Blocked requests now (longest wait s)', CAST(@blocked AS nvarchar(10)) + N' (' + CAST(ISNULL(@blocked_max_s, 0) AS nvarchar(10)) + N')',
         CASE WHEN @blocked_max_s >= @BlockingWarnSec * 5 THEN 'CRITICAL' WHEN @blocked_max_s >= @BlockingWarnSec THEN 'WARNING' ELSE 'OK' END),
     (N'Oldest open user transaction (min)', CAST(ISNULL(@oldest_tran_min, 0) AS nvarchar(10)), CASE WHEN @oldest_tran_min >= @OpenTranWarnMin THEN 'WARNING' ELSE 'OK' END),
     (N'tempdb free %', CAST(@tempdb_free_pct AS nvarchar(10)), CASE WHEN @tempdb_free_pct < 10 THEN 'CRITICAL' WHEN @tempdb_free_pct < 20 THEN 'WARNING' ELSE 'OK' END),
     (N'User sessions', CAST(@users AS nvarchar(10)), 'OK');

    INSERT #issues SELECT status, 'Vitals', metric, value FROM #vitals WHERE status <> 'OK';

    /*=============================================================================
      4. DATABASES + BACKUPS + CHECKDB + LOG USE + AG ROLE
    =============================================================================*/
    -- Last full / diff / log backup per database (msdb read access needed; without it backups are not judged)
    IF OBJECT_ID('tempdb..#bk') IS NOT NULL DROP TABLE #bk;
    CREATE TABLE #bk (database_name sysname, type char(1), backup_finish_date datetime, physical_device_name nvarchar(260));
    DECLARE @bkOk bit = 1;
    BEGIN TRY
        INSERT #bk (database_name, type, backup_finish_date, physical_device_name)
        SELECT database_name, type, backup_finish_date, physical_device_name
        FROM (SELECT b.database_name, b.type, b.backup_finish_date, m.physical_device_name,
                     ROW_NUMBER() OVER (PARTITION BY b.database_name, b.type ORDER BY b.backup_finish_date DESC) AS rn
              FROM msdb.dbo.backupset AS b
              JOIN msdb.dbo.backupmediafamily AS m ON m.media_set_id = b.media_set_id
              WHERE b.backup_finish_date >= DATEADD(DAY, -60, GETDATE())      -- recent history only (fast on big msdb)
                AND (b.type IN ('I', 'L') OR (b.type = 'D' AND b.is_copy_only = 0))) AS x
        WHERE rn = 1;
    END TRY
    BEGIN CATCH
        SET @bkOk = 0;
        INSERT #issues SELECT 'WARNING', 'Backup', N'not checked', N'No permission to read backup history in msdb (' + ERROR_MESSAGE() + N') - backups not judged';
    END CATCH;

    SELECT d.database_id, d.name, d.state_desc, d.user_access_desc, d.recovery_model_desc, d.compatibility_level,
           SUSER_SNAME(d.owner_sid) AS owner_name, d.is_read_only, d.log_reuse_wait_desc,
           CAST(sz.size_mb AS decimal(18,0)) AS size_mb,
           CAST(ls.active_log_size_mb * 100.0 / NULLIF(ls.total_log_size_mb, 0) AS decimal(5,1)) AS log_used_pct,
           ag.name AS ag_name,
           CASE WHEN drs.is_primary_replica = 1 THEN N'PRIMARY' WHEN drs.database_id IS NOT NULL THEN N'SECONDARY' ELSE N'' END AS ag_role,
           drs.synchronization_state_desc AS ag_sync_state,
           CASE WHEN @bkOk = 0 THEN 0 WHEN d.replica_id IS NULL THEN 1 ELSE sys.fn_hadr_backup_is_preferred_replica(d.name) END AS backup_preferred_here,
           bf.backup_finish_date AS last_full, bf.physical_device_name AS last_full_path,
           bd.backup_finish_date AS last_diff,
           bl.backup_finish_date AS last_log,  bl.physical_device_name AS last_log_path,
           CAST(DATABASEPROPERTYEX(d.name, 'LastGoodCheckDbTime') AS datetime) AS last_checkdb,
           CAST('OK' AS varchar(10)) AS status, CAST(N'' AS nvarchar(1000)) AS notes
    INTO #db
    FROM sys.databases AS d
    OUTER APPLY (SELECT SUM(CAST(size AS bigint)) * 8 / 1024.0 AS size_mb FROM sys.master_files mf WHERE mf.database_id = d.database_id) AS sz
    OUTER APPLY (SELECT TOP (1) l.active_log_size_mb, l.total_log_size_mb FROM sys.dm_db_log_stats(d.database_id) l WHERE d.state_desc = N'ONLINE') AS ls
    LEFT JOIN sys.availability_databases_cluster AS adc ON adc.database_name = d.name
    LEFT JOIN sys.availability_groups AS ag ON ag.group_id = adc.group_id
    LEFT JOIN sys.dm_hadr_database_replica_states AS drs ON drs.database_id = d.database_id AND drs.is_local = 1
    LEFT JOIN #bk AS bf ON bf.database_name = d.name AND bf.type = 'D'
    LEFT JOIN #bk AS bd ON bd.database_name = d.name AND bd.type = 'I'
    LEFT JOIN #bk AS bl ON bl.database_name = d.name AND bl.type = 'L'
    WHERE d.source_database_id IS NULL;      -- skip DB snapshots

    -- Evaluate each database
    UPDATE #db SET
        status = CASE
            WHEN state_desc NOT IN (N'ONLINE', N'RESTORING') THEN 'CRITICAL'
            WHEN name <> N'tempdb' AND state_desc = N'ONLINE' AND backup_preferred_here = 1 AND (
                    last_full IS NULL
                 OR (last_full < DATEADD(DAY, -@FullBackupMaxDays, @now) AND ISNULL(last_diff, '19000101') < DATEADD(HOUR, -@DiffBackupMaxHours, @now))
                 OR (recovery_model_desc <> N'SIMPLE' AND database_id > 4 AND ISNULL(last_log, '19000101') < DATEADD(MINUTE, -@LogBackupMaxMin, @now)))
                 THEN 'CRITICAL'
            WHEN name <> N'tempdb' AND state_desc = N'ONLINE' AND ISNULL(last_checkdb, '19000101') < DATEADD(DAY, -@CheckDbMaxDays, @now) THEN 'WARNING'
            WHEN log_used_pct >= @LogUsedWarnPct THEN 'WARNING'
            WHEN user_access_desc <> N'MULTI_USER' THEN 'WARNING'
            ELSE 'OK' END,
        notes = LTRIM(
              CASE WHEN state_desc NOT IN (N'ONLINE', N'RESTORING') THEN N'State ' + state_desc + N'. ' ELSE N'' END
            + CASE WHEN name <> N'tempdb' AND state_desc = N'ONLINE' AND backup_preferred_here = 1 AND last_full IS NULL THEN N'No full backup. ' ELSE N'' END
            + CASE WHEN name <> N'tempdb' AND state_desc = N'ONLINE' AND backup_preferred_here = 1 AND last_full < DATEADD(DAY, -@FullBackupMaxDays, @now)
                        AND ISNULL(last_diff, '19000101') < DATEADD(HOUR, -@DiffBackupMaxHours, @now) THEN N'Full/diff backup too old. ' ELSE N'' END
            + CASE WHEN state_desc = N'ONLINE' AND backup_preferred_here = 1 AND recovery_model_desc <> N'SIMPLE' AND database_id > 4
                        AND ISNULL(last_log, '19000101') < DATEADD(MINUTE, -@LogBackupMaxMin, @now) THEN N'Log backup older than ' + CAST(@LogBackupMaxMin AS nvarchar(10)) + N' min. ' ELSE N'' END
            + CASE WHEN backup_preferred_here = 0 AND @bkOk = 1 THEN N'Backups run on another AG replica. ' ELSE N'' END
            + CASE WHEN name <> N'tempdb' AND state_desc = N'ONLINE' AND ISNULL(last_checkdb, '19000101') < DATEADD(DAY, -@CheckDbMaxDays, @now) THEN N'CHECKDB older than ' + CAST(@CheckDbMaxDays AS nvarchar(10)) + N' days. ' ELSE N'' END
            + CASE WHEN log_used_pct >= @LogUsedWarnPct THEN N'Log ' + CAST(log_used_pct AS nvarchar(10)) + N'% used (' + log_reuse_wait_desc + N'). ' ELSE N'' END
            + CASE WHEN user_access_desc <> N'MULTI_USER' THEN user_access_desc + N'. ' ELSE N'' END);

    INSERT #issues SELECT status, 'Database', name, notes FROM #db WHERE status <> 'OK';

    /*=============================================================================
      5. ALWAYS ON: AGs, REPLICAS (NODES), ROLES, LISTENERS, DB SYNC
    =============================================================================*/
    SELECT ag.name AS ag_name, ags.primary_replica, ar.replica_server_name AS replica_node,
           ars.role_desc, ar.availability_mode_desc, ar.failover_mode_desc,
           ars.connected_state_desc, ars.synchronization_health_desc, ars.operational_state_desc,
           ar.secondary_role_allow_connections_desc, ar.endpoint_url, ar.backup_priority,
           STUFF((SELECT N', ' + l.dns_name + N':' + CAST(l.port AS nvarchar(10))
                  FROM sys.availability_group_listeners l WHERE l.group_id = ag.group_id
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'') AS listeners,
           ars.last_connect_error_description,
           CAST(CASE WHEN ars.connected_state_desc = 'CONNECTED' AND ars.synchronization_health_desc = 'HEALTHY' THEN 'OK'
                     WHEN ars.role_desc IS NULL THEN 'WARNING' ELSE 'CRITICAL' END AS varchar(10)) AS status
    INTO #agr
    FROM sys.availability_groups AS ag
    JOIN sys.dm_hadr_availability_group_states AS ags ON ags.group_id = ag.group_id
    JOIN sys.availability_replicas AS ar ON ar.group_id = ag.group_id
    LEFT JOIN sys.dm_hadr_availability_replica_states AS ars ON ars.replica_id = ar.replica_id;

    INSERT #issues SELECT status, 'AlwaysOn replica', ag_name + N' / ' + replica_node,
           ISNULL(role_desc, N'state not visible from this replica') + N', ' + ISNULL(connected_state_desc, N'?') + N', ' + ISNULL(synchronization_health_desc, N'?')
           + ISNULL(N', ' + last_connect_error_description, N'')
    FROM #agr WHERE status <> 'OK';

    SELECT ag.name AS ag_name, DB_NAME(drs.database_id) AS database_name, ar.replica_server_name AS replica_node,
           CASE WHEN drs.is_primary_replica = 1 THEN N'PRIMARY' ELSE N'SECONDARY' END AS role,
           drs.synchronization_state_desc, drs.synchronization_health_desc, drs.is_suspended, drs.suspend_reason_desc,
           drs.log_send_queue_size AS send_queue_kb, drs.redo_queue_size AS redo_queue_kb,
           drs.secondary_lag_seconds, drs.last_commit_time,
           CAST(CASE WHEN drs.synchronization_health_desc = 'HEALTHY' AND drs.is_suspended = 0 THEN 'OK' ELSE 'CRITICAL' END AS varchar(10)) AS status
    INTO #agdb
    FROM sys.dm_hadr_database_replica_states AS drs
    JOIN sys.availability_replicas AS ar ON ar.replica_id = drs.replica_id
    JOIN sys.availability_groups AS ag ON ag.group_id = drs.group_id;

    INSERT #issues SELECT status, 'AlwaysOn database', ag_name + N' / ' + database_name + N' @ ' + replica_node,
           synchronization_state_desc + CASE WHEN is_suspended = 1 THEN N' SUSPENDED (' + ISNULL(suspend_reason_desc, N'') + N')' ELSE N'' END
           + N', send queue ' + CAST(ISNULL(send_queue_kb, 0) AS nvarchar(20)) + N' KB, redo queue ' + CAST(ISNULL(redo_queue_kb, 0) AS nvarchar(20)) + N' KB'
    FROM #agdb WHERE status <> 'OK';

    -- Cluster (AG on WSFC / FCI)
    SELECT c.cluster_name, c.quorum_type_desc, c.quorum_state_desc, m.member_name, m.member_type_desc, m.member_state_desc, m.number_of_quorum_votes,
           CAST(CASE WHEN m.member_state_desc = 'UP' AND c.quorum_state_desc = 'NORMAL_QUORUM' THEN 'OK' ELSE 'CRITICAL' END AS varchar(10)) AS status
    INTO #cluster
    FROM sys.dm_hadr_cluster AS c CROSS JOIN sys.dm_hadr_cluster_members AS m;

    INSERT #issues SELECT status, 'Cluster', member_name, member_type_desc + N' ' + member_state_desc + N', quorum ' + quorum_state_desc
    FROM #cluster WHERE status <> 'OK';

    /*=============================================================================
      6. DISK SPACE (not available on MI)
    =============================================================================*/
    IF @is_mi = 0
    BEGIN
        INSERT #disk (volume, label, total_gb, free_gb, free_pct)
        EXEC (N'SELECT DISTINCT vs.volume_mount_point, vs.logical_volume_name,
                       CAST(vs.total_bytes / 1073741824.0 AS decimal(18,1)), CAST(vs.available_bytes / 1073741824.0 AS decimal(18,1)),
                       CAST(100.0 * vs.available_bytes / vs.total_bytes AS decimal(5,1))
                FROM sys.master_files mf CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs;');
        UPDATE #disk SET status = CASE WHEN free_pct < @DiskCritPct THEN 'CRITICAL' WHEN free_pct < @DiskWarnPct THEN 'WARNING' ELSE 'OK' END;
        INSERT #issues SELECT status, 'Disk', volume, CAST(free_gb AS nvarchar(20)) + N' GB free of ' + CAST(total_gb AS nvarchar(20)) + N' GB (' + CAST(free_pct AS nvarchar(10)) + N'%)'
        FROM #disk WHERE status <> 'OK';
    END;

    /*=============================================================================
      8. AGENT JOB FAILURES
    =============================================================================*/
    CREATE TABLE #jobs (job_name sysname, run_time datetime, step_id int, step_name sysname NULL, message nvarchar(500));
    BEGIN TRY
        -- run_date / run_time converted inline (msdb.dbo.agent_datetime needs EXECUTE permission)
        INSERT #jobs (job_name, run_time, step_id, step_name, message)
        SELECT j.name, DATETIMEFROMPARTS(h.run_date / 10000, h.run_date / 100 % 100, h.run_date % 100, h.run_time / 10000, h.run_time / 100 % 100, h.run_time % 100, 0), h.step_id, h.step_name, LEFT(h.message, 500)
        FROM msdb.dbo.sysjobhistory AS h
        JOIN msdb.dbo.sysjobs AS j ON j.job_id = h.job_id
        WHERE h.run_status = 0 AND h.step_id > 0 AND h.run_date > 0
          AND DATETIMEFROMPARTS(h.run_date / 10000, h.run_date / 100 % 100, h.run_date % 100, h.run_time / 10000, h.run_time / 100 % 100, h.run_time % 100, 0) >= DATEADD(HOUR, -@JobFailHours, @now);
    END TRY
    BEGIN CATCH
        INSERT #issues SELECT 'WARNING', 'Agent job', N'not read', N'No permission to read job history in msdb (' + ERROR_MESSAGE() + N')';
    END CATCH;

    INSERT #issues SELECT 'WARNING', 'Agent job', job_name, CAST(COUNT(*) AS nvarchar(10)) + N' failed step(s), last at ' + CONVERT(nvarchar(20), MAX(run_time), 120)
    FROM #jobs GROUP BY job_name;

    /*=============================================================================
      9. ERROR LOG: SEVERITY >= 17, CORRUPTION, I/O STALLS (current log)
    =============================================================================*/
    BEGIN TRY
        INSERT #el EXEC sys.xp_readerrorlog 0, 1, N'Severity:';
        INSERT #el EXEC sys.xp_readerrorlog 0, 1, N'I/O requests taking longer than';
        INSERT #el EXEC sys.xp_readerrorlog 0, 1, N'stack dump';
    END TRY
    BEGIN CATCH
        INSERT #issues SELECT 'WARNING', 'Error log', N'not read', N'No permission to read the error log (' + ERROR_MESSAGE() + N') - see SETUP in PerfCheck.sql';
    END CATCH;

    SELECT DISTINCT e.LogDate, e.ProcessInfo, LEFT(e.[Text], 1000) AS message
    INTO #errlog
    FROM #el AS e
    WHERE e.LogDate >= DATEADD(HOUR, -@ErrorLogHours, @now)
      AND (   e.[Text] LIKE N'I/O requests taking longer than%' OR e.[Text] LIKE N'%stack dump%'
           OR TRY_CAST(SUBSTRING(e.[Text], CHARINDEX('Severity:', e.[Text]) + 10, 2) AS int) >= 17);

    INSERT #issues SELECT 'CRITICAL', 'Error log', N'Severe errors (' + CAST(@ErrorLogHours AS nvarchar(5)) + N'h)',
           CAST(COUNT(*) AS nvarchar(10)) + N' entries, latest: ' + MAX(CONVERT(nvarchar(20), LogDate, 120))
    FROM #errlog HAVING COUNT(*) > 0;

    /*=============================================================================
      10. CERTIFICATES (TDE / backup encryption / endpoints)
    =============================================================================*/
    INSERT #issues
    SELECT 'WARNING', 'Certificate', c.name,
           N'Expires ' + CONVERT(nvarchar(10), c.expiry_date, 120)
         + CASE WHEN c.pvt_key_last_backup_date IS NULL AND EXISTS (SELECT 1 FROM sys.dm_database_encryption_keys k WHERE k.encryptor_thumbprint = c.thumbprint)
                THEN N' - TDE certificate private key NEVER backed up' ELSE N'' END
    FROM master.sys.certificates AS c
    WHERE c.name NOT LIKE N'##%'
      AND (c.expiry_date < DATEADD(DAY, @CertWarnDays, @now)
           OR (c.pvt_key_last_backup_date IS NULL AND EXISTS (SELECT 1 FROM sys.dm_database_encryption_keys k WHERE k.encryptor_thumbprint = c.thumbprint)));

    /*=============================================================================
      11. EXTRA DATA FOR PRE / POST COMPARISON
    =============================================================================*/
    IF OBJECT_ID('tempdb..#tf') IS NOT NULL DROP TABLE #tf;
    CREATE TABLE #tf (TraceFlag int, Status int, Global int, Session int);
    INSERT #tf EXEC (N'DBCC TRACESTATUS(-1) WITH NO_INFOMSGS');

    /*=============================================================================
      12. SSIS CATALOG (SSISDB) - catalog settings, projects, environments, failures
    =============================================================================*/
    IF OBJECT_ID('tempdb..#ssis_cat')  IS NOT NULL DROP TABLE #ssis_cat;
    IF OBJECT_ID('tempdb..#ssis_proj') IS NOT NULL DROP TABLE #ssis_proj;
    IF OBJECT_ID('tempdb..#ssis_env')  IS NOT NULL DROP TABLE #ssis_env;
    IF OBJECT_ID('tempdb..#ssis_fail') IS NOT NULL DROP TABLE #ssis_fail;
    CREATE TABLE #ssis_cat  (property_name nvarchar(256), property_value nvarchar(4000));
    CREATE TABLE #ssis_proj (folder nvarchar(128), project nvarchar(128), packages int, object_version_lsn bigint, last_deployed nvarchar(19), deployed_by nvarchar(256));
    CREATE TABLE #ssis_env  (folder nvarchar(128), environment nvarchar(128), variables int);
    CREATE TABLE #ssis_fail (execution_id bigint, folder nvarchar(128) NULL, project nvarchar(128) NULL, package nvarchar(260) NULL, start_time nvarchar(19) NULL, status nvarchar(30) NULL);

    IF DB_ID(N'SSISDB') IS NOT NULL AND HAS_DBACCESS(N'SSISDB') = 1
    BEGIN
        BEGIN TRY
            EXEC (N'INSERT #ssis_cat SELECT property_name, CAST(property_value AS nvarchar(4000)) FROM SSISDB.catalog.catalog_properties;');
            EXEC (N'INSERT #ssis_proj SELECT f.name, p.name, (SELECT COUNT(*) FROM SSISDB.catalog.packages AS k WHERE k.project_id = p.project_id),
                           p.object_version_lsn, CONVERT(nvarchar(19), p.last_deployed_time, 120), p.deployed_by_name
                    FROM SSISDB.catalog.projects AS p JOIN SSISDB.catalog.folders AS f ON f.folder_id = p.folder_id;');
            EXEC (N'INSERT #ssis_env SELECT f.name, e.name, (SELECT COUNT(*) FROM SSISDB.catalog.environment_variables AS v WHERE v.environment_id = e.environment_id)
                    FROM SSISDB.catalog.environments AS e JOIN SSISDB.catalog.folders AS f ON f.folder_id = e.folder_id;');
            SET @sql = N'INSERT #ssis_fail SELECT TOP (200) execution_id, folder_name, project_name, package_name, CONVERT(nvarchar(19), start_time, 120),
                           CASE status WHEN 4 THEN N''Failed'' WHEN 6 THEN N''Ended unexpectedly'' END
                    FROM SSISDB.catalog.executions
                    WHERE status IN (4, 6) AND start_time >= DATEADD(HOUR, -@h, SYSDATETIMEOFFSET())
                    ORDER BY execution_id DESC;';
            EXEC sys.sp_executesql @sql, N'@h int', @h = @JobFailHours;
        END TRY
        BEGIN CATCH
            INSERT #issues (severity, area, item, detail) VALUES ('WARNING', 'SSIS', N'SSISDB', LEFT(N'Could not read the SSIS catalog: ' + ERROR_MESSAGE(), 1900));
        END CATCH;

        INSERT #issues (severity, area, item, detail)
        SELECT 'WARNING', 'SSIS', N'Failed package executions',
               CAST(COUNT(*) AS nvarchar(10)) + N' in the last ' + CAST(@JobFailHours AS nvarchar(5)) + N' h, latest: ' + ISNULL(MAX(package), N'')
        FROM #ssis_fail HAVING COUNT(*) > 0;
    END;

    /*=============================================================================
      13. SSRS REPORT SERVER DATABASES ON THIS INSTANCE - content & subscriptions
      Any database with dbo.Catalog + dbo.Subscriptions + dbo.ExecutionLogStorage.
    =============================================================================*/
    IF OBJECT_ID('tempdb..#ssrs_sum') IS NOT NULL DROP TABLE #ssrs_sum;
    IF OBJECT_ID('tempdb..#ssrs_sub') IS NOT NULL DROP TABLE #ssrs_sub;
    CREATE TABLE #ssrs_sum (rs_database sysname, folders int, reports int, datasources int, datasets int, other_items int,
                            subscriptions int, failing_subscriptions int, schedules int, failed_executions int);
    CREATE TABLE #ssrs_sub (rs_database sysname, subscription_id nvarchar(40), report_path nvarchar(425) NULL, owner nvarchar(260) NULL,
                            description nvarchar(512) NULL, inactive_flags int NULL, last_status nvarchar(260) NULL, last_run nvarchar(19) NULL, is_failing int);

    DECLARE rsc CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM sys.databases
        WHERE state_desc = N'ONLINE' AND HAS_DBACCESS(name) = 1 AND source_database_id IS NULL
          AND OBJECT_ID(QUOTENAME(name) + N'.dbo.Catalog') IS NOT NULL
          AND OBJECT_ID(QUOTENAME(name) + N'.dbo.Subscriptions') IS NOT NULL
          AND OBJECT_ID(QUOTENAME(name) + N'.dbo.ExecutionLogStorage') IS NOT NULL;
    OPEN rsc; FETCH NEXT FROM rsc INTO @dbn;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @sql = N'USE ' + QUOTENAME(@dbn) + N';
    INSERT #ssrs_sub (rs_database, subscription_id, report_path, owner, description, inactive_flags, last_status, last_run, is_failing)
    SELECT DB_NAME(), CAST(s.SubscriptionID AS nvarchar(40)), c.Path, u.UserName, LEFT(s.Description, 512), s.InactiveFlags,
           LEFT(s.LastStatus, 260), CONVERT(nvarchar(19), s.LastRunTime, 120),
           CASE WHEN s.LastStatus LIKE N''%fail%'' OR s.LastStatus LIKE N''%error%'' THEN 1 ELSE 0 END
    FROM dbo.Subscriptions AS s
    LEFT JOIN dbo.Catalog AS c ON c.ItemID = s.Report_OID
    LEFT JOIN dbo.Users AS u ON u.UserID = s.OwnerID;
    INSERT #ssrs_sum
    SELECT DB_NAME(),
           SUM(CASE WHEN c.Type = 1 THEN 1 ELSE 0 END), SUM(CASE WHEN c.Type = 2 THEN 1 ELSE 0 END),
           SUM(CASE WHEN c.Type = 5 THEN 1 ELSE 0 END), SUM(CASE WHEN c.Type = 8 THEN 1 ELSE 0 END),
           SUM(CASE WHEN c.Type NOT IN (1, 2, 5, 8) THEN 1 ELSE 0 END),
           (SELECT COUNT(*) FROM dbo.Subscriptions),
           (SELECT COUNT(*) FROM #ssrs_sub AS x WHERE x.rs_database = DB_NAME() AND x.is_failing = 1),
           (SELECT COUNT(*) FROM dbo.Schedule),
           (SELECT COUNT(*) FROM dbo.ExecutionLogStorage AS e WHERE e.TimeStart >= DATEADD(HOUR, -@h, GETDATE()) AND e.Status <> N''rsSuccess'')
    FROM dbo.Catalog AS c;';
            EXEC sys.sp_executesql @sql, N'@h int', @h = @JobFailHours;
        END TRY
        BEGIN CATCH
            INSERT #issues (severity, area, item, detail) VALUES ('WARNING', 'SSRS', @dbn, LEFT(N'Could not read the report server database: ' + ERROR_MESSAGE(), 1900));
        END CATCH;
        FETCH NEXT FROM rsc INTO @dbn;
    END
    CLOSE rsc; DEALLOCATE rsc;

    INSERT #issues (severity, area, item, detail)
    SELECT 'WARNING', 'SSRS', LEFT(rs_database + N' / ' + ISNULL(report_path, subscription_id), 300), N'Subscription failing: ' + ISNULL(last_status, N'')
    FROM #ssrs_sub WHERE is_failing = 1;
    INSERT #issues (severity, area, item, detail)
    SELECT 'WARNING', 'SSRS', rs_database, CAST(failed_executions AS nvarchar(10)) + N' failed report executions in the last ' + CAST(@JobFailHours AS nvarchar(5)) + N' h'
    FROM #ssrs_sum WHERE failed_executions > 0;

    /*=============================================================================
      SSIS / SSRS / SSAS SERVICES ON THIS SERVER (xp_servicecontrol - sysadmin only)
    =============================================================================*/
    IF OBJECT_ID('tempdb..#bi_svc') IS NOT NULL DROP TABLE #bi_svc;
    CREATE TABLE #bi_svc (service nvarchar(128), state nvarchar(60), status varchar(10));
    IF OBJECT_ID('tempdb..#svcstate') IS NOT NULL DROP TABLE #svcstate;
    CREATE TABLE #svcstate (state nvarchar(200));
    IF @is_mi = 0 AND IS_SRVROLEMEMBER(N'sysadmin') = 1
    BEGIN
        DECLARE @inst sysname = CAST(SERVERPROPERTY('InstanceName') AS sysname), @svcName nvarchar(128), @svcLabel nvarchar(128);
        DECLARE bisvc CURSOR LOCAL FAST_FORWARD FOR
            SELECT n, l FROM (VALUES
                (N'MsDtsServer130', N'SSIS 2016 (MsDtsServer130)'), (N'MsDtsServer140', N'SSIS 2017 (MsDtsServer140)'),
                (N'MsDtsServer150', N'SSIS 2019 (MsDtsServer150)'), (N'MsDtsServer160', N'SSIS 2022 (MsDtsServer160)'),
                (N'MsDtsServer170', N'SSIS 2025 (MsDtsServer170)'),
                (N'SQLServerReportingServices', N'SSRS (SQLServerReportingServices)'), (N'PowerBIReportServer', N'Power BI Report Server'),
                (CASE WHEN @inst IS NULL THEN N'ReportServer' ELSE N'ReportServer$' + @inst END, N'SSRS 2016 (ReportServer)'),
                (CASE WHEN @inst IS NULL THEN N'MSSQLServerOLAPService' ELSE N'MSOLAP$' + @inst END, N'SSAS (' + ISNULL(@inst, N'default') + N')')
            ) AS s(n, l);
        OPEN bisvc;
        FETCH NEXT FROM bisvc INTO @svcName, @svcLabel;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            TRUNCATE TABLE #svcstate;
            BEGIN TRY
                INSERT #svcstate EXEC master.dbo.xp_servicecontrol N'QUERYSTATE', @svcName;
                INSERT #bi_svc (service, state, status)
                SELECT @svcLabel, REPLACE(state, N'.', N''), CASE WHEN state LIKE N'Running%' THEN 'OK' ELSE 'WARNING' END
                FROM #svcstate WHERE state IS NOT NULL AND state NOT LIKE N'%error%' AND state NOT LIKE N'%does not exist%';
            END TRY
            BEGIN CATCH
            END CATCH;   -- service not installed
            FETCH NEXT FROM bisvc INTO @svcName, @svcLabel;
        END;
        CLOSE bisvc; DEALLOCATE bisvc;
        INSERT #issues SELECT 'WARNING', 'BI services', service, N'Service is ' + state FROM #bi_svc WHERE status <> 'OK';
    END;
    

    -- ---- health report ----
    SELECT @p_hCrit = SUM(CASE WHEN severity = 'CRITICAL' THEN 1 ELSE 0 END), @p_hWarn = SUM(CASE WHEN severity = 'WARNING' THEN 1 ELSE 0 END) FROM #issues;
    SET @p_hCrit = ISNULL(@p_hCrit, 0); SET @p_hWarn = ISNULL(@p_hWarn, 0);
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT severity, area, item, ISNULL(detail, N'''') AS detail, CASE severity WHEN ''CRITICAL'' THEN 0 ELSE 1 END AS _o FROM #issues',
         @Title = N'Health - needs attention', @OrderBy = N'_o, area, item', @StatusColumn = N'severity', @MaxRows = 0, @SkipEmpty = 0, @Html = @p_part OUTPUT;
    SET @p_hShort = N'<h2>Health check</h2><div class="banner" style="background:' + CASE WHEN @p_hCrit > 0 THEN N'#f8d7da' WHEN @p_hWarn > 0 THEN N'#fff3cd' ELSE N'#d4edda' END
                 + N'">Health: ' + CAST(@p_hCrit AS nvarchar(10)) + N' critical, ' + CAST(@p_hWarn AS nvarchar(10)) + N' warning(s)</div>'
                 + N'<div>Build: ' + CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(30)) + N' ' + ISNULL(CAST(SERVERPROPERTY('ProductUpdateLevel') AS nvarchar(30)), N'') + N'</div>' + @p_part;
    SET @p_hFull = @p_hShort;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT v.seq AS _seq, v.property, v.value
FROM sys.dm_os_sys_info AS i
CROSS APPLY (VALUES
    (1,  N''Server name'',            CAST(@@SERVERNAME AS nvarchar(4000))),
    (2,  N''Machine / active node'',  CAST(SERVERPROPERTY(''ComputerNamePhysicalNetBIOS'') AS nvarchar(4000))),
    (3,  N''Edition'',                CAST(SERVERPROPERTY(''Edition'') AS nvarchar(4000))),
    (4,  N''Build'',                  CAST(SERVERPROPERTY(''ProductVersion'') AS nvarchar(4000))),
    (5,  N''Product level'',          CAST(SERVERPROPERTY(''ProductLevel'') AS nvarchar(4000))),
    (6,  N''Cumulative update'',      CAST(SERVERPROPERTY(''ProductUpdateLevel'') AS nvarchar(4000))),
    (7,  N''KB'',                     CAST(SERVERPROPERTY(''ProductUpdateReference'') AS nvarchar(4000))),
    (8,  N''Collation'',              CAST(SERVERPROPERTY(''Collation'') AS nvarchar(4000))),
    (9,  N''Failover cluster (FCI)'', CAST(SERVERPROPERTY(''IsClustered'') AS nvarchar(4000))),
    (10, N''Always On enabled'',      CAST(SERVERPROPERTY(''IsHadrEnabled'') AS nvarchar(4000))),
    (11, N''SQL started'',            CONVERT(nvarchar(19), i.sqlserver_start_time, 120)),
    (12, N''SQL Server uptime'',      CAST(DATEDIFF(SECOND, i.sqlserver_start_time, GETDATE()) / 86400 AS nvarchar(10)) + N''d ''
                                    + RIGHT(N''0'' + CAST(DATEDIFF(SECOND, i.sqlserver_start_time, GETDATE()) % 86400 / 3600 AS nvarchar(2)), 2) + N''h ''
                                    + RIGHT(N''0'' + CAST(DATEDIFF(SECOND, i.sqlserver_start_time, GETDATE()) % 3600 / 60 AS nvarchar(2)), 2) + N''m''),
    (13, N''Windows started'',        CONVERT(nvarchar(16), DATEADD(SECOND, -CAST(i.ms_ticks / 1000 AS int), GETDATE()), 120)),
    (14, N''Windows uptime'',         CAST(i.ms_ticks / 1000 / 86400 AS nvarchar(10)) + N''d ''
                                    + RIGHT(N''0'' + CAST(i.ms_ticks / 1000 % 86400 / 3600 AS nvarchar(2)), 2) + N''h ''
                                    + RIGHT(N''0'' + CAST(i.ms_ticks / 1000 % 3600 / 60 AS nvarchar(2)), 2) + N''m''),
    (15, N''Logical CPUs'',           CAST(i.cpu_count AS nvarchar(20))),
    (16, N''Schedulers'',             CAST(i.scheduler_count AS nvarchar(20))),
    (17, N''Physical memory (MB)'',   CAST(i.physical_memory_kb / 1024 AS nvarchar(20))),
    (18, N''Memory model'',           CAST(i.sql_memory_model_desc AS nvarchar(4000)))
) AS v(seq, property, value)',
         @Title = N'Instance', @OrderBy = N'_seq', @MaxRows = 0, @SkipEmpty = 1, @Html = @p_part OUTPUT;
    SET @p_hFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT servicename, status_desc AS status, startup_type_desc AS startup_type, service_account, ifi,
       CONVERT(nvarchar(19), last_startup_time, 120) AS last_startup FROM #svc',
         @Title = N'SQL Server services', @OrderBy = N'servicename', @MaxRows = 0, @SkipEmpty = 1, @Html = @p_part OUTPUT;
    SET @p_hFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT service, state, status FROM #bi_svc',
         @Title = N'SSIS / SSRS / SSAS services on this server', @OrderBy = N'service', @StatusColumn = N'status', @MaxRows = 0, @SkipEmpty = 1, @Html = @p_part OUTPUT;
    SET @p_hFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT seq AS _seq, metric, value, status FROM #vitals',
         @Title = N'Vitals', @OrderBy = N'_seq', @StatusColumn = N'status', @MaxRows = 0, @SkipEmpty = 1, @Html = @p_part OUTPUT;
    SET @p_hFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT d.name, d.state_desc AS state, d.user_access_desc AS user_access, d.recovery_model_desc AS recovery_model,
       d.compatibility_level AS compat, d.owner_name, d.size_mb, d.log_used_pct, d.log_reuse_wait_desc AS log_reuse_wait,
       ISNULL(d.ag_name, N'''') AS ag_name, d.ag_role, ISNULL(d.ag_sync_state, N'''') AS ag_sync_state,
       CONVERT(nvarchar(16), d.last_full, 120) AS last_full, CONVERT(nvarchar(16), d.last_diff, 120) AS last_diff,
       CONVERT(nvarchar(16), d.last_log, 120) AS last_log, CONVERT(nvarchar(16), NULLIF(d.last_checkdb, ''19000101''), 120) AS last_checkdb,
       d.status, d.notes, d.database_id AS _dbid
FROM #db AS d',
         @Title = N'Databases, backups & CHECKDB', @OrderBy = N'_dbid', @StatusColumn = N'status', @MaxRows = 0, @SkipEmpty = 1, @Html = @p_part OUTPUT;
    SET @p_hFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT ag_name, replica_node, ISNULL(primary_replica, N'''') AS primary_replica, ISNULL(role_desc, N'''') AS role,
       availability_mode_desc AS availability_mode, failover_mode_desc AS failover_mode, ISNULL(connected_state_desc, N'''') AS connected_state,
       ISNULL(synchronization_health_desc, N'''') AS sync_health, secondary_role_allow_connections_desc AS readable,
       ISNULL(endpoint_url, N'''') AS endpoint_url, backup_priority, ISNULL(listeners, N'''') AS listeners, status
FROM #agr',
         @Title = N'Always On - replicas (nodes)', @OrderBy = N'ag_name, replica_node', @StatusColumn = N'status', @MaxRows = 0, @SkipEmpty = 1, @Html = @p_part OUTPUT;
    SET @p_hFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT ag.name AS ag_name, l.dns_name AS listener, l.port,
       ISNULL(ip.ip_address, N'''') AS ip_address, ISNULL(ip.ip_subnet_mask, N'''') AS subnet_mask,
       CASE ip.is_dhcp WHEN 1 THEN N''DHCP'' WHEN 0 THEN N''Static'' ELSE N'''' END AS ip_type,
       ISNULL(ip.network_subnet_ip + N''/'' + CAST(ip.network_subnet_prefix_length AS nvarchar(5)), N'''') AS network_subnet,
       ISNULL(ip.state_desc, N'''') AS ip_state, l.is_conformant
FROM sys.availability_group_listeners AS l
JOIN sys.availability_groups AS ag ON ag.group_id = l.group_id
LEFT JOIN sys.availability_group_listener_ip_addresses AS ip ON ip.listener_id = l.listener_id',
         @Title = N'Always On - listeners (IP / DHCP)', @OrderBy = N'ag_name, listener, ip_address', @MaxRows = 0, @SkipEmpty = 1, @Html = @p_part OUTPUT;
    SET @p_hFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT ag_name, database_name, replica_node, role, synchronization_state_desc AS sync_state,
       synchronization_health_desc AS sync_health, is_suspended, send_queue_kb, redo_queue_kb, status FROM #agdb',
         @Title = N'Always On - databases per replica', @OrderBy = N'ag_name, database_name, replica_node', @StatusColumn = N'status', @MaxRows = 0, @SkipEmpty = 1, @Html = @p_part OUTPUT;
    SET @p_hFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT member_name, cluster_name, quorum_type_desc AS quorum_type, quorum_state_desc AS quorum_state,
       member_type_desc AS member_type, member_state_desc AS member_state, number_of_quorum_votes AS votes, status FROM #cluster',
         @Title = N'Cluster & quorum', @OrderBy = N'member_name', @StatusColumn = N'status', @MaxRows = 0, @SkipEmpty = 1, @Html = @p_part OUTPUT;
    SET @p_hFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT volume, ISNULL(label, N'''') AS label, total_gb, free_gb, free_pct, status FROM #disk',
         @Title = N'Disk space', @OrderBy = N'volume', @StatusColumn = N'status', @MaxRows = 0, @SkipEmpty = 1, @Html = @p_part OUTPUT;
    SET @p_hFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT job_name, run_time, CAST(step_id AS nvarchar(5)) + N'' '' + ISNULL(step_name, N'''') AS step, message FROM #jobs',
         @Title = N'Failed job steps (24 h)', @OrderBy = N'run_time DESC', @MaxRows = 0, @SkipEmpty = 1, @Html = @p_part OUTPUT;
    SET @p_hFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT TOP (50) LogDate AS log_time, ProcessInfo AS source, message FROM #errlog ORDER BY LogDate DESC',
         @Title = N'Severe error log entries (24 h)', @OrderBy = N'log_time DESC', @MaxRows = 0, @SkipEmpty = 1, @Html = @p_part OUTPUT;
    SET @p_hFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT TraceFlag AS trace_flag FROM #tf WHERE Global = 1',
         @Title = N'Global trace flags', @OrderBy = N'trace_flag', @MaxRows = 0, @SkipEmpty = 1, @Html = @p_part OUTPUT;
    SET @p_hFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT name, CAST(value_in_use AS nvarchar(100)) AS value_in_use, CAST(value AS nvarchar(100)) AS configured
FROM sys.configurations
WHERE CAST(value AS sql_variant) <> CAST(value_in_use AS sql_variant)
   OR name IN (N''max server memory (MB)'', N''min server memory (MB)'', N''max degree of parallelism'', N''cost threshold for parallelism'',
               N''optimize for ad hoc workloads'', N''backup compression default'', N''remote admin connections'', N''Database Mail XPs'',
               N''xp_cmdshell'', N''clr enabled'', N''blocked process threshold (s)'', N''fill factor (%)'', N''priority boost'', N''lightweight pooling'')',
         @Title = N'sp_configure (key settings and pending changes)', @OrderBy = N'name', @MaxRows = 0, @SkipEmpty = 1, @Html = @p_part OUTPUT;
    SET @p_hFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT name, ISNULL(product, N'''') AS product, ISNULL(provider, N'''') AS provider, ISNULL(data_source, N'''') AS data_source
FROM sys.servers WHERE is_linked = 1',
         @Title = N'Linked servers', @OrderBy = N'name', @MaxRows = 0, @SkipEmpty = 1, @Html = @p_part OUTPUT;
    SET @p_hFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT e.name, e.type_desc AS type, e.state_desc AS state, ISNULL(CAST(t.port AS nvarchar(10)), N'''') AS port
FROM sys.endpoints AS e LEFT JOIN sys.tcp_endpoints AS t ON t.endpoint_id = e.endpoint_id WHERE e.endpoint_id > 5',
         @Title = N'Endpoints', @OrderBy = N'name', @MaxRows = 0, @SkipEmpty = 1, @Html = @p_part OUTPUT;
    SET @p_hFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT name, CONVERT(nvarchar(10), expiry_date, 120) AS expiry FROM master.sys.certificates WHERE name NOT LIKE N''##%'' ',
         @Title = N'Certificates', @OrderBy = N'name', @MaxRows = 0, @SkipEmpty = 1, @Html = @p_part OUTPUT;
    SET @p_hFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT s.name, CASE WHEN r.name IS NULL THEN N''stopped'' ELSE N''running'' END AS state
FROM sys.server_event_sessions AS s LEFT JOIN sys.dm_xe_sessions AS r ON r.name = s.name',
         @Title = N'XE sessions', @OrderBy = N'name', @MaxRows = 0, @SkipEmpty = 1, @Html = @p_part OUTPUT;
    SET @p_hFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT property_name, ISNULL(property_value, N'''') AS property_value FROM #ssis_cat',
         @Title = N'SSIS catalog settings', @OrderBy = N'property_name', @MaxRows = 0, @SkipEmpty = 1, @Html = @p_part OUTPUT;
    SET @p_hFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT folder, project, packages, object_version_lsn, ISNULL(last_deployed, N'''') AS last_deployed, ISNULL(deployed_by, N'''') AS deployed_by FROM #ssis_proj',
         @Title = N'SSIS projects', @OrderBy = N'folder, project', @MaxRows = 0, @SkipEmpty = 1, @Html = @p_part OUTPUT;
    SET @p_hFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT folder, environment, variables FROM #ssis_env',
         @Title = N'SSIS environments', @OrderBy = N'folder, environment', @MaxRows = 0, @SkipEmpty = 1, @Html = @p_part OUTPUT;
    SET @p_hFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT execution_id, ISNULL(folder, N'''') AS folder, ISNULL(project, N'''') AS project, ISNULL(package, N'''') AS package,
       ISNULL(start_time, N'''') AS start_time, ISNULL(status, N'''') AS status FROM #ssis_fail',
         @Title = N'SSIS failed executions (24 h)', @OrderBy = N'execution_id DESC', @MaxRows = 0, @SkipEmpty = 1, @Html = @p_part OUTPUT;
    SET @p_hFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT rs_database, folders, reports, datasources, datasets, other_items, subscriptions, failing_subscriptions, schedules, failed_executions FROM #ssrs_sum',
         @Title = N'SSRS content (report server databases)', @OrderBy = N'rs_database', @MaxRows = 0, @SkipEmpty = 1, @Html = @p_part OUTPUT;
    SET @p_hFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT rs_database, ISNULL(report_path, N'''') AS report_path, ISNULL(owner, N'''') AS owner, ISNULL(description, N'''') AS description,
       ISNULL(last_status, N'''') AS last_status, ISNULL(last_run, N'''') AS last_run, is_failing FROM #ssrs_sub',
         @Title = N'SSRS subscriptions', @OrderBy = N'rs_database, report_path', @MaxRows = 0, @SkipEmpty = 1, @Html = @p_part OUTPUT;
    SET @p_hFull += @p_part;

END;   -- health check

/*#############################################################################
  PERFORMANCE WINDOW
#############################################################################*/
IF @NoPerf = 0
BEGIN
    DECLARE @pf_orig int, @pf_adv int, @pf_thrSet bit = 0, @pf_xe bit = 0, @pf_xeSql nvarchar(max), @pf_n int, @pf_i int = 0,
            @pf_delay char(8), @pf_hasPdb bit = 0, @pf_start datetimeoffset = SYSDATETIMEOFFSET(), @pf_x xml, @pf_cached int = 0;

    -- A previous run was stopped half-way: put its original threshold back first
    IF EXISTS (SELECT 1 FROM dbo.DBA_PerfCheck_State WHERE id = 1)
    BEGIN
        SELECT @pf_orig = orig_threshold FROM dbo.DBA_PerfCheck_State WHERE id = 1;
        BEGIN TRY
            IF @pf_orig <> (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'blocked process threshold (s)')
            BEGIN
                SELECT @pf_adv = CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'show advanced options';
                IF @pf_adv = 0 BEGIN EXEC sys.sp_configure N'show advanced options', 1; RECONFIGURE; END;
                EXEC sys.sp_configure N'blocked process threshold (s)', @pf_orig; RECONFIGURE;
                IF @pf_adv = 0 BEGIN EXEC sys.sp_configure N'show advanced options', 0; RECONFIGURE; END;
            END;
            DELETE dbo.DBA_PerfCheck_State WHERE id = 1;
            SET @p_notes += N'Restored blocked process threshold (' + CAST(@pf_orig AS nvarchar(10)) + N' s) left by an interrupted run. ';
        END TRY
        BEGIN CATCH SET @p_notes += N'Could not restore the threshold left by an interrupted run: ' + ERROR_MESSAGE() + N' '; END CATCH;
    END;

    -- databases for 'Trans/s'
    IF OBJECT_ID('tempdb..#pdb') IS NOT NULL DROP TABLE #pdb;
    CREATE TABLE #pdb (name sysname PRIMARY KEY);
    IF NULLIF(LTRIM(@PerfDatabases), N'') IS NOT NULL
        INSERT #pdb (name)
        SELECT DISTINCT LTRIM(RTRIM(x.d.value('.', 'nvarchar(128)')))
        FROM (SELECT CAST(N'<d>' + REPLACE((SELECT @PerfDatabases FOR XML PATH('')), N',', N'</d><d>') + N'</d>' AS xml) AS v) AS s
        CROSS APPLY s.v.nodes('/d') AS x(d)
        WHERE LTRIM(RTRIM(x.d.value('.', 'nvarchar(128)'))) <> N'';
    IF EXISTS (SELECT 1 FROM #pdb) SET @pf_hasPdb = 1;

    -- 1. blocked process threshold + XE session (recorded first so it can always be undone)
    SELECT @pf_orig = CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'blocked process threshold (s)';
    IF HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER SETTINGS') = 1
    BEGIN
        BEGIN TRY
            IF @pf_orig <> @BlockedThresholdSec
            BEGIN
                INSERT dbo.DBA_PerfCheck_State (id, orig_threshold) VALUES (1, @pf_orig);
                SELECT @pf_adv = CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'show advanced options';
                IF @pf_adv = 0 BEGIN EXEC sys.sp_configure N'show advanced options', 1; RECONFIGURE; END;
                EXEC sys.sp_configure N'blocked process threshold (s)', @BlockedThresholdSec; RECONFIGURE;
                IF @pf_adv = 0 BEGIN EXEC sys.sp_configure N'show advanced options', 0; RECONFIGURE; END;
                SET @pf_thrSet = 1;
            END;
        END TRY
        BEGIN CATCH SET @p_notes += N'Blocked process threshold not changed: ' + ERROR_MESSAGE() + N' '; END CATCH;
    END
    ELSE SET @p_notes += N'No ALTER SETTINGS permission - blocked process threshold not changed. ';

    IF HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER ANY EVENT SESSION') = 1
    BEGIN
        BEGIN TRY
            IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'DBA_PerfCheckJob') DROP EVENT SESSION DBA_PerfCheckJob ON SERVER;
            SET @pf_xeSql = REPLACE(N'CREATE EVENT SESSION DBA_PerfCheckJob ON SERVER
ADD EVENT sqlserver.blocked_process_report,
ADD EVENT sqlserver.xml_deadlock_report,
ADD EVENT sqlserver.rpc_completed (
    ACTION (sqlserver.session_id, sqlserver.database_name, sqlserver.client_app_name, sqlserver.client_hostname, sqlserver.username)
    WHERE duration > #LONG#),
ADD EVENT sqlserver.sql_batch_completed (
    ACTION (sqlserver.session_id, sqlserver.database_name, sqlserver.client_app_name, sqlserver.client_hostname, sqlserver.username)
    WHERE duration > #LONG#)
ADD TARGET package0.ring_buffer (SET max_memory = 8192, max_events_limit = 2000)
WITH (MAX_DISPATCH_LATENCY = 5 SECONDS, EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS, STARTUP_STATE = OFF);', N'#LONG#', CAST(CAST(@LongQuerySec AS bigint) * 1000000 AS nvarchar(20)));
            EXEC (@pf_xeSql);
            ALTER EVENT SESSION DBA_PerfCheckJob ON SERVER STATE = START;
            SET @pf_xe = 1;
        END TRY
        BEGIN CATCH SET @p_notes += N'XE session not started: ' + ERROR_MESSAGE() + N' '; END CATCH;
    END
    ELSE SET @p_notes += N'No ALTER ANY EVENT SESSION permission - no blocked process reports, deadlocks or long-query capture. ';

    -- 2. plan cache baseline for the window's top queries
    IF OBJECT_ID('tempdb..#qstart') IS NOT NULL DROP TABLE #qstart;
    CREATE TABLE #qstart (query_hash binary(8) PRIMARY KEY, ec bigint, el bigint, cpu bigint, rd bigint);
    IF @TopQueries = 1
        INSERT #qstart (query_hash, ec, el, cpu, rd)
        SELECT query_hash, SUM(execution_count), SUM(total_elapsed_time), SUM(total_worker_time), SUM(total_logical_reads)
        FROM sys.dm_exec_query_stats WHERE query_hash IS NOT NULL GROUP BY query_hash;

    -- 3. sample tables
    IF OBJECT_ID('tempdb..#s_time')  IS NOT NULL DROP TABLE #s_time;
    IF OBJECT_ID('tempdb..#s_pc')    IS NOT NULL DROP TABLE #s_pc;
    IF OBJECT_ID('tempdb..#s_waits') IS NOT NULL DROP TABLE #s_waits;
    IF OBJECT_ID('tempdb..#s_io')    IS NOT NULL DROP TABLE #s_io;
    IF OBJECT_ID('tempdb..#s_sess')  IS NOT NULL DROP TABLE #s_sess;
    IF OBJECT_ID('tempdb..#s_blk')   IS NOT NULL DROP TABLE #s_blk;
    IF OBJECT_ID('tempdb..#s_prob')  IS NOT NULL DROP TABLE #s_prob;
    IF OBJECT_ID('tempdb..#s_head')  IS NOT NULL DROP TABLE #s_head;
    IF OBJECT_ID('tempdb..#s_grant') IS NOT NULL DROP TABLE #s_grant;
    IF OBJECT_ID('tempdb..#s_tdbs')  IS NOT NULL DROP TABLE #s_tdbs;
    IF OBJECT_ID('tempdb..#s_tdb')   IS NOT NULL DROP TABLE #s_tdb;
    IF OBJECT_ID('tempdb..#s_ag')    IS NOT NULL DROP TABLE #s_ag;
    IF OBJECT_ID('tempdb..#s_lsn')   IS NOT NULL DROP TABLE #s_lsn;
    CREATE TABLE #s_time  (n int PRIMARY KEY, t datetime2(3));
    CREATE TABLE #s_pc    (n int, obj nvarchar(128), ctr nvarchar(128), inst nvarchar(128), val bigint);
    CREATE TABLE #s_waits (n int, grp nvarchar(60), wait_ms bigint);
    CREATE TABLE #s_io    (n int, db nvarchar(128), ftype varchar(4), reads bigint, rstall bigint, writes bigint, wstall bigint);
    CREATE TABLE #s_sess  (n int, program nvarchar(256), host nvarchar(256), login nvarchar(256), sessions int, active int);
    CREATE TABLE #s_blk   (n int, blocked int, max_wait_ms bigint);
    CREATE TABLE #s_prob  (n int, seen_at datetime, reason nvarchar(40), session_id int, login nvarchar(256), host nvarchar(256), program nvarchar(256),
                           db nvarchar(128), status nvarchar(30), command nvarchar(32), wait_type nvarchar(60), wait_ms bigint, wait_resource nvarchar(256),
                           blocked_by int, elapsed_s bigint, cpu_ms bigint, logical_reads bigint, writes bigint, granted_mb bigint, tempdb_mb decimal(18, 1),
                           open_tran int, statement nvarchar(400), object_name nvarchar(256));
    CREATE TABLE #s_head  (n int, seen_at datetime, session_id int, login nvarchar(256), host nvarchar(256), program nvarchar(256), db nvarchar(128),
                           status nvarchar(30), open_tran int, blocked_sessions int, max_blocked_s bigint, own_wait nvarchar(60),
                           last_request_end datetime, statement_source nvarchar(40), statement nvarchar(400));
    CREATE TABLE #s_grant (n int, seen_at datetime, session_id int, login nvarchar(256), program nvarchar(256), db nvarchar(128), grant_state nvarchar(10),
                           requested_mb bigint, granted_mb bigint, used_mb bigint, wait_ms bigint, dop int, statement nvarchar(400));
    CREATE TABLE #s_tdbs  (n int, seen_at datetime, session_id int, login nvarchar(256), host nvarchar(256), program nvarchar(256),
                           user_objects_mb decimal(18, 1), internal_objects_mb decimal(18, 1), status nvarchar(30), statement nvarchar(400));
    CREATE TABLE #s_tdb   (n int, user_mb decimal(18, 1), internal_mb decimal(18, 1), version_mb decimal(18, 1), free_mb decimal(18, 1), alloc_waiters int);
    CREATE TABLE #s_ag    (n int, ag_name nvarchar(128), db nvarchar(128), replica nvarchar(256), sync_state nvarchar(60), send_kb bigint, redo_kb bigint);
    CREATE TABLE #s_lsn   (n int, listener nvarchar(63), ip nvarchar(48), connections int);

    SET @pf_n = CASE WHEN @DurationMin * 60 / @SampleSec < 1 THEN 1 ELSE @DurationMin * 60 / @SampleSec END;
    SET @pf_delay = CONVERT(char(8), DATEADD(SECOND, @SampleSec, 0), 108);

    IF OBJECT_ID('tempdb..#xe') IS NOT NULL DROP TABLE #xe;
    CREATE TABLE #xe (ev xml);

    BEGIN TRY
        -- 4. sampling loop
        WHILE @pf_i <= @pf_n
        BEGIN
            INSERT #s_time (n, t) VALUES (@pf_i, SYSDATETIME());

            INSERT #s_pc (n, obj, ctr, inst, val)
            SELECT @pf_i, SUBSTRING(RTRIM(object_name), CHARINDEX(N':', object_name) + 1, 128), RTRIM(counter_name), RTRIM(instance_name), cntr_value
            FROM sys.dm_os_performance_counters
            WHERE (RTRIM(object_name) LIKE N'%:SQL Statistics'     AND counter_name IN (N'Batch Requests/sec', N'SQL Compilations/sec', N'SQL Re-Compilations/sec'))
               OR (RTRIM(object_name) LIKE N'%:General Statistics' AND counter_name IN (N'User Connections', N'Processes blocked'))
               OR (RTRIM(object_name) LIKE N'%:Locks'              AND instance_name = N'_Total'
                                                                   AND counter_name IN (N'Lock Waits/sec', N'Lock Wait Time (ms)', N'Lock Timeouts/sec', N'Number of Deadlocks/sec'))
               OR (RTRIM(object_name) LIKE N'%:Buffer Manager'     AND counter_name IN (N'Page life expectancy', N'Buffer cache hit ratio', N'Buffer cache hit ratio base'))
               OR (RTRIM(object_name) LIKE N'%:Memory Manager'     AND counter_name IN (N'Memory Grants Pending', N'Target Server Memory (KB)', N'Total Server Memory (KB)'))
               OR (RTRIM(object_name) LIKE N'%:Databases'          AND counter_name IN (N'Transactions/sec', N'Log Flush Wait Time', N'Log Bytes Flushed/sec'))
               OR (RTRIM(object_name) LIKE N'%:Transactions'       AND counter_name = N'Version Store Size (KB)')
               OR (RTRIM(object_name) LIKE N'%:Database Replica'   AND counter_name IN (N'Transaction Delay', N'Mirrored Write Transactions/sec'));

            INSERT #s_waits (n, grp, wait_ms)
            SELECT @pf_i, grp, SUM(wait_time_ms)
            FROM (SELECT CASE WHEN wait_type LIKE N'LCK[_]M[_]%'     THEN N'LCK_M_*'
                              WHEN wait_type LIKE N'PAGEIOLATCH[_]%' THEN N'PAGEIOLATCH_*'
                              WHEN wait_type LIKE N'PAGELATCH[_]%'   THEN N'PAGELATCH_*'
                              WHEN wait_type IN (N'WRITELOG', N'CXPACKET', N'CXCONSUMER', N'SOS_SCHEDULER_YIELD', N'HADR_SYNC_COMMIT', N'RESOURCE_SEMAPHORE') THEN wait_type
                         END AS grp, wait_time_ms
                  FROM sys.dm_os_wait_stats) AS w
            WHERE grp IS NOT NULL GROUP BY grp;

            INSERT #s_io (n, db, ftype, reads, rstall, writes, wstall)
            SELECT @pf_i, DB_NAME(vfs.database_id), CASE WHEN mf.type = 1 THEN 'LOG' ELSE 'DATA' END,
                   SUM(vfs.num_of_reads), SUM(vfs.io_stall_read_ms), SUM(vfs.num_of_writes), SUM(vfs.io_stall_write_ms)
            FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
            JOIN sys.master_files AS mf ON mf.database_id = vfs.database_id AND mf.file_id = vfs.file_id
            GROUP BY vfs.database_id, CASE WHEN mf.type = 1 THEN 'LOG' ELSE 'DATA' END;

            INSERT #s_sess (n, program, host, login, sessions, active)
            SELECT @pf_i, ISNULL(s.program_name, N''), ISNULL(s.host_name, N''), s.login_name, COUNT(*), SUM(CASE WHEN r.session_id IS NULL THEN 0 ELSE 1 END)
            FROM sys.dm_exec_sessions AS s LEFT JOIN sys.dm_exec_requests AS r ON r.session_id = s.session_id
            WHERE s.is_user_process = 1 AND s.session_id <> @@SPID
            GROUP BY s.program_name, s.host_name, s.login_name;

            INSERT #s_blk (n, blocked, max_wait_ms)
            SELECT @pf_i, COUNT(*), ISNULL(MAX(wait_time), 0)
            FROM sys.dm_exec_requests WHERE blocking_session_id > 0 AND wait_time >= @BlockedThresholdSec * 1000;

            -- problem sessions: blocked, I/O / log / memory / tempdb waits, long running
            INSERT #s_prob
            SELECT TOP (25) @pf_i, GETDATE(),
                   CASE WHEN r.blocking_session_id > 0 AND r.wait_time >= @BlockedThresholdSec * 1000 THEN N'Blocked'
                        WHEN r.wait_type LIKE N'PAGEIOLATCH[_]%' OR r.wait_type IN (N'IO_COMPLETION', N'ASYNC_IO_COMPLETION') THEN N'I/O wait'
                        WHEN r.wait_type = N'WRITELOG' THEN N'Log write wait'
                        WHEN r.wait_type = N'RESOURCE_SEMAPHORE' THEN N'Memory grant wait'
                        WHEN r.wait_type LIKE N'PAGELATCH[_]%' AND r.wait_resource LIKE N'2:%' THEN N'TempDB contention'
                        ELSE N'Long running' END,
                   r.session_id, s.login_name, ISNULL(s.host_name, N''), ISNULL(s.program_name, N''), ISNULL(DB_NAME(r.database_id), N''),
                   r.status, r.command, ISNULL(r.wait_type, N''), r.wait_time, ISNULL(r.wait_resource, N''), r.blocking_session_id,
                   r.total_elapsed_time / 1000, r.cpu_time, r.logical_reads, r.writes, r.granted_query_memory * 8 / 1024, ISNULL(tu.tempdb_mb, 0),
                   r.open_transaction_count,
                   ISNULL(LEFT(LTRIM(SUBSTRING(t.text, r.statement_start_offset / 2 + 1,
                          (CASE WHEN r.statement_end_offset = -1 THEN DATALENGTH(t.text) ELSE r.statement_end_offset END - r.statement_start_offset) / 2 + 1)), 400), N''),
                   ISNULL(OBJECT_NAME(t.objectid, t.dbid), N'')
            FROM sys.dm_exec_requests AS r
            JOIN sys.dm_exec_sessions AS s ON s.session_id = r.session_id
            OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
            OUTER APPLY (SELECT SUM(tsu.user_objects_alloc_page_count - tsu.user_objects_dealloc_page_count
                                    + tsu.internal_objects_alloc_page_count - tsu.internal_objects_dealloc_page_count) * 8 / 1024.0 AS tempdb_mb
                         FROM sys.dm_db_task_space_usage AS tsu WHERE tsu.session_id = r.session_id AND tsu.request_id = r.request_id) AS tu
            WHERE s.is_user_process = 1 AND r.session_id <> @@SPID
              AND (   (r.blocking_session_id > 0 AND r.wait_time >= @BlockedThresholdSec * 1000)
                   OR r.wait_type LIKE N'PAGEIOLATCH[_]%' OR r.wait_type IN (N'IO_COMPLETION', N'ASYNC_IO_COMPLETION', N'WRITELOG', N'RESOURCE_SEMAPHORE')
                   OR (r.wait_type LIKE N'PAGELATCH[_]%' AND r.wait_resource LIKE N'2:%')
                   OR r.total_elapsed_time >= @LongQuerySec * 1000)
            ORDER BY CASE WHEN r.blocking_session_id > 0 THEN 0 ELSE 1 END, r.total_elapsed_time DESC;

            -- head blockers (incl. idle sessions holding an open transaction: last statement they ran)
            ;WITH b AS (
                SELECT blocking_session_id AS sid, COUNT(*) AS blocked_sessions, MAX(wait_time) AS max_wait_ms
                FROM sys.dm_exec_requests WHERE blocking_session_id > 0 AND blocking_session_id <> session_id
                GROUP BY blocking_session_id HAVING MAX(wait_time) >= @BlockedThresholdSec * 1000)
            INSERT #s_head
            SELECT TOP (10) @pf_i, GETDATE(), b.sid, s.login_name, ISNULL(s.host_name, N''), ISNULL(s.program_name, N''),
                   ISNULL(DB_NAME(COALESCE(r.database_id, s.database_id)), N''), s.status, s.open_transaction_count, b.blocked_sessions, b.max_wait_ms / 1000,
                   ISNULL(r.wait_type, N''), s.last_request_end_time,
                   CASE WHEN r.session_id IS NULL THEN N'last statement (session idle)' ELSE N'running now' END,
                   ISNULL(LEFT(LTRIM(CASE WHEN r.session_id IS NOT NULL
                               THEN SUBSTRING(t.text, r.statement_start_offset / 2 + 1,
                                    (CASE WHEN r.statement_end_offset = -1 THEN DATALENGTH(t.text) ELSE r.statement_end_offset END - r.statement_start_offset) / 2 + 1)
                               ELSE t.text END), 400), N'')
            FROM b
            JOIN sys.dm_exec_sessions AS s ON s.session_id = b.sid
            LEFT JOIN sys.dm_exec_requests AS r ON r.session_id = b.sid
            OUTER APPLY (SELECT TOP (1) c.most_recent_sql_handle FROM sys.dm_exec_connections AS c WHERE c.session_id = b.sid) AS c
            OUTER APPLY sys.dm_exec_sql_text(COALESCE(r.sql_handle, c.most_recent_sql_handle)) AS t
            WHERE NOT EXISTS (SELECT 1 FROM sys.dm_exec_requests AS r2 WHERE r2.session_id = b.sid AND r2.blocking_session_id > 0 AND r2.blocking_session_id <> r2.session_id)
            ORDER BY b.blocked_sessions DESC;

            -- memory grants: waiting, or big
            INSERT #s_grant
            SELECT TOP (10) @pf_i, GETDATE(), mg.session_id, s.login_name, ISNULL(s.program_name, N''), ISNULL(DB_NAME(r.database_id), N''),
                   CASE WHEN mg.grant_time IS NULL THEN N'WAITING' ELSE N'granted' END,
                   mg.requested_memory_kb / 1024, ISNULL(mg.granted_memory_kb, 0) / 1024, ISNULL(mg.used_memory_kb, 0) / 1024, ISNULL(mg.wait_time_ms, 0), mg.dop,
                   ISNULL(LEFT(LTRIM(SUBSTRING(t.text, ISNULL(r.statement_start_offset, 0) / 2 + 1,
                          (CASE WHEN ISNULL(r.statement_end_offset, -1) = -1 THEN DATALENGTH(t.text) ELSE r.statement_end_offset END - ISNULL(r.statement_start_offset, 0)) / 2 + 1)), 400), N'')
            FROM sys.dm_exec_query_memory_grants AS mg
            JOIN sys.dm_exec_sessions AS s ON s.session_id = mg.session_id
            LEFT JOIN sys.dm_exec_requests AS r ON r.session_id = mg.session_id AND r.request_id = mg.request_id
            OUTER APPLY sys.dm_exec_sql_text(mg.sql_handle) AS t
            WHERE mg.session_id <> @@SPID AND (mg.grant_time IS NULL OR mg.granted_memory_kb >= @BigGrantMB * 1024)
            ORDER BY CASE WHEN mg.grant_time IS NULL THEN 0 ELSE 1 END, mg.requested_memory_kb DESC;

            -- tempdb users
            INSERT #s_tdbs
            SELECT TOP (10) @pf_i, GETDATE(), u.session_id, s.login_name, ISNULL(s.host_name, N''), ISNULL(s.program_name, N''),
                   u.user_mb, u.internal_mb, s.status, ISNULL(LEFT(LTRIM(t.text), 400), N'')
            FROM (SELECT session_id, SUM(user_pages) * 8 / 1024.0 AS user_mb, SUM(internal_pages) * 8 / 1024.0 AS internal_mb
                  FROM (SELECT session_id, user_objects_alloc_page_count - user_objects_dealloc_page_count AS user_pages,
                               internal_objects_alloc_page_count - internal_objects_dealloc_page_count AS internal_pages
                        FROM sys.dm_db_session_space_usage
                        UNION ALL
                        SELECT session_id, user_objects_alloc_page_count - user_objects_dealloc_page_count,
                               internal_objects_alloc_page_count - internal_objects_dealloc_page_count
                        FROM sys.dm_db_task_space_usage) AS x
                  GROUP BY session_id) AS u
            JOIN sys.dm_exec_sessions AS s ON s.session_id = u.session_id AND s.is_user_process = 1
            LEFT JOIN sys.dm_exec_requests AS r ON r.session_id = u.session_id
            OUTER APPLY (SELECT TOP (1) c.most_recent_sql_handle FROM sys.dm_exec_connections AS c WHERE c.session_id = u.session_id) AS c
            OUTER APPLY sys.dm_exec_sql_text(COALESCE(r.sql_handle, c.most_recent_sql_handle)) AS t
            WHERE u.user_mb + u.internal_mb >= @TempdbSessionMB
            ORDER BY u.user_mb + u.internal_mb DESC;

            INSERT #s_tdb (n, user_mb, internal_mb, version_mb, free_mb, alloc_waiters)
            SELECT @pf_i, SUM(user_object_reserved_page_count) * 8 / 1024.0, SUM(internal_object_reserved_page_count) * 8 / 1024.0,
                   SUM(version_store_reserved_page_count) * 8 / 1024.0, SUM(unallocated_extent_page_count) * 8 / 1024.0,
                   (SELECT COUNT(*) FROM sys.dm_os_waiting_tasks WHERE wait_type LIKE N'PAGELATCH[_]%' AND resource_description LIKE N'2:%')
            FROM tempdb.sys.dm_db_file_space_usage;

            IF CAST(SERVERPROPERTY('IsHadrEnabled') AS int) = 1
            BEGIN
                INSERT #s_ag (n, ag_name, db, replica, sync_state, send_kb, redo_kb)
                SELECT @pf_i, ag.name, adc.database_name, ar.replica_server_name, ISNULL(drs.synchronization_state_desc, N''),
                       ISNULL(drs.log_send_queue_size, 0), ISNULL(drs.redo_queue_size, 0)
                FROM sys.dm_hadr_database_replica_states AS drs
                JOIN sys.availability_replicas AS ar ON ar.replica_id = drs.replica_id
                JOIN sys.availability_groups AS ag ON ag.group_id = drs.group_id
                JOIN sys.availability_databases_cluster AS adc ON adc.group_database_id = drs.group_database_id;

                INSERT #s_lsn (n, listener, ip, connections)
                SELECT @pf_i, l.dns_name, ip.ip_address, COUNT(c.session_id)
                FROM sys.availability_group_listeners AS l
                JOIN sys.availability_group_listener_ip_addresses AS ip ON ip.listener_id = l.listener_id
                LEFT JOIN sys.dm_exec_connections AS c ON c.local_net_address = ip.ip_address AND c.local_tcp_port = l.port
                GROUP BY l.dns_name, ip.ip_address;
            END;

            IF @pf_i < @pf_n WAITFOR DELAY @pf_delay;
            SET @pf_i += 1;
        END;   -- sampling loop

        -- 5. Extended Events: blocked process reports, deadlocks, long queries
        IF @pf_xe = 1 AND EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'DBA_PerfCheckJob')
        BEGIN
            WAITFOR DELAY '00:00:06';   -- MAX_DISPATCH_LATENCY: let the last events reach the target
            SELECT @pf_x = CAST(t.target_data AS xml)
            FROM sys.dm_xe_session_targets AS t
            JOIN sys.dm_xe_sessions AS se ON se.address = t.event_session_address
            WHERE se.name = N'DBA_PerfCheckJob' AND t.target_name = N'ring_buffer';
            INSERT #xe (ev) SELECT n.query('.') FROM @pf_x.nodes('/RingBufferTarget/event') AS q(n);
        END;
    END TRY
    BEGIN CATCH
        SET @p_notes += N'Performance window stopped early: ' + ERROR_MESSAGE() + N' ';
    END CATCH;

    -- 6. put the server back: drop the XE session, restore the threshold
    BEGIN TRY
        IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'DBA_PerfCheckJob') DROP EVENT SESSION DBA_PerfCheckJob ON SERVER;
    END TRY
    BEGIN CATCH SET @p_notes += N'XE session DBA_PerfCheckJob not dropped: ' + ERROR_MESSAGE() + N' '; END CATCH;
    IF @pf_thrSet = 1
    BEGIN
        BEGIN TRY
            SELECT @pf_adv = CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'show advanced options';
            IF @pf_adv = 0 BEGIN EXEC sys.sp_configure N'show advanced options', 1; RECONFIGURE; END;
            EXEC sys.sp_configure N'blocked process threshold (s)', @pf_orig; RECONFIGURE;
            IF @pf_adv = 0 BEGIN EXEC sys.sp_configure N'show advanced options', 0; RECONFIGURE; END;
            DELETE dbo.DBA_PerfCheck_State WHERE id = 1;
        END TRY
        BEGIN CATCH
            SET @p_notes += N'Threshold NOT restored (' + ERROR_MESSAGE() + N') - run: EXEC sp_configure ''blocked process threshold (s)'', '
                          + CAST(@pf_orig AS nvarchar(10)) + N'; RECONFIGURE; ';
        END CATCH;
    END;

    -- 7. XE results
    IF OBJECT_ID('tempdb..#x_blocked') IS NOT NULL DROP TABLE #x_blocked;
    IF OBJECT_ID('tempdb..#x_dl')      IS NOT NULL DROP TABLE #x_dl;
    IF OBJECT_ID('tempdb..#x_dlproc')  IS NOT NULL DROP TABLE #x_dlproc;
    IF OBJECT_ID('tempdb..#x_long')    IS NOT NULL DROP TABLE #x_long;
    SELECT DATEADD(MINUTE, DATEDIFF(MINUTE, GETUTCDATE(), GETDATE()), ev.value('(event/@timestamp)[1]', 'datetime2')) AS event_time,
           ev.value('(event/data[@name="duration"]/value)[1]', 'bigint') / 1000000 AS blocked_s,
           ISNULL(ev.value('(event/data[@name="database_name"]/value)[1]', 'nvarchar(128)'), N'') AS db,
           ISNULL(ev.value('(event/data[@name="blocked_process"]/value/blocked-process-report/blocked-process/process/@spid)[1]', 'nvarchar(10)'), N'') AS blocked_spid,
           ISNULL(ev.value('(event/data[@name="blocked_process"]/value/blocked-process-report/blocking-process/process/@spid)[1]', 'nvarchar(10)'), N'') AS blocking_spid,
           ISNULL(LEFT(LTRIM(ev.value('(event/data[@name="blocked_process"]/value/blocked-process-report/blocked-process/process/inputbuf)[1]', 'nvarchar(max)')), 300), N'') AS blocked_sql,
           ISNULL(LEFT(LTRIM(ev.value('(event/data[@name="blocked_process"]/value/blocked-process-report/blocking-process/process/inputbuf)[1]', 'nvarchar(max)')), 300), N'') AS blocking_sql
    INTO #x_blocked
    FROM #xe WHERE ev.value('(event/@name)[1]', 'nvarchar(60)') = N'blocked_process_report';

    SELECT ROW_NUMBER() OVER (ORDER BY ev.value('(event/@timestamp)[1]', 'datetime2')) AS deadlock_no,
           DATEADD(MINUTE, DATEDIFF(MINUTE, GETUTCDATE(), GETDATE()), ev.value('(event/@timestamp)[1]', 'datetime2')) AS event_time,
           ev.value('count(event/data[@name="xml_report"]/value/deadlock/process-list/process)', 'int') AS processes,
           ev.query('event/data[@name="xml_report"]/value/deadlock') AS deadlock_graph
    INTO #x_dl
    FROM #xe WHERE ev.value('(event/@name)[1]', 'nvarchar(60)') = N'xml_deadlock_report';

    SELECT d.deadlock_no, d.event_time,
           CASE WHEN p.n.value('@id', 'nvarchar(50)') = d.deadlock_graph.value('(deadlock/victim-list/victimProcess/@id)[1]', 'nvarchar(50)') THEN N'VICTIM' ELSE N'' END AS victim,
           ISNULL(p.n.value('@spid', 'nvarchar(10)'), N'') AS session_id, ISNULL(p.n.value('@loginname', 'nvarchar(128)'), N'') AS login,
           ISNULL(p.n.value('@hostname', 'nvarchar(128)'), N'') AS host, ISNULL(p.n.value('@clientapp', 'nvarchar(128)'), N'') AS app,
           ISNULL(DB_NAME(p.n.value('@currentdb', 'int')), N'') AS db, ISNULL(p.n.value('@isolationlevel', 'nvarchar(60)'), N'') AS isolation,
           ISNULL(p.n.value('@lockMode', 'nvarchar(20)'), N'') AS lock_mode, ISNULL(p.n.value('@waitresource', 'nvarchar(200)'), N'') AS wait_resource,
           ISNULL(LEFT(LTRIM(p.n.value('(inputbuf)[1]', 'nvarchar(max)')), 400), N'') AS statement
    INTO #x_dlproc
    FROM #x_dl AS d CROSS APPLY d.deadlock_graph.nodes('deadlock/process-list/process') AS p(n);

    SELECT DATEADD(MINUTE, DATEDIFF(MINUTE, GETUTCDATE(), GETDATE()), ev.value('(event/@timestamp)[1]', 'datetime2')) AS end_time,
           CAST(ev.value('(event/data[@name="duration"]/value)[1]', 'bigint') / 1000000.0 AS decimal(18, 1)) AS duration_s,
           ev.value('(event/data[@name="cpu_time"]/value)[1]', 'bigint') / 1000 AS cpu_ms,
           ev.value('(event/data[@name="logical_reads"]/value)[1]', 'bigint') AS logical_reads,
           ISNULL(ev.value('(event/action[@name="session_id"]/value)[1]', 'nvarchar(10)'), N'') AS session_id,
           ISNULL(ev.value('(event/action[@name="database_name"]/value)[1]', 'nvarchar(128)'), N'') AS db,
           ISNULL(ev.value('(event/action[@name="client_app_name"]/value)[1]', 'nvarchar(128)'), N'') AS app,
           ISNULL(ev.value('(event/action[@name="client_hostname"]/value)[1]', 'nvarchar(128)'), N'') AS host,
           ISNULL(ev.value('(event/action[@name="username"]/value)[1]', 'nvarchar(128)'), N'') AS login,
           ISNULL(LEFT(LTRIM(COALESCE(ev.value('(event/data[@name="statement"]/value)[1]', 'nvarchar(max)'),
                                      ev.value('(event/data[@name="batch_text"]/value)[1]', 'nvarchar(max)'))), 400), N'') AS statement
    INTO #x_long
    FROM #xe WHERE ev.value('(event/@name)[1]', 'nvarchar(60)') IN (N'rpc_completed', N'sql_batch_completed');

    -- 8. top queries of the window: plan cache now minus the baseline, per query_hash
    IF OBJECT_ID('tempdb..#qtop') IS NOT NULL DROP TABLE #qtop;
    CREATE TABLE #qtop (query_hash binary(8), executions bigint, total_duration_ms decimal(19, 1), avg_duration_ms decimal(19, 1),
                        total_cpu_ms decimal(19, 1), total_logical_reads bigint, sql_handle varbinary(64), plan_handle varbinary(64),
                        stmt_start int, stmt_end int, rn_d int, rn_c int, rn_r int);
    IF @TopQueries = 1
    BEGIN
        IF OBJECT_ID('tempdb..#qraw') IS NOT NULL DROP TABLE #qraw;
        SELECT query_hash, sql_handle, plan_handle, statement_start_offset, statement_end_offset,
               execution_count, total_elapsed_time, total_worker_time, total_logical_reads,
               ROW_NUMBER() OVER (PARTITION BY query_hash ORDER BY total_elapsed_time DESC) AS rn
        INTO #qraw FROM sys.dm_exec_query_stats WHERE query_hash IS NOT NULL;
        SET @pf_cached = @@ROWCOUNT;

        WITH e AS (
            SELECT query_hash, SUM(execution_count) AS ec, SUM(total_elapsed_time) AS el, SUM(total_worker_time) AS cpu, SUM(total_logical_reads) AS rd,
                   MAX(CASE WHEN rn = 1 THEN sql_handle END) AS sh, MAX(CASE WHEN rn = 1 THEN plan_handle END) AS ph,
                   MAX(CASE WHEN rn = 1 THEN statement_start_offset END) AS so, MAX(CASE WHEN rn = 1 THEN statement_end_offset END) AS eo
            FROM #qraw GROUP BY query_hash),
        d AS (
            SELECT e.query_hash, e.sh, e.ph, e.so, e.eo,
                   CASE WHEN s.query_hash IS NULL OR e.ec < s.ec THEN e.ec  ELSE e.ec  - s.ec  END AS ec,
                   CASE WHEN s.query_hash IS NULL OR e.ec < s.ec THEN e.el  ELSE e.el  - s.el  END AS el,
                   CASE WHEN s.query_hash IS NULL OR e.ec < s.ec THEN e.cpu ELSE e.cpu - s.cpu END AS cpu,
                   CASE WHEN s.query_hash IS NULL OR e.ec < s.ec THEN e.rd  ELSE e.rd  - s.rd  END AS rd
            FROM e LEFT JOIN #qstart AS s ON s.query_hash = e.query_hash),
        r AS (
            SELECT *, ROW_NUMBER() OVER (ORDER BY el DESC) AS rn_d, ROW_NUMBER() OVER (ORDER BY cpu DESC) AS rn_c, ROW_NUMBER() OVER (ORDER BY rd DESC) AS rn_r
            FROM d WHERE ec > 0)
        INSERT #qtop
        SELECT query_hash, ec, CAST(el / 1000.0 AS decimal(19, 1)), CAST(el / 1000.0 / ec AS decimal(19, 1)), CAST(cpu / 1000.0 AS decimal(19, 1)), rd,
               sh, ph, so, eo, rn_d, rn_c, rn_r
        FROM r WHERE rn_d <= 20 OR rn_c <= 20 OR rn_r <= 20;
    END;
    IF OBJECT_ID('tempdb..#qtx') IS NOT NULL DROP TABLE #qtx;
    SELECT q.*, ISNULL(DB_NAME(COALESCE(t.dbid, CONVERT(int, pa.value))), N'') AS db,
           ISNULL(LEFT(LTRIM(SUBSTRING(t.text, q.stmt_start / 2 + 1,
                  (CASE WHEN q.stmt_end = -1 THEN DATALENGTH(t.text) ELSE q.stmt_end END - q.stmt_start) / 2 + 1)), 400), N'') AS query_text,
           ISNULL(OBJECT_NAME(t.objectid, t.dbid), N'') AS object_name
    INTO #qtx
    FROM #qtop AS q
    OUTER APPLY sys.dm_exec_sql_text(q.sql_handle) AS t
    OUTER APPLY (SELECT value FROM sys.dm_exec_plan_attributes(q.plan_handle) WHERE attribute = N'dbid') AS pa;

    -- 9. per-interval metrics
    IF OBJECT_ID('tempdb..#iv0') IS NOT NULL DROP TABLE #iv0;
    IF OBJECT_ID('tempdb..#pcd') IS NOT NULL DROP TABLE #pcd;
    IF OBJECT_ID('tempdb..#iv')  IS NOT NULL DROP TABLE #iv;
    SELECT b.n, b.t, CAST(DATEDIFF(MILLISECOND, a.t, b.t) / 1000.0 AS float) AS dt
    INTO #iv0 FROM #s_time AS b JOIN #s_time AS a ON a.n = b.n - 1 WHERE b.t > a.t;
    SET @p_intervals = (SELECT COUNT(*) FROM #iv0);

    SELECT b.n, b.obj, b.ctr, b.inst, b.val AS v, CASE WHEN b.val >= a.val THEN b.val - a.val ELSE 0 END AS d
    INTO #pcd FROM #s_pc AS b JOIN #s_pc AS a ON a.n = b.n - 1 AND a.obj = b.obj AND a.ctr = b.ctr AND a.inst = b.inst;

    WITH pc AS (
        SELECT p.n,
               SUM(CASE WHEN p.ctr = N'Batch Requests/sec' THEN p.d END) AS batch_d,
               SUM(CASE WHEN p.obj = N'Databases' AND p.ctr = N'Transactions/sec'
                         AND ((@pf_hasPdb = 1 AND pd.name IS NOT NULL) OR (@pf_hasPdb = 0 AND p.inst = N'_Total')) THEN p.d END) AS tx_d,
               SUM(CASE WHEN p.ctr = N'SQL Compilations/sec' THEN p.d END) AS comp_d,
               SUM(CASE WHEN p.ctr = N'SQL Re-Compilations/sec' THEN p.d END) AS recomp_d,
               MAX(CASE WHEN p.ctr = N'User Connections' THEN p.v END) AS user_conn,
               SUM(CASE WHEN p.obj = N'Locks' AND p.ctr = N'Lock Waits/sec' THEN p.d END) AS lw_d,
               SUM(CASE WHEN p.obj = N'Locks' AND p.ctr = N'Lock Wait Time (ms)' THEN p.d END) AS lwt_d,
               SUM(CASE WHEN p.obj = N'Locks' AND p.ctr = N'Lock Timeouts/sec' THEN p.d END) AS lto_d,
               SUM(CASE WHEN p.obj = N'Locks' AND p.ctr = N'Number of Deadlocks/sec' THEN p.d END) AS dl_d,
               MAX(CASE WHEN p.ctr = N'Page life expectancy' THEN p.v END) AS ple,
               MAX(CASE WHEN p.ctr = N'Buffer cache hit ratio' THEN p.v END) AS bchr,
               MAX(CASE WHEN p.ctr = N'Buffer cache hit ratio base' THEN p.v END) AS bchr_base,
               MAX(CASE WHEN p.ctr = N'Memory Grants Pending' THEN p.v END) AS grants_pending,
               MAX(CASE WHEN p.ctr = N'Target Server Memory (KB)' THEN p.v END) AS target_kb,
               MAX(CASE WHEN p.ctr = N'Total Server Memory (KB)' THEN p.v END) AS total_kb,
               SUM(CASE WHEN p.obj = N'Databases' AND p.ctr = N'Log Flush Wait Time' AND p.inst = N'_Total' THEN p.d END) AS lfw_d,
               SUM(CASE WHEN p.obj = N'Databases' AND p.ctr = N'Log Bytes Flushed/sec' AND p.inst = N'_Total' THEN p.d END) AS lbf_d,
               MAX(CASE WHEN p.ctr = N'Version Store Size (KB)' THEN p.v END) AS vs_kb,
               SUM(CASE WHEN p.obj = N'Database Replica' AND p.ctr = N'Transaction Delay' AND p.inst = N'_Total' THEN p.d END) AS td_d,
               SUM(CASE WHEN p.obj = N'Database Replica' AND p.ctr = N'Mirrored Write Transactions/sec' AND p.inst = N'_Total' THEN p.d END) AS mw_d
        FROM #pcd AS p LEFT JOIN #pdb AS pd ON pd.name = p.inst
        GROUP BY p.n)
    SELECT i.n, i.t,
           CAST(ISNULL(pc.batch_d, 0) / i.dt AS decimal(18, 1))   AS batch_s,
           CAST(ISNULL(pc.tx_d, 0) / i.dt AS decimal(18, 1))      AS tx_s,
           CAST(ISNULL(pc.comp_d, 0) / i.dt AS decimal(18, 1))    AS comp_s,
           CAST(ISNULL(pc.recomp_d, 0) / i.dt AS decimal(18, 1))  AS recomp_s,
           ISNULL(pc.user_conn, 0)                                 AS user_conn,
           CAST(ISNULL(pc.lw_d, 0) / i.dt AS decimal(18, 1))      AS lock_waits_s,
           CAST(ISNULL(pc.lwt_d, 0) / i.dt AS decimal(18, 1))     AS lock_wait_ms_s,
           CAST(ISNULL(pc.lto_d, 0) / i.dt AS decimal(18, 1))     AS lock_timeouts_s,
           CAST(ISNULL(pc.dl_d, 0) / i.dt AS decimal(18, 3))      AS deadlocks_s,
           ISNULL(pc.dl_d, 0)                                      AS deadlocks,
           ISNULL(pc.lto_d, 0)                                     AS lock_timeouts,
           ISNULL(bk.blocked, 0)                                   AS blocked,
           CAST(ISNULL(bk.max_wait_ms, 0) / 1000.0 AS decimal(18, 1)) AS max_block_s,
           ISNULL(pc.ple, 0)                                       AS ple,
           CAST(pc.bchr * 100.0 / NULLIF(pc.bchr_base, 0) AS decimal(5, 1)) AS buffer_hit_pct,
           ISNULL(pc.grants_pending, 0)                            AS grants_pending,
           ISNULL(pc.target_kb, 0) / 1024                          AS target_mb,
           ISNULL(pc.total_kb, 0) / 1024                           AS total_mb,
           CAST(io.rs * 1.0 / NULLIF(io.r, 0) AS decimal(18, 1))   AS data_read_ms,
           CAST(io.ws * 1.0 / NULLIF(io.w, 0) AS decimal(18, 1))   AS log_write_ms,
           CAST(ISNULL(pc.lfw_d, 0) / i.dt AS decimal(18, 1))     AS log_flush_wait_ms_s,
           CAST(ISNULL(pc.lbf_d, 0) / i.dt / 1048576.0 AS decimal(18, 2)) AS log_mb_s,
           CAST(td.user_mb + td.internal_mb + td.version_mb AS decimal(18, 1)) AS tempdb_used_mb,
           CAST(ISNULL(pc.vs_kb, 0) / 1024.0 AS decimal(18, 1))   AS version_store_mb,
           ISNULL(td.alloc_waiters, 0)                             AS tempdb_alloc_waits,
           CAST(ISNULL(ag.send_kb, 0) / 1024.0 AS decimal(18, 1)) AS ag_send_mb,
           CAST(ISNULL(ag.redo_kb, 0) / 1024.0 AS decimal(18, 1)) AS ag_redo_mb,
           CAST(pc.td_d * 1.0 / NULLIF(pc.mw_d, 0) AS decimal(18, 1)) AS ag_trans_delay_ms,
           ISNULL(ls.conns, 0)                                     AS listener_conns
    INTO #iv
    FROM #iv0 AS i
    LEFT JOIN pc ON pc.n = i.n
    LEFT JOIN #s_blk AS bk ON bk.n = i.n
    LEFT JOIN #s_tdb AS td ON td.n = i.n
    OUTER APPLY (SELECT SUM(CASE WHEN b.ftype = 'DATA' THEN b.reads - a.reads END) AS r, SUM(CASE WHEN b.ftype = 'DATA' THEN b.rstall - a.rstall END) AS rs,
                        SUM(CASE WHEN b.ftype = 'LOG' THEN b.writes - a.writes END) AS w, SUM(CASE WHEN b.ftype = 'LOG' THEN b.wstall - a.wstall END) AS ws
                 FROM #s_io AS b JOIN #s_io AS a ON a.n = b.n - 1 AND a.db = b.db AND a.ftype = b.ftype
                 WHERE b.n = i.n AND b.reads >= a.reads AND b.writes >= a.writes) AS io
    OUTER APPLY (SELECT MAX(send_kb) AS send_kb, MAX(redo_kb) AS redo_kb FROM #s_ag WHERE n = i.n) AS ag
    OUTER APPLY (SELECT SUM(connections) AS conns FROM #s_lsn WHERE n = i.n) AS ls;

    -- window summary: avg / min / max of every metric
    IF OBJECT_ID('tempdb..#psum') IS NOT NULL DROP TABLE #psum;
    SELECT u.seq AS _seq, u.area, u.metric, CAST(AVG(u.v) AS decimal(18, 1)) AS [avg], CAST(MIN(u.v) AS decimal(18, 1)) AS [min], CAST(MAX(u.v) AS decimal(18, 1)) AS [max]
    INTO #psum
    FROM #iv AS i
    CROSS APPLY (VALUES
        (1, N'Throughput', N'Batch requests/s', CAST(i.batch_s AS float)), (2, N'Throughput', N'Transactions/s' + CASE WHEN @pf_hasPdb = 1 THEN N' (' + @PerfDatabases + N')' ELSE N'' END, i.tx_s),
        (3, N'Compilation', N'Compilations/s', i.comp_s), (4, N'Compilation', N'Re-compilations/s', i.recomp_s),
        (5, N'Connections', N'User connections', i.user_conn),
        (6, N'Locking', N'Lock waits/s', i.lock_waits_s), (7, N'Locking', N'Lock wait time ms/s', i.lock_wait_ms_s),
        (8, N'Locking', N'Lock timeouts/s', i.lock_timeouts_s), (9, N'Locking', N'Deadlocks/s', i.deadlocks_s),
        (10, N'Locking', N'Sessions blocked > threshold', i.blocked), (11, N'Locking', N'Longest block (s)', i.max_block_s),
        (12, N'Memory', N'Page life expectancy (s)', i.ple), (13, N'Memory', N'Buffer cache hit ratio %', i.buffer_hit_pct),
        (14, N'Memory', N'Memory grants pending', i.grants_pending), (15, N'Memory', N'Target server memory MB', i.target_mb),
        (16, N'Memory', N'Total server memory MB', i.total_mb),
        (17, N'I/O', N'Data file read latency ms', i.data_read_ms), (18, N'I/O', N'Log file write latency ms', i.log_write_ms),
        (19, N'I/O', N'Log flush wait ms/s', i.log_flush_wait_ms_s), (20, N'I/O', N'Log MB flushed/s', i.log_mb_s),
        (21, N'TempDB', N'TempDB used MB', i.tempdb_used_mb), (22, N'TempDB', N'Version store MB', i.version_store_mb),
        (23, N'TempDB', N'Allocation waits (tasks)', i.tempdb_alloc_waits),
        (24, N'Always On', N'Log send queue MB (max replica)', i.ag_send_mb), (25, N'Always On', N'Redo queue MB (max replica)', i.ag_redo_mb),
        (26, N'Always On', N'Transaction delay ms', i.ag_trans_delay_ms), (27, N'Always On', N'Listener connections', i.listener_conns)
    ) AS u(seq, area, metric, v)
    GROUP BY u.seq, u.area, u.metric;

    -- waits per interval (ms waited in the interval)
    IF OBJECT_ID('tempdb..#pwaits') IS NOT NULL DROP TABLE #pwaits;
    SELECT i.n AS _n, CONVERT(char(8), i.t, 108) AS [time],
           SUM(CASE WHEN b.grp = N'LCK_M_*' THEN b.wait_ms - a.wait_ms END) AS [LCK_M_*],
           SUM(CASE WHEN b.grp = N'PAGEIOLATCH_*' THEN b.wait_ms - a.wait_ms END) AS [PAGEIOLATCH_*],
           SUM(CASE WHEN b.grp = N'PAGELATCH_*' THEN b.wait_ms - a.wait_ms END) AS [PAGELATCH_*],
           SUM(CASE WHEN b.grp = N'WRITELOG' THEN b.wait_ms - a.wait_ms END) AS [WRITELOG],
           SUM(CASE WHEN b.grp = N'CXPACKET' THEN b.wait_ms - a.wait_ms END) AS [CXPACKET],
           SUM(CASE WHEN b.grp = N'CXCONSUMER' THEN b.wait_ms - a.wait_ms END) AS [CXCONSUMER],
           SUM(CASE WHEN b.grp = N'SOS_SCHEDULER_YIELD' THEN b.wait_ms - a.wait_ms END) AS [SOS_SCHEDULER_YIELD],
           SUM(CASE WHEN b.grp = N'HADR_SYNC_COMMIT' THEN b.wait_ms - a.wait_ms END) AS [HADR_SYNC_COMMIT],
           SUM(CASE WHEN b.grp = N'RESOURCE_SEMAPHORE' THEN b.wait_ms - a.wait_ms END) AS [RESOURCE_SEMAPHORE]
    INTO #pwaits
    FROM #iv0 AS i
    JOIN #s_waits AS b ON b.n = i.n
    JOIN #s_waits AS a ON a.n = i.n - 1 AND a.grp = b.grp AND b.wait_ms >= a.wait_ms
    GROUP BY i.n, i.t;

    -- 10. performance issues
    IF OBJECT_ID('tempdb..#pissues') IS NOT NULL DROP TABLE #pissues;
    CREATE TABLE #pissues (severity varchar(10), area varchar(40), item nvarchar(300), detail nvarchar(2000));
    INSERT #pissues SELECT 'WARNING', 'Memory', N'Page Life Expectancy', N'Dropped to ' + CAST(MIN(ple) AS nvarchar(20)) + N' s (threshold ' + CAST(@PleMin AS nvarchar(10)) + N' s)'
        FROM #iv HAVING MIN(ple) < @PleMin;
    INSERT #pissues SELECT 'WARNING', 'Memory', N'Memory Grants Pending', N'Up to ' + CAST(MAX(grants_pending) AS nvarchar(20)) + N' queries waiting for memory'
        FROM #iv HAVING MAX(grants_pending) > 0;
    INSERT #pissues SELECT 'WARNING', 'Memory', N'RESOURCE_SEMAPHORE waits', CAST(SUM([RESOURCE_SEMAPHORE]) AS nvarchar(30)) + N' ms waited for query memory'
        FROM #pwaits HAVING SUM([RESOURCE_SEMAPHORE]) > 0;
    INSERT #pissues SELECT 'WARNING', 'Locking', N'Deadlocks', CAST(CASE WHEN (SELECT COUNT(*) FROM #x_dl) > ISNULL(SUM(deadlocks), 0) THEN (SELECT COUNT(*) FROM #x_dl) ELSE ISNULL(SUM(deadlocks), 0) END AS nvarchar(20)) + N' deadlock(s) in the window'
        FROM #iv HAVING SUM(deadlocks) > 0 OR (SELECT COUNT(*) FROM #x_dl) > 0;
    INSERT #pissues SELECT 'WARNING', 'Locking', N'Blocking', N'Sessions blocked over ' + CAST(@BlockedThresholdSec AS nvarchar(10)) + N' s: up to ' + CAST(ISNULL(MAX(blocked), 0) AS nvarchar(10))
                         + N' at a time, ' + CAST((SELECT COUNT(*) FROM #x_blocked) AS nvarchar(10)) + N' blocked process report(s), longest ' + CAST(ISNULL(MAX(max_block_s), 0) AS nvarchar(20)) + N' s'
        FROM #iv HAVING MAX(blocked) > 0 OR (SELECT COUNT(*) FROM #x_blocked) > 0;
    INSERT #pissues SELECT 'WARNING', 'Locking', N'Lock timeouts', CAST(SUM(lock_timeouts) AS nvarchar(20)) + N' lock timeout(s)' FROM #iv HAVING SUM(lock_timeouts) > 0;
    INSERT #pissues SELECT 'WARNING', 'I/O', N'Data file read latency', N'Average ' + CAST(CAST(AVG(data_read_ms) AS decimal(18, 1)) AS nvarchar(20)) + N' ms (threshold ' + CAST(@DataReadMs AS nvarchar(10)) + N' ms)'
        FROM #iv HAVING AVG(data_read_ms) > @DataReadMs;
    INSERT #pissues SELECT 'WARNING', 'I/O', N'Log file write latency', N'Average ' + CAST(CAST(AVG(log_write_ms) AS decimal(18, 1)) AS nvarchar(20)) + N' ms (threshold ' + CAST(@LogWriteMs AS nvarchar(10)) + N' ms)'
        FROM #iv HAVING AVG(log_write_ms) > @LogWriteMs;
    INSERT #pissues SELECT 'WARNING', 'TempDB', N'Allocation contention', N'Up to ' + CAST(MAX(tempdb_alloc_waits) AS nvarchar(10)) + N' tasks waiting on tempdb allocation pages'
        FROM #iv HAVING MAX(tempdb_alloc_waits) > 0;
    INSERT #pissues SELECT DISTINCT 'CRITICAL', 'Always On', db + N' on ' + replica, N'Not synchronizing during the window (' + sync_state + N')'
        FROM #s_ag WHERE sync_state NOT IN (N'SYNCHRONIZED', N'SYNCHRONIZING', N'');
    INSERT #pissues SELECT 'WARNING', 'Always On', N'Log send queue', N'Peaked at ' + CAST(MAX(ag_send_mb) AS nvarchar(20)) + N' MB (threshold ' + CAST(@AgSendQueueMB AS nvarchar(10)) + N' MB)'
        FROM #iv HAVING MAX(ag_send_mb) > @AgSendQueueMB;
    INSERT #pissues SELECT 'WARNING', 'Queries', N'Queries over ' + CAST(@LongQuerySec AS nvarchar(10)) + N' s', CAST(COUNT(*) AS nvarchar(10)) + N' query(ies), longest ' + CAST(MAX(duration_s) AS nvarchar(20)) + N' s'
        FROM #x_long HAVING COUNT(*) > 0;
    INSERT #pissues SELECT 'WARNING', 'Locking', N'Idle session ' + CAST(session_id AS nvarchar(10)) + N' holding locks',
                           login + N' on ' + host + N' (' + program + N') left a transaction open and blocked ' + CAST(MAX(blocked_sessions) AS nvarchar(10))
                           + N' session(s) for up to ' + CAST(MAX(max_blocked_s) AS nvarchar(20)) + N' s - last statement: ' + statement
        FROM #s_head WHERE statement_source LIKE N'last statement%' AND open_tran > 0
        GROUP BY session_id, login, host, program, statement;
    INSERT #pissues SELECT 'WARNING', 'Memory', N'Queries waiting for memory', CAST(COUNT(DISTINCT session_id) AS nvarchar(10)) + N' session(s) waited for a memory grant - see Memory grants'
        FROM #s_grant WHERE grant_state = N'WAITING' HAVING COUNT(*) > 0;
    IF @p_notes <> N'' INSERT #pissues VALUES ('WARNING', 'Collection', N'Performance window', LEFT(@p_notes, 1990));

    SELECT @p_pCrit = SUM(CASE WHEN severity = 'CRITICAL' THEN 1 ELSE 0 END), @p_pWarn = SUM(CASE WHEN severity = 'WARNING' THEN 1 ELSE 0 END) FROM #pissues;
    SET @p_pCrit = ISNULL(@p_pCrit, 0); SET @p_pWarn = ISNULL(@p_pWarn, 0);
END;   -- performance window

IF @NoPerf = 0
BEGIN
    -- ---- performance report ----
    SET @p_pFull = N'<h2>Performance window: ' + CONVERT(nvarchar(16), (SELECT MIN(t) FROM #s_time), 120) + N' - '
                 + CONVERT(nvarchar(5), (SELECT MAX(t) FROM #s_time), 108) + N' (' + CAST(@p_intervals AS nvarchar(10)) + N' intervals of '
                 + CAST(@SampleSec AS nvarchar(10)) + N' s)</h2>';
    SET @p_pShort = @p_pFull;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT severity, area, item, detail, CASE severity WHEN ''CRITICAL'' THEN 0 ELSE 1 END AS _o FROM #pissues',
         @Title = N'Performance - needs attention', @OrderBy = N'_o, area, item', @StatusColumn = N'severity', @MaxRows = 0, @SkipEmpty = 0, @Html = @p_part OUTPUT;
    SET @p_pFull += @p_part;
    SET @p_pShort += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT _seq, area, metric, [avg], [min], [max] FROM #psum',
         @Title = N'Performance summary for the window', @OrderBy = N'_seq', @MaxRows = 0, @SkipEmpty = 0, @Html = @p_part OUTPUT;
    SET @p_pFull += @p_part;
    SET @p_pShort += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT MIN(seen_at) AS first_seen, MAX(seen_at) AS last_seen, COUNT(*) AS samples, session_id, MAX(login) AS login, MAX(host) AS host,
       MAX(program) AS program, MAX(db) AS db, MAX(status) AS status, MAX(open_tran) AS open_tran, MAX(blocked_sessions) AS blocked_sessions,
       MAX(max_blocked_s) AS max_blocked_s, MAX(statement_source) AS statement_source, statement
FROM #s_head GROUP BY session_id, statement',
         @Title = N'Head blockers (top of each blocking chain)', @OrderBy = N'max_blocked_s DESC', @MaxRows = 0, @SkipEmpty = 0, @Html = @p_part OUTPUT;
    SET @p_pFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT MIN(seen_at) AS first_seen, MAX(seen_at) AS last_seen, COUNT(*) AS samples, session_id, MAX(login) AS login, MAX(host) AS host,
       MAX(program) AS program, MAX(db) AS db, MAX(status) AS status, MAX(open_tran) AS open_tran, MAX(blocked_sessions) AS blocked_sessions,
       MAX(max_blocked_s) AS max_blocked_s, MAX(statement_source) AS statement_source, statement
FROM #s_head GROUP BY session_id, statement',
         @Title = N'Head blockers (top of each blocking chain) - top 10, all in the attachment', @OrderBy = N'max_blocked_s DESC', @MaxRows = 10, @SkipEmpty = 1, @Html = @p_part OUTPUT;
    SET @p_pShort += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT MIN(seen_at) AS first_seen, MAX(seen_at) AS last_seen, COUNT(*) AS samples, reason, session_id, MAX(login) AS login,
       MAX(host) AS host, MAX(program) AS program, MAX(db) AS db, MAX(command) AS command, MAX(wait_type) AS wait_type, MAX(wait_ms) AS max_wait_ms,
       MAX(wait_resource) AS wait_resource, MAX(blocked_by) AS blocked_by, MAX(elapsed_s) AS max_elapsed_s, MAX(cpu_ms) AS max_cpu_ms,
       MAX(logical_reads) AS max_reads, MAX(writes) AS max_writes, MAX(granted_mb) AS granted_mb, MAX(tempdb_mb) AS tempdb_mb, MAX(open_tran) AS open_tran,
       MAX(object_name) AS object_name, statement
FROM #s_prob GROUP BY session_id, reason, statement',
         @Title = N'Problem sessions (blocked, I/O / log / memory / tempdb waits, long running)', @OrderBy = N'max_elapsed_s DESC', @MaxRows = 0, @SkipEmpty = 0, @Html = @p_part OUTPUT;
    SET @p_pFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT MIN(seen_at) AS first_seen, MAX(seen_at) AS last_seen, COUNT(*) AS samples, reason, session_id, MAX(login) AS login,
       MAX(host) AS host, MAX(program) AS program, MAX(db) AS db, MAX(command) AS command, MAX(wait_type) AS wait_type, MAX(wait_ms) AS max_wait_ms,
       MAX(wait_resource) AS wait_resource, MAX(blocked_by) AS blocked_by, MAX(elapsed_s) AS max_elapsed_s, MAX(cpu_ms) AS max_cpu_ms,
       MAX(logical_reads) AS max_reads, MAX(writes) AS max_writes, MAX(granted_mb) AS granted_mb, MAX(tempdb_mb) AS tempdb_mb, MAX(open_tran) AS open_tran,
       MAX(object_name) AS object_name, statement
FROM #s_prob GROUP BY session_id, reason, statement',
         @Title = N'Problem sessions (blocked, I/O / log / memory / tempdb waits, long running) - top 10, all in the attachment', @OrderBy = N'max_elapsed_s DESC', @MaxRows = 10, @SkipEmpty = 1, @Html = @p_part OUTPUT;
    SET @p_pShort += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT MIN(seen_at) AS first_seen, MAX(seen_at) AS last_seen, COUNT(*) AS samples, session_id, MAX(login) AS login, MAX(program) AS program,
       MAX(db) AS db, MAX(grant_state) AS grant_state, MAX(requested_mb) AS requested_mb, MAX(granted_mb) AS granted_mb, MAX(used_mb) AS used_mb,
       MAX(wait_ms) AS max_wait_ms, MAX(dop) AS dop, statement
FROM #s_grant GROUP BY session_id, statement',
         @Title = N'Memory grants (waiting, or big)', @OrderBy = N'requested_mb DESC', @MaxRows = 0, @SkipEmpty = 0, @Html = @p_part OUTPUT;
    SET @p_pFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT MIN(seen_at) AS first_seen, MAX(seen_at) AS last_seen, COUNT(*) AS samples, session_id, MAX(login) AS login, MAX(host) AS host,
       MAX(program) AS program, MAX(user_objects_mb) AS user_objects_mb, MAX(internal_objects_mb) AS internal_objects_mb, statement
FROM #s_tdbs GROUP BY session_id, statement',
         @Title = N'TempDB users', @OrderBy = N'user_objects_mb DESC', @MaxRows = 0, @SkipEmpty = 0, @Html = @p_part OUTPUT;
    SET @p_pFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT n AS _n, CONVERT(char(8), t, 108) AS [time], batch_s AS [batch req/s], tx_s AS [trans/s], comp_s AS [compiles/s], recomp_s AS [recompiles/s],
       user_conn AS [user conns], lock_waits_s AS [lock waits/s], lock_wait_ms_s AS [lock wait ms/s], lock_timeouts_s AS [lock timeouts/s],
       deadlocks_s AS [deadlocks/s], blocked AS [blocked], max_block_s AS [max block s], ple AS [PLE s], buffer_hit_pct AS [buffer hit %],
       grants_pending AS [grants pending], target_mb AS [target MB], total_mb AS [total MB], data_read_ms AS [data read ms], log_write_ms AS [log write ms],
       log_flush_wait_ms_s AS [log flush wait ms/s], log_mb_s AS [log MB/s], tempdb_used_mb AS [tempdb used MB], version_store_mb AS [version store MB],
       tempdb_alloc_waits AS [tempdb alloc waits], ag_send_mb AS [AG send queue MB], ag_redo_mb AS [AG redo queue MB],
       ag_trans_delay_ms AS [AG trans delay ms], listener_conns AS [listener conns]
FROM #iv',
         @Title = N'Per interval', @OrderBy = N'_n', @MaxRows = 0, @SkipEmpty = 0, @Html = @p_part OUTPUT;
    SET @p_pFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT * FROM #pwaits',
         @Title = N'Wait stats per interval (ms waited)', @OrderBy = N'_n', @MaxRows = 0, @SkipEmpty = 0, @Html = @p_part OUTPUT;
    SET @p_pFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT TOP (20) p.inst AS [database], CAST(AVG(p.d / i.dt) AS decimal(18, 1)) AS [avg trans/s], CAST(MAX(p.d / i.dt) AS decimal(18, 1)) AS [peak trans/s]
FROM #pcd AS p JOIN #iv0 AS i ON i.n = p.n
WHERE p.obj = N''Databases'' AND p.ctr = N''Transactions/sec'' AND p.inst NOT IN (N''_Total'', N''mssqlsystemresource'')
  AND (NOT EXISTS (SELECT 1 FROM #pdb) OR p.inst IN (SELECT name FROM #pdb))
GROUP BY p.inst ORDER BY AVG(p.d / i.dt) DESC',
         @Title = N'Transactions/sec per database', @OrderBy = N'[avg trans/s] DESC', @MaxRows = 0, @SkipEmpty = 0, @Html = @p_part OUTPUT;
    SET @p_pFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT b.db AS [database], b.ftype AS file_type, b.reads - a.reads AS reads,
       CAST((b.rstall - a.rstall) * 1.0 / NULLIF(b.reads - a.reads, 0) AS decimal(18, 1)) AS [avg read ms],
       b.writes - a.writes AS writes, CAST((b.wstall - a.wstall) * 1.0 / NULLIF(b.writes - a.writes, 0) AS decimal(18, 1)) AS [avg write ms]
FROM #s_io AS b JOIN #s_io AS a ON a.db = b.db AND a.ftype = b.ftype AND a.n = 0
WHERE b.n = (SELECT MAX(n) FROM #s_time) AND b.reads >= a.reads AND b.writes >= a.writes AND (b.reads - a.reads) + (b.writes - a.writes) > 0',
         @Title = N'Data / log file latency in the window', @OrderBy = N'CASE WHEN ISNULL([avg read ms], 0) > ISNULL([avg write ms], 0) THEN [avg read ms] ELSE [avg write ms] END DESC', @MaxRows = 0, @SkipEmpty = 0, @Html = @p_part OUTPUT;
    SET @p_pFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT TOP (15) program, host, login, MAX(sessions) AS [peak sessions],
       CAST(SUM(sessions) * 1.0 / (SELECT COUNT(*) FROM #s_time) AS decimal(18, 1)) AS [avg sessions], MAX(active) AS [peak active]
FROM #s_sess GROUP BY program, host, login ORDER BY MAX(sessions) DESC',
         @Title = N'Connection pool usage (sessions per application / host / login)', @OrderBy = N'[peak sessions] DESC', @MaxRows = 0, @SkipEmpty = 0, @Html = @p_part OUTPUT;
    SET @p_pFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT CASE WHEN EXISTS (SELECT 1 FROM #s_ag AS x WHERE x.ag_name = g.ag_name AND x.db = g.db AND x.replica = g.replica
                                       AND x.sync_state NOT IN (N''SYNCHRONIZED'', N''SYNCHRONIZING'', N'''')) THEN ''CRITICAL'' ELSE '''' END AS status,
       g.ag_name, g.db AS [database], g.replica,
       (SELECT TOP (1) l.sync_state FROM #s_ag AS l WHERE l.ag_name = g.ag_name AND l.db = g.db AND l.replica = g.replica ORDER BY l.n DESC) AS [sync state (last)],
       STUFF((SELECT DISTINCT N'', '' + x.sync_state FROM #s_ag AS x WHERE x.ag_name = g.ag_name AND x.db = g.db AND x.replica = g.replica FOR XML PATH('''')), 1, 2, N'''') AS [states seen],
       CAST(MAX(g.send_kb) / 1024.0 AS decimal(18, 1)) AS [max send queue MB], CAST(MAX(g.redo_kb) / 1024.0 AS decimal(18, 1)) AS [max redo queue MB],
       CAST((SELECT (MAX(CASE WHEN pc.ctr = N''Transaction Delay'' THEN pc.val END) - MIN(CASE WHEN pc.ctr = N''Transaction Delay'' THEN pc.val END)) * 1.0
                    / NULLIF(MAX(CASE WHEN pc.ctr = N''Mirrored Write Transactions/sec'' THEN pc.val END) - MIN(CASE WHEN pc.ctr = N''Mirrored Write Transactions/sec'' THEN pc.val END), 0)
             FROM #s_pc AS pc WHERE pc.obj = N''Database Replica'' AND pc.inst = g.db) AS decimal(18, 1)) AS [avg trans delay ms]
FROM #s_ag AS g GROUP BY g.ag_name, g.db, g.replica',
         @Title = N'Always On during the window', @OrderBy = N'ag_name, [database], replica', @StatusColumn = N'status', @MaxRows = 0, @SkipEmpty = 0, @Html = @p_part OUTPUT;
    SET @p_pFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT listener, ip, MIN(connections) AS [min conns], CAST(AVG(connections * 1.0) AS decimal(18, 1)) AS [avg conns], MAX(connections) AS [max conns]
FROM #s_lsn GROUP BY listener, ip',
         @Title = N'Listener connections', @OrderBy = N'listener, ip', @MaxRows = 0, @SkipEmpty = 0, @Html = @p_part OUTPUT;
    SET @p_pFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT TOP (50) * FROM #x_blocked ORDER BY blocked_s DESC',
         @Title = N'Blocked process reports (XE)', @OrderBy = N'blocked_s DESC', @MaxRows = 0, @SkipEmpty = 0, @Html = @p_part OUTPUT;
    SET @p_pFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT deadlock_no, event_time, processes FROM #x_dl',
         @Title = N'Deadlocks', @OrderBy = N'deadlock_no', @MaxRows = 0, @SkipEmpty = 0, @Html = @p_part OUTPUT;
    SET @p_pFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT * FROM #x_dlproc',
         @Title = N'Deadlock processes', @OrderBy = N'deadlock_no, victim DESC', @MaxRows = 0, @SkipEmpty = 0, @Html = @p_part OUTPUT;
    SET @p_pFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT TOP (10) deadlock_no, CONVERT(nvarchar(max), deadlock_graph) AS deadlock_xml FROM #x_dl ORDER BY deadlock_no',
         @Title = N'Deadlock graphs - copy a graph into a .xdl file to see the diagram in SSMS', @OrderBy = N'deadlock_no', @MaxRows = 0, @SkipEmpty = 0, @Html = @p_part OUTPUT;
    SET @p_pFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT TOP (200) * FROM #x_long ORDER BY duration_s DESC',
         @Title = N'Queries over the long-query limit (XE)', @OrderBy = N'duration_s DESC', @MaxRows = 0, @SkipEmpty = 0, @Html = @p_part OUTPUT;
    SET @p_pFull += @p_part;
    SET @p_pFull += N'<div style="color:#555;margin-top:12px">Top queries = plan cache (sys.dm_exec_query_stats) at the end of the window minus the start, grouped by query_hash ('
                  + CAST(@pf_cached AS nvarchar(20)) + N' cached statements). Plans evicted or recompiled during the window and OPTION (RECOMPILE) statements are not counted; those over '
                  + CAST(@LongQuerySec AS nvarchar(10)) + N' s are in the list above.</div>';
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT db, object_name, CONVERT(nvarchar(20), query_hash, 1) AS query_hash, executions, total_duration_ms, avg_duration_ms, total_cpu_ms, total_logical_reads, query_text, rn_d AS _r
FROM #qtx WHERE rn_d <= 20',
         @Title = N'Top 20 queries in the window by duration', @OrderBy = N'_r', @MaxRows = 0, @SkipEmpty = 0, @Html = @p_part OUTPUT;
    SET @p_pFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT db, object_name, CONVERT(nvarchar(20), query_hash, 1) AS query_hash, executions, total_cpu_ms, total_duration_ms, total_logical_reads, query_text, rn_c AS _r
FROM #qtx WHERE rn_c <= 20',
         @Title = N'Top 20 queries in the window by CPU', @OrderBy = N'_r', @MaxRows = 0, @SkipEmpty = 0, @Html = @p_part OUTPUT;
    SET @p_pFull += @p_part;
    EXEC dbo.usp_DBA_HtmlTable @Query = N'SELECT db, object_name, CONVERT(nvarchar(20), query_hash, 1) AS query_hash, executions, total_logical_reads, total_duration_ms, total_cpu_ms, query_text, rn_r AS _r
FROM #qtx WHERE rn_r <= 20',
         @Title = N'Top 20 queries in the window by logical reads', @OrderBy = N'_r', @MaxRows = 0, @SkipEmpty = 0, @Html = @p_part OUTPUT;
    SET @p_pFull += @p_part;
END;

/*#############################################################################
  REPORT + EMAIL
#############################################################################*/
DECLARE @r_tag varchar(10), @r_head nvarchar(max), @r_full nvarchar(max), @r_short nvarchar(max), @r_subject nvarchar(255),
        @r_file nvarchar(260), @r_query nvarchar(max), @r_max bigint = 0, @r_mailId int, @r_how nvarchar(200), @r_crit int, @r_warn int,
        @r_imp varchar(6), @r_body nvarchar(max);
SET @r_crit = @p_hCrit + @p_pCrit; SET @r_warn = @p_hWarn + @p_pWarn;
SET @r_tag = CASE WHEN @r_crit > 0 THEN 'CRITICAL' WHEN @r_warn > 0 THEN 'WARNING' ELSE 'OK' END;
SET @r_imp = CASE WHEN @r_tag = 'CRITICAL' THEN 'High' ELSE 'Normal' END;   -- EXEC parameters can't be expressions
SET @r_head = N'<h1>' + dbo.fn_DBA_Html(@@SERVERNAME) + N'</h1>'
    + N'<div class="banner" style="background:' + CASE @r_tag WHEN 'CRITICAL' THEN N'#f8d7da' WHEN 'WARNING' THEN N'#fff3cd' ELSE N'#d4edda' END + N'">'
    + @r_tag + N' - ' + CASE WHEN @NoHealth = 0 THEN N'health: ' + CAST(@p_hCrit AS nvarchar(10)) + N' critical, ' + CAST(@p_hWarn AS nvarchar(10)) + N' warning(s)' ELSE N'' END
    + CASE WHEN @NoHealth = 0 AND @NoPerf = 0 THEN N'; ' ELSE N'' END
    + CASE WHEN @NoPerf = 0 THEN N'performance: ' + CAST(@p_pCrit AS nvarchar(10)) + N' critical, ' + CAST(@p_pWarn AS nvarchar(10)) + N' warning(s)' ELSE N'' END + N'</div>'
    + N'<div>Label: <b>' + dbo.fn_DBA_Html(@Label) + N'</b> &nbsp;|&nbsp; '
    + CASE WHEN @NoPerf = 0 THEN N'Window: every ' + CAST(@SampleSec AS nvarchar(10)) + N' s for ' + CAST(@DurationMin AS nvarchar(10)) + N' min &nbsp;|&nbsp; ' ELSE N'' END
    + N'Run as: ' + dbo.fn_DBA_Html(SUSER_SNAME()) + N' &nbsp;|&nbsp; ' + CONVERT(nvarchar(16), @p_runStart, 120) + N' - ' + CONVERT(nvarchar(5), GETDATE(), 108) + N'</div>';
SET @r_full  = N'<html><head><meta charset="utf-8"><style>
body{font-family:Segoe UI,Arial,sans-serif;font-size:12px;color:#222}
h1{color:#fff;background:#1f4e79;padding:6px 10px;font-size:18px;margin:24px 0 6px 0} h2{color:#1f4e79;margin-bottom:2px} h3{color:#1f4e79;margin:18px 0 4px 0;border-bottom:1px solid #1f4e79}
table{border-collapse:collapse;margin-bottom:8px} th{background:#1f4e79;color:#fff;padding:4px 6px;text-align:left;font-weight:600}
td{border:1px solid #d0d0d0;padding:3px 6px;vertical-align:top}
.banner{padding:10px 14px;font-size:14px;font-weight:600;margin:8px 0}
</style></head><body>' + @r_head + @p_hFull + @p_pFull + N'</body></html>';
SET @r_short = N'<html><head><meta charset="utf-8"><style>
body{font-family:Segoe UI,Arial,sans-serif;font-size:12px;color:#222}
h1{color:#fff;background:#1f4e79;padding:6px 10px;font-size:18px;margin:24px 0 6px 0} h2{color:#1f4e79;margin-bottom:2px} h3{color:#1f4e79;margin:18px 0 4px 0;border-bottom:1px solid #1f4e79}
table{border-collapse:collapse;margin-bottom:8px} th{background:#1f4e79;color:#fff;padding:4px 6px;text-align:left;font-weight:600}
td{border:1px solid #d0d0d0;padding:3px 6px;vertical-align:top}
.banner{padding:10px 14px;font-size:14px;font-weight:600;margin:8px 0}
</style></head><body>' + @r_head + @p_hShort + @p_pShort;
SET @r_subject = N'[' + @r_tag + N'] SQL Server Health & Performance Check [' + @Label + N'] - ' + @@SERVERNAME;
SET @r_file = REPLACE(REPLACE(@@SERVERNAME, N'\', N'_'), N',', N'_') + N'_HEALTHPERF_' + @Label + N'_' + FORMAT(@p_runStart, 'yyyyMMdd_HHmm') + N'.html';

IF @SendEmail = 0
BEGIN
    -- testing: click the XML cell in SSMS to see the full HTML; save it as .html to view it in a browser
    SELECT @r_tag AS result, @p_hCrit AS health_critical, @p_hWarn AS health_warnings, @p_pCrit AS perf_critical, @p_pWarn AS perf_warnings,
           (SELECT @r_full AS [processing-instruction(report_html)] FOR XML PATH(''), TYPE) AS full_report_html,
           (SELECT @r_short + N'</body></html>' AS [processing-instruction(email_body_html)] FOR XML PATH(''), TYPE) AS email_body_html;
    RETURN;
END;

IF @MailProfile IS NULL
    SELECT TOP (1) @MailProfile = p.name
    FROM msdb.dbo.sysmail_profile AS p
    LEFT JOIN msdb.dbo.sysmail_principalprofile AS pp ON pp.profile_id = p.profile_id AND pp.is_default = 1 AND pp.principal_sid = 0x00
    WHERE EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profileaccount AS pa WHERE pa.profile_id = p.profile_id)
    ORDER BY CASE WHEN pp.profile_id IS NOT NULL THEN 0 ELSE 1 END, p.profile_id;
IF @MailProfile IS NULL
    RAISERROR(N'No Database Mail profile with an SMTP account on this instance - run scripts/45_database_mail_setup.sql. The report was not sent.', 16, 1);
SELECT @r_max = CAST(paramvalue AS bigint) FROM msdb.dbo.sysmail_configuration WHERE paramname = N'MaxFileSize';

SET @r_mailId = NULL;
IF @AttachReport = 1 AND (@r_max <= 0 OR LEN(@r_full) <= @r_max)
BEGIN
    BEGIN TRY
        -- the report is attached as a query result (works for every login; no file on disk needed)
        SET @r_query = N'SET NOCOUNT ON; SELECT N''' + REPLACE(@r_full, N'''', N'''''') + N''';';
        SET @r_body = @r_short + N'<p style="color:#555">The full report (all sections, per-interval tables and query lists) is attached: ' + @r_file + N'</p></body></html>';
        EXEC msdb.dbo.sp_send_dbmail
             @profile_name = @MailProfile, @recipients = @Recipients, @copy_recipients = @CopyRecipients, @from_address = @FromAddress,
             @subject = @r_subject, @body_format = 'HTML', @importance = @r_imp, @body = @r_body,
             @query = @r_query, @execute_query_database = N'master', @attach_query_result_as_file = 1, @query_attachment_filename = @r_file,
             @query_result_header = 0, @query_no_truncate = 1, @query_result_no_padding = 1, @exclude_query_output = 1, @ansi_attachment = 1,
             @mailitem_id = @r_mailId OUTPUT;
        SET @r_how = N'with the report attached';
    END TRY
    BEGIN CATCH
        SET @r_how = N'attachment failed (' + ERROR_MESSAGE() + N')';
        SET @r_mailId = NULL;
    END CATCH;
END
ELSE IF @AttachReport = 1
    SET @r_how = N'report is ' + CAST(LEN(@r_full) / 1024 AS nvarchar(20)) + N' KB, above Database Mail MaxFileSize (' + CAST(@r_max / 1024 AS nvarchar(20))
               + N' KB) - raise it with scripts/45_database_mail_setup.sql (@MaxFileSizeMB)';

IF @r_mailId IS NULL
BEGIN
    -- summary only (the per-section tables of the email body are still included)
    DECLARE @r_note nvarchar(max) = N'<p style="color:#a94442">Full report not attached: ' + dbo.fn_DBA_Html(ISNULL(@r_how, N'@AttachReport = 0')) + N'. '
        + N'Run EXEC ' + DB_NAME() + N'.dbo.usp_DBA_HealthPerfCheck @SendEmail = 0 in SSMS to see it.</p></body></html>';
    SET @r_body = @r_short + @r_note;
    EXEC msdb.dbo.sp_send_dbmail
         @profile_name = @MailProfile, @recipients = @Recipients, @copy_recipients = @CopyRecipients, @from_address = @FromAddress,
         @subject = @r_subject, @body_format = 'HTML', @importance = @r_imp, @body = @r_body, @mailitem_id = @r_mailId OUTPUT;
    SET @r_how = N'summary only - ' + ISNULL(@r_how, N'');
END;
PRINT N'Report ' + @r_tag + N' queued as Database Mail item ' + CAST(@r_mailId AS nvarchar(20)) + N' via profile ''' + @MailProfile + N''' (' + @r_how + N'). '
    + N'Check: SELECT sent_status FROM msdb.dbo.sysmail_allitems WHERE mailitem_id = ' + CAST(@r_mailId AS nvarchar(20)) + N';';

END TRY
BEGIN CATCH
    SET @p_err = ERROR_MESSAGE() + N' (line ' + CAST(ERROR_LINE() AS nvarchar(10)) + N')';
    -- make sure the server is put back even when the check fails
    BEGIN TRY
        IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'DBA_PerfCheckJob') DROP EVENT SESSION DBA_PerfCheckJob ON SERVER;
        IF EXISTS (SELECT 1 FROM dbo.DBA_PerfCheck_State WHERE id = 1)
        BEGIN
            DECLARE @c_orig int = (SELECT orig_threshold FROM dbo.DBA_PerfCheck_State WHERE id = 1),
                    @c_adv int = (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'show advanced options');
            IF @c_adv = 0 BEGIN EXEC sys.sp_configure N'show advanced options', 1; RECONFIGURE; END;
            EXEC sys.sp_configure N'blocked process threshold (s)', @c_orig; RECONFIGURE;
            IF @c_adv = 0 BEGIN EXEC sys.sp_configure N'show advanced options', 0; RECONFIGURE; END;
            DELETE dbo.DBA_PerfCheck_State WHERE id = 1;
        END;
    END TRY
    BEGIN CATCH
    END CATCH;
    -- tell the team the check itself failed
    IF @SendEmail = 1 AND NULLIF(LTRIM(@Recipients), N'') IS NOT NULL
    BEGIN
        BEGIN TRY
            IF @MailProfile IS NULL
                SELECT TOP (1) @MailProfile = p.name FROM msdb.dbo.sysmail_profile AS p
                WHERE EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profileaccount AS pa WHERE pa.profile_id = p.profile_id) ORDER BY p.profile_id;
            DECLARE @c_subj nvarchar(255) = N'[FAILED] SQL Server Health & Performance Check [' + @Label + N'] - ' + @@SERVERNAME,
                    @c_body nvarchar(max) = N'<html><head><meta charset="utf-8"><style>
body{font-family:Segoe UI,Arial,sans-serif;font-size:12px;color:#222}
h1{color:#fff;background:#1f4e79;padding:6px 10px;font-size:18px;margin:24px 0 6px 0} h2{color:#1f4e79;margin-bottom:2px} h3{color:#1f4e79;margin:18px 0 4px 0;border-bottom:1px solid #1f4e79}
table{border-collapse:collapse;margin-bottom:8px} th{background:#1f4e79;color:#fff;padding:4px 6px;text-align:left;font-weight:600}
td{border:1px solid #d0d0d0;padding:3px 6px;vertical-align:top}
.banner{padding:10px 14px;font-size:14px;font-weight:600;margin:8px 0}
</style></head><body><h1>' + dbo.fn_DBA_Html(@@SERVERNAME) + N'</h1><div class="banner" style="background:#f8d7da">The check failed: '
                                          + dbo.fn_DBA_Html(@p_err) + N'</div><div>Run as ' + dbo.fn_DBA_Html(SUSER_SNAME()) + N', started ' + CONVERT(nvarchar(16), @p_runStart, 120) + N'.</div></body></html>';
            IF @MailProfile IS NOT NULL
                EXEC msdb.dbo.sp_send_dbmail @profile_name = @MailProfile, @recipients = @Recipients, @copy_recipients = @CopyRecipients,
                     @subject = @c_subj, @body = @c_body, @body_format = 'HTML', @importance = 'High';
        END TRY
        BEGIN CATCH
        END CATCH;
    END;
    RAISERROR(N'Health & performance check failed: %s', 16, 1, @p_err);   -- the Agent job shows as failed
END CATCH;
END;
GO
-- the empty stub has no parameters, so this tells whether the ALTER above worked
IF EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID(N'dbo.usp_DBA_HealthPerfCheck') AND name = N'@Recipients')
    PRINT N'PART 1 done: dbo.usp_DBA_HealthPerfCheck is installed / up to date in ' + DB_NAME() + N'.';
ELSE
    RAISERROR(N'PART 1 did NOT complete: dbo.usp_DBA_HealthPerfCheck is missing or still the empty stub - see the errors above.', 16, 1);
GO

/*=============================================================================
  PART 2 - CREATE THE SQL AGENT JOB  (set the parameters, then run this part)
  Creates or replaces the job and a schedule. Steps:
    1. AG role check (when @PrimaryOnly = 1): continues if this instance has no
       availability group, is PRIMARY for at least one, or an AG is RESOLVING (no
       primary); if it is SECONDARY for every AG it stops - the job ends as
       succeeded, no email. After a failover the new primary takes over by itself.
    2. The health & performance check (dbo.usp_DBA_HealthPerfCheck).
  The job runs as its owner (sa by default), so it has all permissions.
  Run it now:  EXEC msdb.dbo.sp_start_job @job_name = N'DBA - Health & Performance Check';
=============================================================================*/
USE [msdb];
GO
DECLARE
    @JobName         sysname       = N'DBA - Health & Performance Check',
    @ProcDatabase    sysname       = N'master',                    -- database used on the USE line of PART 1
    @Recipients      nvarchar(max) = N'dba-team@yourcompany.com',  -- ; separated
    @CopyRecipients  nvarchar(max) = NULL,
    @MailProfile     sysname       = NULL,                         -- NULL = default public profile
    @FromAddress     nvarchar(256) = NULL,
    @Label           nvarchar(50)  = N'SCHEDULED',
    @SampleSec       int           = 60,                           -- performance window: seconds between samples
    @DurationMin     int           = 30,                           -- performance window: minutes (job runs about this long)
    @PerfDatabases   nvarchar(max) = NULL,                         -- e.g. N'MARS,CLR' for Trans/s; NULL = all
    @NoPerf          bit           = 0,                            -- 1 = health check only (job takes ~1 min)
    @PrimaryOnly     bit           = 1,                            -- 1 = step 1 checks the AG role: run only where this instance is primary
                                                                   --     for at least one AG (or has no AG); on a secondary-only instance
                                                                   --     the job ends as succeeded without running. Install on every replica.
    @Schedule        varchar(10)   = 'DAILY',                      -- DAILY | WEEKLY | ONCE | NONE (no schedule, run on demand)
    @StartTime       char(5)       = '06:00',                      -- HH:mm, server local time
    @WeekDays        varchar(60)   = 'Mon,Wed,Fri',                -- WEEKLY only
    @OnceDate        date          = NULL,                         -- ONCE only, e.g. '2026-11-25'
    @JobOwner        sysname       = NULL,                         -- NULL = sa (found by SID, works when sa is renamed or disabled)
    @NotifyOperator  sysname       = NULL,                         -- optional Agent operator emailed when the JOB fails
    @UpdateExisting  bit           = 1;                            -- 1 = update the existing job in place (history kept); 0 = stop if it exists

/*---------------------------------------------------------------------------*/
DECLARE @jobId uniqueidentifier, @cmd nvarchar(max), @freqType int, @freqInterval int = 0, @recur int = 0,
        @startTimeInt int, @startDate int = CONVERT(int, CONVERT(char(8), GETDATE(), 112)), @schedName sysname;

IF OBJECT_ID(QUOTENAME(@ProcDatabase) + N'.dbo.usp_DBA_HealthPerfCheck', N'P') IS NULL
BEGIN RAISERROR(N'dbo.usp_DBA_HealthPerfCheck not found in %s - run PART 1 first (or fix @ProcDatabase).', 16, 1, @ProcDatabase); RETURN; END;
IF @StartTime NOT LIKE '[0-2][0-9]:[0-5][0-9]'
BEGIN RAISERROR(N'@StartTime must be HH:mm.', 16, 1); RETURN; END;
SET @startTimeInt = CAST(REPLACE(@StartTime, ':', '') AS int) * 100;
SET @Schedule = UPPER(@Schedule);
IF @Schedule NOT IN ('DAILY', 'WEEKLY', 'ONCE', 'NONE')
BEGIN RAISERROR(N'@Schedule must be DAILY, WEEKLY, ONCE or NONE.', 16, 1); RETURN; END;
IF @Schedule = 'ONCE' AND @OnceDate IS NULL
BEGIN RAISERROR(N'@OnceDate is required for @Schedule = ONCE.', 16, 1); RETURN; END;

SET @cmd = N'SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON; SET ARITHABORT ON; SET ANSI_WARNINGS ON;' + NCHAR(13) + NCHAR(10)
    + N'EXEC dbo.usp_DBA_HealthPerfCheck' + NCHAR(13) + NCHAR(10)
    + N'     @Recipients = N''' + REPLACE(@Recipients, N'''', N'''''') + N''''
    + CASE WHEN @CopyRecipients IS NOT NULL THEN N', @CopyRecipients = N''' + REPLACE(@CopyRecipients, N'''', N'''''') + N'''' ELSE N'' END
    + CASE WHEN @MailProfile IS NOT NULL THEN N', @MailProfile = N''' + REPLACE(@MailProfile, N'''', N'''''') + N'''' ELSE N'' END
    + CASE WHEN @FromAddress IS NOT NULL THEN N', @FromAddress = N''' + REPLACE(@FromAddress, N'''', N'''''') + N'''' ELSE N'' END + NCHAR(13) + NCHAR(10)
    + N'   , @Label = N''' + REPLACE(@Label, N'''', N'''''') + N''', @SampleSec = ' + CAST(@SampleSec AS nvarchar(10))
    + N', @DurationMin = ' + CAST(@DurationMin AS nvarchar(10)) + N', @NoPerf = ' + CAST(@NoPerf AS nvarchar(1))
    + CASE WHEN @PerfDatabases IS NOT NULL THEN N', @PerfDatabases = N''' + REPLACE(@PerfDatabases, N'''', N'''''') + N'''' ELSE N'' END + N';';

IF NOT EXISTS (SELECT 1 FROM dbo.syscategories WHERE name = N'Database Maintenance' AND category_class = 1)
    EXEC dbo.sp_add_category @class = N'JOB', @type = N'LOCAL', @name = N'Database Maintenance';

DECLARE @existed bit = 0, @stepId int, @schedId int;
SELECT @jobId = job_id FROM dbo.sysjobs WHERE name = @JobName;
IF @jobId IS NOT NULL
BEGIN
    -- update in place: job history is kept; steps and schedules are rebuilt from the parameters above
    IF @UpdateExisting = 0 BEGIN RAISERROR(N'Job %s already exists (set @UpdateExisting = 1 to update it).', 16, 1, @JobName); RETURN; END;
    SET @existed = 1;
    EXEC dbo.sp_update_job @job_id = @jobId, @enabled = 1, @category_name = N'Database Maintenance',
         @description = N'Health check + performance window, emailed by Database Mail (dbo.usp_DBA_HealthPerfCheck, automation/perf-check-agent).',
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
         @job_name = @JobName, @enabled = 1, @category_name = N'Database Maintenance',
         @description = N'Health check + performance window, emailed by Database Mail (dbo.usp_DBA_HealthPerfCheck, automation/perf-check-agent).',
         @owner_login_name = @JobOwner, @notify_level_eventlog = 2,
         @notify_level_email = 0, @job_id = @jobId OUTPUT;
DECLARE @owner sysname = ISNULL(@JobOwner, SUSER_SNAME(0x01));
EXEC dbo.sp_update_job @job_id = @jobId, @owner_login_name = @owner;
IF @NotifyOperator IS NOT NULL
    EXEC dbo.sp_update_job @job_id = @jobId, @notify_level_email = 2, @notify_email_operator_name = @NotifyOperator;

IF @PrimaryOnly = 1
BEGIN
    DECLARE @agCmd nvarchar(max) = N'SET NOCOUNT ON; SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
-- Step 1: run the check only on the primary replica (or when there is no AG / no primary)
IF CAST(SERVERPROPERTY(''IsHadrEnabled'') AS int) = 1
   AND EXISTS (SELECT 1 FROM sys.dm_hadr_availability_replica_states WHERE is_local = 1)
   AND NOT EXISTS (SELECT 1 FROM sys.dm_hadr_availability_replica_states WHERE is_local = 1 AND role_desc <> N''SECONDARY'')
BEGIN
    DECLARE @m nvarchar(2000) = N''Skipped: '' + @@SERVERNAME + N'' is a SECONDARY replica for every availability group (''
        + STUFF((SELECT N'', '' + ag.name FROM sys.availability_groups AS ag ORDER BY ag.name FOR XML PATH('''')), 1, 2, N'''')
        + N''). The primary replica runs the check. The job ends as succeeded.'';
    RAISERROR(N''%s'', 16, 1, @m);   -- step 1 "fails" on purpose -> the job quits reporting success
END
ELSE
    PRINT N''Proceeding: '' + @@SERVERNAME + CASE WHEN EXISTS (SELECT 1 FROM sys.dm_hadr_availability_replica_states WHERE is_local = 1)
                                             THEN N'' is PRIMARY (or RESOLVING) for at least one availability group.'' ELSE N'' has no availability group.'' END;';
    EXEC dbo.sp_add_jobstep
         @job_id = @jobId, @step_id = 1, @step_name = N'AG role check - continue only on the primary', @subsystem = N'TSQL',
         @database_name = N'master', @command = @agCmd,
         @on_success_action = 3,   -- go to the next step
         @on_fail_action = 1,      -- secondary: quit the job reporting success
         @retry_attempts = 0;
END;

EXEC dbo.sp_add_jobstep
     @job_id = @jobId, @step_name = N'Health & performance check', @subsystem = N'TSQL',
     @database_name = @ProcDatabase, @command = @cmd, @on_success_action = 1, @on_fail_action = 2, @retry_attempts = 0;

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
PRINT CASE WHEN @PrimaryOnly = 1 THEN N'Step 1: AG role check (runs step 2 only on the primary). ' ELSE N'' END + N'Check step command:' + NCHAR(13) + NCHAR(10) + @cmd;
PRINT N'Run it now: EXEC msdb.dbo.sp_start_job @job_name = N''' + @JobName + N''';';
GO
