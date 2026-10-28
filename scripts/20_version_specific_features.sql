/*******************************************************************************
 File    : 20_version_specific_features.sql
 Purpose : DMVs / checks that only exist from a given version onward.
 Tags    : version noted per section. Azure SQL DB and MI usually have all
           of these (they run the latest engine).
*******************************************************************************/

/*=============================================================================
  20.1  2017+ : HOST INFO, AUTOMATIC TUNING, RESUMABLE INDEX
=============================================================================*/
SELECT * FROM sys.dm_os_host_info;                       -- Windows or Linux
SELECT * FROM sys.dm_db_tuning_recommendations;          -- plan regression recommendations (current DB)
SELECT * FROM sys.index_resumable_operations;            -- paused/running resumable rebuilds


/*=============================================================================
  20.2  2019+ : ACCELERATED DATABASE RECOVERY (ADR)
=============================================================================*/
SELECT name, is_accelerated_database_recovery_on FROM sys.databases ORDER BY name;

SELECT DB_NAME(database_id) AS database_name,
       persistent_version_store_size_kb / 1024 AS pvs_mb,
       current_aborted_transaction_count, oldest_active_transaction_id
FROM sys.dm_tran_persistent_version_store_stats;
-- ALTER DATABASE [YourDB] SET ACCELERATED_DATABASE_RECOVERY = ON;


/*=============================================================================
  20.3  2019+ : DECODE A wait_resource PAGE (PAGELATCH / PAGEIOLATCH)
  Replaces DBCC PAGE for finding which object a hot page belongs to.
=============================================================================*/
SELECT r.session_id, r.wait_type, r.wait_resource,
       OBJECT_SCHEMA_NAME(pi.object_id, pi.database_id) + N'.' + OBJECT_NAME(pi.object_id, pi.database_id) AS object_name,
       pi.index_id, pi.page_type_desc
FROM sys.dm_exec_requests AS r
CROSS APPLY sys.fn_PageResCracker(r.page_resource) AS prc
CROSS APPLY sys.dm_db_page_info(prc.db_id, prc.file_id, prc.page_id, 'LIMITED') AS pi
WHERE r.page_resource IS NOT NULL;


/*=============================================================================
  20.4  2019+ : LAST ACTUAL EXECUTION PLAN FROM CACHE
  Needs: ALTER DATABASE SCOPED CONFIGURATION SET LAST_QUERY_PLAN_STATS = ON;
=============================================================================*/
SELECT TOP (10) DB_NAME(t.dbid) AS database_name, qs.execution_count, t.text, qps.query_plan AS last_actual_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
CROSS APPLY sys.dm_exec_query_plan_stats(qs.plan_handle) AS qps
ORDER BY qs.total_worker_time DESC;


/*=============================================================================
  20.5  2019+ : MISSING INDEX -> WHICH QUERY ASKED FOR IT
=============================================================================*/
SELECT TOP (20) mid.statement AS table_name, mid.equality_columns, mid.inequality_columns, mid.included_columns,
       migsq.user_seeks, migsq.avg_user_impact, migsq.avg_total_user_cost,
       SUBSTRING(t.text, migsq.last_statement_start_offset / 2 + 1,
           (CASE migsq.last_statement_end_offset WHEN -1 THEN DATALENGTH(t.text)
            ELSE migsq.last_statement_end_offset END - migsq.last_statement_start_offset) / 2 + 1) AS query_text
FROM sys.dm_db_missing_index_group_stats_query AS migsq
JOIN sys.dm_db_missing_index_groups  AS mig ON mig.index_group_handle = migsq.group_handle
JOIN sys.dm_db_missing_index_details AS mid ON mid.index_handle = mig.index_handle
CROSS APPLY sys.dm_exec_sql_text(migsq.last_sql_handle) AS t
ORDER BY migsq.avg_total_user_cost * migsq.avg_user_impact * migsq.user_seeks DESC;


/*=============================================================================
  20.6  2019+ : INTELLIGENT QUERY PROCESSING SETTINGS (current DB)
=============================================================================*/
SELECT name, value, is_value_default
FROM sys.database_scoped_configurations
WHERE name IN (N'BATCH_MODE_ON_ROWSTORE', N'BATCH_MODE_MEMORY_GRANT_FEEDBACK',
               N'ROW_MODE_MEMORY_GRANT_FEEDBACK', N'INTERLEAVED_EXECUTION_TVF',
               N'TSQL_SCALAR_UDF_INLINING', N'DEFERRED_COMPILATION_TV',
               N'PARAMETER_SENSITIVE_PLAN_OPTIMIZATION', N'DOP_FEEDBACK', N'CE_FEEDBACK',
               N'MEMORY_GRANT_FEEDBACK_PERCENTILE_GRANT', N'MEMORY_GRANT_FEEDBACK_PERSISTENCE',
               N'OPTIMIZED_PLAN_FORCING', N'LAST_QUERY_PLAN_STATS', N'LIGHTWEIGHT_QUERY_PROFILING')
ORDER BY name;


/*=============================================================================
  20.7  2022+ : CONTAINED AVAILABILITY GROUPS
=============================================================================*/
SELECT name, is_contained, cluster_type_desc FROM sys.availability_groups;


/*=============================================================================
  20.8  2022+ : PARAMETER SENSITIVE PLAN (PSP) VARIANTS IN QUERY STORE
=============================================================================*/
SELECT qv.query_variant_query_id, qv.parent_query_id, qv.dispatcher_plan_id, qt.query_sql_text
FROM sys.query_store_query_variant AS qv
JOIN sys.query_store_query AS q ON q.query_id = qv.parent_query_id
JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id;


/*=============================================================================
  20.9  2022+ : LEDGER TABLES
=============================================================================*/
SELECT OBJECT_SCHEMA_NAME(object_id) + N'.' + name AS table_name, ledger_type_desc, is_dropped_ledger_table
FROM sys.tables
WHERE ledger_type <> 0;


/*=============================================================================
  20.10 2022+ : OUT-OF-MEMORY EVENTS
=============================================================================*/
SELECT * FROM sys.dm_os_out_of_memory_events ORDER BY event_time DESC;


/*=============================================================================
  20.11 2025 (and Azure SQL DB) : OPTIMIZED LOCKING
  Requires ADR. Reduces lock memory / blocking via TID locking + LAQ.
  Verify feature names/columns on your exact build - 2025 is the newest
  release and some DMVs/properties have evolved through CUs.
=============================================================================*/
SELECT name,
       is_accelerated_database_recovery_on,
       is_read_committed_snapshot_on,
       DATABASEPROPERTYEX(name, 'IsOptimizedLockingOn') AS is_optimized_locking_on
FROM sys.databases
WHERE database_id > 4
ORDER BY name;
-- ALTER DATABASE [YourDB] SET OPTIMIZED_LOCKING = ON;   -- ADR must be ON first


/*=============================================================================
  20.12 QUICK "WHAT VERSION AM I ON" DECODER
=============================================================================*/
SELECT CASE PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS varchar(20)), 4)
           WHEN '13' THEN 'SQL Server 2016'
           WHEN '14' THEN 'SQL Server 2017'
           WHEN '15' THEN 'SQL Server 2019'
           WHEN '16' THEN 'SQL Server 2022'
           WHEN '17' THEN 'SQL Server 2025'
           WHEN '12' THEN CASE WHEN SERVERPROPERTY('EngineEdition') = 5 THEN 'Azure SQL Database'
                               WHEN SERVERPROPERTY('EngineEdition') = 8 THEN 'Azure SQL Managed Instance'
                               ELSE 'SQL Server 2014' END
           ELSE 'Other / unknown' END AS sql_version,
       SERVERPROPERTY('ProductVersion') AS build,
       SERVERPROPERTY('ProductUpdateLevel') AS cu,
       SERVERPROPERTY('EngineEdition') AS engine_edition;
