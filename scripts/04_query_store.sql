/*******************************************************************************
 File    : 04_query_store.sql
 Purpose : Historical query performance, plan regressions, forced plans.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] Managed Instance   [SQLDB] Azure SQL DB
 Note    : Run in the context of the user database (USE YourDB). Query Store is
           ON by default for new DBs in 2022+ and in Azure SQL DB / MI.
           Times in Query Store are UTC (datetimeoffset).
*******************************************************************************/

/*=============================================================================
  4.1  QUERY STORE STATUS - CURRENT DB                         [BOX][MI][SQLDB]
  actual_state_desc = READ_ONLY when desired = READ_WRITE usually means it
  hit max size -> see readonly_reason / increase MAX_STORAGE_SIZE_MB.
=============================================================================*/
SELECT DB_NAME()                     AS database_name,
       desired_state_desc, actual_state_desc, readonly_reason,
       current_storage_size_mb, max_storage_size_mb,
       query_capture_mode_desc, size_based_cleanup_mode_desc,
       stale_query_threshold_days, interval_length_minutes,
       flush_interval_seconds, max_plans_per_query, wait_stats_capture_mode_desc
FROM sys.database_query_store_options;


/*=============================================================================
  4.2  QUERY STORE STATUS - ALL DATABASES                             [BOX][MI]
=============================================================================*/
SELECT name, is_query_store_on FROM sys.databases WHERE database_id > 4 ORDER BY name;


/*=============================================================================
  4.3  TOP QUERIES IN LAST N HOURS (choose metric)             [BOX][MI][SQLDB]
=============================================================================*/
DECLARE @hours int = 24, @metric varchar(10) = 'CPU';   -- CPU | DURATION | READS | EXECS | MEMORY

WITH agg AS (
    SELECT
        q.query_id,
        SUM(rs.count_executions)                                       AS execs,
        SUM(rs.avg_cpu_time        * rs.count_executions) / 1000.0     AS total_cpu_ms,
        SUM(rs.avg_duration        * rs.count_executions) / 1000.0     AS total_duration_ms,
        SUM(rs.avg_logical_io_reads* rs.count_executions)              AS total_reads,
        SUM(rs.avg_query_max_used_memory * rs.count_executions) * 8 / 1024.0 AS total_mem_mb,
        COUNT(DISTINCT p.plan_id)                                      AS plan_count
    FROM sys.query_store_runtime_stats          AS rs
    JOIN sys.query_store_runtime_stats_interval AS i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
    JOIN sys.query_store_plan                   AS p ON p.plan_id = rs.plan_id
    JOIN sys.query_store_query                  AS q ON q.query_id = p.query_id
    WHERE i.start_time >= DATEADD(HOUR, -@hours, SYSDATETIMEOFFSET())
    GROUP BY q.query_id
)
SELECT TOP (25)
    a.query_id,
    OBJECT_SCHEMA_NAME(q.object_id) + N'.' + OBJECT_NAME(q.object_id) AS object_name,
    a.execs, a.plan_count,
    CAST(a.total_cpu_ms                AS decimal(18,0)) AS total_cpu_ms,
    CAST(a.total_cpu_ms / a.execs      AS decimal(18,2)) AS avg_cpu_ms,
    CAST(a.total_duration_ms / a.execs AS decimal(18,2)) AS avg_duration_ms,
    CAST(a.total_reads / a.execs       AS decimal(18,0)) AS avg_reads,
    qt.query_sql_text
FROM agg AS a
JOIN sys.query_store_query      AS q  ON q.query_id = a.query_id
JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
ORDER BY CASE @metric
            WHEN 'CPU'      THEN a.total_cpu_ms
            WHEN 'DURATION' THEN a.total_duration_ms
            WHEN 'READS'    THEN a.total_reads
            WHEN 'EXECS'    THEN a.execs
            WHEN 'MEMORY'   THEN a.total_mem_mb END DESC;


/*=============================================================================
  4.4  REGRESSED QUERIES: RECENT vs HISTORY (avg duration)     [BOX][MI][SQLDB]
=============================================================================*/
DECLARE @recent_hours int = 4, @history_days int = 7;

WITH recent AS (
    SELECT p.query_id, SUM(rs.avg_duration * rs.count_executions) / SUM(rs.count_executions) AS avg_dur, SUM(rs.count_executions) AS execs
    FROM sys.query_store_runtime_stats AS rs
    JOIN sys.query_store_runtime_stats_interval AS i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
    JOIN sys.query_store_plan AS p ON p.plan_id = rs.plan_id
    WHERE i.start_time >= DATEADD(HOUR, -@recent_hours, SYSDATETIMEOFFSET())
    GROUP BY p.query_id
), hist AS (
    SELECT p.query_id, SUM(rs.avg_duration * rs.count_executions) / SUM(rs.count_executions) AS avg_dur, SUM(rs.count_executions) AS execs
    FROM sys.query_store_runtime_stats AS rs
    JOIN sys.query_store_runtime_stats_interval AS i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
    JOIN sys.query_store_plan AS p ON p.plan_id = rs.plan_id
    WHERE i.start_time >= DATEADD(DAY, -@history_days, SYSDATETIMEOFFSET())
      AND i.start_time <  DATEADD(HOUR, -@recent_hours, SYSDATETIMEOFFSET())
    GROUP BY p.query_id
)
SELECT TOP (25)
    r.query_id,
    CAST(h.avg_dur / 1000.0 AS decimal(18,2)) AS hist_avg_ms,
    CAST(r.avg_dur / 1000.0 AS decimal(18,2)) AS recent_avg_ms,
    CAST(r.avg_dur / NULLIF(h.avg_dur, 0) AS decimal(10,2)) AS times_slower,
    r.execs AS recent_execs, h.execs AS hist_execs,
    qt.query_sql_text
FROM recent AS r
JOIN hist   AS h ON h.query_id = r.query_id
JOIN sys.query_store_query      AS q  ON q.query_id = r.query_id
JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
WHERE r.avg_dur > 2 * h.avg_dur
  AND r.execs >= 5
ORDER BY (r.avg_dur - h.avg_dur) * r.execs DESC;


/*=============================================================================
  4.5  QUERIES WITH MULTIPLE PLANS (plan instability)          [BOX][MI][SQLDB]
=============================================================================*/
WITH mp AS (
    SELECT q.query_id, q.query_text_id,
           COUNT(DISTINCT p.plan_id)          AS plan_count,
           MAX(CAST(p.is_forced_plan AS int)) AS has_forced_plan
    FROM sys.query_store_query AS q
    JOIN sys.query_store_plan  AS p ON p.query_id = q.query_id
    GROUP BY q.query_id, q.query_text_id
    HAVING COUNT(DISTINCT p.plan_id) > 1
)
SELECT TOP (25) mp.query_id, mp.plan_count, mp.has_forced_plan, qt.query_sql_text
FROM mp
JOIN sys.query_store_query_text AS qt ON qt.query_text_id = mp.query_text_id
ORDER BY mp.plan_count DESC;

-- Per-plan stats for one query (pick the good plan to force)
DECLARE @qid bigint = 1;   -- <== change
WITH s AS (
    SELECT rs.plan_id,
           SUM(rs.count_executions) AS execs,
           SUM(rs.avg_duration * rs.count_executions) / SUM(rs.count_executions) / 1000.0 AS avg_duration_ms,
           SUM(rs.avg_cpu_time * rs.count_executions) / SUM(rs.count_executions) / 1000.0 AS avg_cpu_ms,
           SUM(rs.avg_logical_io_reads * rs.count_executions) / SUM(rs.count_executions)  AS avg_reads
    FROM sys.query_store_runtime_stats AS rs
    JOIN sys.query_store_plan AS p ON p.plan_id = rs.plan_id
    WHERE p.query_id = @qid
    GROUP BY rs.plan_id
)
SELECT p.plan_id, p.is_forced_plan, p.last_execution_time, s.execs,
       CAST(s.avg_duration_ms AS decimal(18,2)) AS avg_duration_ms,
       CAST(s.avg_cpu_ms      AS decimal(18,2)) AS avg_cpu_ms,
       CAST(s.avg_reads       AS decimal(18,0)) AS avg_reads,
       TRY_CAST(p.query_plan AS xml) AS query_plan
FROM s
JOIN sys.query_store_plan AS p ON p.plan_id = s.plan_id
ORDER BY s.avg_duration_ms;


/*=============================================================================
  4.6  FORCED PLANS & FORCING FAILURES                         [BOX][MI][SQLDB]
=============================================================================*/
SELECT p.query_id, p.plan_id, p.plan_forcing_type_desc,
       p.force_failure_count, p.last_force_failure_reason_desc,
       p.last_execution_time, qt.query_sql_text
FROM sys.query_store_plan       AS p
JOIN sys.query_store_query      AS q  ON q.query_id = p.query_id
JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
WHERE p.is_forced_plan = 1;

-- EXEC sys.sp_query_store_force_plan   @query_id = 1, @plan_id = 1;
-- EXEC sys.sp_query_store_unforce_plan @query_id = 1, @plan_id = 1;


/*=============================================================================
  4.7  WAIT CATEGORIES PER QUERY (2017+)                       [BOX][MI][SQLDB]
=============================================================================*/
DECLARE @hrs int = 24;
SELECT TOP (25) p.query_id, ws.wait_category_desc,
       SUM(ws.total_query_wait_time_ms) AS total_wait_ms
FROM sys.query_store_wait_stats AS ws
JOIN sys.query_store_runtime_stats_interval AS i ON i.runtime_stats_interval_id = ws.runtime_stats_interval_id
JOIN sys.query_store_plan AS p ON p.plan_id = ws.plan_id
WHERE i.start_time >= DATEADD(HOUR, -@hrs, SYSDATETIMEOFFSET())
GROUP BY p.query_id, ws.wait_category_desc
ORDER BY total_wait_ms DESC;


/*=============================================================================
  4.8  QUERY STORE HINTS (2022+, Azure SQL DB, MI)             [BOX][MI][SQLDB]
=============================================================================*/
SELECT query_hint_id, query_id, query_hint_text, last_query_hint_failure_reason_desc,
       query_hint_failure_count, source_desc
FROM sys.query_store_query_hints;

-- EXEC sys.sp_query_store_set_hints   @query_id = 1, @query_hints = N'OPTION (MAXDOP 1)';
-- EXEC sys.sp_query_store_clear_hints @query_id = 1;


/*=============================================================================
  4.9  FIND A QUERY IN QUERY STORE BY TEXT                     [BOX][MI][SQLDB]
=============================================================================*/
SELECT q.query_id, q.last_execution_time, OBJECT_NAME(q.object_id) AS object_name, qt.query_sql_text
FROM sys.query_store_query      AS q
JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
WHERE qt.query_sql_text LIKE N'%YourText%'      -- <== change
ORDER BY q.last_execution_time DESC;


/*=============================================================================
  4.10 ENABLE / FIX QUERY STORE (templates)                    [BOX][MI][SQLDB]
=============================================================================*/
/*
ALTER DATABASE [YourDB] SET QUERY_STORE = ON;
ALTER DATABASE [YourDB] SET QUERY_STORE (
    OPERATION_MODE = READ_WRITE,
    MAX_STORAGE_SIZE_MB = 2048,
    QUERY_CAPTURE_MODE = AUTO,
    SIZE_BASED_CLEANUP_MODE = AUTO,
    CLEANUP_POLICY = (STALE_QUERY_THRESHOLD_DAYS = 30),
    WAIT_STATS_CAPTURE_MODE = ON);
-- ALTER DATABASE [YourDB] SET QUERY_STORE CLEAR;   -- wipes all QS data
*/
