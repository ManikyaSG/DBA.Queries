/*******************************************************************************
 File    : 09_tempdb.sql
 Purpose : tempdb configuration, space consumers, version store, contention.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] Managed Instance   [SQLDB] Azure SQL DB
*******************************************************************************/

/*=============================================================================
  9.1  TEMPDB FILE LAYOUT (equal sizes? equal growth? # files vs cores)
                                                                      [BOX][MI]
  Guide: 1 data file per logical core up to 8, all the same size & growth.
=============================================================================*/
SELECT name, type_desc, physical_name,
       CAST(CAST(size AS bigint) * 8 / 1024 AS bigint) AS size_mb,
       CASE WHEN is_percent_growth = 1 THEN CAST(growth AS varchar(10)) + ' %'
            ELSE CAST(growth * 8 / 1024 AS varchar(10)) + ' MB' END AS growth
FROM sys.master_files
WHERE database_id = 2
ORDER BY type_desc DESC, file_id;

SELECT (SELECT COUNT(*) FROM sys.master_files WHERE database_id = 2 AND type = 0) AS tempdb_data_files,
       (SELECT cpu_count FROM sys.dm_os_sys_info)                                AS logical_cpus,
       (SELECT COUNT(DISTINCT size) FROM sys.master_files WHERE database_id = 2 AND type = 0) AS distinct_sizes;  -- should be 1


/*=============================================================================
  9.2  TEMPDB SPACE BY CATEGORY                                [BOX][MI][SQLDB]
=============================================================================*/
SELECT
    SUM(total_page_count)                 * 8 / 1024 AS total_mb,
    SUM(unallocated_extent_page_count)    * 8 / 1024 AS free_mb,
    SUM(user_object_reserved_page_count)  * 8 / 1024 AS user_objects_mb,     -- #temp, @table vars
    SUM(internal_object_reserved_page_count) * 8 / 1024 AS internal_objects_mb, -- sorts, hashes, spools
    SUM(version_store_reserved_page_count)   * 8 / 1024 AS version_store_mb,   -- RCSI/SI/online index/AG readable secondary
    SUM(mixed_extent_page_count)          * 8 / 1024 AS mixed_extents_mb
FROM tempdb.sys.dm_db_file_space_usage;


/*=============================================================================
  9.3  TEMPDB USAGE BY SESSION (allocated incl. running tasks) [BOX][MI][SQLDB]
=============================================================================*/
WITH task AS (
    SELECT session_id,
           SUM(user_objects_alloc_page_count - user_objects_dealloc_page_count)         AS task_user_pages,
           SUM(internal_objects_alloc_page_count - internal_objects_dealloc_page_count) AS task_internal_pages
    FROM tempdb.sys.dm_db_task_space_usage
    GROUP BY session_id
)
SELECT TOP (25)
    ss.session_id, s.login_name, s.host_name, s.program_name, s.status,
    (ss.user_objects_alloc_page_count - ss.user_objects_dealloc_page_count + ISNULL(t.task_user_pages, 0)) * 8 / 1024         AS user_obj_mb,
    (ss.internal_objects_alloc_page_count - ss.internal_objects_dealloc_page_count + ISNULL(t.task_internal_pages, 0)) * 8 / 1024 AS internal_obj_mb,
    ib.event_info AS last_sql
FROM tempdb.sys.dm_db_session_space_usage AS ss
JOIN sys.dm_exec_sessions AS s ON s.session_id = ss.session_id
LEFT JOIN task AS t ON t.session_id = ss.session_id
OUTER APPLY sys.dm_exec_input_buffer(ss.session_id, NULL) AS ib
WHERE s.is_user_process = 1
ORDER BY user_obj_mb + internal_obj_mb DESC;


/*=============================================================================
  9.4  VERSION STORE BY DATABASE (2016 SP2+ / 2017+)           [BOX][MI]
=============================================================================*/
SELECT DB_NAME(database_id) AS database_name,
       reserved_page_count * 8 / 1024 AS version_store_mb,
       reserved_space_kb / 1024       AS reserved_mb
FROM sys.dm_tran_version_store_space_usage
ORDER BY reserved_page_count DESC;


/*=============================================================================
  9.5  LONG-RUNNING SNAPSHOT TRANSACTIONS (hold version store) [BOX][MI][SQLDB]
=============================================================================*/
SELECT TOP (20) ast.session_id, ast.transaction_id, ast.elapsed_time_seconds,
       ast.is_snapshot, s.login_name, s.host_name, s.program_name, ib.event_info AS last_sql
FROM sys.dm_tran_active_snapshot_database_transactions AS ast
JOIN sys.dm_exec_sessions AS s ON s.session_id = ast.session_id
OUTER APPLY sys.dm_exec_input_buffer(ast.session_id, NULL) AS ib
ORDER BY ast.elapsed_time_seconds DESC;


/*=============================================================================
  9.6  TEMPDB ALLOCATION CONTENTION (PAGELATCH on db 2)        [BOX][MI]
  Resource 2:x:1 (PFS), 2:x:2 (GAM), 2:x:3 (SGAM) -> add files / 2019+ enable
  memory-optimized tempdb metadata for system-table contention.
=============================================================================*/
SELECT session_id, wait_type, wait_duration_ms, resource_description
FROM sys.dm_os_waiting_tasks
WHERE wait_type LIKE N'PAGELATCH%'
  AND resource_description LIKE N'2:%';


/*=============================================================================
  9.7  MEMORY-OPTIMIZED TEMPDB METADATA (2019+)                       [BOX]
=============================================================================*/
SELECT SERVERPROPERTY('IsTempdbMetadataMemoryOptimized') AS is_tempdb_metadata_memory_optimized;
-- ALTER SERVER CONFIGURATION SET MEMORY_OPTIMIZED TEMPDB_METADATA = ON;   -- needs restart


/*=============================================================================
  9.8  RESIZE / ADD TEMPDB FILES (templates)                          [BOX]
=============================================================================*/
/*
ALTER DATABASE tempdb MODIFY FILE (NAME = N'tempdev',  SIZE = 8192MB, FILEGROWTH = 1024MB);
ALTER DATABASE tempdb ADD FILE    (NAME = N'tempdev2', FILENAME = N'T:\TempDB\tempdev2.ndf', SIZE = 8192MB, FILEGROWTH = 1024MB);
-- Azure VM: tempdb on the local D: (temporary) SSD is common; make sure the folder
-- is re-created at boot (SQL IaaS extension / scheduled task) if you use it.
*/
