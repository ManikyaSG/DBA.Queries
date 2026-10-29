/*******************************************************************************
 File    : 39_advanced_tuning.sql
 Purpose : Deeper tuning tools: statistics histograms & ascending keys,
           auto-update thresholds, estimate-vs-actual on running queries,
           parallelism & skew, compile cost / optimizer timeouts, plan
           guides, Resource Governor, In-Memory OLTP, spinlocks, hint
           quick reference.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] Managed Instance   [SQLDB] Azure SQL DB
*******************************************************************************/

/*=============================================================================
  39.1 STATISTICS ON A TABLE + HISTOGRAM          (2016 SP1 CU2+) [BOX][MI][SQLDB]
=============================================================================*/
DECLARE @tbl sysname = N'dbo.Orders';   -- <== change
SELECT s.stats_id, s.name AS stats_name, s.auto_created, s.has_filter, s.filter_definition,
       STUFF((SELECT N', ' + c.name FROM sys.stats_columns sc JOIN sys.columns c ON c.object_id = sc.object_id AND c.column_id = sc.column_id
              WHERE sc.object_id = s.object_id AND sc.stats_id = s.stats_id ORDER BY sc.stats_column_id
              FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'') AS columns,
       sp.last_updated, sp.rows, sp.rows_sampled, sp.steps, sp.modification_counter, sp.persisted_sample_percent
FROM sys.stats AS s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
WHERE s.object_id = OBJECT_ID(@tbl)
ORDER BY s.stats_id;

DECLARE @stats_id int = 1;   -- <== from above
SELECT step_number, range_high_key, range_rows, equal_rows, distinct_range_rows, average_range_rows
FROM sys.dm_db_stats_histogram(OBJECT_ID(@tbl), @stats_id)
ORDER BY step_number;
-- Classic alternative: DBCC SHOW_STATISTICS (N'dbo.Orders', N'PK_Orders') WITH HISTOGRAM;


/*=============================================================================
  39.2 ASCENDING KEY PROBLEM (new rows beyond the last histogram step)
                                                               [BOX][MI][SQLDB]
  Queries for "today's" rows estimate ~1 row -> bad plans until stats update.
  Highlight together with 39.1 (uses @tbl / @stats_id declared there).
=============================================================================*/
SELECT TOP (3) step_number, range_high_key, equal_rows, range_rows
FROM sys.dm_db_stats_histogram(OBJECT_ID(@tbl), @stats_id)
ORDER BY step_number DESC;
-- Compare with the actual max of the leading column:
-- SELECT MAX(OrderDate) FROM dbo.Orders;
-- Fixes: more frequent UPDATE STATISTICS on that stat (job), compat 120+ CE handles it better,
-- or UPDATE STATISTICS dbo.Orders (IX_Orders_OrderDate) WITH FULLSCAN, PERSIST_SAMPLE_PERCENT = ON;


/*=============================================================================
  39.3 STATS PAST THE AUTO-UPDATE THRESHOLD BUT NOT YET UPDATED  [BOX][MI][SQLDB]
  Compat 130+: threshold = MIN(500 + 20% rows, SQRT(1000 * rows)).
  Auto update only fires when a query compiles against them - these are
  candidates for a manual / scheduled update.
=============================================================================*/
SELECT OBJECT_SCHEMA_NAME(s.object_id) + N'.' + OBJECT_NAME(s.object_id) AS table_name, s.name AS stats_name,
       sp.rows, sp.modification_counter, sp.last_updated,
       CAST(CASE WHEN sp.rows <= 500 THEN 500
                 WHEN 500 + 0.2 * sp.rows < SQRT(1000.0 * sp.rows) THEN 500 + 0.2 * sp.rows
                 ELSE SQRT(1000.0 * sp.rows) END AS bigint) AS threshold
FROM sys.stats AS s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
WHERE OBJECTPROPERTY(s.object_id, 'IsUserTable') = 1
  AND sp.modification_counter > CASE WHEN sp.rows <= 500 THEN 500
                                     WHEN 500 + 0.2 * sp.rows < SQRT(1000.0 * sp.rows) THEN 500 + 0.2 * sp.rows
                                     ELSE SQRT(1000.0 * sp.rows) END
ORDER BY sp.modification_counter DESC;


/*=============================================================================
  39.4 ESTIMATED vs ACTUAL ROWS FOR A RUNNING QUERY (cardinality problems)
                                                               [BOX][MI][SQLDB]
  Big gaps between estimate_row_count and row_count = bad estimates.
  2019+ (lightweight profiling on by default); older: see 02 2.2 note.
=============================================================================*/
DECLARE @spid int = 55;   -- <== change
SELECT node_id, physical_operator_name, OBJECT_NAME(object_id) AS object_name, index_id,
       estimate_row_count, row_count,
       CAST(row_count * 1.0 / NULLIF(estimate_row_count, 0) AS decimal(18,2)) AS actual_vs_estimate,
       elapsed_time_ms, cpu_time_ms, logical_read_count
FROM sys.dm_exec_query_profiles
WHERE session_id = @spid
ORDER BY ABS(row_count - estimate_row_count) DESC;


/*=============================================================================
  39.5 PARALLELISM: WHO GOES PARALLEL, AND SKEW               [BOX][MI][SQLDB]
=============================================================================*/
-- Cached queries that run parallel, by CPU (min/max/last_dop exist from 2016)
SELECT TOP (25) qs.execution_count, qs.last_dop, qs.min_dop, qs.max_dop,
       qs.total_worker_time / qs.execution_count / 1000   AS avg_cpu_ms,
       qs.total_elapsed_time / qs.execution_count / 1000  AS avg_duration_ms,
       CAST(1.0 * qs.total_worker_time / NULLIF(qs.total_elapsed_time, 0) AS decimal(10,2)) AS cpu_to_duration,   -- >1 = parallel work
       SUBSTRING(t.text, qs.statement_start_offset / 2 + 1, 200) AS statement_start
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
WHERE qs.max_dop > 1
ORDER BY qs.total_worker_time DESC;

-- Live: threads per parallel request and how unevenly they wait (skew)
SELECT t.session_id, COUNT(*) AS tasks, MAX(t.exec_context_id) AS max_context,
       SUM(CASE WHEN t.task_state = 'RUNNING'   THEN 1 ELSE 0 END) AS running,
       SUM(CASE WHEN t.task_state = 'SUSPENDED' THEN 1 ELSE 0 END) AS suspended,
       SUM(CASE WHEN t.task_state = 'RUNNABLE'  THEN 1 ELSE 0 END) AS runnable
FROM sys.dm_os_tasks AS t
WHERE t.session_id > 50
GROUP BY t.session_id
HAVING COUNT(*) > 1
ORDER BY tasks DESC;

SELECT wt.session_id, wt.exec_context_id, wt.wait_type, wt.wait_duration_ms, wt.resource_description
FROM sys.dm_os_waiting_tasks AS wt
WHERE wt.wait_type IN (N'CXPACKET', N'CXCONSUMER', N'CXSYNC_PORT', N'CXSYNC_CONSUMER')
ORDER BY wt.session_id, wt.exec_context_id;
-- Many CXPACKET on producers while one thread is busy = skewed distribution (bad estimates / data skew).


/*=============================================================================
  39.6 COMPILE COST & OPTIMIZER TIMEOUTS                       [BOX][MI][SQLDB]
=============================================================================*/
-- Optimizer counters since restart
SELECT counter, occurrence, value
FROM sys.dm_exec_query_optimizer_info
WHERE counter IN (N'optimizations', N'elapsed time', N'trivial plan', N'search 0', N'search 1', N'search 2',
                  N'timeout', N'memory limit exceeded', N'tables', N'hints');

-- Query Store: most expensive compiles (run in user DB)
SELECT TOP (25) q.query_id, q.count_compiles,
       q.avg_compile_duration / 1000.0 AS avg_compile_ms, q.last_compile_duration / 1000.0 AS last_compile_ms,
       q.avg_compile_memory_kb, q.max_compile_memory_kb,
       LEFT(qt.query_sql_text, 200) AS query_start
FROM sys.query_store_query AS q
JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
ORDER BY q.avg_compile_duration * q.count_compiles DESC;

-- Cached plans where the optimizer gave up (TimeOut) - plan quality may be poor
WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
SELECT TOP (25) qs.execution_count, qs.total_worker_time / 1000 AS total_cpu_ms, t.text, qp.query_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
WHERE qp.query_plan.exist('//StmtSimple[@StatementOptmEarlyAbortReason="TimeOut"]') = 1
ORDER BY qs.total_worker_time DESC;


/*=============================================================================
  39.7 PLAN GUIDES - CURRENT DB (forgotten ones cause odd plans)  [BOX][MI][SQLDB]
=============================================================================*/
SELECT pg.plan_guide_id, pg.name, pg.is_disabled, pg.scope_type_desc,
       OBJECT_NAME(pg.scope_object_id) AS scope_object, pg.hints, LEFT(pg.query_text, 200) AS query_text,
       v.msgnum AS validation_error, v.message AS validation_message
FROM sys.plan_guides AS pg
OUTER APPLY sys.fn_validate_plan_guide(pg.plan_guide_id) AS v;
-- EXEC sp_control_plan_guide N'DISABLE', N'GuideName';   |  N'DROP'
-- Prefer Query Store hints / forced plans (04 4.6/4.8) over new plan guides.


/*=============================================================================
  39.8 RESOURCE GOVERNOR                                               [BOX][MI]
=============================================================================*/
SELECT c.is_enabled, OBJECT_SCHEMA_NAME(c.classifier_function_id, 1) + N'.' + OBJECT_NAME(c.classifier_function_id, 1) AS classifier_function,
       dc.is_reconfiguration_pending
FROM sys.resource_governor_configuration AS c
CROSS JOIN sys.dm_resource_governor_configuration AS dc;

SELECT p.name AS pool, p.min_cpu_percent, p.max_cpu_percent, p.cap_cpu_percent,
       p.min_memory_percent, p.max_memory_percent,
       p.total_cpu_usage_ms, p.used_memory_kb / 1024 AS used_mb, p.target_memory_kb / 1024 AS target_mb,
       p.active_memgrant_count, p.memgrant_waiter_count
FROM sys.dm_resource_governor_resource_pools AS p;

SELECT g.name AS workload_group, p.name AS pool, g.total_request_count, g.active_request_count,
       g.queued_request_count, g.total_queued_request_count, g.total_cpu_usage_ms, g.max_request_cpu_time_ms,
       g.total_cpu_limit_violation_count, g.blocked_task_count,
       g.request_max_memory_grant_percent, g.max_dop, g.group_max_requests
FROM sys.dm_resource_governor_workload_groups AS g
JOIN sys.dm_resource_governor_resource_pools AS p ON p.pool_id = g.pool_id;

-- Which group did each session land in?
SELECT s.session_id, s.login_name, s.program_name, g.name AS workload_group
FROM sys.dm_exec_sessions AS s
JOIN sys.dm_resource_governor_workload_groups AS g ON g.group_id = s.group_id
WHERE s.is_user_process = 1;
-- Classifier runs at login - a slow/failing classifier function slows/blocks ALL logins.
-- Handy: cap memory grants for reporting users ->  ALTER WORKLOAD GROUP [Reports] WITH (REQUEST_MAX_MEMORY_GRANT_PERCENT = 10);


/*=============================================================================
  39.9 IN-MEMORY OLTP (memory-optimized tables) - CURRENT DB  [BOX][MI][SQLDB*]
=============================================================================*/
SELECT OBJECT_SCHEMA_NAME(t.object_id) + N'.' + OBJECT_NAME(t.object_id) AS table_name, t.durability_desc,
       ms.memory_allocated_for_table_kb / 1024 AS table_alloc_mb, ms.memory_used_by_table_kb / 1024 AS table_used_mb,
       ms.memory_allocated_for_indexes_kb / 1024 AS index_alloc_mb, ms.memory_used_by_indexes_kb / 1024 AS index_used_mb
FROM sys.tables AS t
JOIN sys.dm_db_xtp_table_memory_stats AS ms ON ms.object_id = t.object_id
WHERE t.is_memory_optimized = 1
ORDER BY ms.memory_allocated_for_table_kb DESC;

-- Hash index bucket health: empty_bucket_pct < ~33% or long chains = BUCKET_COUNT too small / many duplicates
SELECT OBJECT_NAME(h.object_id) AS table_name, i.name AS index_name, h.total_bucket_count, h.empty_bucket_count,
       CAST(100.0 * h.empty_bucket_count / h.total_bucket_count AS decimal(5,2)) AS empty_bucket_pct,
       h.avg_chain_length, h.max_chain_length
FROM sys.dm_db_xtp_hash_index_stats AS h
JOIN sys.indexes AS i ON i.object_id = h.object_id AND i.index_id = h.index_id
ORDER BY h.avg_chain_length DESC;

-- Total XTP memory on the instance + which resource pool the DB is bound to   [BOX][MI]
SELECT SUM(pages_kb) / 1024 AS xtp_memory_mb FROM sys.dm_os_memory_clerks WHERE type = N'MEMORYCLERK_XTP';
SELECT d.name, p.name AS bound_resource_pool
FROM sys.databases d LEFT JOIN sys.dm_resource_governor_resource_pools p ON p.pool_id = d.resource_pool_id
WHERE d.database_id > 4;
-- *Azure SQL DB: Premium / Business Critical tiers only; xtp_storage_percent in 16.2.


/*=============================================================================
  39.10 SPINLOCK CONTENTION (advanced - high CPU with low waits)        [BOX][MI]
  Compare two samples; large backoffs growing fast = real contention.
=============================================================================*/
SELECT TOP (20) name, collisions, spins, spins_per_collision, sleep_time, backoffs
FROM sys.dm_os_spinlock_stats
ORDER BY spins DESC;
-- Common culprits: SOS_CACHESTORE / SOS_SELIST_SIZED_SLOCK (plan cache, ad hoc storms),
-- LOCK_HASH (hot rows), XDESMGR (very high tran rate). Usually needs a CU / design change.


/*=============================================================================
  39.11 QUERY HINT / FIX QUICK REFERENCE
=============================================================================*/
/*
 Parameter sniffing     OPTION (RECOMPILE)  |  OPTION (OPTIMIZE FOR (@p = 42))  |  OPTIMIZE FOR UNKNOWN
                        2022+: PSP optimization (compat 160) | Query Store force plan / hints (04)
 Bad estimates (CE)     OPTION (USE HINT ('FORCE_LEGACY_CARDINALITY_ESTIMATION'))
                        OPTION (USE HINT ('ASSUME_JOIN_PREDICATE_DEPENDS_ON_FILTERS'))
                        OPTION (USE HINT ('QUERY_OPTIMIZER_COMPATIBILITY_LEVEL_150'))
 Parallelism            OPTION (MAXDOP 1) / (MAXDOP 4)  |  DB scoped: ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 8
 Memory grants          OPTION (MIN_GRANT_PERCENT = 5, MAX_GRANT_PERCENT = 20)
 Row goal issues        OPTION (USE HINT ('DISABLE_OPTIMIZER_ROWGOAL'))
 Join choice (last resort)  OPTION (HASH JOIN) / (LOOP JOIN) - forces for the WHOLE query
 Apply without code change: Query Store hints  EXEC sys.sp_query_store_set_hints @query_id = 1, @query_hints = N'OPTION (RECOMPILE)';
 List of valid USE HINT names on your build:  SELECT name FROM sys.dm_exec_valid_use_hints;
*/
SELECT name FROM sys.dm_exec_valid_use_hints ORDER BY name;
