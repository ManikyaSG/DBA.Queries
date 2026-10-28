/*******************************************************************************
 File    : 17_azure_managed_instance.sql
 Purpose : Azure SQL Managed Instance specific checks.
 Tags    : [MI]
 Note    : Almost everything in the other files works on MI (it is the
           full SQL engine). This file covers what is MI-specific:
           resource history, storage limits, governance, tier behaviour.
*******************************************************************************/

/*=============================================================================
  17.1 AM I ON A MANAGED INSTANCE?                                    [MI]
=============================================================================*/
SELECT SERVERPROPERTY('EngineEdition') AS engine_edition,   -- 8 = Managed Instance
       SERVERPROPERTY('ServerName')    AS server_name,
       @@VERSION                       AS version;


/*=============================================================================
  17.2 INSTANCE RESOURCE HISTORY - CPU / STORAGE / IO   (master)      [MI]
  ~14 days of 5-minute (approx) samples.
=============================================================================*/
SELECT TOP (300)
    start_time, end_time, resource_name, sku, hardware_generation,
    virtual_core_count, avg_cpu_percent,
    reserved_storage_mb, storage_space_used_mb,
    CAST(100.0 * storage_space_used_mb / NULLIF(reserved_storage_mb, 0) AS decimal(5,2)) AS storage_used_pct,
    io_requests, io_bytes_read, io_bytes_written
FROM master.sys.server_resource_stats
ORDER BY start_time DESC;

-- Daily peak CPU
SELECT CAST(start_time AS date) AS day, MAX(avg_cpu_percent) AS peak_cpu, AVG(avg_cpu_percent) AS avg_cpu
FROM master.sys.server_resource_stats
GROUP BY CAST(start_time AS date)
ORDER BY day DESC;


/*=============================================================================
  17.3 INSTANCE GOVERNANCE LIMITS (log rate, IOPS, memory)            [MI]
=============================================================================*/
SELECT * FROM sys.dm_instance_resource_governance;


/*=============================================================================
  17.4 STORAGE: INSTANCE TOTAL vs RESERVED                            [MI]
  Instance stops accepting writes when storage_space_used reaches reserved.
=============================================================================*/
SELECT TOP (1) reserved_storage_mb, storage_space_used_mb,
       reserved_storage_mb - storage_space_used_mb AS free_mb
FROM master.sys.server_resource_stats
ORDER BY start_time DESC;

SELECT DB_NAME(database_id) AS database_name, type_desc,
       CAST(SUM(CAST(size AS bigint)) * 8 / 1024.0 / 1024 AS decimal(18,2)) AS size_gb
FROM sys.master_files
GROUP BY database_id, type_desc
ORDER BY size_gb DESC;


/*=============================================================================
  17.5 GENERAL PURPOSE: FILE SIZE vs REMOTE STORAGE PERFORMANCE        [MI]
  On General Purpose, each file sits on remote storage whose IOPS/throughput
  grow with file size. Small files on busy DBs => high IO latency.
  Pre-growing hot data/log files can raise IO limits (check current MS docs
  for the size tiers on your hardware generation).
=============================================================================*/
SELECT DB_NAME(mf.database_id) AS database_name, mf.name, mf.type_desc,
       CAST(CAST(mf.size AS bigint) * 8 / 1024.0 / 1024 AS decimal(18,2)) AS size_gb,
       CAST(vfs.io_stall_read_ms  * 1.0 / NULLIF(vfs.num_of_reads, 0)  AS decimal(10,2)) AS avg_read_ms,
       CAST(vfs.io_stall_write_ms * 1.0 / NULLIF(vfs.num_of_writes, 0) AS decimal(10,2)) AS avg_write_ms,
       vfs.num_of_reads + vfs.num_of_writes AS total_io
FROM sys.master_files AS mf
JOIN sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs ON vfs.database_id = mf.database_id AND vfs.file_id = mf.file_id
ORDER BY total_io DESC;


/*=============================================================================
  17.6 LOG RATE GOVERNANCE WAITS                                      [MI]
  INSTANCE_LOG_RATE_GOVERNOR / LOG_RATE_GOVERNOR high = log throughput cap hit
  (big index rebuilds, bulk loads). Batch the work or scale up.
=============================================================================*/
SELECT wait_type, waiting_tasks_count, wait_time_ms
FROM sys.dm_os_wait_stats
WHERE wait_type IN (N'INSTANCE_LOG_RATE_GOVERNOR', N'LOG_RATE_GOVERNOR', N'POOL_LOG_RATE_GOVERNOR',
                    N'HADR_THROTTLE_LOG_RATE_GOVERNOR', N'HADR_THROTTLE_LOG_RATE_SEND_RECV_QUEUE_SIZE',
                    N'WRITELOG', N'IO_QUEUE_LIMIT')
ORDER BY wait_time_ms DESC;


/*=============================================================================
  17.7 BUSINESS CRITICAL / FAILOVER GROUP REPLICA STATE               [MI]
  Business Critical runs on an internal AG; failover groups and MI link use
  geo-replication. The HADR DMVs show what is visible to you.
=============================================================================*/
SELECT DB_NAME(database_id) AS database_name, is_local, is_primary_replica,
       synchronization_state_desc, synchronization_health_desc,
       log_send_queue_size, redo_queue_size, secondary_lag_seconds, last_commit_time
FROM sys.dm_hadr_database_replica_states
ORDER BY database_name, is_primary_replica DESC;

-- Failover group / MI link (if configured):
-- SELECT * FROM sys.dm_hadr_fabric_continuous_copy_status;


/*=============================================================================
  17.8 BACKUP HISTORY ON MI                                           [MI]
  Automated (platform) backups are managed by Azure; msdb shows backups you
  run yourself (COPY_ONLY to URL). For automated backup activity you can use
  an XE session on backup_restore_progress_trace or the portal.
=============================================================================*/
SELECT TOP (50) database_name, type, backup_start_date, backup_finish_date,
       is_copy_only, backup_size / 1048576 AS size_mb
FROM msdb.dbo.backupset
ORDER BY backup_start_date DESC;


/*=============================================================================
  17.9 THINGS THAT BEHAVE DIFFERENTLY ON MI (quick reference)
=============================================================================*/
/*
 - No access to OS / file paths: sys.dm_os_volume_stats, xp_cmdshell, default trace
   file paths and sys.dm_server_services are unavailable or limited.
 - Backups: only COPY_ONLY BACKUP TO URL for user backups. Restores FROM URL.
 - tempdb: fixed per tier; can add files/size within limits.
 - Max server memory / some sp_configure options are platform-managed.
 - SQL Agent is available; Database Mail uses a profile named 'AzureManagedInstance_dbmail_profile'.
 - Error log: xp_readerrorlog works but is noisy (platform messages).
*/
