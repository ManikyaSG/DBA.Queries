/*******************************************************************************
 File    : 21_cdc_change_tracking.sql
 Purpose : Change Data Capture (CDC) and Change Tracking (CT) - what is
           enabled, capture latency, errors, jobs, retention, log impact.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] Managed Instance   [SQLDB] Azure SQL DB
 Note    : CDC on BOX/MI uses SQL Agent capture + cleanup jobs.
           Azure SQL DB uses an internal scheduler (no Agent jobs).
           CDC reads the transaction log: a broken/stopped capture job shows
           up as log_reuse_wait_desc = REPLICATION and a growing log.
*******************************************************************************/

/*=============================================================================
  21.1 DATABASES WITH CDC / CHANGE TRACKING ENABLED            [BOX][MI][SQLDB]
=============================================================================*/
SELECT d.name, d.is_cdc_enabled,
       CASE WHEN ct.database_id IS NOT NULL THEN 1 ELSE 0 END AS is_change_tracking_enabled,
       ct.retention_period, ct.retention_period_units_desc, ct.is_auto_cleanup_on,
       d.log_reuse_wait_desc
FROM sys.databases AS d
LEFT JOIN sys.change_tracking_databases AS ct ON ct.database_id = d.database_id
WHERE d.is_cdc_enabled = 1 OR ct.database_id IS NOT NULL
ORDER BY d.name;


/*=============================================================================
  21.2 CDC TRACKED TABLES & CAPTURE INSTANCES - CURRENT DB     [BOX][MI][SQLDB]
=============================================================================*/
SELECT OBJECT_SCHEMA_NAME(ct.source_object_id) + N'.' + OBJECT_NAME(ct.source_object_id) AS source_table,
       ct.capture_instance, ct.supports_net_changes, ct.role_name AS gating_role,
       ct.index_name AS unique_index_for_net_changes, ct.filegroup_name,
       ct.create_date, ct.start_lsn,
       sys.fn_cdc_map_lsn_to_time(ct.start_lsn)          AS capture_start_time,
       sys.fn_cdc_get_min_lsn(ct.capture_instance)        AS min_lsn_available,
       sys.fn_cdc_map_lsn_to_time(sys.fn_cdc_get_min_lsn(ct.capture_instance)) AS oldest_change_time,
       OBJECT_NAME(ct.object_id)                          AS change_table_name
FROM cdc.change_tables AS ct
ORDER BY source_table;

-- Max LSN captured so far (database-wide) and its time
SELECT sys.fn_cdc_get_max_lsn() AS max_lsn,
       sys.fn_cdc_map_lsn_to_time(sys.fn_cdc_get_max_lsn()) AS last_captured_change_time;


/*=============================================================================
  21.3 CAPTURED COLUMNS PER CAPTURE INSTANCE - CURRENT DB      [BOX][MI][SQLDB]
=============================================================================*/
SELECT ct.capture_instance, cc.column_ordinal, cc.column_name, cc.column_type, cc.is_computed
FROM cdc.captured_columns AS cc
JOIN cdc.change_tables AS ct ON ct.object_id = cc.object_id
ORDER BY ct.capture_instance, cc.column_ordinal;


/*=============================================================================
  21.4 SOURCE TABLE COLUMNS NOT CAPTURED (schema drift after enabling CDC)
                                                               [BOX][MI][SQLDB]
  CDC does not pick up new columns - you need a 2nd capture instance.
=============================================================================*/
SELECT ct.capture_instance,
       OBJECT_SCHEMA_NAME(c.object_id) + N'.' + OBJECT_NAME(c.object_id) AS source_table,
       c.name AS column_not_captured
FROM cdc.change_tables AS ct
JOIN sys.columns AS c ON c.object_id = ct.source_object_id
WHERE NOT EXISTS (SELECT 1 FROM cdc.captured_columns AS cc
                  WHERE cc.object_id = ct.object_id AND cc.column_name = c.name)
ORDER BY source_table, c.column_id;


/*=============================================================================
  21.5 CDC CAPTURE LATENCY & THROUGHPUT (log scan sessions)    [BOX][MI][SQLDB]
  latency (seconds) = how far behind the log the capture is. Should be low.
  session_id 0 = aggregate since restart.
=============================================================================*/
SELECT TOP (50) session_id, start_time, end_time, duration, scan_phase,
       error_count, tran_count, command_count, empty_scan_count,
       latency, last_commit_time, log_record_count, schema_change_count, failed_sessions_count
FROM sys.dm_cdc_log_scan_sessions
ORDER BY session_id DESC;


/*=============================================================================
  21.6 CDC ERRORS                                              [BOX][MI][SQLDB]
=============================================================================*/
SELECT session_id, phase_number, entry_time, error_number, error_severity, error_state, error_message
FROM sys.dm_cdc_errors
ORDER BY entry_time DESC;


/*=============================================================================
  21.7 CDC AGENT JOBS & SETTINGS (retention, polling)                 [BOX][MI]
  retention is in MINUTES (default 4320 = 3 days).
=============================================================================*/
SELECT DB_NAME(cj.database_id) AS database_name, cj.job_type, j.name AS job_name, j.enabled,
       cj.maxtrans, cj.maxscans, cj.continuous, cj.pollinginterval,
       cj.retention AS retention_minutes, cj.retention / 1440.0 AS retention_days, cj.threshold
FROM msdb.dbo.cdc_jobs AS cj
LEFT JOIN msdb.dbo.sysjobs AS j ON j.job_id = cj.job_id
ORDER BY database_name, cj.job_type;
-- Current DB shortcut:  EXEC sys.sp_cdc_help_jobs;

-- Is the capture job actually running right now?
SELECT j.name, ja.start_execution_date, ja.stop_execution_date
FROM msdb.dbo.sysjobactivity AS ja
JOIN msdb.dbo.sysjobs AS j ON j.job_id = ja.job_id
WHERE j.name LIKE N'cdc.%capture'
  AND ja.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions);


/*=============================================================================
  21.8 CDC IS HOLDING THE LOG? (log_reuse_wait = REPLICATION)          [BOX][MI]
=============================================================================*/
SELECT name, is_cdc_enabled, is_published, log_reuse_wait_desc
FROM sys.databases
WHERE log_reuse_wait_desc = N'REPLICATION';
-- Fix: start capture job (EXEC sys.sp_cdc_start_job @job_type = N'capture'), check 21.6 errors.
-- Last resort (DATA LOSS for CDC consumers): EXEC sp_repldone NULL, NULL, 0, 0, 1;


/*=============================================================================
  21.9 CHANGE TABLE SIZES - CURRENT DB                         [BOX][MI][SQLDB]
=============================================================================*/
SELECT ct.capture_instance,
       SUM(CASE WHEN ps.index_id < 2 THEN ps.row_count ELSE 0 END)     AS change_rows,
       CAST(SUM(ps.reserved_page_count) * 8 / 1024.0 AS decimal(18,2)) AS reserved_mb
FROM cdc.change_tables AS ct
JOIN sys.dm_db_partition_stats AS ps ON ps.object_id = ct.object_id
GROUP BY ct.capture_instance
ORDER BY reserved_mb DESC;


/*=============================================================================
  21.10 READ CHANGES (template)                                [BOX][MI][SQLDB]
  __$operation: 1=delete 2=insert 3=update(before) 4=update(after)
=============================================================================*/
/*
DECLARE @from binary(10) = sys.fn_cdc_get_min_lsn(N'dbo_Orders'),
        @to   binary(10) = sys.fn_cdc_get_max_lsn();
-- Changes in a time window:
-- SET @from = sys.fn_cdc_map_time_to_lsn('smallest greater than or equal', '2026-10-28 00:00');
-- SET @to   = sys.fn_cdc_map_time_to_lsn('largest less than or equal',     '2026-10-28 23:59');
SELECT sys.fn_cdc_map_lsn_to_time(__$start_lsn) AS change_time, *
FROM cdc.fn_cdc_get_all_changes_dbo_Orders(@from, @to, N'all update old');
-- Net changes (needs supports_net_changes = 1):
-- SELECT * FROM cdc.fn_cdc_get_net_changes_dbo_Orders(@from, @to, N'all');
*/


/*=============================================================================
  21.11 ENABLE / DISABLE / TUNE CDC (templates)                [BOX][MI][SQLDB]
=============================================================================*/
/*
USE [YourDB];
EXEC sys.sp_cdc_enable_db;
EXEC sys.sp_cdc_enable_table
     @source_schema = N'dbo', @source_name = N'Orders',
     @role_name = NULL,                    -- or a gating role
     @supports_net_changes = 1,            -- needs PK / unique index
     @filegroup_name = NULL;               -- put change tables on their own FG for big volumes

EXEC sys.sp_cdc_disable_table @source_schema = N'dbo', @source_name = N'Orders', @capture_instance = N'dbo_Orders';
EXEC sys.sp_cdc_disable_db;

-- Change retention to 7 days / tune capture batch:
EXEC sys.sp_cdc_change_job @job_type = N'cleanup', @retention = 10080;
EXEC sys.sp_cdc_change_job @job_type = N'capture', @maxtrans = 1000, @maxscans = 10, @pollinginterval = 5;
EXEC sys.sp_cdc_stop_job  @job_type = N'capture';
EXEC sys.sp_cdc_start_job @job_type = N'capture';
*/


/*=============================================================================
  21.12 CDC + ALWAYS ON NOTES                                         [BOX]
=============================================================================*/
/*
 - CDC jobs are created only on the replica where CDC was enabled. After failover
   create them on the new primary:  EXEC sys.sp_cdc_add_job @job_type = N'capture';
                                    EXEC sys.sp_cdc_add_job @job_type = N'cleanup';
   (or pre-create them on every replica and let them check sys.fn_hadr_is_primary_replica).
 - By default the capture process only reads log that is hardened on all SYNC
   secondaries. Trace flag 1448 lets it advance even if ASYNC secondaries are behind.
 - Restoring a CDC DB elsewhere: RESTORE ... WITH KEEP_CDC, then add the jobs.
*/


/*=============================================================================
  21.13 CHANGE TRACKING - TABLES & VERSIONS - CURRENT DB       [BOX][MI][SQLDB]
  If a client's last synced version < min_valid_version it must re-initialise.
=============================================================================*/
SELECT OBJECT_SCHEMA_NAME(ctt.object_id) + N'.' + OBJECT_NAME(ctt.object_id) AS table_name,
       ctt.is_track_columns_updated_on,
       ctt.min_valid_version,
       ctt.begin_version, ctt.cleanup_version,
       CHANGE_TRACKING_CURRENT_VERSION() AS current_version
FROM sys.change_tracking_tables AS ctt
ORDER BY table_name;

-- Size of the CT side tables + commit table
SELECT OBJECT_NAME(it.parent_id) AS tracked_table, it.name AS internal_table, it.internal_type_desc,
       SUM(ps.row_count) AS rows,
       CAST(SUM(ps.reserved_page_count) * 8 / 1024.0 AS decimal(18,2)) AS reserved_mb
FROM sys.internal_tables AS it
JOIN sys.dm_db_partition_stats AS ps ON ps.object_id = it.object_id AND ps.index_id IN (0, 1)
WHERE it.internal_type_desc IN (N'CHANGE_TRACKING', N'TRACKED_COMMITTED_TRANSACTIONS')
GROUP BY it.parent_id, it.name, it.internal_type_desc
ORDER BY reserved_mb DESC;

/*
ALTER DATABASE [YourDB] SET CHANGE_TRACKING = ON (CHANGE_RETENTION = 2 DAYS, AUTO_CLEANUP = ON);
ALTER TABLE dbo.Orders ENABLE CHANGE_TRACKING WITH (TRACK_COLUMNS_UPDATED = ON);
-- Read changes since version @v:
SELECT ct.*, o.* FROM CHANGETABLE(CHANGES dbo.Orders, @v) AS ct LEFT JOIN dbo.Orders AS o ON o.OrderID = ct.OrderID;
-- Manual cleanup (2016 SP2+/2017 CU+):  EXEC sys.sp_flush_CT_internal_table_on_demand @TableToClean = N'dbo.Orders';
*/
