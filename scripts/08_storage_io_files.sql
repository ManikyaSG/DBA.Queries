/*******************************************************************************
 File    : 08_storage_io_files.sql
 Purpose : Disk latency, file sizes & free space, log usage, VLFs, autogrowth.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] Managed Instance   [SQLDB] Azure SQL DB
*******************************************************************************/

/*=============================================================================
  8.1  FILE I/O LATENCY - ALL DATABASES (since restart)               [BOX][MI]
  Rough guide: data reads < 20ms, log writes < 5ms (SSD/premium) are healthy.
  Azure SQL DB: use sys.dm_io_virtual_file_stats(DB_ID(), NULL) + sys.database_files.
=============================================================================*/
SELECT
    DB_NAME(vfs.database_id)                                                AS database_name,
    mf.name AS logical_name, mf.type_desc, mf.physical_name,
    vfs.num_of_reads, vfs.num_of_writes,
    CAST(vfs.io_stall_read_ms  * 1.0 / NULLIF(vfs.num_of_reads, 0)  AS decimal(10,2)) AS avg_read_ms,
    CAST(vfs.io_stall_write_ms * 1.0 / NULLIF(vfs.num_of_writes, 0) AS decimal(10,2)) AS avg_write_ms,
    CAST(vfs.io_stall * 1.0 / NULLIF(vfs.num_of_reads + vfs.num_of_writes, 0) AS decimal(10,2)) AS avg_io_ms,
    vfs.num_of_bytes_read    / 1048576 AS mb_read,
    vfs.num_of_bytes_written / 1048576 AS mb_written,
    vfs.size_on_disk_bytes   / 1048576 AS size_mb
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
JOIN sys.master_files AS mf ON mf.database_id = vfs.database_id AND mf.file_id = vfs.file_id
ORDER BY avg_io_ms DESC;


/*=============================================================================
  8.2  FILE I/O LATENCY - DELTA OVER N SECONDS (live)                 [BOX][MI]
=============================================================================*/
DECLARE @delay char(8) = '00:00:30';
IF OBJECT_ID('tempdb..#io1') IS NOT NULL DROP TABLE #io1;
SELECT database_id, file_id, num_of_reads, num_of_writes, io_stall_read_ms, io_stall_write_ms
INTO #io1 FROM sys.dm_io_virtual_file_stats(NULL, NULL);
WAITFOR DELAY @delay;
SELECT DB_NAME(v.database_id) AS database_name, mf.name AS logical_name, mf.type_desc,
       v.num_of_reads  - a.num_of_reads  AS reads,
       v.num_of_writes - a.num_of_writes AS writes,
       CAST((v.io_stall_read_ms  - a.io_stall_read_ms)  * 1.0 / NULLIF(v.num_of_reads  - a.num_of_reads, 0)  AS decimal(10,2)) AS avg_read_ms,
       CAST((v.io_stall_write_ms - a.io_stall_write_ms) * 1.0 / NULLIF(v.num_of_writes - a.num_of_writes, 0) AS decimal(10,2)) AS avg_write_ms
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS v
JOIN #io1 AS a ON a.database_id = v.database_id AND a.file_id = v.file_id
JOIN sys.master_files AS mf ON mf.database_id = v.database_id AND mf.file_id = v.file_id
WHERE (v.num_of_reads - a.num_of_reads) + (v.num_of_writes - a.num_of_writes) > 0
ORDER BY (v.io_stall_read_ms - a.io_stall_read_ms) + (v.io_stall_write_ms - a.io_stall_write_ms) DESC;


/*=============================================================================
  8.3  PENDING I/O REQUESTS RIGHT NOW                                 [BOX][MI]
=============================================================================*/
SELECT DB_NAME(vfs.database_id) AS database_name, mf.physical_name,
       pio.io_type, pio.io_pending, pio.io_pending_ms_ticks
FROM sys.dm_io_pending_io_requests AS pio
JOIN sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs ON vfs.file_handle = pio.io_handle
JOIN sys.master_files AS mf ON mf.database_id = vfs.database_id AND mf.file_id = vfs.file_id
ORDER BY pio.io_pending_ms_ticks DESC;


/*=============================================================================
  8.4  DRIVE / VOLUME FREE SPACE                                      [BOX][MI]
=============================================================================*/
SELECT DISTINCT
    vs.volume_mount_point, vs.logical_volume_name, vs.file_system_type,
    vs.total_bytes / 1073741824     AS total_gb,
    vs.available_bytes / 1073741824 AS free_gb,
    CAST(100.0 * vs.available_bytes / vs.total_bytes AS decimal(5,2)) AS free_pct
FROM sys.master_files AS mf
CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs
ORDER BY free_pct;


/*=============================================================================
  8.5  FILE SIZE & FREE SPACE - CURRENT DB                     [BOX][MI][SQLDB]
=============================================================================*/
SELECT name AS logical_name, type_desc, physical_name,
       CAST(size / 128.0 AS decimal(18,2))                                         AS size_mb,
       CAST(FILEPROPERTY(name, 'SpaceUsed') / 128.0 AS decimal(18,2))              AS used_mb,
       CAST((size - FILEPROPERTY(name, 'SpaceUsed')) / 128.0 AS decimal(18,2))     AS free_mb,
       CAST(100.0 * (size - FILEPROPERTY(name, 'SpaceUsed')) / NULLIF(size, 0) AS decimal(5,2)) AS free_pct,
       CASE WHEN is_percent_growth = 1 THEN CAST(growth AS varchar(10)) + '%'
            ELSE CAST(growth / 128 AS varchar(10)) + ' MB' END                    AS growth,
       CASE max_size WHEN -1 THEN 'Unlimited' WHEN 0 THEN 'No growth'
            ELSE CAST(CAST(max_size AS bigint) / 128 AS varchar(20)) + ' MB' END   AS max_size
FROM sys.database_files;


/*=============================================================================
  8.6  FILE SIZE & FREE SPACE - ALL ONLINE DATABASES                  [BOX][MI]
=============================================================================*/
IF OBJECT_ID('tempdb..#files') IS NOT NULL DROP TABLE #files;
CREATE TABLE #files (database_name sysname, logical_name sysname, type_desc nvarchar(60),
                     size_mb decimal(18,2), used_mb decimal(18,2), physical_name nvarchar(260));
DECLARE @sql nvarchar(max) = N'';
SELECT @sql += N'USE ' + QUOTENAME(name) + N';
INSERT #files SELECT DB_NAME(), name, type_desc, size/128.0, FILEPROPERTY(name,''SpaceUsed'')/128.0, physical_name FROM sys.database_files;
'
FROM sys.databases WHERE state_desc = N'ONLINE' AND HAS_DBACCESS(name) = 1;
EXEC sys.sp_executesql @sql;
SELECT database_name, logical_name, type_desc, size_mb, used_mb,
       size_mb - used_mb AS free_mb,
       CAST(100.0 * (size_mb - used_mb) / NULLIF(size_mb, 0) AS decimal(5,2)) AS free_pct,
       physical_name
FROM #files ORDER BY free_mb DESC;


/*=============================================================================
  8.7  LOG SPACE - ALL DATABASES + WHY LOG CAN'T TRUNCATE             [BOX][MI]
  log_reuse_wait_desc: LOG_BACKUP (take log backup), ACTIVE_TRANSACTION
  (see 02 open trans), AVAILABILITY_REPLICA (AG secondary behind), REPLICATION...
=============================================================================*/
DBCC SQLPERF(LOGSPACE);

SELECT name, recovery_model_desc, log_reuse_wait_desc
FROM sys.databases
WHERE log_reuse_wait_desc <> N'NOTHING'
ORDER BY name;


/*=============================================================================
  8.8  LOG STATS PER DATABASE (2016 SP2+)                             [BOX][MI]
=============================================================================*/
SELECT d.name, d.recovery_model_desc,
       ls.total_log_size_mb, ls.active_log_size_mb,
       ls.log_since_last_log_backup_mb, ls.log_backup_time,
       ls.log_since_last_checkpoint_mb, ls.total_vlf_count, ls.active_vlf_count,
       ls.log_truncation_holdup_reason, ls.log_recovery_size_mb
FROM sys.databases AS d
CROSS APPLY sys.dm_db_log_stats(d.database_id) AS ls
WHERE d.state_desc = N'ONLINE'
ORDER BY ls.total_log_size_mb DESC;


/*=============================================================================
  8.9  VLF COUNT PER DATABASE (2016 SP2+)                             [BOX][MI]
  Thousands of VLFs = slow recovery / AG redo / restores. Fix: shrink log,
  regrow in large fixed chunks (see 19_maintenance).
=============================================================================*/
SELECT d.name AS database_name, COUNT(li.database_id) AS vlf_count,
       SUM(CASE WHEN li.vlf_active = 1 THEN 1 ELSE 0 END) AS active_vlfs,
       CAST(SUM(li.vlf_size_mb) AS decimal(18,2)) AS log_size_mb
FROM sys.databases AS d
CROSS APPLY sys.dm_db_log_info(d.database_id) AS li
WHERE d.state_desc = N'ONLINE'
GROUP BY d.name
ORDER BY vlf_count DESC;


/*=============================================================================
  8.10 AUTOGROWTH SETTINGS - FLAG % GROWTH & TINY INCREMENTS          [BOX][MI]
=============================================================================*/
SELECT DB_NAME(database_id) AS database_name, name AS logical_name, type_desc,
       CAST(CAST(size AS bigint) * 8 / 1024 AS bigint) AS size_mb,
       CASE WHEN is_percent_growth = 1 THEN CAST(growth AS varchar(10)) + ' %'
            ELSE CAST(growth * 8 / 1024 AS varchar(10)) + ' MB' END AS growth_setting,
       CASE WHEN is_percent_growth = 1 THEN 'WARN: percent growth'
            WHEN growth * 8 / 1024 < 64 AND growth <> 0 THEN 'WARN: growth < 64 MB'
            WHEN growth = 0 THEN 'WARN: autogrowth disabled'
            ELSE 'OK' END AS finding
FROM sys.master_files
ORDER BY finding DESC, database_name;


/*=============================================================================
  8.11 RECENT AUTOGROWTH / SHRINK EVENTS (default trace)                 [BOX]
=============================================================================*/
DECLARE @trc nvarchar(260);
SELECT @trc = REVERSE(SUBSTRING(REVERSE(path), CHARINDEX(N'\', REVERSE(path)), 260)) + N'log.trc'
FROM sys.traces WHERE is_default = 1;

SELECT te.name AS event_name, t.DatabaseName, t.FileName, t.StartTime,
       t.Duration / 1000 AS duration_ms,
       t.IntegerData * 8 / 1024 AS growth_mb,
       t.LoginName, t.ApplicationName, t.HostName
FROM sys.fn_trace_gettable(@trc, DEFAULT) AS t
JOIN sys.trace_events AS te ON te.trace_event_id = t.EventClass
WHERE t.EventClass IN (92, 93, 94, 95)  -- data grow, log grow, data shrink, log shrink
ORDER BY t.StartTime DESC;


/*=============================================================================
  8.12 LARGEST TABLES - CURRENT DB                             [BOX][MI][SQLDB]
=============================================================================*/
SELECT TOP (50)
    OBJECT_SCHEMA_NAME(ps.object_id) + N'.' + OBJECT_NAME(ps.object_id) AS table_name,
    SUM(CASE WHEN ps.index_id < 2 THEN ps.row_count ELSE 0 END)          AS row_count,
    CAST(SUM(ps.reserved_page_count) * 8 / 1024.0 AS decimal(18,2))      AS reserved_mb,
    CAST(SUM(CASE WHEN ps.index_id < 2 THEN ps.used_page_count ELSE 0 END) * 8 / 1024.0 AS decimal(18,2)) AS data_mb,
    CAST(SUM(CASE WHEN ps.index_id > 1 THEN ps.used_page_count ELSE 0 END) * 8 / 1024.0 AS decimal(18,2)) AS index_mb
FROM sys.dm_db_partition_stats AS ps
WHERE OBJECTPROPERTY(ps.object_id, 'IsMSShipped') = 0
GROUP BY ps.object_id
ORDER BY reserved_mb DESC;
