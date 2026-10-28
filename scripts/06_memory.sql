/*******************************************************************************
 File    : 06_memory.sql
 Purpose : Memory pressure, buffer pool usage, memory grants, PLE.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] Managed Instance   [SQLDB] Azure SQL DB
*******************************************************************************/

/*=============================================================================
  6.1  OS + SQL PROCESS MEMORY OVERVIEW                               [BOX][MI]
  system_memory_state_desc should be "Available physical memory is high".
  process_physical_memory_low / virtual_memory_low = 1 is a red flag.
=============================================================================*/
SELECT total_physical_memory_kb / 1024     AS os_total_mb,
       available_physical_memory_kb / 1024 AS os_available_mb,
       total_page_file_kb / 1024           AS page_file_mb,
       system_memory_state_desc
FROM sys.dm_os_sys_memory;

SELECT physical_memory_in_use_kb / 1024     AS sql_physical_in_use_mb,
       locked_page_allocations_kb / 1024    AS locked_pages_mb,
       large_page_allocations_kb / 1024     AS large_pages_mb,
       memory_utilization_percentage,
       available_commit_limit_kb / 1024     AS available_commit_mb,
       process_physical_memory_low, process_virtual_memory_low,
       page_fault_count
FROM sys.dm_os_process_memory;


/*=============================================================================
  6.2  KEY MEMORY COUNTERS                                     [BOX][MI][SQLDB]
  Total < Target for long periods after warm-up = not enough memory needed;
  Memory Grants Pending > 0 sustained = memory pressure for queries.
=============================================================================*/
SELECT RTRIM(object_name) AS object_name, RTRIM(counter_name) AS counter_name,
       RTRIM(instance_name) AS instance_name, cntr_value
FROM sys.dm_os_performance_counters
WHERE (object_name LIKE N'%Memory Manager%' AND counter_name IN (
          N'Total Server Memory (KB)', N'Target Server Memory (KB)',
          N'Stolen Server Memory (KB)', N'Database Cache Memory (KB)',
          N'Free Memory (KB)', N'Memory Grants Pending', N'Memory Grants Outstanding'))
   OR (object_name LIKE N'%Buffer Manager%' AND counter_name IN (
          N'Page life expectancy', N'Lazy writes/sec', N'Page reads/sec', N'Checkpoint pages/sec'))
ORDER BY object_name, counter_name;


/*=============================================================================
  6.3  PAGE LIFE EXPECTANCY PER NUMA NODE                             [BOX][MI]
  Old "300 seconds" rule is outdated; rough guide = (buffer pool GB / 4) * 300.
  Watch for sudden drops more than the absolute value.
=============================================================================*/
SELECT RTRIM(object_name) AS object_name, RTRIM(instance_name) AS numa_node, cntr_value AS ple_seconds
FROM sys.dm_os_performance_counters
WHERE counter_name = N'Page life expectancy';


/*=============================================================================
  6.4  BUFFER POOL USAGE BY DATABASE                           [BOX][MI][SQLDB]
  Can take a while on servers with very large memory.
=============================================================================*/
SELECT
    CASE database_id WHEN 32767 THEN 'ResourceDb' ELSE DB_NAME(database_id) END AS database_name,
    COUNT_BIG(*) * 8 / 1024                                       AS cached_mb,
    SUM(CAST(is_modified AS int)) * 8 / 1024                      AS dirty_mb,
    CAST(100.0 * COUNT_BIG(*) / SUM(COUNT_BIG(*)) OVER () AS decimal(5,2)) AS pct_of_bp
FROM sys.dm_os_buffer_descriptors
GROUP BY database_id
ORDER BY cached_mb DESC;


/*=============================================================================
  6.5  BUFFER POOL USAGE BY OBJECT - CURRENT DB                [BOX][MI][SQLDB]
=============================================================================*/
SELECT TOP (25)
    OBJECT_SCHEMA_NAME(p.object_id) + N'.' + OBJECT_NAME(p.object_id) AS object_name,
    i.name AS index_name,
    COUNT_BIG(*) * 8 / 1024 AS cached_mb,
    SUM(CAST(bd.is_modified AS int)) * 8 / 1024 AS dirty_mb
FROM sys.dm_os_buffer_descriptors AS bd
JOIN sys.allocation_units AS au ON au.allocation_unit_id = bd.allocation_unit_id
JOIN sys.partitions       AS p  ON (au.type IN (1, 3) AND au.container_id = p.hobt_id)
                                OR (au.type = 2      AND au.container_id = p.partition_id)
LEFT JOIN sys.indexes     AS i  ON i.object_id = p.object_id AND i.index_id = p.index_id
WHERE bd.database_id = DB_ID()
  AND OBJECTPROPERTY(p.object_id, 'IsMSShipped') = 0
GROUP BY p.object_id, i.name
ORDER BY cached_mb DESC;


/*=============================================================================
  6.6  TOP MEMORY CLERKS (who is using non-buffer memory)      [BOX][MI][SQLDB]
  Large CACHESTORE_SQLCP = ad hoc plan bloat; MEMORYCLERK_SQLQERESERVATIONS
  = query grants; OBJECTSTORE_LOCK_MANAGER = lots of locks.
=============================================================================*/
SELECT TOP (20) [type] AS clerk_type, name,
       SUM(pages_kb) / 1024 AS memory_mb
FROM sys.dm_os_memory_clerks
GROUP BY [type], name
ORDER BY memory_mb DESC;


/*=============================================================================
  6.7  MEMORY GRANTS - WAITING AND RUNNING                     [BOX][MI][SQLDB]
  grant_time NULL = still waiting (RESOURCE_SEMAPHORE wait).
=============================================================================*/
SELECT mg.session_id, mg.request_time, mg.grant_time,
       mg.requested_memory_kb / 1024 AS requested_mb,
       mg.granted_memory_kb / 1024   AS granted_mb,
       mg.used_memory_kb / 1024      AS used_mb,
       mg.ideal_memory_kb / 1024     AS ideal_mb,
       mg.wait_time_ms, mg.dop, mg.query_cost, mg.resource_semaphore_id,
       t.text AS sql_text, qp.query_plan
FROM sys.dm_exec_query_memory_grants AS mg
OUTER APPLY sys.dm_exec_sql_text(mg.sql_handle)    AS t
OUTER APPLY sys.dm_exec_query_plan(mg.plan_handle) AS qp
ORDER BY mg.requested_memory_kb DESC;

SELECT resource_semaphore_id, pool_id, target_memory_kb / 1024 AS target_mb,
       total_memory_kb / 1024 AS total_mb, available_memory_kb / 1024 AS available_mb,
       granted_memory_kb / 1024 AS granted_mb, grantee_count, waiter_count, timeout_error_count
FROM sys.dm_exec_query_resource_semaphores;


/*=============================================================================
  6.8  LOW MEMORY NOTIFICATIONS FROM RING BUFFER                      [BOX][MI]
=============================================================================*/
DECLARE @ms_now bigint = (SELECT ms_ticks FROM sys.dm_os_sys_info);
SELECT TOP (50)
    DATEADD(MILLISECOND, -1 * (@ms_now - rb.[timestamp]), SYSDATETIME()) AS event_time,
    x.record.value('(./Record/ResourceMonitor/Notification)[1]', 'varchar(50)')        AS notification,
    x.record.value('(./Record/MemoryRecord/AvailablePhysicalMemory)[1]', 'bigint') / 1024 AS os_available_mb,
    x.record.value('(./Record/MemoryNode/TargetMemory)[1]', 'bigint') / 1024           AS sql_target_mb,
    x.record.value('(./Record/MemoryNode/CommittedMemory)[1]', 'bigint') / 1024        AS sql_committed_mb
FROM sys.dm_os_ring_buffers AS rb
CROSS APPLY (SELECT CAST(rb.record AS xml)) AS x(record)
WHERE rb.ring_buffer_type = N'RING_BUFFER_RESOURCE_MONITOR'
ORDER BY rb.[timestamp] DESC;


/*=============================================================================
  6.9  OUT-OF-MEMORY EVENTS (2022+, Azure SQL DB, MI)          [BOX][MI][SQLDB]
=============================================================================*/
SELECT *        -- key columns: event_time, oom_cause_desc, top_memory_clerks, top_resource_pools
FROM sys.dm_os_out_of_memory_events
ORDER BY event_time DESC;


/*=============================================================================
  6.10 MEMORY SETTINGS CHECK                                          [BOX][MI]
=============================================================================*/
SELECT
    (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'max server memory (MB)') AS max_server_memory_mb,
    (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'min server memory (MB)') AS min_server_memory_mb,
    (SELECT physical_memory_kb / 1024 FROM sys.dm_os_sys_info)                                      AS physical_memory_mb,
    (SELECT sql_memory_model_desc FROM sys.dm_os_sys_info)                                          AS memory_model;
-- EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
-- EXEC sp_configure 'max server memory (MB)', 28672; RECONFIGURE;
