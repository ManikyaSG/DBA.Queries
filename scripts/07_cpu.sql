/*******************************************************************************
 File    : 07_cpu.sql
 Purpose : CPU utilisation history, scheduler pressure, who is burning CPU.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] Managed Instance   [SQLDB] Azure SQL DB
 Note    : Azure SQL DB CPU history -> 16_azure_sql_database.sql (dm_db_resource_stats)
           Managed Instance CPU history -> 17_azure_managed_instance.sql
*******************************************************************************/

/*=============================================================================
  7.1  CPU % - LAST ~256 MINUTES (1-minute samples)                   [BOX][MI]
  sql_cpu = SQL Server process, other_cpu = everything else on the box.
=============================================================================*/
DECLARE @ms_now bigint = (SELECT ms_ticks FROM sys.dm_os_sys_info);

SELECT TOP (256)
    DATEADD(MILLISECOND, -1 * (@ms_now - y.[timestamp]), SYSDATETIME()) AS sample_time,
    y.sql_cpu,
    100 - y.system_idle - y.sql_cpu AS other_cpu,
    y.system_idle
FROM (
    SELECT x.[timestamp],
           x.rec.value('(./Record/@id)[1]', 'int') AS record_id,
           x.rec.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int')         AS system_idle,
           x.rec.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') AS sql_cpu
    FROM (SELECT [timestamp], CONVERT(xml, record) AS rec
          FROM sys.dm_os_ring_buffers
          WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
            AND record LIKE N'%<SystemHealth>%') AS x
) AS y
ORDER BY y.record_id DESC;


/*=============================================================================
  7.2  SCHEDULER PRESSURE (runnable queue)                     [BOX][MI][SQLDB]
  runnable_tasks_count consistently > 0 on many schedulers = CPU pressure.
=============================================================================*/
SELECT scheduler_id, cpu_id, parent_node_id, status, is_online,
       current_tasks_count, runnable_tasks_count, current_workers_count,
       active_workers_count, work_queue_count, pending_disk_io_count, load_factor
FROM sys.dm_os_schedulers
WHERE status = N'VISIBLE ONLINE'
ORDER BY runnable_tasks_count DESC;

SELECT SUM(runnable_tasks_count) AS total_runnable,
       AVG(runnable_tasks_count * 1.0) AS avg_runnable_per_scheduler,
       SUM(work_queue_count) AS tasks_waiting_for_worker
FROM sys.dm_os_schedulers
WHERE status = N'VISIBLE ONLINE';


/*=============================================================================
  7.3  WORKER THREAD USAGE (THREADPOOL risk)                   [BOX][MI][SQLDB]
=============================================================================*/
SELECT
    (SELECT max_workers_count FROM sys.dm_os_sys_info)                                AS max_workers,
    (SELECT SUM(current_workers_count) FROM sys.dm_os_schedulers WHERE status = N'VISIBLE ONLINE') AS current_workers,
    (SELECT SUM(active_workers_count)  FROM sys.dm_os_schedulers WHERE status = N'VISIBLE ONLINE') AS active_workers,
    (SELECT COUNT(*) FROM sys.dm_os_waiting_tasks WHERE wait_type = N'THREADPOOL')    AS tasks_waiting_threadpool;


/*=============================================================================
  7.4  TOP CPU CONSUMERS RIGHT NOW                             [BOX][MI][SQLDB]
=============================================================================*/
SELECT TOP (20)
    r.session_id, s.login_name, s.host_name, s.program_name, DB_NAME(r.database_id) AS database_name,
    r.cpu_time AS cpu_ms, r.total_elapsed_time / 1000 AS elapsed_s, r.dop,
    r.status, r.wait_type, r.logical_reads,
    SUBSTRING(t.text, (r.statement_start_offset / 2) + 1,
        ((CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(t.text)
          ELSE r.statement_end_offset END - r.statement_start_offset) / 2) + 1) AS statement_text
FROM sys.dm_exec_requests AS r
JOIN sys.dm_exec_sessions AS s ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE s.is_user_process = 1 AND r.session_id <> @@SPID
ORDER BY r.cpu_time DESC;


/*=============================================================================
  7.5  CPU USAGE BY DATABASE (from plan cache - approximate)   [BOX][MI][SQLDB]
=============================================================================*/
WITH db_cpu AS (
    SELECT CAST(pa.value AS int) AS database_id, SUM(qs.total_worker_time) AS cpu_us
    FROM sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_plan_attributes(qs.plan_handle) AS pa
    WHERE pa.attribute = N'dbid'
    GROUP BY CAST(pa.value AS int)
)
SELECT CASE database_id WHEN 32767 THEN 'ResourceDb' ELSE DB_NAME(database_id) END AS database_name,
       cpu_us / 1000 AS cpu_ms,
       CAST(100.0 * cpu_us / SUM(cpu_us) OVER () AS decimal(5,2)) AS cpu_pct
FROM db_cpu
ORDER BY cpu_us DESC;


/*=============================================================================
  7.6  NUMA NODES & PARALLELISM SETTINGS                       [BOX][MI][SQLDB]
=============================================================================*/
SELECT node_id, node_state_desc, memory_node_id, online_scheduler_count,
       active_worker_count, avg_load_balance, cpu_affinity_mask
FROM sys.dm_os_nodes
WHERE node_state_desc NOT LIKE N'%DAC%';

SELECT name, value_in_use FROM sys.configurations
WHERE name IN (N'max degree of parallelism', N'cost threshold for parallelism');

SELECT name, value FROM sys.database_scoped_configurations WHERE name = N'MAXDOP';
