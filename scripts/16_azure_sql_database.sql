/*******************************************************************************
 File    : 16_azure_sql_database.sql
 Purpose : Azure SQL Database (single DB / elastic pool) specific checks.
 Tags    : [SQLDB]  (some also work on MI - marked)
 Note    : Each query notes whether it runs in the USER database or in MASTER.
           Most generic DMVs in other files (sessions, plan cache, Query Store,
           indexes) work in Azure SQL DB as-is - just run them in the user DB.
*******************************************************************************/

/*=============================================================================
  16.1 SERVICE TIER / SIZE / LIMITS                         (user DB) [SQLDB]
=============================================================================*/
SELECT DB_NAME() AS database_name,
       DATABASEPROPERTYEX(DB_NAME(), 'Edition')          AS edition,
       DATABASEPROPERTYEX(DB_NAME(), 'ServiceObjective') AS service_objective,
       CAST(DATABASEPROPERTYEX(DB_NAME(), 'MaxSizeInBytes') AS bigint) / 1073741824 AS max_size_gb,
       DATABASEPROPERTYEX(DB_NAME(), 'Updateability')    AS updateability;   -- READ_ONLY on read replicas

SELECT * FROM sys.database_service_objectives;     -- edition, service_objective, elastic_pool_name

-- Governance limits actually applied to this DB (max log rate, IOPS, workers...)
SELECT * FROM sys.dm_user_db_resource_governance;


/*=============================================================================
  16.2 RESOURCE USAGE - LAST HOUR (15-second samples)       (user DB) [SQLDB]
  Any metric near 100% = you are hitting the tier's limit.
=============================================================================*/
SELECT end_time,
       avg_cpu_percent, avg_data_io_percent, avg_log_write_percent,
       avg_memory_usage_percent, max_worker_percent, max_session_percent,
       xtp_storage_percent, avg_instance_cpu_percent, avg_instance_memory_percent
FROM sys.dm_db_resource_stats
ORDER BY end_time DESC;

-- Summary of the last hour
SELECT MAX(avg_cpu_percent)        AS max_cpu,  AVG(avg_cpu_percent)        AS avg_cpu,
       MAX(avg_data_io_percent)    AS max_io,   AVG(avg_data_io_percent)    AS avg_io,
       MAX(avg_log_write_percent)  AS max_log,  AVG(avg_log_write_percent)  AS avg_log,
       MAX(avg_memory_usage_percent) AS max_mem,
       MAX(max_worker_percent)     AS max_workers,
       MAX(max_session_percent)    AS max_sessions
FROM sys.dm_db_resource_stats;


/*=============================================================================
  16.3 RESOURCE USAGE - LAST 14 DAYS (5-min samples)          (master) [SQLDB]
=============================================================================*/
/*
SELECT start_time, end_time, database_name, sku, avg_cpu_percent, avg_data_io_percent,
       avg_log_write_percent, max_worker_percent, max_session_percent, storage_in_megabytes
FROM sys.resource_stats
WHERE database_name = N'YourDB'
ORDER BY start_time DESC;
*/


/*=============================================================================
  16.4 ELASTIC POOL USAGE                                      (master) [SQLDB]
=============================================================================*/
/*
SELECT start_time, end_time, elastic_pool_name, avg_cpu_percent, avg_data_io_percent,
       avg_log_write_percent, max_worker_percent, max_session_percent, avg_storage_percent
FROM sys.elastic_pool_resource_stats
ORDER BY end_time DESC;
*/


/*=============================================================================
  16.5 WAIT STATS - THIS DATABASE                            (user DB) [SQLDB]
  Watch for: LOG_RATE_GOVERNOR (log write cap), SOS_SCHEDULER_YIELD (CPU cap),
  PAGEIOLATCH_* (IO cap), RESOURCE_SEMAPHORE (memory).
=============================================================================*/
SELECT TOP (20) wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms,
       CAST(wait_time_ms * 1.0 / NULLIF(waiting_tasks_count, 0) AS decimal(10,2)) AS avg_wait_ms
FROM sys.dm_db_wait_stats
WHERE wait_type NOT LIKE N'%SLEEP%' AND wait_type NOT LIKE N'%IDLE%' AND wait_type NOT LIKE N'%QUEUE%'
  AND wait_type NOT IN (N'XE_TIMER_EVENT', N'WAITFOR', N'BROKER_TASK_STOP', N'CXCONSUMER')
ORDER BY wait_time_ms DESC;


/*=============================================================================
  16.6 SPACE USED vs ALLOCATED vs MAX                       (user DB) [SQLDB]
=============================================================================*/
SELECT file_id, name, type_desc,
       CAST(size / 128.0 AS decimal(18,2))                            AS allocated_mb,
       CAST(FILEPROPERTY(name, 'SpaceUsed') / 128.0 AS decimal(18,2)) AS used_mb,
       CAST(max_size / 128.0 AS decimal(18,2))                        AS max_mb
FROM sys.database_files;
-- Reclaim allocated-but-unused space (beware fragmentation):  DBCC SHRINKFILE (1, <target_mb>);


/*=============================================================================
  16.7 GEO-REPLICATION / FAILOVER GROUP LINK STATUS         (user DB) [SQLDB]
=============================================================================*/
SELECT link_guid, partner_server, partner_database, replication_state_desc,
       role_desc, secondary_allow_connections_desc, last_replication, replication_lag_sec
FROM sys.dm_geo_replication_link_status;

-- In master: SELECT * FROM sys.geo_replication_links;


/*=============================================================================
  16.8 LONG-RUNNING MANAGEMENT OPERATIONS (scale, copy, restore) (master) [SQLDB]
=============================================================================*/
-- SELECT * FROM sys.dm_operation_status ORDER BY start_time DESC;


/*=============================================================================
  16.9 AUTOMATIC TUNING                                      (user DB) [SQLDB][MI]
=============================================================================*/
SELECT name, desired_state_desc, actual_state_desc, reason_desc
FROM sys.database_automatic_tuning_options;

SELECT name, type, reason, valid_since, last_refresh,
       JSON_VALUE(state, '$.currentValue')                        AS current_state,
       JSON_VALUE(details, '$.implementationDetails.script')      AS fix_script,
       score
FROM sys.dm_db_tuning_recommendations
ORDER BY score DESC;
-- ALTER DATABASE CURRENT SET AUTOMATIC_TUNING (FORCE_LAST_GOOD_PLAN = ON);


/*=============================================================================
  16.10 ACTIVE CONNECTIONS vs LIMIT                          (user DB) [SQLDB]
=============================================================================*/
SELECT COUNT(*) AS sessions,
       SUM(CASE WHEN status = 'running' THEN 1 ELSE 0 END) AS running,
       (SELECT MAX(max_session_percent) FROM sys.dm_db_resource_stats) AS max_session_pct_last_hour
FROM sys.dm_exec_sessions
WHERE is_user_process = 1;


/*=============================================================================
  16.11 PERSISTENT VERSION STORE (ADR is always on in Azure SQL DB) (user DB) [SQLDB]
=============================================================================*/
SELECT DB_NAME(database_id) AS database_name,
       persistent_version_store_size_kb / 1024 AS pvs_mb,
       online_index_version_store_size_kb / 1024 AS online_index_vs_mb,
       current_aborted_transaction_count,
       oldest_active_transaction_id, oldest_aborted_transaction_id,
       pvs_off_row_page_skipped_oldest_active_xdesid   -- >0 = a long open tran is blocking PVS cleanup
FROM sys.dm_tran_persistent_version_store_stats
WHERE database_id = DB_ID();
