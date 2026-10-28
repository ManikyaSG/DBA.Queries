/*******************************************************************************
 File    : 03_query_performance_plan_cache.sql
 Purpose : Find the expensive queries / procedures from the plan cache.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] Managed Instance   [SQLDB] Azure SQL DB
 Note    : Plan cache only holds what is cached NOW (lost on restart, memory
           pressure, recompiles, OPTION(RECOMPILE)). For history use Query Store
           (04_query_store.sql).
*******************************************************************************/

/*=============================================================================
  3.1  TOP N STATEMENTS - CHOOSE THE SORT                      [BOX][MI][SQLDB]
  @SortBy: CPU | READS | WRITES | DURATION | EXECS | GRANT | SPILLS
  total_spills needs 2016 SP2+ / 2017+
=============================================================================*/
DECLARE @SortBy varchar(10) = 'CPU';   -- <== change
DECLARE @Top    int         = 25;

SELECT TOP (@Top)
    DB_NAME(t.dbid)                                         AS database_name,
    OBJECT_SCHEMA_NAME(t.objectid, t.dbid) + N'.' + OBJECT_NAME(t.objectid, t.dbid) AS object_name,
    qs.execution_count,
    qs.total_worker_time / 1000                             AS total_cpu_ms,
    qs.total_worker_time / qs.execution_count / 1000        AS avg_cpu_ms,
    qs.total_elapsed_time / qs.execution_count / 1000       AS avg_duration_ms,
    qs.total_logical_reads / qs.execution_count             AS avg_logical_reads,
    qs.total_logical_writes / qs.execution_count            AS avg_logical_writes,
    qs.total_physical_reads / qs.execution_count            AS avg_physical_reads,
    qs.total_rows / qs.execution_count                      AS avg_rows,
    qs.total_grant_kb / qs.execution_count / 1024           AS avg_grant_mb,
    qs.total_spills / qs.execution_count                    AS avg_spills,
    qs.creation_time                                        AS plan_cached_at,
    qs.last_execution_time,
    SUBSTRING(t.text, (qs.statement_start_offset / 2) + 1,
        ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(t.text)
          ELSE qs.statement_end_offset END - qs.statement_start_offset) / 2) + 1) AS statement_text,
    qs.query_hash, qs.query_plan_hash, qs.plan_handle,
    qp.query_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)      AS t
OUTER APPLY sys.dm_exec_query_plan(qs.plan_handle)   AS qp
ORDER BY
    CASE @SortBy
        WHEN 'CPU'      THEN qs.total_worker_time
        WHEN 'READS'    THEN qs.total_logical_reads
        WHEN 'WRITES'   THEN qs.total_logical_writes
        WHEN 'DURATION' THEN qs.total_elapsed_time
        WHEN 'EXECS'    THEN qs.execution_count
        WHEN 'GRANT'    THEN qs.total_grant_kb
        WHEN 'SPILLS'   THEN qs.total_spills
    END DESC;


/*=============================================================================
  3.2  TOP STORED PROCEDURES                                   [BOX][MI][SQLDB]
=============================================================================*/
SELECT TOP (25)
    DB_NAME(ps.database_id)                               AS database_name,
    OBJECT_SCHEMA_NAME(ps.object_id, ps.database_id) + N'.' + OBJECT_NAME(ps.object_id, ps.database_id) AS proc_name,
    ps.execution_count,
    ps.total_worker_time / 1000                           AS total_cpu_ms,
    ps.total_worker_time / ps.execution_count / 1000      AS avg_cpu_ms,
    ps.total_elapsed_time / ps.execution_count / 1000     AS avg_duration_ms,
    ps.total_logical_reads / ps.execution_count           AS avg_logical_reads,
    ps.cached_time, ps.last_execution_time
FROM sys.dm_exec_procedure_stats AS ps
ORDER BY ps.total_worker_time DESC;


/*=============================================================================
  3.3  TOP QUERIES AGGREGATED BY query_hash                    [BOX][MI][SQLDB]
  Catches ad-hoc / non-parameterised workloads where the same query shape
  appears as thousands of separate cache entries.
=============================================================================*/
SELECT TOP (25)
    qs.query_hash,
    COUNT(*)                                      AS cached_plan_entries,
    SUM(qs.execution_count)                       AS executions,
    SUM(qs.total_worker_time) / 1000              AS total_cpu_ms,
    SUM(qs.total_logical_reads)                   AS total_reads,
    MAX(CAST(SUBSTRING(t.text, (qs.statement_start_offset / 2) + 1, 4000) AS nvarchar(4000))) AS sample_text
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
GROUP BY qs.query_hash
ORDER BY total_cpu_ms DESC;


/*=============================================================================
  3.4  PARAMETER SNIFFING SUSPECTS (large min/max variance)    [BOX][MI][SQLDB]
=============================================================================*/
SELECT TOP (25)
    DB_NAME(t.dbid) AS database_name,
    OBJECT_NAME(t.objectid, t.dbid) AS object_name,
    qs.execution_count,
    qs.min_worker_time / 1000  AS min_cpu_ms,
    qs.max_worker_time / 1000  AS max_cpu_ms,
    qs.min_logical_reads, qs.max_logical_reads,
    qs.min_rows, qs.max_rows,
    SUBSTRING(t.text, (qs.statement_start_offset / 2) + 1,
        ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(t.text)
          ELSE qs.statement_end_offset END - qs.statement_start_offset) / 2) + 1) AS statement_text,
    qs.plan_handle
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
WHERE qs.execution_count > 10
  AND qs.max_logical_reads > 10 * (qs.min_logical_reads + 1)
ORDER BY qs.max_logical_reads - qs.min_logical_reads DESC;


/*=============================================================================
  3.5  FIND A QUERY IN CACHE BY TEXT                           [BOX][MI][SQLDB]
=============================================================================*/
DECLARE @search nvarchar(200) = N'%YourTableOrProcName%';   -- <== change
SELECT TOP (50)
    DB_NAME(t.dbid) AS database_name, qs.execution_count,
    qs.total_worker_time / qs.execution_count / 1000 AS avg_cpu_ms,
    qs.last_execution_time, t.text, qs.plan_handle, qp.query_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS t
OUTER APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE t.text LIKE @search
  AND t.text NOT LIKE N'%dm_exec_query_stats%'
ORDER BY qs.last_execution_time DESC;


/*=============================================================================
  3.6  PLAN CACHE COMPOSITION & SINGLE-USE PLAN BLOAT          [BOX][MI][SQLDB]
  Many MB in single-use Adhoc plans -> consider 'optimize for ad hoc workloads'.
=============================================================================*/
SELECT cp.objtype, cp.cacheobjtype,
       COUNT(*)                                                    AS plan_count,
       SUM(CAST(cp.size_in_bytes AS bigint)) / 1048576             AS total_mb,
       SUM(CASE WHEN cp.usecounts = 1 THEN 1 ELSE 0 END)           AS single_use_plans,
       SUM(CASE WHEN cp.usecounts = 1 THEN CAST(cp.size_in_bytes AS bigint) ELSE 0 END) / 1048576 AS single_use_mb
FROM sys.dm_exec_cached_plans AS cp
GROUP BY cp.objtype, cp.cacheobjtype
ORDER BY total_mb DESC;


/*=============================================================================
  3.7  PLANS WITH IMPLICIT CONVERSIONS / MISSING INDEX / WARNINGS
                                                               [BOX][MI][SQLDB]
  XML shredding is expensive - run off-peak on busy servers.
=============================================================================*/
WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
SELECT TOP (50)
    DB_NAME(t.dbid)                                                         AS database_name,
    qs.execution_count,
    qs.total_worker_time / 1000                                             AS total_cpu_ms,
    qp.query_plan.exist('//PlanAffectingConvert')                           AS has_implicit_convert,
    qp.query_plan.exist('//MissingIndexes')                                 AS has_missing_index,
    qp.query_plan.exist('//Warnings/SpillToTempDb')                         AS has_spill,
    qp.query_plan.exist('//Warnings/NoJoinPredicate')                       AS has_no_join_predicate,
    t.text, qp.query_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS t
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE qp.query_plan.exist('//PlanAffectingConvert') = 1
   OR qp.query_plan.exist('//Warnings') = 1
ORDER BY qs.total_worker_time DESC;


/*=============================================================================
  3.8  RECOMPILES / COMPILATIONS RATE                                 [BOX][MI]
  Values are cumulative counters - sample twice and diff for a per-sec rate.
=============================================================================*/
SELECT counter_name, cntr_value
FROM sys.dm_os_performance_counters
WHERE object_name LIKE N'%SQL Statistics%'
  AND counter_name IN (N'Batch Requests/sec', N'SQL Compilations/sec', N'SQL Re-Compilations/sec');


/*=============================================================================
  3.9  REMOVE ONE BAD PLAN FROM CACHE (surgical, not FREEPROCCACHE)
                                                               [BOX][MI][SQLDB]
=============================================================================*/
-- DBCC FREEPROCCACHE (0x060005....);                            -- plan_handle from 3.1 / 3.5
-- ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;    -- current DB only (2016+, Azure)
