/*******************************************************************************
 File    : HC_Snapshot.sql   (automation/pre-post-check)
 Purpose : Data-only version of scripts/44_health_check_report_email.sql for
           PRE / POST change comparison. Collects the same health check plus
           config, trace flags, all jobs, logins, server roles, linked servers,
           endpoints, certificates and XE sessions, and returns one result set
           per section (first column = _section). No email, no objects created.
           Invoke-PrePostCheck.ps1 runs it, stores the results on the VM as
           JSON, compares PRE vs POST and emails the outcome.
 Tags    : [BOX] 2016 SP2 - 2025 / Azure VM   [MI] (services/disks skipped)
 Note    : Can also be run on its own in SSMS to see every section as a grid.
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

SELECT N'jobs' AS _section, j.name, CAST(j.enabled AS nvarchar(5)) AS enabled, SUSER_SNAME(j.owner_sid) AS owner,
       c.name AS category,
       CASE js.last_run_outcome WHEN 0 THEN N'Failed' WHEN 1 THEN N'Succeeded' WHEN 3 THEN N'Canceled' ELSE N'Unknown' END AS last_outcome,
       CASE WHEN js.last_run_date > 0 THEN CONVERT(nvarchar(16), msdb.dbo.agent_datetime(js.last_run_date, js.last_run_time), 120) END AS last_run
FROM msdb.dbo.sysjobs AS j
LEFT JOIN msdb.dbo.sysjobservers AS js ON js.job_id = j.job_id
LEFT JOIN msdb.dbo.syscategories AS c ON c.category_id = j.category_id
ORDER BY j.name;

SELECT N'logins' AS _section, name, type_desc AS type, CAST(is_disabled AS nvarchar(5)) AS is_disabled, ISNULL(default_database_name, N'') AS default_database
FROM sys.server_principals
WHERE type IN ('S', 'U', 'G', 'E', 'X') AND name NOT LIKE N'##%'
ORDER BY name;

SELECT N'server_roles' AS _section, r.name AS role, m.name AS member
FROM sys.server_role_members AS rm
JOIN sys.server_principals AS r ON r.principal_id = rm.role_principal_id
JOIN sys.server_principals AS m ON m.principal_id = rm.member_principal_id
ORDER BY r.name, m.name;

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

SELECT N'issues' AS _section, severity, area, item, ISNULL(detail, N'') AS detail
FROM #issues ORDER BY CASE severity WHEN 'CRITICAL' THEN 0 ELSE 1 END, area, item;
