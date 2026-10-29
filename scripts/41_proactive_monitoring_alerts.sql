/*******************************************************************************
 File    : 41_proactive_monitoring_alerts.sql
 Purpose : Catch problems BEFORE users / managers do: one problems-only
           health check, disk & database growth forecast, files that can't
           grow, SQL Agent alert setup (severity / corruption / AG), restart
           and configuration-change history, scheduled email template.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] Managed Instance (noted)
*******************************************************************************/

/*=============================================================================
  41.1 PROBLEMS-ONLY HEALTH CHECK (0 rows = all good)                 [BOX][MI]
  Run every morning / at shift handover / before you say "all fine".
=============================================================================*/
DECLARE @log_rpo_min     int = 30,     -- max minutes since last log backup (FULL recovery DBs)
        @full_max_days   int = 7,      -- max days since full (if no diff in last day)
        @checkdb_days    int = 7,
        @disk_free_pct   int = 15,
        @log_used_pct    int = 80,
        @tempdb_free_pct int = 20,
        @blocking_min    int = 5,
        @open_tran_min   int = 30,
        @cert_days       int = 30,
        @vlf_max         int = 1000;

DECLARE @issues TABLE (severity varchar(10), area varchar(30), item nvarchar(256), detail nvarchar(4000));
DECLARE @is_mi bit = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 8 THEN 1 ELSE 0 END;

-- Databases
INSERT @issues SELECT 'CRITICAL', 'Database', name, 'State: ' + state_desc + ' / ' + user_access_desc
FROM sys.databases WHERE state_desc NOT IN (N'ONLINE', N'RESTORING') OR user_access_desc <> N'MULTI_USER';

-- Recent restart
INSERT @issues SELECT 'WARNING', 'Instance', 'Restarted recently', 'Up since ' + CONVERT(varchar(20), sqlserver_start_time, 120)
FROM sys.dm_os_sys_info WHERE sqlserver_start_time > DATEADD(HOUR, -24, GETDATE());

-- Backups (AG-aware: skipped where another replica is the preferred backup replica)
INSERT @issues
SELECT 'CRITICAL', 'Backup', d.name,
       CASE WHEN f.last_full IS NULL THEN 'No full backup ever'
            WHEN d.recovery_model_desc <> 'SIMPLE' AND (l.last_log IS NULL OR l.last_log < DATEADD(MINUTE, -@log_rpo_min, GETDATE()))
                 THEN 'Last log backup: ' + ISNULL(CONVERT(varchar(20), l.last_log, 120), 'never') + ' (RPO ' + CAST(@log_rpo_min AS varchar(5)) + ' min)'
            ELSE 'Last full ' + CONVERT(varchar(20), f.last_full, 120) + ', no recent diff' END
FROM sys.databases AS d
OUTER APPLY (SELECT MAX(backup_finish_date) AS last_full FROM msdb.dbo.backupset WHERE database_name = d.name AND type = 'D') AS f
OUTER APPLY (SELECT MAX(backup_finish_date) AS last_diff FROM msdb.dbo.backupset WHERE database_name = d.name AND type = 'I') AS i
OUTER APPLY (SELECT MAX(backup_finish_date) AS last_log  FROM msdb.dbo.backupset WHERE database_name = d.name AND type = 'L') AS l
WHERE d.database_id <> 2 AND d.state_desc = N'ONLINE' AND d.source_database_id IS NULL AND d.is_in_standby = 0
  AND (d.replica_id IS NULL OR sys.fn_hadr_backup_is_preferred_replica(d.name) = 1)
  AND (   f.last_full IS NULL
       OR (f.last_full < DATEADD(DAY, -@full_max_days, GETDATE()) AND ISNULL(i.last_diff, '19000101') < DATEADD(DAY, -1, GETDATE()))
       OR (d.recovery_model_desc <> 'SIMPLE' AND d.database_id > 4
           AND (l.last_log IS NULL OR l.last_log < DATEADD(MINUTE, -@log_rpo_min, GETDATE()))));

-- CHECKDB
INSERT @issues SELECT 'WARNING', 'Integrity', name,
       'Last good CHECKDB: ' + ISNULL(CONVERT(varchar(20), CAST(DATABASEPROPERTYEX(name, 'LastGoodCheckDbTime') AS datetime), 120), 'never')
FROM sys.databases
WHERE database_id <> 2 AND state_desc = N'ONLINE'
  AND ISNULL(CAST(DATABASEPROPERTYEX(name, 'LastGoodCheckDbTime') AS datetime), '19000101') < DATEADD(DAY, -@checkdb_days, GETDATE());

INSERT @issues SELECT 'CRITICAL', 'Integrity', DB_NAME(database_id), 'Suspect page ' + CAST(file_id AS varchar(5)) + ':' + CAST(page_id AS varchar(20))
       + ' event_type ' + CAST(event_type AS varchar(3)) + ' at ' + CONVERT(varchar(20), last_update_date, 120)
FROM msdb.dbo.suspect_pages WHERE last_update_date > DATEADD(DAY, -30, GETDATE());

-- Always On
INSERT @issues SELECT 'CRITICAL', 'AlwaysOn', ag.name + ' / ' + ar.replica_server_name,
       ISNULL(ars.connected_state_desc, '?') + ' / ' + ISNULL(ars.synchronization_health_desc, '?') + ISNULL(' / ' + ars.last_connect_error_description, '')
FROM sys.availability_replicas ar
JOIN sys.availability_groups ag ON ag.group_id = ar.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id
WHERE ars.connected_state_desc <> 'CONNECTED' OR ars.synchronization_health_desc <> 'HEALTHY';

INSERT @issues SELECT 'CRITICAL', 'AlwaysOn', DB_NAME(drs.database_id) + ' on ' + ar.replica_server_name,
       drs.synchronization_state_desc + CASE WHEN drs.is_suspended = 1 THEN ' SUSPENDED (' + drs.suspend_reason_desc + ')' ELSE '' END
     + ' send_queue_kb=' + CAST(ISNULL(drs.log_send_queue_size, 0) AS varchar(20)) + ' redo_queue_kb=' + CAST(ISNULL(drs.redo_queue_size, 0) AS varchar(20))
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
WHERE drs.synchronization_health_desc <> 'HEALTHY' OR drs.is_suspended = 1;

-- Jobs failed in last 24h
INSERT @issues SELECT 'WARNING', 'Agent job', j.name, 'Failed at ' + CONVERT(varchar(20), msdb.dbo.agent_datetime(h.run_date, h.run_time), 120) + ': ' + LEFT(h.message, 300)
FROM msdb.dbo.sysjobhistory h JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
WHERE h.step_id = 0 AND h.run_status = 0
  AND msdb.dbo.agent_datetime(h.run_date, h.run_time) > DATEADD(HOUR, -24, GETDATE());

-- Agent service + disk space (not available on MI)
IF @is_mi = 0
BEGIN
    INSERT @issues EXEC (N'SELECT ''CRITICAL'', ''Service'', servicename, status_desc FROM sys.dm_server_services
                           WHERE servicename LIKE N''SQL Server Agent%'' AND status_desc <> N''Running''');
    DECLARE @disk_sql nvarchar(max) = N'SELECT CASE WHEN pct < 10 THEN ''CRITICAL'' ELSE ''WARNING'' END, ''Disk'', volume_mount_point,
                                  CAST(free_gb AS varchar(20)) + '' GB free ('' + CAST(pct AS varchar(10)) + ''%)''
                           FROM (SELECT DISTINCT vs.volume_mount_point,
                                        CAST(vs.available_bytes / 1073741824.0 AS decimal(18,1)) AS free_gb,
                                        CAST(100.0 * vs.available_bytes / vs.total_bytes AS decimal(5,1)) AS pct
                                 FROM sys.master_files mf CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs) v
                           WHERE pct < ' + CAST(@disk_free_pct AS nvarchar(5)) + N';';
    INSERT @issues EXEC (@disk_sql);
END;

-- Log usage
INSERT @issues SELECT CASE WHEN ls.active_log_size_mb * 100.0 / NULLIF(ls.total_log_size_mb, 0) > 90 THEN 'CRITICAL' ELSE 'WARNING' END,
       'Log space', d.name,
       CAST(CAST(ls.active_log_size_mb * 100.0 / NULLIF(ls.total_log_size_mb, 0) AS decimal(5,1)) AS varchar(10)) + '% used, reuse wait: ' + d.log_reuse_wait_desc
FROM sys.databases d CROSS APPLY sys.dm_db_log_stats(d.database_id) ls
WHERE d.state_desc = N'ONLINE' AND ls.active_log_size_mb * 100.0 / NULLIF(ls.total_log_size_mb, 0) > @log_used_pct;

-- VLFs
INSERT @issues SELECT 'WARNING', 'Log VLFs', d.name, CAST(ls.total_vlf_count AS varchar(10)) + ' VLFs (slow recovery / failover)'
FROM sys.databases d CROSS APPLY sys.dm_db_log_stats(d.database_id) ls
WHERE d.state_desc = N'ONLINE' AND ls.total_vlf_count > @vlf_max;

-- Files that cannot grow
INSERT @issues SELECT 'WARNING', 'File growth', DB_NAME(database_id) + '.' + name,
       CASE WHEN growth = 0 THEN 'Autogrowth disabled' ELSE 'At ' + CAST(CAST(100.0 * size / max_size AS decimal(5,1)) AS varchar(10)) + '% of max_size' END
FROM sys.master_files
WHERE database_id <> 2 AND (growth = 0 OR (max_size > 0 AND size >= 0.9 * max_size));

-- tempdb
INSERT @issues SELECT 'WARNING', 'tempdb', 'Free space',
       CAST(CAST(100.0 * SUM(unallocated_extent_page_count) / SUM(total_page_count) AS decimal(5,1)) AS varchar(10)) + '% free'
FROM tempdb.sys.dm_db_file_space_usage
HAVING 100.0 * SUM(unallocated_extent_page_count) / SUM(total_page_count) < @tempdb_free_pct;

-- Blocking & long transactions
INSERT @issues SELECT 'CRITICAL', 'Blocking', 'Session ' + CAST(r.session_id AS varchar(10)) + ' blocked by ' + CAST(r.blocking_session_id AS varchar(10)),
       CAST(r.wait_time / 60000 AS varchar(10)) + ' min, ' + ISNULL(r.wait_type, '') + ' on ' + ISNULL(DB_NAME(r.database_id), '')
FROM sys.dm_exec_requests r WHERE r.blocking_session_id > 0 AND r.wait_time > @blocking_min * 60000;

INSERT @issues SELECT 'WARNING', 'Open transaction', 'Session ' + CAST(st.session_id AS varchar(10)) + ' (' + s.login_name + ')',
       'Open since ' + CONVERT(varchar(20), at.transaction_begin_time, 120) + ' from ' + ISNULL(s.host_name, '') + ' / ' + ISNULL(s.program_name, '')
FROM sys.dm_tran_active_transactions at
JOIN sys.dm_tran_session_transactions st ON st.transaction_id = at.transaction_id
JOIN sys.dm_exec_sessions s ON s.session_id = st.session_id
WHERE at.transaction_begin_time < DATEADD(MINUTE, -@open_tran_min, GETDATE()) AND s.is_user_process = 1;

-- Memory
INSERT @issues SELECT 'WARNING', 'Memory', 'Memory Grants Pending', CAST(cntr_value AS varchar(10)) + ' queries waiting for memory'
FROM sys.dm_os_performance_counters WHERE counter_name = N'Memory Grants Pending' AND cntr_value > 0;

-- Certificates (TDE / backup / endpoints)
INSERT @issues SELECT 'WARNING', 'Certificate', c.name,
       'Expires ' + CONVERT(varchar(10), c.expiry_date, 120)
     + CASE WHEN c.pvt_key_last_backup_date IS NULL AND EXISTS (SELECT 1 FROM sys.dm_database_encryption_keys k WHERE k.encryptor_thumbprint = c.thumbprint)
            THEN ' | TDE cert PRIVATE KEY NEVER BACKED UP' ELSE '' END
FROM master.sys.certificates c
WHERE c.name NOT LIKE N'##%'
  AND (c.expiry_date < DATEADD(DAY, @cert_days, GETDATE())
       OR (c.pvt_key_last_backup_date IS NULL AND EXISTS (SELECT 1 FROM sys.dm_database_encryption_keys k WHERE k.encryptor_thumbprint = c.thumbprint)));

-- Severity >= 17 errors in the current error log
IF OBJECT_ID('tempdb..#sev') IS NOT NULL DROP TABLE #sev;
CREATE TABLE #sev (LogDate datetime, ProcessInfo nvarchar(50), [Text] nvarchar(max));
INSERT #sev EXEC sys.xp_readerrorlog 0, 1, N'Severity:';
INSERT @issues SELECT 'CRITICAL', 'Error log', 'Severity ' + CAST(sev AS varchar(3)) + ' errors (24h)',
       CAST(COUNT(*) AS varchar(10)) + 'x, last ' + CONVERT(varchar(20), MAX(LogDate), 120) + ': ' + MAX(LEFT([Text], 200))
FROM (SELECT LogDate, [Text], TRY_CAST(SUBSTRING([Text], CHARINDEX('Severity:', [Text]) + 10, 2) AS int) AS sev FROM #sev) x
WHERE sev >= 17 AND LogDate > DATEADD(HOUR, -24, GETDATE())
GROUP BY sev;

-- Database Mail
INSERT @issues SELECT 'WARNING', 'Database Mail', 'Failed mails (24h)', CAST(COUNT(*) AS varchar(10)) + ' not sent - alerts may not be reaching you'
FROM msdb.dbo.sysmail_allitems WHERE sent_status = 'failed' AND send_request_date > DATEADD(HOUR, -24, GETDATE())
HAVING COUNT(*) > 0;

SELECT severity, area, item, detail FROM @issues
ORDER BY CASE severity WHEN 'CRITICAL' THEN 0 ELSE 1 END, area, item;


/*=============================================================================
  41.2 GROWTH FORECAST - DAYS UNTIL DISK FULL                            [BOX]
  Growth rate from FULL backup sizes over the last 30 days (data only - log
  growth comes on top). Needs 2+ fulls per DB in the window.
=============================================================================*/
WITH fb AS (
    SELECT database_name, backup_finish_date, backup_size,
           ROW_NUMBER() OVER (PARTITION BY database_name ORDER BY backup_finish_date)      AS rn_first,
           ROW_NUMBER() OVER (PARTITION BY database_name ORDER BY backup_finish_date DESC) AS rn_last
    FROM msdb.dbo.backupset
    WHERE type = 'D' AND is_copy_only = 0 AND backup_finish_date >= DATEADD(DAY, -30, GETDATE())
),
gr AS (
    SELECT f.database_name,
           (l.backup_size - f.backup_size) / 1048576.0 / NULLIF(DATEDIFF(DAY, f.backup_finish_date, l.backup_finish_date), 0) AS mb_per_day
    FROM fb f JOIN fb l ON l.database_name = f.database_name AND l.rn_last = 1
    WHERE f.rn_first = 1
),
dv AS (   -- which volumes hold each DB's data files
    SELECT DISTINCT mf.database_id, vs.volume_mount_point
    FROM sys.master_files mf CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs
    WHERE mf.type = 0
),
dvc AS (SELECT database_id, volume_mount_point, COUNT(*) OVER (PARTITION BY database_id) AS nvol FROM dv),
vol AS (
    SELECT DISTINCT vs.volume_mount_point, vs.available_bytes / 1048576 AS free_mb, vs.total_bytes / 1048576 AS total_mb
    FROM sys.master_files mf CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs
)
SELECT v.volume_mount_point, v.total_mb / 1024 AS total_gb, v.free_mb / 1024 AS free_gb,
       CAST(SUM(gr.mb_per_day / dvc.nvol) AS decimal(18,1)) AS growth_mb_per_day,
       CAST(v.free_mb / NULLIF(SUM(gr.mb_per_day / dvc.nvol), 0) AS decimal(18,0)) AS days_until_full
FROM vol v
LEFT JOIN dvc ON dvc.volume_mount_point = v.volume_mount_point
LEFT JOIN gr ON gr.database_name = DB_NAME(dvc.database_id) AND gr.mb_per_day > 0
GROUP BY v.volume_mount_point, v.total_mb, v.free_mb
ORDER BY days_until_full;

-- Per database growth (top growers)
WITH fb AS (
    SELECT database_name, backup_finish_date, backup_size,
           ROW_NUMBER() OVER (PARTITION BY database_name ORDER BY backup_finish_date)      AS rn_first,
           ROW_NUMBER() OVER (PARTITION BY database_name ORDER BY backup_finish_date DESC) AS rn_last
    FROM msdb.dbo.backupset
    WHERE type = 'D' AND is_copy_only = 0 AND backup_finish_date >= DATEADD(DAY, -30, GETDATE())
)
SELECT f.database_name,
       CAST(l.backup_size / 1073741824.0 AS decimal(18,2)) AS current_used_gb,
       CAST((l.backup_size - f.backup_size) / 1048576.0 / NULLIF(DATEDIFF(DAY, f.backup_finish_date, l.backup_finish_date), 0) AS decimal(18,1)) AS mb_per_day,
       CAST((l.backup_size - f.backup_size) / 1048576.0 / NULLIF(DATEDIFF(DAY, f.backup_finish_date, l.backup_finish_date), 0) * 30 / 1024 AS decimal(18,2)) AS gb_per_month
FROM fb f JOIN fb l ON l.database_name = f.database_name AND l.rn_last = 1
WHERE f.rn_first = 1
ORDER BY mb_per_day DESC;


/*=============================================================================
  41.3 FILES THAT WILL FAIL THEIR NEXT AUTOGROWTH                         [BOX]
  (not enough free disk for one more growth step, or at max_size)
=============================================================================*/
SELECT DB_NAME(mf.database_id) AS database_name, mf.name AS logical_name, mf.type_desc, vs.volume_mount_point,
       CAST(mf.size AS bigint) * 8 / 1024 AS size_mb,
       CASE WHEN mf.is_percent_growth = 1 THEN CAST(mf.size AS bigint) * 8 / 1024 * mf.growth / 100
            ELSE CAST(mf.growth AS bigint) * 8 / 1024 END AS next_growth_mb,
       vs.available_bytes / 1048576 AS disk_free_mb,
       CASE WHEN mf.max_size = -1 THEN 'unlimited' ELSE CAST(CAST(mf.max_size AS bigint) * 8 / 1024 AS varchar(20)) + ' MB' END AS max_size,
       CASE WHEN mf.growth = 0 THEN 'Autogrowth OFF'
            WHEN mf.max_size > 0 AND mf.size >= mf.max_size THEN 'AT MAX SIZE'
            ELSE 'NOT ENOUGH DISK FOR NEXT GROWTH' END AS finding
FROM sys.master_files AS mf
CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs
WHERE mf.growth = 0
   OR (mf.max_size > 0 AND mf.size >= mf.max_size)
   OR vs.available_bytes / 1048576 < CASE WHEN mf.is_percent_growth = 1 THEN CAST(mf.size AS bigint) * 8 / 1024 * mf.growth / 100
                                          ELSE CAST(mf.growth AS bigint) * 8 / 1024 END
ORDER BY finding, database_name;
-- Autogrowth OFF is fine only if someone pre-sizes the file and watches free space inside it (08 8.5/8.6).


/*=============================================================================
  41.4 SQL AGENT ALERTS - GENERATE THE STANDARD SET                    [BOX][MI]
  Outputs commands (review, then run). Needs Database Mail + an Agent mail
  profile (SSMS > SQL Server Agent > Properties > Alert System), then
  restart Agent.
=============================================================================*/
DECLARE @operator sysname = N'DBA Team', @email nvarchar(200) = N'dba-team@yourcompany.com';   -- <== change

WITH alerts AS (
    SELECT * FROM (VALUES
        (N'Severity 017 - Insufficient resources',  17, 0),
        (N'Severity 018 - Nonfatal internal error', 18, 0),
        (N'Severity 019 - Fatal resource error',    19, 0),
        (N'Severity 020 - Fatal error in process',  20, 0),
        (N'Severity 021 - Fatal error in database', 21, 0),
        (N'Severity 022 - Table integrity suspect', 22, 0),
        (N'Severity 023 - Database integrity suspect', 23, 0),
        (N'Severity 024 - Hardware error',          24, 0),
        (N'Severity 025 - Fatal system error',      25, 0),
        (N'Error 823 - OS I/O error',                0, 823),
        (N'Error 824 - Logical consistency I/O error', 0, 824),
        (N'Error 825 - Read retry (disk failing)',   0, 825),
        (N'Error 829 - Page marked RestorePending',  0, 829),
        (N'Error 832 - Constant page changed in memory', 0, 832),
        (N'Error 855 - Uncorrectable memory error',  0, 855),
        (N'Error 856 - Memory error corrected',      0, 856),
        (N'AG 1480 - Role change (failover)',        0, 1480),
        (N'AG 35264 - Data movement suspended',      0, 35264),
        (N'AG 35265 - Data movement resumed',        0, 35265),
        (N'AG 41404 - AG offline / failover failed', 0, 41404),
        (N'AG 41405 - AG not ready for automatic failover', 0, 41405),
        (N'Error 9002 - Transaction log full',       0, 9002),
        (N'Error 1105 - Filegroup full',             0, 1105),
        (N'Error 17883 - Non-yielding scheduler',    0, 17883)
    ) AS v(alert_name, severity, message_id)
)
SELECT 0 AS seq, N'IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysoperators WHERE name = N''' + @operator + N''') '
               + N'EXEC msdb.dbo.sp_add_operator @name = N''' + @operator + N''', @enabled = 1, @email_address = N''' + @email + N''';' AS cmd
UNION ALL
SELECT 1, N'IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysalerts WHERE name = N''' + alert_name + N''') BEGIN '
        + N'EXEC msdb.dbo.sp_add_alert @name = N''' + alert_name + N''', @message_id = ' + CAST(message_id AS nvarchar(10))
        + N', @severity = ' + CAST(severity AS nvarchar(3)) + N', @enabled = 1, @delay_between_responses = 300, @include_event_description_in = 1; '
        + N'EXEC msdb.dbo.sp_add_notification @alert_name = N''' + alert_name + N''', @operator_name = N''' + @operator + N''', @notification_method = 1; END;'
FROM alerts
UNION ALL   -- alerts on message ids only fire if the message is written to the error log
SELECT 2, N'EXEC sp_altermessage ' + CAST(m.message_id AS nvarchar(10)) + N', ''WITH_LOG'', ''true'';  -- not logged by default'
FROM sys.messages AS m
WHERE m.language_id = 1033 AND m.is_event_logged = 0
  AND m.message_id IN (823, 824, 825, 829, 832, 855, 856, 1480, 35264, 35265, 41404, 41405, 9002, 1105, 17883)
ORDER BY seq;


/*=============================================================================
  41.5 VERIFY ALERTS ACTUALLY NOTIFY SOMEONE                          [BOX][MI]
=============================================================================*/
SELECT a.name AS alert_name, a.enabled, a.severity, a.message_id, a.occurrence_count,
       CASE WHEN a.last_occurrence_date > 0 THEN msdb.dbo.agent_datetime(a.last_occurrence_date, a.last_occurrence_time) END AS last_fired,
       o.name AS operator, o.email_address, o.enabled AS operator_enabled,
       CASE WHEN n.alert_id IS NULL THEN 'NO NOTIFICATION - nobody will know' ELSE '' END AS finding
FROM msdb.dbo.sysalerts AS a
LEFT JOIN msdb.dbo.sysnotifications AS n ON n.alert_id = a.id
LEFT JOIN msdb.dbo.sysoperators AS o ON o.id = n.operator_id
ORDER BY finding DESC, a.name;

-- Failed jobs notify anyone?
SELECT j.name, j.enabled, j.notify_level_email, o.name AS operator
FROM msdb.dbo.sysjobs j LEFT JOIN msdb.dbo.sysoperators o ON o.id = j.notify_email_operator_id
WHERE j.enabled = 1 AND (j.notify_level_email NOT IN (2, 3) OR o.id IS NULL);   -- 2 = on failure, 3 = always
-- Fix: EXEC msdb.dbo.sp_update_job @job_name = N'...', @notify_level_email = 2, @notify_email_operator_name = N'DBA Team';
-- Test mail: EXEC msdb.dbo.sp_send_dbmail @recipients = N'dba-team@yourcompany.com', @subject = N'Test from SQL', @body = N'OK';


/*=============================================================================
  41.6 RESTART / SHUTDOWN HISTORY (from all error logs)                [BOX][MI]
  A start without a preceding "terminating" message = crash / power loss /
  forced kill. Check Windows System log / Azure activity log for the cause.
=============================================================================*/
IF OBJECT_ID('tempdb..#logs') IS NOT NULL DROP TABLE #logs;
IF OBJECT_ID('tempdb..#ev') IS NOT NULL DROP TABLE #ev;
CREATE TABLE #logs (ArchiveNo int, LogDate datetime, LogSize bigint);
CREATE TABLE #ev (LogDate datetime, ProcessInfo nvarchar(50), [Text] nvarchar(max));
INSERT #logs EXEC sys.sp_enumerrorlogs;

DECLARE @n int = 0, @max int = (SELECT MAX(ArchiveNo) FROM #logs);
WHILE @n <= @max
BEGIN
    INSERT #ev EXEC sys.xp_readerrorlog @n, 1, N'Server process ID is';
    INSERT #ev EXEC sys.xp_readerrorlog @n, 1, N'SQL Server is terminating';
    INSERT #ev EXEC sys.xp_readerrorlog @n, 1, N'SQL Server is now ready for client connections';
    SET @n += 1;
END;
SELECT DISTINCT LogDate,
       CASE WHEN [Text] LIKE N'Server process ID%' THEN 'START'
            WHEN [Text] LIKE N'SQL Server is now ready%' THEN 'READY'
            ELSE 'SHUTDOWN' END AS event, [Text]
FROM #ev ORDER BY LogDate DESC;


/*=============================================================================
  41.7 CONFIGURATION CHANGES (who changed what, when)                  [BOX][MI]
=============================================================================*/
TRUNCATE TABLE #ev;
SET @n = 0;
WHILE @n <= @max
BEGIN
    INSERT #ev EXEC sys.xp_readerrorlog @n, 1, N'Configuration option';
    INSERT #ev EXEC sys.xp_readerrorlog @n, 1, N'Setting database option';
    INSERT #ev EXEC sys.xp_readerrorlog @n, 1, N'DBCC TRACEON';
    SET @n += 1;
END;
SELECT DISTINCT LogDate, ProcessInfo, [Text] FROM #ev ORDER BY LogDate DESC;
-- The ProcessInfo spid + 28_version_control 28.2 (default trace) tell you which login did it.
-- (Run together with 41.6 - it reuses #ev and @n/@max.)


/*=============================================================================
  41.8 SCHEDULE IT: EMAIL ONLY WHEN 41.1 FINDS SOMETHING              [BOX][MI]
=============================================================================*/
/*
 1. USE DBAdmin; wrap the body of 41.1 in:
      CREATE OR ALTER PROCEDURE dbo.usp_DBA_HealthCheck AS BEGIN SET NOCOUNT ON; <41.1 body> END;
    and change the final SELECT to also INSERT into a table, e.g. dbo.HealthCheckResult(run_time, severity, area, item, detail).
 2. Agent job every 15-60 min, step:
      DECLARE @rows int;
      CREATE TABLE #r (severity varchar(10), area varchar(30), item nvarchar(256), detail nvarchar(4000));
      INSERT #r EXEC DBAdmin.dbo.usp_DBA_HealthCheck;
      SELECT @rows = COUNT(*) FROM #r WHERE severity = 'CRITICAL';
      IF @rows > 0
          EXEC msdb.dbo.sp_send_dbmail
               @recipients = N'dba-team@yourcompany.com',
               @subject    = N'[SQL CRITICAL] ' + @@SERVERNAME,
               @query      = N'EXEC DBAdmin.dbo.usp_DBA_HealthCheck',
               @attach_query_result_as_file = 0, @query_result_width = 400;
 3. Run the same job on every AG replica and on MI (Database Mail works there too).
*/
