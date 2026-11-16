/*******************************************************************************
 File    : HC_Snapshot.sql   (automation/pre-post-check-v2)
 Purpose : Data-only version of scripts/44_health_check_report_email.sql for
           PRE / POST change comparison. Collects the same health check plus
           config, trace flags, linked servers,
           endpoints, certificates, XE sessions, SSIS catalog (SSISDB) and SSRS
           report server databases, and returns one result set
           per section (first column = _section). No email, no objects created.
           Invoke-PrePostCheck.ps1 runs it, stores the results on the VM as
           JSON, compares PRE vs POST and emails the outcome.
 Tags    : [BOX] 2016 SP2 - 2025 / Azure VM   [MI] (services/disks skipped)
 Note    : Can also be run on its own in SSMS to see every section as a grid
           (run the part above the first --##PERF marker).
 PERF    : The --##PERF_* blocks at the end are run separately by the script
           during the HEALTH performance window (sampled every N seconds).
*******************************************************************************/
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
             WHERE b.database_name = d.name AND b.type = 'D' AND b.is_copy_only = 0 ORDER BY b.backup_finish_date DESC) AS bf
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
  OUTPUT - one result set per section. First column _section = section name.
  Every value is returned as text so PRE / POST compare exactly.
=============================================================================*/
-- instance (property_code is the comparison key)
SELECT N'instance' AS _section, v.property_code, v.property, v.value
FROM sys.dm_os_sys_info AS i
CROSS APPLY (VALUES
    (N'server_name', N'Server name',            CAST(@@SERVERNAME AS nvarchar(4000))),
    (N'node',        N'Machine / active node',  CAST(SERVERPROPERTY('ComputerNamePhysicalNetBIOS') AS nvarchar(4000))),
    (N'edition',     N'Edition',                CAST(SERVERPROPERTY('Edition') AS nvarchar(4000))),
    (N'build',       N'Build',                  CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(4000))),
    (N'sp_level',    N'Product level',          CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(4000))),
    (N'cu',          N'Cumulative update',      CAST(SERVERPROPERTY('ProductUpdateLevel') AS nvarchar(4000))),
    (N'kb',          N'KB',                     CAST(SERVERPROPERTY('ProductUpdateReference') AS nvarchar(4000))),
    (N'collation',   N'Collation',              CAST(SERVERPROPERTY('Collation') AS nvarchar(4000))),
    (N'is_fci',      N'Failover cluster (FCI)', CAST(SERVERPROPERTY('IsClustered') AS nvarchar(4000))),
    (N'is_hadr',     N'Always On enabled',      CAST(SERVERPROPERTY('IsHadrEnabled') AS nvarchar(4000))),
    (N'start_time',  N'SQL started',            CONVERT(nvarchar(19), i.sqlserver_start_time, 120)),
    (N'sql_uptime',  N'SQL Server uptime',      CAST(DATEDIFF(SECOND, i.sqlserver_start_time, GETDATE()) / 86400 AS nvarchar(10)) + N'd '
                                                + RIGHT(N'0' + CAST(DATEDIFF(SECOND, i.sqlserver_start_time, GETDATE()) % 86400 / 3600 AS nvarchar(2)), 2) + N'h '
                                                + RIGHT(N'0' + CAST(DATEDIFF(SECOND, i.sqlserver_start_time, GETDATE()) % 3600 / 60 AS nvarchar(2)), 2) + N'm'),
    (N'os_boot_time',N'Windows started',        CONVERT(nvarchar(16), DATEADD(SECOND, -CAST(i.ms_ticks / 1000 AS int), GETDATE()), 120)),
    (N'os_uptime',   N'Windows uptime',         CAST(i.ms_ticks / 1000 / 86400 AS nvarchar(10)) + N'd '
                                                + RIGHT(N'0' + CAST(i.ms_ticks / 1000 % 86400 / 3600 AS nvarchar(2)), 2) + N'h '
                                                + RIGHT(N'0' + CAST(i.ms_ticks / 1000 % 3600 / 60 AS nvarchar(2)), 2) + N'm'),
    (N'cpu_count',   N'Logical CPUs',           CAST(i.cpu_count AS nvarchar(20))),
    (N'schedulers',  N'Schedulers',             CAST(i.scheduler_count AS nvarchar(20))),
    (N'memory_mb',   N'Physical memory (MB)',   CAST(i.physical_memory_kb / 1024 AS nvarchar(20))),
    (N'memory_model',N'Memory model',           CAST(i.sql_memory_model_desc AS nvarchar(4000)))
) AS v(property_code, property, value);

SELECT N'services' AS _section, servicename, status_desc AS status, startup_type_desc AS startup_type,
       service_account, ifi, CONVERT(nvarchar(19), last_startup_time, 120) AS last_startup
FROM #svc ORDER BY servicename;

SELECT N'vitals' AS _section, metric, value, status FROM #vitals ORDER BY seq;

SELECT N'config' AS _section, name, CAST(value_in_use AS nvarchar(100)) AS value_in_use
FROM sys.configurations ORDER BY name;

SELECT N'traceflags' AS _section, CAST(TraceFlag AS nvarchar(10)) AS trace_flag, CAST(Global AS nvarchar(5)) AS global
FROM #tf WHERE Global = 1 ORDER BY TraceFlag;

SELECT N'databases' AS _section, d.name, d.state_desc AS state, d.user_access_desc AS user_access,
       d.recovery_model_desc AS recovery_model, CAST(d.compatibility_level AS nvarchar(5)) AS compat_level,
       d.owner_name, CAST(sd.is_read_only AS nvarchar(5)) AS is_read_only, sd.page_verify_option_desc AS page_verify,
       CAST(sd.is_read_committed_snapshot_on AS nvarchar(5)) AS rcsi, sd.snapshot_isolation_state_desc AS snapshot_isolation,
       CAST(sd.is_encrypted AS nvarchar(5)) AS is_encrypted, CAST(sd.is_broker_enabled AS nvarchar(5)) AS broker,
       CAST(sd.is_trustworthy_on AS nvarchar(5)) AS trustworthy, CAST(sd.is_query_store_on AS nvarchar(5)) AS query_store,
       ISNULL(d.ag_name, N'') AS ag_name, d.ag_role, ISNULL(d.ag_sync_state, N'') AS ag_sync_state,
       CAST(d.size_mb AS nvarchar(30)) AS size_mb, CAST(d.log_used_pct AS nvarchar(10)) AS log_used_pct, d.log_reuse_wait_desc AS log_reuse_wait,
       CONVERT(nvarchar(16), d.last_full, 120) AS last_full,
       CASE WHEN CHARINDEX(N'\', REPLACE(d.last_full_path, N'/', N'\')) > 0
            THEN LEFT(REPLACE(d.last_full_path, N'/', N'\'), LEN(REPLACE(d.last_full_path, N'/', N'\')) - CHARINDEX(N'\', REVERSE(REPLACE(d.last_full_path, N'/', N'\'))))
            ELSE d.last_full_path END AS last_full_folder,
       CONVERT(nvarchar(16), d.last_diff, 120) AS last_diff,
       CONVERT(nvarchar(16), d.last_log, 120) AS last_log,
       CASE WHEN CHARINDEX(N'\', REPLACE(d.last_log_path, N'/', N'\')) > 0
            THEN LEFT(REPLACE(d.last_log_path, N'/', N'\'), LEN(REPLACE(d.last_log_path, N'/', N'\')) - CHARINDEX(N'\', REVERSE(REPLACE(d.last_log_path, N'/', N'\'))))
            ELSE d.last_log_path END AS last_log_folder,
       CONVERT(nvarchar(16), NULLIF(d.last_checkdb, '19000101'), 120) AS last_checkdb,
       d.status, d.notes
FROM #db AS d
JOIN sys.databases AS sd ON sd.database_id = d.database_id
ORDER BY d.database_id;

SELECT N'ag_replicas' AS _section, ag_name, replica_node, ISNULL(primary_replica, N'') AS primary_replica, ISNULL(role_desc, N'') AS role,
       availability_mode_desc AS availability_mode, failover_mode_desc AS failover_mode,
       ISNULL(connected_state_desc, N'') AS connected_state, ISNULL(synchronization_health_desc, N'') AS sync_health,
       secondary_role_allow_connections_desc AS readable, ISNULL(endpoint_url, N'') AS endpoint_url,
       CAST(backup_priority AS nvarchar(5)) AS backup_priority, ISNULL(listeners, N'') AS listeners, status
FROM #agr ORDER BY ag_name, replica_node;

-- Listener IPs: static or DHCP, subnet, IP resource state (DNN listeners are not listed here)
SELECT N'ag_listeners' AS _section, ag.name AS ag_name, l.dns_name AS listener, CAST(l.port AS nvarchar(10)) AS port,
       ISNULL(ip.ip_address, N'') AS ip_address, ISNULL(ip.ip_subnet_mask, N'') AS subnet_mask,
       CASE ip.is_dhcp WHEN 1 THEN N'DHCP' WHEN 0 THEN N'Static' ELSE N'' END AS ip_type,
       ISNULL(ip.network_subnet_ip + N'/' + CAST(ip.network_subnet_prefix_length AS nvarchar(5)), N'') AS network_subnet,
       ISNULL(ip.state_desc, N'') AS ip_state, CAST(l.is_conformant AS nvarchar(5)) AS is_conformant
FROM sys.availability_group_listeners AS l
JOIN sys.availability_groups AS ag ON ag.group_id = l.group_id
LEFT JOIN sys.availability_group_listener_ip_addresses AS ip ON ip.listener_id = l.listener_id
ORDER BY ag.name, l.dns_name, ip.ip_address;

SELECT N'ag_databases' AS _section, ag_name, database_name, replica_node, role,
       synchronization_state_desc AS sync_state, synchronization_health_desc AS sync_health,
       CAST(is_suspended AS nvarchar(5)) AS is_suspended,
       CAST(send_queue_kb AS nvarchar(30)) AS send_queue_kb, CAST(redo_queue_kb AS nvarchar(30)) AS redo_queue_kb, status
FROM #agdb ORDER BY ag_name, database_name, replica_node;

SELECT N'cluster' AS _section, member_name, cluster_name, quorum_type_desc AS quorum_type, quorum_state_desc AS quorum_state,
       member_type_desc AS member_type, member_state_desc AS member_state, CAST(number_of_quorum_votes AS nvarchar(5)) AS votes, status
FROM #cluster ORDER BY member_name;

SELECT N'disks' AS _section, volume, ISNULL(label, N'') AS label, CAST(total_gb AS nvarchar(30)) AS total_gb,
       CAST(free_gb AS nvarchar(30)) AS free_gb, CAST(free_pct AS nvarchar(10)) AS free_pct, status
FROM #disk ORDER BY volume;

SELECT N'files' AS _section, database_name, logical_name, type_desc AS type, physical_name, state_desc AS state,
       CAST(size_mb AS nvarchar(30)) AS size_mb, CAST(used_mb AS nvarchar(30)) AS used_mb, growth, max_size, status
FROM #files ORDER BY database_name, logical_name;

SELECT N'linked_servers' AS _section, name, ISNULL(product, N'') AS product, ISNULL(provider, N'') AS provider, ISNULL(data_source, N'') AS data_source
FROM sys.servers WHERE is_linked = 1 ORDER BY name;

SELECT N'endpoints' AS _section, e.name, e.type_desc AS type, e.state_desc AS state, ISNULL(CAST(t.port AS nvarchar(10)), N'') AS port
FROM sys.endpoints AS e LEFT JOIN sys.tcp_endpoints AS t ON t.endpoint_id = e.endpoint_id
WHERE e.endpoint_id > 5
ORDER BY e.name;

SELECT N'certificates' AS _section, name, CONVERT(nvarchar(100), thumbprint, 1) AS thumbprint, CONVERT(nvarchar(10), expiry_date, 120) AS expiry
FROM master.sys.certificates WHERE name NOT LIKE N'##%' ORDER BY name;

SELECT N'xe_sessions' AS _section, s.name, CASE WHEN r.name IS NULL THEN N'0' ELSE N'1' END AS running
FROM sys.server_event_sessions AS s LEFT JOIN sys.dm_xe_sessions AS r ON r.name = s.name
ORDER BY s.name;

SELECT N'job_failures' AS _section, job_name, CONVERT(nvarchar(16), run_time, 120) AS run_time,
       CAST(step_id AS nvarchar(5)) + N' ' + step_name AS step, message
FROM #jobs ORDER BY run_time DESC;

SELECT TOP (50) N'errorlog' AS _section, CONVERT(nvarchar(19), LogDate, 120) AS log_time, ProcessInfo AS source, message
FROM #errlog ORDER BY LogDate DESC;

SELECT N'ssis_catalog' AS _section, property_name, ISNULL(property_value, N'') AS property_value FROM #ssis_cat ORDER BY property_name;

SELECT N'ssis_projects' AS _section, folder, project, CAST(packages AS nvarchar(10)) AS packages,
       CAST(object_version_lsn AS nvarchar(30)) AS object_version_lsn, ISNULL(last_deployed, N'') AS last_deployed, ISNULL(deployed_by, N'') AS deployed_by
FROM #ssis_proj ORDER BY folder, project;

SELECT N'ssis_environments' AS _section, folder, environment, CAST(variables AS nvarchar(10)) AS variables
FROM #ssis_env ORDER BY folder, environment;

SELECT N'ssis_failures' AS _section, CAST(execution_id AS nvarchar(30)) AS execution_id, ISNULL(folder, N'') AS folder, ISNULL(project, N'') AS project,
       ISNULL(package, N'') AS package, ISNULL(start_time, N'') AS start_time, ISNULL(status, N'') AS status
FROM #ssis_fail ORDER BY execution_id DESC;

SELECT N'ssrs_summary' AS _section, rs_database, CAST(folders AS nvarchar(10)) AS folders, CAST(reports AS nvarchar(10)) AS reports,
       CAST(datasources AS nvarchar(10)) AS datasources, CAST(datasets AS nvarchar(10)) AS datasets, CAST(other_items AS nvarchar(10)) AS other_items,
       CAST(subscriptions AS nvarchar(10)) AS subscriptions, CAST(failing_subscriptions AS nvarchar(10)) AS failing_subscriptions,
       CAST(schedules AS nvarchar(10)) AS schedules, CAST(failed_executions AS nvarchar(10)) AS failed_executions
FROM #ssrs_sum ORDER BY rs_database;

SELECT N'ssrs_subscriptions' AS _section, rs_database, subscription_id, ISNULL(report_path, N'') AS report_path, ISNULL(owner, N'') AS owner,
       ISNULL(description, N'') AS description, CAST(ISNULL(inactive_flags, 0) AS nvarchar(10)) AS inactive_flags,
       ISNULL(last_status, N'') AS last_status, ISNULL(last_run, N'') AS last_run, CAST(is_failing AS nvarchar(5)) AS is_failing
FROM #ssrs_sub ORDER BY rs_database, report_path;

SELECT N'issues' AS _section, severity, area, item, ISNULL(detail, N'') AS detail
FROM #issues ORDER BY CASE severity WHEN 'CRITICAL' THEN 0 ELSE 1 END, area, item;


/*******************************************************************************
 PERFORMANCE WINDOW (HEALTH only) - each block below is run separately by
 Invoke-PrePostCheck.ps1. Tokens {{...}} are replaced by the script from $Config.
   PERF_START    : sets 'blocked process threshold' and starts XE session
                   DBA_PerfWindow (blocked process reports, deadlocks, queries
                   longer than {{LONG_SEC}} s). Needs ALTER SETTINGS / ALTER ANY
                   EVENT SESSION; without them it carries on read-only.
   PERF_SAMPLE   : one sample (counters, waits, file I/O, sessions, blocking,
                   tempdb, Always On, listener connections). Deltas per interval
                   are calculated by the script.
   PERF_END      : blocked process reports, deadlocks, long queries (XE) and the
                   top queries of the window from the plan cache
                   (sys.dm_exec_query_stats at window start vs end - no Query Store).
   PERF_TEARDOWN : drops the XE session and restores the original threshold.
*******************************************************************************/
--##PERF_START
SET NOCOUNT ON;
DECLARE @orig int, @adv int, @thr bit = 0, @xe bit = 0, @msg nvarchar(2000) = N'';
SELECT @orig = CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'blocked process threshold (s)';
SELECT @adv  = CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'show advanced options';
IF HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER SETTINGS') = 1
BEGIN
    BEGIN TRY
        IF @orig <> {{BPT_SEC}}
        BEGIN
            IF @adv = 0 BEGIN EXEC sys.sp_configure N'show advanced options', 1; RECONFIGURE; END;
            EXEC sys.sp_configure N'blocked process threshold (s)', {{BPT_SEC}}; RECONFIGURE;
            IF @adv = 0 BEGIN EXEC sys.sp_configure N'show advanced options', 0; RECONFIGURE; END;
        END;
        SET @thr = 1;
    END TRY
    BEGIN CATCH SET @msg += N'Threshold not changed: ' + ERROR_MESSAGE() + N' '; END CATCH;
END
ELSE SET @msg += N'No ALTER SETTINGS permission - blocked process threshold not changed. ';

IF HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER ANY EVENT SESSION') = 1
BEGIN
    BEGIN TRY
        IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'DBA_PerfWindow')
            DROP EVENT SESSION DBA_PerfWindow ON SERVER;
        EXEC (N'CREATE EVENT SESSION DBA_PerfWindow ON SERVER
ADD EVENT sqlserver.blocked_process_report,
ADD EVENT sqlserver.xml_deadlock_report,
ADD EVENT sqlserver.rpc_completed (
    ACTION (sqlserver.database_name, sqlserver.client_app_name, sqlserver.client_hostname, sqlserver.username)
    WHERE duration > {{LONG_US}}),
ADD EVENT sqlserver.sql_batch_completed (
    ACTION (sqlserver.database_name, sqlserver.client_app_name, sqlserver.client_hostname, sqlserver.username)
    WHERE duration > {{LONG_US}})
ADD TARGET package0.ring_buffer (SET max_memory = 8192, max_events_limit = 2000)
WITH (MAX_DISPATCH_LATENCY = 5 SECONDS, EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS, STARTUP_STATE = OFF);');
        ALTER EVENT SESSION DBA_PerfWindow ON SERVER STATE = START;
        SET @xe = 1;
    END TRY
    BEGIN CATCH SET @msg += N'XE session not started: ' + ERROR_MESSAGE() + N' '; END CATCH;
END
ELSE SET @msg += N'No ALTER ANY EVENT SESSION permission - blocked process reports, deadlocks and long queries come from DMVs only. ';

-- Plan cache baseline for the window's top queries (session #temp table, compared at PERF_END)
IF OBJECT_ID('tempdb..#qstart') IS NOT NULL DROP TABLE #qstart;
CREATE TABLE #qstart (query_hash binary(8) PRIMARY KEY, ec bigint, el bigint, cpu bigint, rd bigint);
IF {{TOPQ}} = 1
    INSERT #qstart (query_hash, ec, el, cpu, rd)
    SELECT query_hash, SUM(execution_count), SUM(total_elapsed_time), SUM(total_worker_time), SUM(total_logical_reads)
    FROM sys.dm_exec_query_stats WHERE query_hash IS NOT NULL GROUP BY query_hash;

SELECT N'perf_setup' AS _section, CAST(@orig AS nvarchar(10)) AS orig_threshold, CAST(@thr AS nvarchar(1)) AS threshold_set,
       CAST(@xe AS nvarchar(1)) AS xe_started, CONVERT(nvarchar(40), SYSDATETIMEOFFSET(), 127) AS start_time, @msg AS message;

--##PERF_SAMPLE
SET NOCOUNT ON;
SELECT N'sample' AS _section, CONVERT(nvarchar(23), SYSDATETIME(), 121) AS sample_time;

SELECT N'pc' AS _section,
       SUBSTRING(RTRIM(object_name), CHARINDEX(N':', object_name) + 1, 128) AS obj,
       RTRIM(counter_name) AS ctr, RTRIM(instance_name) AS inst, CAST(cntr_value AS nvarchar(30)) AS val
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

SELECT N'waits' AS _section, grp, CAST(SUM(wait_time_ms) AS nvarchar(30)) AS wait_ms, CAST(SUM(waiting_tasks_count) AS nvarchar(30)) AS tasks
FROM (SELECT CASE WHEN wait_type LIKE N'LCK[_]M[_]%'      THEN N'LCK_M_*'
                  WHEN wait_type LIKE N'PAGEIOLATCH[_]%'  THEN N'PAGEIOLATCH_*'
                  WHEN wait_type LIKE N'PAGELATCH[_]%'    THEN N'PAGELATCH_*'
                  WHEN wait_type IN (N'WRITELOG', N'CXPACKET', N'CXCONSUMER', N'SOS_SCHEDULER_YIELD', N'HADR_SYNC_COMMIT', N'RESOURCE_SEMAPHORE') THEN wait_type
             END AS grp, wait_time_ms, waiting_tasks_count
      FROM sys.dm_os_wait_stats) AS w
WHERE grp IS NOT NULL
GROUP BY grp;

SELECT N'io' AS _section, DB_NAME(vfs.database_id) AS db, CASE WHEN mf.type = 1 THEN N'LOG' ELSE N'DATA' END AS ftype,
       CAST(SUM(vfs.num_of_reads) AS nvarchar(30)) AS reads, CAST(SUM(vfs.io_stall_read_ms) AS nvarchar(30)) AS read_stall_ms,
       CAST(SUM(vfs.num_of_writes) AS nvarchar(30)) AS writes, CAST(SUM(vfs.io_stall_write_ms) AS nvarchar(30)) AS write_stall_ms
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
JOIN sys.master_files AS mf ON mf.database_id = vfs.database_id AND mf.file_id = vfs.file_id
GROUP BY vfs.database_id, CASE WHEN mf.type = 1 THEN N'LOG' ELSE N'DATA' END;

SELECT N'sessions' AS _section, ISNULL(s.program_name, N'') AS program, ISNULL(s.host_name, N'') AS host, s.login_name AS login,
       CAST(COUNT(*) AS nvarchar(10)) AS sessions, CAST(SUM(CASE WHEN r.session_id IS NULL THEN 0 ELSE 1 END) AS nvarchar(10)) AS active
FROM sys.dm_exec_sessions AS s
LEFT JOIN sys.dm_exec_requests AS r ON r.session_id = s.session_id
WHERE s.is_user_process = 1
GROUP BY s.program_name, s.host_name, s.login_name;

SELECT N'blocking' AS _section, CAST(COUNT(*) AS nvarchar(10)) AS blocked, CAST(ISNULL(MAX(wait_time), 0) AS nvarchar(20)) AS max_wait_ms
FROM sys.dm_exec_requests WHERE blocking_session_id > 0 AND wait_time >= {{BPT_SEC}} * 1000;

SELECT TOP (5) N'blocked_now' AS _section, CONVERT(nvarchar(19), GETDATE(), 120) AS seen_at, CAST(r.session_id AS nvarchar(10)) AS session_id,
       CAST(r.blocking_session_id AS nvarchar(10)) AS blocked_by, r.wait_type, CAST(r.wait_time / 1000 AS nvarchar(20)) AS wait_s,
       ISNULL(DB_NAME(r.database_id), N'') AS db, ISNULL(LEFT(t.text, 200), N'') AS sql_text
FROM sys.dm_exec_requests AS r
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE r.blocking_session_id > 0 AND r.wait_time >= {{BPT_SEC}} * 1000
ORDER BY r.wait_time DESC;

SELECT N'tempdb' AS _section,
       CAST(CAST(SUM(user_object_reserved_page_count)     * 8 / 1024.0 AS decimal(18, 1)) AS nvarchar(30)) AS user_mb,
       CAST(CAST(SUM(internal_object_reserved_page_count) * 8 / 1024.0 AS decimal(18, 1)) AS nvarchar(30)) AS internal_mb,
       CAST(CAST(SUM(version_store_reserved_page_count)   * 8 / 1024.0 AS decimal(18, 1)) AS nvarchar(30)) AS version_mb,
       CAST(CAST(SUM(unallocated_extent_page_count)       * 8 / 1024.0 AS decimal(18, 1)) AS nvarchar(30)) AS free_mb,
       CAST((SELECT COUNT(*) FROM sys.dm_os_waiting_tasks WHERE wait_type LIKE N'PAGELATCH[_]%' AND resource_description LIKE N'2:%') AS nvarchar(10)) AS alloc_waiters
FROM tempdb.sys.dm_db_file_space_usage;

IF CAST(SERVERPROPERTY('IsHadrEnabled') AS int) = 1
BEGIN
    SELECT N'ag' AS _section, ag.name AS ag_name, adc.database_name AS db, ar.replica_server_name AS replica,
           ISNULL(drs.synchronization_state_desc, N'') AS sync_state,
           CAST(ISNULL(drs.log_send_queue_size, 0) AS nvarchar(20)) AS send_queue_kb,
           CAST(ISNULL(drs.redo_queue_size, 0) AS nvarchar(20)) AS redo_queue_kb
    FROM sys.dm_hadr_database_replica_states AS drs
    JOIN sys.availability_replicas AS ar ON ar.replica_id = drs.replica_id
    JOIN sys.availability_groups AS ag ON ag.group_id = drs.group_id
    JOIN sys.availability_databases_cluster AS adc ON adc.group_database_id = drs.group_database_id;

    SELECT N'listener' AS _section, l.dns_name AS listener, ip.ip_address, CAST(COUNT(c.session_id) AS nvarchar(10)) AS connections
    FROM sys.availability_group_listeners AS l
    JOIN sys.availability_group_listener_ip_addresses AS ip ON ip.listener_id = l.listener_id
    LEFT JOIN sys.dm_exec_connections AS c ON c.local_net_address = ip.ip_address AND c.local_tcp_port = l.port
    GROUP BY l.dns_name, ip.ip_address;
END;

--##PERF_END
SET NOCOUNT ON;
DECLARE @s datetimeoffset = CAST(N'{{START}}' AS datetimeoffset), @e datetimeoffset = SYSDATETIMEOFFSET();

-- Extended Events (blocked process reports, deadlocks, queries > {{LONG_SEC}} s)
IF OBJECT_ID('tempdb..#xe') IS NOT NULL DROP TABLE #xe;
CREATE TABLE #xe (ev xml);
IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'DBA_PerfWindow')
BEGIN
    DECLARE @x xml;
    SELECT @x = CAST(t.target_data AS xml)
    FROM sys.dm_xe_session_targets AS t
    JOIN sys.dm_xe_sessions AS se ON se.address = t.event_session_address
    WHERE se.name = N'DBA_PerfWindow' AND t.target_name = N'ring_buffer';
    INSERT #xe (ev) SELECT n.query('.') FROM @x.nodes('/RingBufferTarget/event') AS q(n);
END;

SELECT TOP (50) N'xe_blocked' AS _section,
       CONVERT(nvarchar(19), DATEADD(MINUTE, DATEDIFF(MINUTE, GETUTCDATE(), GETDATE()), ev.value('(event/@timestamp)[1]', 'datetime2')), 120) AS event_time,
       CAST(ev.value('(event/data[@name="duration"]/value)[1]', 'bigint') / 1000000 AS nvarchar(20)) AS blocked_s,
       ISNULL(ev.value('(event/data[@name="database_name"]/value)[1]', 'nvarchar(128)'), N'') AS db,
       ISNULL(ev.value('(event/data[@name="blocked_process"]/value/blocked-process-report/blocked-process/process/@spid)[1]', 'nvarchar(10)'), N'') AS blocked_spid,
       ISNULL(ev.value('(event/data[@name="blocked_process"]/value/blocked-process-report/blocking-process/process/@spid)[1]', 'nvarchar(10)'), N'') AS blocking_spid,
       ISNULL(LEFT(LTRIM(ev.value('(event/data[@name="blocked_process"]/value/blocked-process-report/blocked-process/process/inputbuf)[1]', 'nvarchar(max)')), 200), N'') AS blocked_sql,
       ISNULL(LEFT(LTRIM(ev.value('(event/data[@name="blocked_process"]/value/blocked-process-report/blocking-process/process/inputbuf)[1]', 'nvarchar(max)')), 200), N'') AS blocking_sql
FROM #xe WHERE ev.value('(event/@name)[1]', 'nvarchar(60)') = N'blocked_process_report'
ORDER BY ev.value('(event/data[@name="duration"]/value)[1]', 'bigint') DESC;

SELECT N'xe_deadlocks' AS _section,
       CONVERT(nvarchar(19), DATEADD(MINUTE, DATEDIFF(MINUTE, GETUTCDATE(), GETDATE()), ev.value('(event/@timestamp)[1]', 'datetime2')), 120) AS event_time,
       CAST(ev.value('count(event/data[@name="xml_report"]/value/deadlock/process-list/process)', 'int') AS nvarchar(10)) AS processes,
       ISNULL(ev.value('(event/data[@name="xml_report"]/value/deadlock/victim-list/victimProcess/@id)[1]', 'nvarchar(50)'), N'') AS victim,
       ISNULL(ev.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process/@currentdbname)[1]', 'nvarchar(128)'), N'') AS db,
       ISNULL(LEFT(LTRIM(ev.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process/inputbuf)[1]', 'nvarchar(max)')), 200), N'') AS sql_text
FROM #xe WHERE ev.value('(event/@name)[1]', 'nvarchar(60)') = N'xml_deadlock_report'
ORDER BY event_time;

SELECT TOP (200) N'xe_long' AS _section,
       CONVERT(nvarchar(19), DATEADD(MINUTE, DATEDIFF(MINUTE, GETUTCDATE(), GETDATE()), ev.value('(event/@timestamp)[1]', 'datetime2')), 120) AS end_time,
       CAST(CAST(ev.value('(event/data[@name="duration"]/value)[1]', 'bigint') / 1000000.0 AS decimal(18, 1)) AS nvarchar(30)) AS duration_s,
       CAST(ev.value('(event/data[@name="cpu_time"]/value)[1]', 'bigint') / 1000 AS nvarchar(30)) AS cpu_ms,
       CAST(ev.value('(event/data[@name="logical_reads"]/value)[1]', 'bigint') AS nvarchar(30)) AS logical_reads,
       ISNULL(ev.value('(event/action[@name="database_name"]/value)[1]', 'nvarchar(128)'), N'') AS db,
       ISNULL(ev.value('(event/action[@name="client_app_name"]/value)[1]', 'nvarchar(128)'), N'') AS app,
       ISNULL(ev.value('(event/action[@name="client_hostname"]/value)[1]', 'nvarchar(128)'), N'') AS host,
       ISNULL(ev.value('(event/action[@name="username"]/value)[1]', 'nvarchar(128)'), N'') AS login,
       ISNULL(LEFT(LTRIM(COALESCE(ev.value('(event/data[@name="statement"]/value)[1]', 'nvarchar(max)'),
                                  ev.value('(event/data[@name="batch_text"]/value)[1]', 'nvarchar(max)'))), 300), N'') AS sql_text
FROM #xe WHERE ev.value('(event/@name)[1]', 'nvarchar(60)') IN (N'rpc_completed', N'sql_batch_completed')
ORDER BY ev.value('(event/data[@name="duration"]/value)[1]', 'bigint') DESC;

-- Top queries of the window from the plan cache: sys.dm_exec_query_stats now minus the baseline taken at
-- PERF_START (#qstart, same connection), grouped by query_hash so the same query with different literals or
-- plans counts once. Not seen: plans evicted / recompiled during the window and OPTION (RECOMPILE) statements.
IF OBJECT_ID('tempdb..#qraw') IS NOT NULL DROP TABLE #qraw;
IF OBJECT_ID('tempdb..#qtop') IS NOT NULL DROP TABLE #qtop;
CREATE TABLE #qtop (query_hash binary(8), executions bigint, total_duration_ms decimal(19, 1), avg_duration_ms decimal(19, 1),
                    total_cpu_ms decimal(19, 1), total_logical_reads bigint, sql_handle varbinary(64), plan_handle varbinary(64),
                    stmt_start int, stmt_end int, rn_d int, rn_c int, rn_r int);
DECLARE @cached int = 0;
IF {{TOPQ}} = 1 AND OBJECT_ID('tempdb..#qstart') IS NOT NULL
BEGIN
    SELECT query_hash, sql_handle, plan_handle, statement_start_offset, statement_end_offset,
           execution_count, total_elapsed_time, total_worker_time, total_logical_reads,
           ROW_NUMBER() OVER (PARTITION BY query_hash ORDER BY total_elapsed_time DESC) AS rn
    INTO #qraw
    FROM sys.dm_exec_query_stats
    WHERE query_hash IS NOT NULL;
    SET @cached = @@ROWCOUNT;

    WITH e AS (
        SELECT query_hash, SUM(execution_count) AS ec, SUM(total_elapsed_time) AS el, SUM(total_worker_time) AS cpu, SUM(total_logical_reads) AS rd,
               MAX(CASE WHEN rn = 1 THEN sql_handle END) AS sh, MAX(CASE WHEN rn = 1 THEN plan_handle END) AS ph,
               MAX(CASE WHEN rn = 1 THEN statement_start_offset END) AS so, MAX(CASE WHEN rn = 1 THEN statement_end_offset END) AS eo
        FROM #qraw GROUP BY query_hash),
    d AS (   -- delta; if the plan was recompiled / re-cached (counters went down) use the current values
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
              (CASE WHEN q.stmt_end = -1 THEN DATALENGTH(t.text) ELSE q.stmt_end END - q.stmt_start) / 2 + 1)), 300), N'') AS query_text,
       ISNULL(OBJECT_NAME(t.objectid, t.dbid), N'') AS object_name
INTO #qtx
FROM #qtop AS q
OUTER APPLY sys.dm_exec_sql_text(q.sql_handle) AS t
OUTER APPLY (SELECT value FROM sys.dm_exec_plan_attributes(q.plan_handle) WHERE attribute = N'dbid') AS pa;

SELECT N'topq_info' AS _section, CAST({{TOPQ}} AS nvarchar(1)) AS collected, CAST(@cached AS nvarchar(20)) AS plan_cache_entries;
SELECT TOP (20) N'top_duration' AS _section, db, object_name, CONVERT(nvarchar(20), query_hash, 1) AS query_hash, CAST(executions AS nvarchar(20)) AS executions,
       CAST(total_duration_ms AS nvarchar(30)) AS total_duration_ms, CAST(avg_duration_ms AS nvarchar(30)) AS avg_duration_ms,
       CAST(total_cpu_ms AS nvarchar(30)) AS total_cpu_ms, CAST(total_logical_reads AS nvarchar(30)) AS total_logical_reads, query_text
FROM #qtx WHERE rn_d <= 20 ORDER BY rn_d;
SELECT TOP (20) N'top_cpu' AS _section, db, object_name, CONVERT(nvarchar(20), query_hash, 1) AS query_hash, CAST(executions AS nvarchar(20)) AS executions,
       CAST(total_cpu_ms AS nvarchar(30)) AS total_cpu_ms, CAST(total_duration_ms AS nvarchar(30)) AS total_duration_ms,
       CAST(total_logical_reads AS nvarchar(30)) AS total_logical_reads, query_text
FROM #qtx WHERE rn_c <= 20 ORDER BY rn_c;
SELECT TOP (20) N'top_reads' AS _section, db, object_name, CONVERT(nvarchar(20), query_hash, 1) AS query_hash, CAST(executions AS nvarchar(20)) AS executions,
       CAST(total_logical_reads AS nvarchar(30)) AS total_logical_reads, CAST(total_duration_ms AS nvarchar(30)) AS total_duration_ms,
       CAST(total_cpu_ms AS nvarchar(30)) AS total_cpu_ms, query_text
FROM #qtx WHERE rn_r <= 20 ORDER BY rn_r;

--##PERF_TEARDOWN
SET NOCOUNT ON;
DECLARE @adv int, @msg nvarchar(2000) = N'';
BEGIN TRY
    IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'DBA_PerfWindow')
        DROP EVENT SESSION DBA_PerfWindow ON SERVER;
END TRY
BEGIN CATCH SET @msg += N'XE session not dropped: ' + ERROR_MESSAGE() + N' '; END CATCH;
IF {{RESTORE}} = 1
BEGIN
    BEGIN TRY
        IF (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'blocked process threshold (s)') <> {{ORIG}}
        BEGIN
            SELECT @adv = CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'show advanced options';
            IF @adv = 0 BEGIN EXEC sys.sp_configure N'show advanced options', 1; RECONFIGURE; END;
            EXEC sys.sp_configure N'blocked process threshold (s)', {{ORIG}}; RECONFIGURE;
            IF @adv = 0 BEGIN EXEC sys.sp_configure N'show advanced options', 0; RECONFIGURE; END;
        END;
    END TRY
    BEGIN CATCH SET @msg += N'Threshold not restored: ' + ERROR_MESSAGE() + N' '; END CATCH;
END;
IF OBJECT_ID('tempdb..#qstart') IS NOT NULL DROP TABLE #qstart;
SELECT N'perf_teardown' AS _section,
       (SELECT CAST(value_in_use AS nvarchar(10)) FROM sys.configurations WHERE name = N'blocked process threshold (s)') AS threshold_now, @msg AS message;
