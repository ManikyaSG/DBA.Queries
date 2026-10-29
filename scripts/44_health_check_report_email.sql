/*******************************************************************************
 File    : 44_health_check_report_email.sql
 Purpose : ONE-SHOT SQL SERVER HEALTH CHECK - run the whole file (F5).
           Collects: instance & build, SQL services, health vitals (CPU,
           memory, blocking, tempdb), databases (state, recovery model,
           compat, owner, size, log use, last full / diff / log backup +
           paths, last CHECKDB, AG role), Always On (AGs, replicas / nodes,
           primary & secondary states, listeners, DB sync per replica),
           cluster & quorum, disk space, data & log files (paths, size, used,
           growth), failed jobs, severity 17+ errors - plus a summary of
           everything that needs attention.
           LAST BLOCK: builds an HTML report and emails it via Database Mail.
 Tags    : [BOX] 2016 SP2 - 2025 / Azure VM   [MI] (services/disks skipped)
 Use for : daily HC, shift handover, pre/post patching or upgrade evidence
           (run before and after, compare the two emails / grids).
 Schedule: Agent job, step type T-SQL, paste this file, database = master.
 Safe    : read-only except sending the email. No objects are created.
*******************************************************************************/
SET NOCOUNT ON;
-- XML methods / FOR XML need these ON. SQL Agent T-SQL steps default QUOTED_IDENTIFIER OFF, so set them explicitly.
SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON;
SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;

/*=============================================================================
  CONFIGURATION  <== change these
=============================================================================*/
DECLARE @SendEmail          bit           = 1,                              -- 0 = only show result grids
        @MailProfile        sysname       = N'DBA_Mail',                    -- MI default: AzureManagedInstance_dbmail_profile
        @Recipients         nvarchar(max) = N'dba-team@yourcompany.com',    -- ; separated
        @CopyRecipients     nvarchar(max) = NULL,
        @SendOnlyIfIssues   bit           = 0,                              -- 1 = mail only when WARNING/CRITICAL found
        @ShowResultSets     bit           = 1,                              -- 0 when running as an Agent job
        @ReportTitle        nvarchar(200) = N'SQL Server Health Check',
        -- thresholds
        @LogBackupMaxMin    int = 60,      -- FULL/BULK_LOGGED DBs: max minutes since last log backup
        @FullBackupMaxDays  int = 7,       -- max days since last full ...
        @DiffBackupMaxHours int = 26,      -- ... unless a diff is newer than this
        @CheckDbMaxDays     int = 7,
        @DiskWarnPct        int = 15,
        @DiskCritPct        int = 10,
        @LogUsedWarnPct     int = 80,
        @FileFreeWarnPct    int = 10,      -- data file internal free % (only flagged when autogrowth is off / at max)
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
IF OBJECT_ID('tempdb..#files')   IS NOT NULL DROP TABLE #files;
IF OBJECT_ID('tempdb..#used')    IS NOT NULL DROP TABLE #used;
IF OBJECT_ID('tempdb..#jobs')    IS NOT NULL DROP TABLE #jobs;
IF OBJECT_ID('tempdb..#errlog')  IS NOT NULL DROP TABLE #errlog;
IF OBJECT_ID('tempdb..#el')      IS NOT NULL DROP TABLE #el;

CREATE TABLE #issues (severity varchar(10), area varchar(40), item nvarchar(300), detail nvarchar(2000));
CREATE TABLE #inst   (seq int IDENTITY, property nvarchar(100), value nvarchar(4000));
CREATE TABLE #svc    (servicename nvarchar(256), status_desc nvarchar(60), startup_type_desc nvarchar(60),
                      service_account nvarchar(256), last_startup_time datetimeoffset NULL, ifi nvarchar(1) NULL);
CREATE TABLE #vitals (seq int IDENTITY, metric nvarchar(100), value nvarchar(400), status varchar(10));
CREATE TABLE #disk   (volume nvarchar(256), label nvarchar(256), total_gb decimal(18,1), free_gb decimal(18,1), free_pct decimal(5,1), status varchar(10));
CREATE TABLE #used   (database_name sysname, logical_name sysname, used_mb decimal(18,1));
CREATE TABLE #el     (LogDate datetime, ProcessInfo nvarchar(50), [Text] nvarchar(max));

/*=============================================================================
  1. INSTANCE
=============================================================================*/
INSERT #inst (property, value)
SELECT v.p, v.v
FROM sys.dm_os_sys_info AS i
CROSS APPLY (VALUES
    (N'Server name',          CAST(@@SERVERNAME AS nvarchar(4000))),
    (N'Machine / node',       CAST(SERVERPROPERTY('ComputerNamePhysicalNetBIOS') AS nvarchar(4000))),
    (N'Edition',              CAST(SERVERPROPERTY('Edition') AS nvarchar(4000))),
    (N'Version / build',      CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(4000)) + N'  ' + ISNULL(CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(20)), N'')
                              + N' ' + ISNULL(CAST(SERVERPROPERTY('ProductUpdateLevel') AS nvarchar(20)), N'') + N' ' + ISNULL(CAST(SERVERPROPERTY('ProductUpdateReference') AS nvarchar(20)), N'')),
    (N'Collation',            CAST(SERVERPROPERTY('Collation') AS nvarchar(4000))),
    (N'Failover cluster (FCI)', CASE WHEN SERVERPROPERTY('IsClustered') = 1 THEN N'Yes' ELSE N'No' END),
    (N'Always On enabled',    CASE WHEN SERVERPROPERTY('IsHadrEnabled') = 1 THEN N'Yes' ELSE N'No' END),
    (N'SQL started',          CONVERT(nvarchar(30), i.sqlserver_start_time, 120) + N'  (' + CAST(DATEDIFF(HOUR, i.sqlserver_start_time, @now) / 24 AS nvarchar(10)) + N' days up)'),
    (N'Logical CPUs / schedulers', CAST(i.cpu_count AS nvarchar(10)) + N' / ' + CAST(i.scheduler_count AS nvarchar(10))),
    (N'Physical memory (MB)', CAST(i.physical_memory_kb / 1024 AS nvarchar(20))),
    (N'Max server memory (MB)', (SELECT CAST(value_in_use AS nvarchar(20)) FROM sys.configurations WHERE name = N'max server memory (MB)')),
    (N'MAXDOP / Cost threshold', (SELECT CAST(value_in_use AS nvarchar(10)) FROM sys.configurations WHERE name = N'max degree of parallelism')
                              + N' / ' + (SELECT CAST(value_in_use AS nvarchar(10)) FROM sys.configurations WHERE name = N'cost threshold for parallelism')),
    (N'Report generated',     CONVERT(nvarchar(30), @now, 120))
) AS v(p, v);

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
SELECT d.database_id, d.name, d.state_desc, d.user_access_desc, d.recovery_model_desc, d.compatibility_level,
       SUSER_SNAME(d.owner_sid) AS owner_name, d.is_read_only, d.log_reuse_wait_desc,
       CAST(sz.size_mb AS decimal(18,0)) AS size_mb,
       CAST(ls.active_log_size_mb * 100.0 / NULLIF(ls.total_log_size_mb, 0) AS decimal(5,1)) AS log_used_pct,
       ag.name AS ag_name,
       CASE WHEN drs.is_primary_replica = 1 THEN N'PRIMARY' WHEN drs.database_id IS NOT NULL THEN N'SECONDARY' ELSE N'' END AS ag_role,
       drs.synchronization_state_desc AS ag_sync_state,
       CASE WHEN d.replica_id IS NULL THEN 1 ELSE sys.fn_hadr_backup_is_preferred_replica(d.name) END AS backup_preferred_here,
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
OUTER APPLY (SELECT TOP (1) b.backup_finish_date, m.physical_device_name FROM msdb.dbo.backupset b
             JOIN msdb.dbo.backupmediafamily m ON m.media_set_id = b.media_set_id
             WHERE b.database_name = d.name AND b.type = 'D' ORDER BY b.backup_finish_date DESC) AS bf
OUTER APPLY (SELECT TOP (1) b.backup_finish_date FROM msdb.dbo.backupset b
             WHERE b.database_name = d.name AND b.type = 'I' ORDER BY b.backup_finish_date DESC) AS bd
OUTER APPLY (SELECT TOP (1) b.backup_finish_date, m.physical_device_name FROM msdb.dbo.backupset b
             JOIN msdb.dbo.backupmediafamily m ON m.media_set_id = b.media_set_id
             WHERE b.database_name = d.name AND b.type = 'L' ORDER BY b.backup_finish_date DESC) AS bl
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
        + CASE WHEN backup_preferred_here = 0 THEN N'Backups run on another AG replica. ' ELSE N'' END
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
  7. DATA & LOG FILES (paths, size, used, growth)
=============================================================================*/
DECLARE dbc CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE state_desc = N'ONLINE' AND HAS_DBACCESS(name) = 1 AND source_database_id IS NULL;
OPEN dbc; FETCH NEXT FROM dbc INTO @dbn;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'USE ' + QUOTENAME(@dbn) + N'; SELECT DB_NAME(), name, CAST(FILEPROPERTY(name, ''SpaceUsed'') / 128.0 AS decimal(18,1)) FROM sys.database_files WHERE type IN (0, 1);';
    BEGIN TRY
        INSERT #used EXEC sys.sp_executesql @sql;
    END TRY
    BEGIN CATCH   -- e.g. non-readable AG secondary
    END CATCH;
    FETCH NEXT FROM dbc INTO @dbn;
END
CLOSE dbc; DEALLOCATE dbc;

SELECT DB_NAME(mf.database_id) AS database_name, mf.name AS logical_name, mf.type_desc, mf.physical_name, mf.state_desc,
       CAST(CAST(mf.size AS bigint) * 8 / 1024.0 AS decimal(18,1)) AS size_mb,
       u.used_mb,
       CAST(CAST(mf.size AS bigint) * 8 / 1024.0 - u.used_mb AS decimal(18,1)) AS free_mb,
       CAST(100.0 * (CAST(mf.size AS bigint) * 8 / 1024.0 - u.used_mb) / NULLIF(CAST(mf.size AS bigint) * 8 / 1024.0, 0) AS decimal(5,1)) AS free_pct,
       CASE WHEN mf.is_percent_growth = 1 THEN CAST(mf.growth AS nvarchar(10)) + N' %'
            WHEN mf.growth = 0 THEN N'OFF'
            ELSE CAST(CAST(mf.growth AS bigint) * 8 / 1024 AS nvarchar(20)) + N' MB' END AS growth,
       CASE mf.max_size WHEN -1 THEN N'unlimited' WHEN 0 THEN N'no growth'
            ELSE CAST(CAST(mf.max_size AS bigint) * 8 / 1024 AS nvarchar(20)) + N' MB' END AS max_size,
       CAST('OK' AS varchar(10)) AS status
INTO #files
FROM sys.master_files AS mf
LEFT JOIN #used AS u ON u.database_name = DB_NAME(mf.database_id) AND u.logical_name = mf.name
WHERE mf.type IN (0, 1);

UPDATE #files SET status = 'WARNING'
WHERE (growth = N'OFF' OR (max_size NOT IN (N'unlimited', N'no growth') AND size_mb >= 0.9 * TRY_CAST(REPLACE(max_size, N' MB', N'') AS decimal(18,1))))
  AND ISNULL(free_pct, 100) < @FileFreeWarnPct;
UPDATE #files SET status = 'WARNING' WHERE growth LIKE N'% [%]' AND status = 'OK' AND size_mb > 10240;   -- % growth on big files

INSERT #issues SELECT 'WARNING', 'File', database_name + N'.' + logical_name,
       CASE WHEN growth LIKE N'% [%]' THEN N'Percent autogrowth on a ' + CAST(size_mb AS nvarchar(20)) + N' MB file'
            ELSE N'Only ' + CAST(ISNULL(free_pct, 0) AS nvarchar(10)) + N'% free inside and cannot grow (growth ' + growth + N', max ' + max_size + N')' END
FROM #files WHERE status <> 'OK';

/*=============================================================================
  8. AGENT JOB FAILURES
=============================================================================*/
SELECT j.name AS job_name, msdb.dbo.agent_datetime(h.run_date, h.run_time) AS run_time, h.step_id, h.step_name,
       LEFT(h.message, 500) AS message
INTO #jobs
FROM msdb.dbo.sysjobhistory AS h
JOIN msdb.dbo.sysjobs AS j ON j.job_id = h.job_id
WHERE h.run_status = 0 AND h.step_id > 0
  AND msdb.dbo.agent_datetime(h.run_date, h.run_time) >= DATEADD(HOUR, -@JobFailHours, @now);

INSERT #issues SELECT 'WARNING', 'Agent job', job_name, CAST(COUNT(*) AS nvarchar(10)) + N' failed step(s), last at ' + CONVERT(nvarchar(20), MAX(run_time), 120)
FROM #jobs GROUP BY job_name;

/*=============================================================================
  9. ERROR LOG: SEVERITY >= 17, CORRUPTION, I/O STALLS (current log)
=============================================================================*/
INSERT #el EXEC sys.xp_readerrorlog 0, 1, N'Severity:';
INSERT #el EXEC sys.xp_readerrorlog 0, 1, N'I/O requests taking longer than';
INSERT #el EXEC sys.xp_readerrorlog 0, 1, N'stack dump';

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
  RESULT GRIDS
=============================================================================*/
IF @ShowResultSets = 1
BEGIN
    SELECT severity, area, item, detail FROM #issues ORDER BY CASE severity WHEN 'CRITICAL' THEN 0 ELSE 1 END, area, item;
    SELECT property, value FROM #inst ORDER BY seq;
    SELECT * FROM #svc;
    SELECT metric, value, status FROM #vitals ORDER BY seq;
    SELECT name, status, notes, state_desc, recovery_model_desc, compatibility_level, owner_name, size_mb, log_used_pct, log_reuse_wait_desc,
           ag_name, ag_role, ag_sync_state, last_full, last_full_path, last_diff, last_log, last_log_path, last_checkdb
    FROM #db ORDER BY database_id;
    SELECT * FROM #agr ORDER BY ag_name, role_desc, replica_node;
    SELECT * FROM #agdb ORDER BY ag_name, database_name, role;
    SELECT * FROM #cluster;
    SELECT * FROM #disk ORDER BY volume;
    SELECT * FROM #files ORDER BY database_name, type_desc DESC, logical_name;
    SELECT * FROM #jobs ORDER BY run_time DESC;
    SELECT * FROM #errlog ORDER BY LogDate DESC;
END;

/*=============================================================================
  EMAIL: BUILD HTML REPORT AND SEND VIA DATABASE MAIL
  FOR XML PATH('tr') HTML-encodes values; [@style] colours the whole row.
=============================================================================*/
DECLARE @crit int = (SELECT COUNT(*) FROM #issues WHERE severity = 'CRITICAL'),
        @warn int = (SELECT COUNT(*) FROM #issues WHERE severity = 'WARNING'),
        @html nvarchar(max), @subject nvarchar(255), @importance varchar(6),
        @red  nvarchar(60) = N'background-color:#f8d7da', @amber nvarchar(60) = N'background-color:#fff3cd',
        @none nvarchar(200) = N'<tr><td colspan="20" style="color:#2e7d32">None</td></tr>';

SET @html = CAST(N'' AS nvarchar(max)) + N'<html><head><style>
body{font-family:Segoe UI,Arial,sans-serif;font-size:12px;color:#222}
h2{color:#1f4e79;margin-bottom:2px} h3{color:#1f4e79;margin:18px 0 4px 0;border-bottom:1px solid #1f4e79}
table{border-collapse:collapse;margin-bottom:8px} th{background:#1f4e79;color:#fff;padding:4px 6px;text-align:left;font-weight:600}
td{border:1px solid #d0d0d0;padding:3px 6px;vertical-align:top} .ok{color:#2e7d32;font-weight:600} .bad{color:#c62828;font-weight:600}
</style></head><body>'
+ N'<h2>' + @ReportTitle + N' - ' + @@SERVERNAME + N'</h2>'
+ N'<div>Generated ' + CONVERT(nvarchar(20), @now, 120) + N' &nbsp;|&nbsp; '
+ CASE WHEN @crit + @warn = 0 THEN N'<span class="ok">ALL CHECKS PASSED</span>'
       ELSE N'<span class="bad">' + CAST(@crit AS nvarchar(10)) + N' critical, ' + CAST(@warn AS nvarchar(10)) + N' warning(s)</span>' END
+ N'</div>'

-- Summary of issues
+ N'<h3>Needs attention</h3><table><tr><th>Severity</th><th>Area</th><th>Item</th><th>Detail</th></tr>'
+ ISNULL(CAST((SELECT [@style] = CASE severity WHEN 'CRITICAL' THEN @red ELSE @amber END,
                      td = severity, '', td = area, '', td = item, '', td = ISNULL(detail, N'')
               FROM #issues ORDER BY CASE severity WHEN 'CRITICAL' THEN 0 ELSE 1 END, area, item
               FOR XML PATH('tr'), TYPE) AS nvarchar(max)), @none)
+ N'</table>'

-- Instance
+ N'<h3>Instance</h3><table>'
+ ISNULL(CAST((SELECT th = property, '', td = ISNULL(value, N'') FROM #inst ORDER BY seq FOR XML PATH('tr'), TYPE) AS nvarchar(max)), @none)
+ N'</table>'

-- Services
+ CASE WHEN @is_mi = 1 THEN N'' ELSE
  N'<h3>SQL Server services</h3><table><tr><th>Service</th><th>Status</th><th>Startup</th><th>Account</th><th>Last start</th><th>IFI</th></tr>'
+ ISNULL(CAST((SELECT [@style] = CASE WHEN status_desc <> N'Running' AND startup_type_desc = N'Automatic' THEN @red END,
                      td = servicename, '', td = status_desc, '', td = startup_type_desc, '', td = ISNULL(service_account, N''), '',
                      td = ISNULL(CONVERT(nvarchar(20), last_startup_time, 120), N''), '', td = ISNULL(ifi, N'')
               FROM #svc ORDER BY servicename FOR XML PATH('tr'), TYPE) AS nvarchar(max)), @none)
+ N'</table>' END

-- Vitals
+ N'<h3>Vitals</h3><table><tr><th>Metric</th><th>Value</th><th>Status</th></tr>'
+ ISNULL(CAST((SELECT [@style] = CASE status WHEN 'CRITICAL' THEN @red WHEN 'WARNING' THEN @amber END,
                      td = metric, '', td = value, '', td = status
               FROM #vitals ORDER BY seq FOR XML PATH('tr'), TYPE) AS nvarchar(max)), @none)
+ N'</table>'

-- Databases
+ N'<h3>Databases, backups &amp; CHECKDB</h3><table><tr><th>Database</th><th>Status</th><th>Notes</th><th>State</th><th>Recovery</th><th>Compat</th>'
+ N'<th>Owner</th><th>Size MB</th><th>Log used %</th><th>AG / role</th><th>Last full</th><th>Last diff</th><th>Last log</th><th>Last CHECKDB</th><th>Full backup path</th><th>Log backup path</th></tr>'
+ ISNULL(CAST((SELECT [@style] = CASE status WHEN 'CRITICAL' THEN @red WHEN 'WARNING' THEN @amber END,
                      td = name, '', td = status, '', td = ISNULL(notes, N''), '', td = state_desc, '', td = recovery_model_desc, '',
                      td = CAST(compatibility_level AS nvarchar(5)), '', td = ISNULL(owner_name, N'?'), '',
                      td = ISNULL(CAST(size_mb AS nvarchar(20)), N''), '', td = ISNULL(CAST(log_used_pct AS nvarchar(10)), N''), '',
                      td = CASE WHEN ag_name IS NULL THEN N'' ELSE ag_name + N' / ' + ag_role + ISNULL(N' (' + ag_sync_state + N')', N'') END, '',
                      td = ISNULL(CONVERT(nvarchar(16), last_full, 120), N'never'), '',
                      td = ISNULL(CONVERT(nvarchar(16), last_diff, 120), N''), '',
                      td = ISNULL(CONVERT(nvarchar(16), last_log, 120), CASE WHEN recovery_model_desc = N'SIMPLE' THEN N'n/a' ELSE N'never' END), '',
                      td = ISNULL(CONVERT(nvarchar(16), NULLIF(last_checkdb, '19000101'), 120), N'never'), '',
                      td = ISNULL(last_full_path, N''), '', td = ISNULL(last_log_path, N'')
               FROM #db ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARNING' THEN 1 ELSE 2 END, database_id
               FOR XML PATH('tr'), TYPE) AS nvarchar(max)), @none)
+ N'</table>'

-- Always On replicas
+ CASE WHEN NOT EXISTS (SELECT 1 FROM #agr) THEN N'<h3>Always On</h3><div>No availability groups on this instance.</div>' ELSE
  N'<h3>Always On - replicas (nodes)</h3><table><tr><th>AG</th><th>Primary</th><th>Replica node</th><th>Role</th><th>Commit mode</th><th>Failover</th>'
+ N'<th>Connected</th><th>Health</th><th>Readable</th><th>Listener</th><th>Endpoint</th><th>Status</th></tr>'
+ ISNULL(CAST((SELECT [@style] = CASE status WHEN 'CRITICAL' THEN @red WHEN 'WARNING' THEN @amber END,
                      td = ag_name, '', td = ISNULL(primary_replica, N''), '', td = replica_node, '', td = ISNULL(role_desc, N'?'), '',
                      td = availability_mode_desc, '', td = failover_mode_desc, '', td = ISNULL(connected_state_desc, N'?'), '',
                      td = ISNULL(synchronization_health_desc, N'?'), '', td = secondary_role_allow_connections_desc, '',
                      td = ISNULL(listeners, N'(none / DNN)'), '', td = ISNULL(endpoint_url, N''), '', td = status
               FROM #agr ORDER BY ag_name, role_desc, replica_node FOR XML PATH('tr'), TYPE) AS nvarchar(max)), @none)
+ N'</table>'
+ N'<h3>Always On - databases per replica</h3><table><tr><th>AG</th><th>Database</th><th>Replica node</th><th>Role</th><th>Sync state</th><th>Health</th>'
+ N'<th>Suspended</th><th>Send queue KB</th><th>Redo queue KB</th><th>Lag s</th><th>Last commit</th></tr>'
+ ISNULL(CAST((SELECT [@style] = CASE status WHEN 'CRITICAL' THEN @red END,
                      td = ag_name, '', td = database_name, '', td = replica_node, '', td = role, '', td = synchronization_state_desc, '',
                      td = synchronization_health_desc, '', td = CASE WHEN is_suspended = 1 THEN N'YES ' + ISNULL(suspend_reason_desc, N'') ELSE N'no' END, '',
                      td = ISNULL(CAST(send_queue_kb AS nvarchar(20)), N''), '', td = ISNULL(CAST(redo_queue_kb AS nvarchar(20)), N''), '',
                      td = ISNULL(CAST(secondary_lag_seconds AS nvarchar(20)), N''), '', td = ISNULL(CONVERT(nvarchar(20), last_commit_time, 120), N'')
               FROM #agdb ORDER BY ag_name, database_name, role FOR XML PATH('tr'), TYPE) AS nvarchar(max)), @none)
+ N'</table>' END

-- Cluster
+ CASE WHEN NOT EXISTS (SELECT 1 FROM #cluster) THEN N'' ELSE
  N'<h3>Windows cluster &amp; quorum</h3><table><tr><th>Cluster</th><th>Quorum</th><th>Quorum state</th><th>Member</th><th>Type</th><th>State</th><th>Votes</th></tr>'
+ ISNULL(CAST((SELECT [@style] = CASE status WHEN 'CRITICAL' THEN @red END,
                      td = cluster_name, '', td = quorum_type_desc, '', td = quorum_state_desc, '', td = member_name, '',
                      td = member_type_desc, '', td = member_state_desc, '', td = CAST(number_of_quorum_votes AS nvarchar(5))
               FROM #cluster ORDER BY member_type_desc, member_name FOR XML PATH('tr'), TYPE) AS nvarchar(max)), @none)
+ N'</table>' END

-- Disks
+ CASE WHEN @is_mi = 1 THEN N'' ELSE
  N'<h3>Disk space</h3><table><tr><th>Volume</th><th>Label</th><th>Total GB</th><th>Free GB</th><th>Free %</th><th>Status</th></tr>'
+ ISNULL(CAST((SELECT [@style] = CASE status WHEN 'CRITICAL' THEN @red WHEN 'WARNING' THEN @amber END,
                      td = volume, '', td = ISNULL(label, N''), '', td = CAST(total_gb AS nvarchar(20)), '', td = CAST(free_gb AS nvarchar(20)), '',
                      td = CAST(free_pct AS nvarchar(10)), '', td = status
               FROM #disk ORDER BY volume FOR XML PATH('tr'), TYPE) AS nvarchar(max)), @none)
+ N'</table>' END

-- Files
+ N'<h3>Data &amp; log files</h3><table><tr><th>Database</th><th>Logical name</th><th>Type</th><th>Path</th><th>Size MB</th><th>Used MB</th><th>Free %</th><th>Growth</th><th>Max size</th></tr>'
+ ISNULL(CAST((SELECT [@style] = CASE status WHEN 'WARNING' THEN @amber END,
                      td = database_name, '', td = logical_name, '', td = type_desc, '', td = physical_name, '',
                      td = CAST(size_mb AS nvarchar(20)), '', td = ISNULL(CAST(used_mb AS nvarchar(20)), N''), '',
                      td = ISNULL(CAST(free_pct AS nvarchar(10)), N''), '', td = growth, '', td = max_size
               FROM #files ORDER BY database_name, type_desc DESC, logical_name FOR XML PATH('tr'), TYPE) AS nvarchar(max)), @none)
+ N'</table>'

-- Jobs
+ N'<h3>Failed job steps (last ' + CAST(@JobFailHours AS nvarchar(5)) + N' h)</h3><table><tr><th>Job</th><th>Run time</th><th>Step</th><th>Message</th></tr>'
+ ISNULL(CAST((SELECT [@style] = @amber, td = job_name, '', td = CONVERT(nvarchar(20), run_time, 120), '',
                      td = CAST(step_id AS nvarchar(5)) + N' ' + step_name, '', td = message
               FROM #jobs ORDER BY run_time DESC FOR XML PATH('tr'), TYPE) AS nvarchar(max)), @none)
+ N'</table>'

-- Error log
+ N'<h3>Severe error log entries (last ' + CAST(@ErrorLogHours AS nvarchar(5)) + N' h)</h3><table><tr><th>Time</th><th>Source</th><th>Message</th></tr>'
+ ISNULL(CAST((SELECT TOP (50) [@style] = @red, td = CONVERT(nvarchar(20), LogDate, 120), '', td = ProcessInfo, '', td = message
               FROM #errlog ORDER BY LogDate DESC FOR XML PATH('tr'), TYPE) AS nvarchar(max)), @none)
+ N'</table>'

+ N'<p style="color:#777">Thresholds: log backup ' + CAST(@LogBackupMaxMin AS nvarchar(5)) + N' min, full ' + CAST(@FullBackupMaxDays AS nvarchar(5))
+ N' d (or diff ' + CAST(@DiffBackupMaxHours AS nvarchar(5)) + N' h), CHECKDB ' + CAST(@CheckDbMaxDays AS nvarchar(5)) + N' d, disk warn/crit '
+ CAST(@DiskWarnPct AS nvarchar(5)) + N'/' + CAST(@DiskCritPct AS nvarchar(5)) + N' %, log used ' + CAST(@LogUsedWarnPct AS nvarchar(5)) + N' %. '
+ N'Source: DBA.Queries scripts/44_health_check_report_email.sql</p></body></html>';

SET @subject = N'[' + CASE WHEN @crit > 0 THEN N'CRITICAL' WHEN @warn > 0 THEN N'WARNING' ELSE N'OK' END + N'] '
             + @ReportTitle + N' - ' + @@SERVERNAME + N' - ' + CONVERT(nvarchar(16), @now, 120);
SET @importance = CASE WHEN @crit > 0 THEN 'High' ELSE 'Normal' END;

IF @SendEmail = 1
BEGIN
    IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name = @MailProfile)
        RAISERROR (N'Database Mail profile "%s" not found - email not sent. Check msdb.dbo.sysmail_profile.', 16, 1, @MailProfile);
    ELSE IF @SendOnlyIfIssues = 1 AND @crit + @warn = 0
        PRINT N'No issues found and @SendOnlyIfIssues = 1 - email not sent.';
    ELSE
    BEGIN
        EXEC msdb.dbo.sp_send_dbmail
             @profile_name    = @MailProfile,
             @recipients      = @Recipients,
             @copy_recipients = @CopyRecipients,
             @subject         = @subject,
             @body            = @html,
             @body_format     = 'HTML',
             @importance      = @importance;
        PRINT N'Health check email queued to ' + @Recipients + N' (' + CAST(@crit AS nvarchar(10)) + N' critical, ' + CAST(@warn AS nvarchar(10)) + N' warnings).';
        -- Delivery status: SELECT TOP (5) mailitem_id, subject, sent_status, sent_date FROM msdb.dbo.sysmail_allitems ORDER BY mailitem_id DESC;
    END;
END
ELSE
    PRINT N'@SendEmail = 0 - report built (' + CAST(LEN(@html) AS nvarchar(20)) + N' chars), not sent. SELECT @html to preview.';
-- Preview the HTML in SSMS: uncomment, copy the cell into a .html file and open it in a browser.
-- SELECT @html AS html_report;
