/*******************************************************************************
 File    : PerfCheck.sql   (automation/perf-check)
 Purpose : Performance window for every SQL Server instance on a VM. Run by
           Invoke-PerfCheck.ps1 (double-click Run-PerfCheck.bat): each --##PERF_*
           block below is run separately; the script sets the @p_ parameter
           values at the top of each block from $Config.
 SSMS    : the file also runs as-is in SSMS (F5) as a quick end-to-end test:
           START, ONE sample, END (top queries / XE since START) and TEARDOWN
           (restores the threshold, drops the XE session). Or select and run the
           blocks one by one in the SAME query window, e.g. START, a few
           SAMPLEs while you generate load, then END and TEARDOWN.
   PERF_START    : sets 'blocked process threshold' to @p_BptSec s, starts the XE
                   session DBA_PerfWindow (blocked process reports, deadlocks,
                   queries longer than @p_LongUs microseconds) and takes a plan cache
                   baseline for the window's top queries.
   PERF_SAMPLE   : one sample every N seconds (counters, waits, file I/O,
                   sessions, blocking, tempdb, Always On, listener connections).
   PERF_END      : blocked process reports, deadlocks, long queries (XE) and the
                   top 20 queries of the window (plan cache start vs end).
   PERF_TEARDOWN : drops the XE session and restores the original threshold.
 Tags    : [BOX] SQL Server 2016 SP2 - 2025 / Azure VM. No Query Store needed.

 ONE-TIME SETUP - dedicated SQL login (run in SSMS as sysadmin on EVERY instance,
 including every AG replica). Copy the block between the lines, change the password.
 The instance must allow SQL authentication (Server Properties > Security >
 "SQL Server and Windows Authentication mode"; check with
 SELECT SERVERPROPERTY('IsIntegratedSecurityOnly') -- 0 = mixed mode).
 ------------------------------------------------------------------------------
USE master;
IF SUSER_ID(N'dba_perfcheck') IS NULL
    CREATE LOGIN [dba_perfcheck] WITH PASSWORD = N'<strong password here>',
        CHECK_POLICY = ON, CHECK_EXPIRATION = OFF, DEFAULT_DATABASE = master;
    -- AG replicas: create it with the SAME SID everywhere so it survives failover:
    -- SELECT sid FROM sys.server_principals WHERE name = N'dba_perfcheck';  (on the first replica)
    -- CREATE LOGIN [dba_perfcheck] WITH PASSWORD = N'...', SID = 0x..., CHECK_POLICY = ON, CHECK_EXPIRATION = OFF;
GRANT VIEW SERVER STATE       TO [dba_perfcheck];   -- DMVs and performance counters
GRANT ALTER SETTINGS          TO [dba_perfcheck];   -- 'blocked process threshold' (set and restored)
GRANT ALTER ANY EVENT SESSION TO [dba_perfcheck];   -- temporary XE session DBA_PerfWindow
USE msdb;
IF USER_ID(N'dba_perfcheck') IS NULL CREATE USER [dba_perfcheck] FOR LOGIN [dba_perfcheck];
ALTER ROLE DatabaseMailUserRole ADD MEMBER [dba_perfcheck];   -- send the report by Database Mail
 ------------------------------------------------------------------------------
 To remove it later: DROP USER [dba_perfcheck] (in msdb), then DROP LOGIN [dba_perfcheck].
*******************************************************************************/

--##PERF_START
SET NOCOUNT ON;
DECLARE @p_BptSec int = 5;               -- blocked process threshold (s) during the window
DECLARE @p_LongUs bigint = 5000000;      -- capture queries longer than this, in microseconds (5000000 = 5 s)
DECLARE @p_TopQ bit = 1;                 -- 1 = plan cache baseline for the top 20 queries
DECLARE @orig int, @adv int, @thr bit = 0, @xe bit = 0, @msg nvarchar(2000) = N'';
SELECT @orig = CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'blocked process threshold (s)';
SELECT @adv  = CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'show advanced options';
IF HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER SETTINGS') = 1
BEGIN
    BEGIN TRY
        IF @orig <> @p_BptSec
        BEGIN
            IF @adv = 0 BEGIN EXEC sys.sp_configure N'show advanced options', 1; RECONFIGURE; END;
            EXEC sys.sp_configure N'blocked process threshold (s)', @p_BptSec; RECONFIGURE;
            IF @adv = 0 BEGIN EXEC sys.sp_configure N'show advanced options', 0; RECONFIGURE; END;
        END;
        SET @thr = 1;
    END TRY
    BEGIN CATCH SET @msg += N'Threshold not changed: ' + ERROR_MESSAGE() + N' '; END CATCH;
END
ELSE SET @msg += N'No ALTER SETTINGS permission - blocked process threshold not changed. ';

IF HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER ANY EVENT SESSION') = 1
BEGIN
    BEGIN TRY
        IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'DBA_PerfWindow')
            DROP EVENT SESSION DBA_PerfWindow ON SERVER;
        DECLARE @xeSql nvarchar(max) = REPLACE(N'CREATE EVENT SESSION DBA_PerfWindow ON SERVER
ADD EVENT sqlserver.blocked_process_report,
ADD EVENT sqlserver.xml_deadlock_report,
ADD EVENT sqlserver.rpc_completed (
    ACTION (sqlserver.database_name, sqlserver.client_app_name, sqlserver.client_hostname, sqlserver.username)
    WHERE duration > #LONG#),
ADD EVENT sqlserver.sql_batch_completed (
    ACTION (sqlserver.database_name, sqlserver.client_app_name, sqlserver.client_hostname, sqlserver.username)
    WHERE duration > #LONG#)
ADD TARGET package0.ring_buffer (SET max_memory = 8192, max_events_limit = 2000)
WITH (MAX_DISPATCH_LATENCY = 5 SECONDS, EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS, STARTUP_STATE = OFF);', N'#LONG#', CAST(@p_LongUs AS nvarchar(20)));
        EXEC (@xeSql);
        ALTER EVENT SESSION DBA_PerfWindow ON SERVER STATE = START;
        SET @xe = 1;
    END TRY
    BEGIN CATCH SET @msg += N'XE session not started: ' + ERROR_MESSAGE() + N' '; END CATCH;
END
ELSE SET @msg += N'No ALTER ANY EVENT SESSION permission - blocked process reports, deadlocks and long queries come from DMVs only. ';

-- Plan cache baseline for the window's top queries (session #temp table, compared at PERF_END)
IF OBJECT_ID('tempdb..#qstart') IS NOT NULL DROP TABLE #qstart;
CREATE TABLE #qstart (query_hash binary(8) PRIMARY KEY, ec bigint, el bigint, cpu bigint, rd bigint);
IF @p_TopQ = 1
    INSERT #qstart (query_hash, ec, el, cpu, rd)
    SELECT query_hash, SUM(execution_count), SUM(total_elapsed_time), SUM(total_worker_time), SUM(total_logical_reads)
    FROM sys.dm_exec_query_stats WHERE query_hash IS NOT NULL GROUP BY query_hash;

-- Remember the original values in this session (used by TEARDOWN when run from SSMS)
IF OBJECT_ID('tempdb..#perf_state') IS NOT NULL DROP TABLE #perf_state;
SELECT @orig AS orig, @thr AS thr_set, SYSDATETIMEOFFSET() AS start_time INTO #perf_state;

SELECT N'perf_setup' AS _section, CAST(@orig AS nvarchar(10)) AS orig_threshold, CAST(@thr AS nvarchar(1)) AS threshold_set,
       CAST(@xe AS nvarchar(1)) AS xe_started, CONVERT(nvarchar(40), SYSDATETIMEOFFSET(), 127) AS start_time, @msg AS message;

GO
--##PERF_SAMPLE
SET NOCOUNT ON;
DECLARE @p_BptSec int = 5;               -- report sessions blocked at least this long (s)
SELECT N'sample' AS _section, CONVERT(nvarchar(23), SYSDATETIME(), 121) AS sample_time;

SELECT N'pc' AS _section,
       SUBSTRING(RTRIM(object_name), CHARINDEX(N':', object_name) + 1, 128) AS obj,
       RTRIM(counter_name) AS ctr, RTRIM(instance_name) AS inst, CAST(cntr_value AS nvarchar(30)) AS val
FROM sys.dm_os_performance_counters
WHERE (RTRIM(object_name) LIKE N'%:SQL Statistics'     AND counter_name IN (N'Batch Requests/sec', N'SQL Compilations/sec', N'SQL Re-Compilations/sec'))
   OR (RTRIM(object_name) LIKE N'%:General Statistics' AND counter_name IN (N'User Connections', N'Processes blocked'))
   OR (RTRIM(object_name) LIKE N'%:Locks'              AND instance_name = N'_Total'
                                                       AND counter_name IN (N'Lock Waits/sec', N'Lock Wait Time (ms)', N'Lock Timeouts/sec', N'Number of Deadlocks/sec'))
   OR (RTRIM(object_name) LIKE N'%:Buffer Manager'     AND counter_name IN (N'Page life expectancy', N'Buffer cache hit ratio', N'Buffer cache hit ratio base'))
   OR (RTRIM(object_name) LIKE N'%:Memory Manager'     AND counter_name IN (N'Memory Grants Pending', N'Target Server Memory (KB)', N'Total Server Memory (KB)'))
   OR (RTRIM(object_name) LIKE N'%:Databases'          AND counter_name IN (N'Transactions/sec', N'Log Flush Wait Time', N'Log Bytes Flushed/sec'))
   OR (RTRIM(object_name) LIKE N'%:Transactions'       AND counter_name = N'Version Store Size (KB)')
   OR (RTRIM(object_name) LIKE N'%:Database Replica'   AND counter_name IN (N'Transaction Delay', N'Mirrored Write Transactions/sec'));

SELECT N'waits' AS _section, grp, CAST(SUM(wait_time_ms) AS nvarchar(30)) AS wait_ms, CAST(SUM(waiting_tasks_count) AS nvarchar(30)) AS tasks
FROM (SELECT CASE WHEN wait_type LIKE N'LCK[_]M[_]%'      THEN N'LCK_M_*'
                  WHEN wait_type LIKE N'PAGEIOLATCH[_]%'  THEN N'PAGEIOLATCH_*'
                  WHEN wait_type LIKE N'PAGELATCH[_]%'    THEN N'PAGELATCH_*'
                  WHEN wait_type IN (N'WRITELOG', N'CXPACKET', N'CXCONSUMER', N'SOS_SCHEDULER_YIELD', N'HADR_SYNC_COMMIT', N'RESOURCE_SEMAPHORE') THEN wait_type
             END AS grp, wait_time_ms, waiting_tasks_count
      FROM sys.dm_os_wait_stats) AS w
WHERE grp IS NOT NULL
GROUP BY grp;

SELECT N'io' AS _section, DB_NAME(vfs.database_id) AS db, CASE WHEN mf.type = 1 THEN N'LOG' ELSE N'DATA' END AS ftype,
       CAST(SUM(vfs.num_of_reads) AS nvarchar(30)) AS reads, CAST(SUM(vfs.io_stall_read_ms) AS nvarchar(30)) AS read_stall_ms,
       CAST(SUM(vfs.num_of_writes) AS nvarchar(30)) AS writes, CAST(SUM(vfs.io_stall_write_ms) AS nvarchar(30)) AS write_stall_ms
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
JOIN sys.master_files AS mf ON mf.database_id = vfs.database_id AND mf.file_id = vfs.file_id
GROUP BY vfs.database_id, CASE WHEN mf.type = 1 THEN N'LOG' ELSE N'DATA' END;

SELECT N'sessions' AS _section, ISNULL(s.program_name, N'') AS program, ISNULL(s.host_name, N'') AS host, s.login_name AS login,
       CAST(COUNT(*) AS nvarchar(10)) AS sessions, CAST(SUM(CASE WHEN r.session_id IS NULL THEN 0 ELSE 1 END) AS nvarchar(10)) AS active
FROM sys.dm_exec_sessions AS s
LEFT JOIN sys.dm_exec_requests AS r ON r.session_id = s.session_id
WHERE s.is_user_process = 1
GROUP BY s.program_name, s.host_name, s.login_name;

SELECT N'blocking' AS _section, CAST(COUNT(*) AS nvarchar(10)) AS blocked, CAST(ISNULL(MAX(wait_time), 0) AS nvarchar(20)) AS max_wait_ms
FROM sys.dm_exec_requests WHERE blocking_session_id > 0 AND wait_time >= @p_BptSec * 1000;

SELECT TOP (5) N'blocked_now' AS _section, CONVERT(nvarchar(19), GETDATE(), 120) AS seen_at, CAST(r.session_id AS nvarchar(10)) AS session_id,
       CAST(r.blocking_session_id AS nvarchar(10)) AS blocked_by, r.wait_type, CAST(r.wait_time / 1000 AS nvarchar(20)) AS wait_s,
       ISNULL(DB_NAME(r.database_id), N'') AS db, ISNULL(LEFT(t.text, 200), N'') AS sql_text
FROM sys.dm_exec_requests AS r
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE r.blocking_session_id > 0 AND r.wait_time >= @p_BptSec * 1000
ORDER BY r.wait_time DESC;

SELECT N'tempdb' AS _section,
       CAST(CAST(SUM(user_object_reserved_page_count)     * 8 / 1024.0 AS decimal(18, 1)) AS nvarchar(30)) AS user_mb,
       CAST(CAST(SUM(internal_object_reserved_page_count) * 8 / 1024.0 AS decimal(18, 1)) AS nvarchar(30)) AS internal_mb,
       CAST(CAST(SUM(version_store_reserved_page_count)   * 8 / 1024.0 AS decimal(18, 1)) AS nvarchar(30)) AS version_mb,
       CAST(CAST(SUM(unallocated_extent_page_count)       * 8 / 1024.0 AS decimal(18, 1)) AS nvarchar(30)) AS free_mb,
       CAST((SELECT COUNT(*) FROM sys.dm_os_waiting_tasks WHERE wait_type LIKE N'PAGELATCH[_]%' AND resource_description LIKE N'2:%') AS nvarchar(10)) AS alloc_waiters
FROM tempdb.sys.dm_db_file_space_usage;

IF CAST(SERVERPROPERTY('IsHadrEnabled') AS int) = 1
BEGIN
    SELECT N'ag' AS _section, ag.name AS ag_name, adc.database_name AS db, ar.replica_server_name AS replica,
           ISNULL(drs.synchronization_state_desc, N'') AS sync_state,
           CAST(ISNULL(drs.log_send_queue_size, 0) AS nvarchar(20)) AS send_queue_kb,
           CAST(ISNULL(drs.redo_queue_size, 0) AS nvarchar(20)) AS redo_queue_kb
    FROM sys.dm_hadr_database_replica_states AS drs
    JOIN sys.availability_replicas AS ar ON ar.replica_id = drs.replica_id
    JOIN sys.availability_groups AS ag ON ag.group_id = drs.group_id
    JOIN sys.availability_databases_cluster AS adc ON adc.group_database_id = drs.group_database_id;

    SELECT N'listener' AS _section, l.dns_name AS listener, ip.ip_address, CAST(COUNT(c.session_id) AS nvarchar(10)) AS connections
    FROM sys.availability_group_listeners AS l
    JOIN sys.availability_group_listener_ip_addresses AS ip ON ip.listener_id = l.listener_id
    LEFT JOIN sys.dm_exec_connections AS c ON c.local_net_address = ip.ip_address AND c.local_tcp_port = l.port
    GROUP BY l.dns_name, ip.ip_address;
END;

GO
--##PERF_END
SET NOCOUNT ON;
DECLARE @p_Start nvarchar(40) = NULL;    -- window start; NULL = from PERF_START in this session
DECLARE @p_TopQ bit = 1;                 -- 1 = top 20 queries from the plan cache
DECLARE @s datetimeoffset = TRY_CAST(@p_Start AS datetimeoffset), @e datetimeoffset = SYSDATETIMEOFFSET();
IF @s IS NULL AND OBJECT_ID('tempdb..#perf_state') IS NOT NULL SELECT @s = start_time FROM #perf_state;
IF @s IS NULL SET @s = DATEADD(MINUTE, -30, @e);

-- Extended Events (blocked process reports, deadlocks, long queries)
IF OBJECT_ID('tempdb..#xe') IS NOT NULL DROP TABLE #xe;
CREATE TABLE #xe (ev xml);
IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'DBA_PerfWindow')
BEGIN
    DECLARE @x xml;
    SELECT @x = CAST(t.target_data AS xml)
    FROM sys.dm_xe_session_targets AS t
    JOIN sys.dm_xe_sessions AS se ON se.address = t.event_session_address
    WHERE se.name = N'DBA_PerfWindow' AND t.target_name = N'ring_buffer';
    INSERT #xe (ev) SELECT n.query('.') FROM @x.nodes('/RingBufferTarget/event') AS q(n);
END;

SELECT TOP (50) N'xe_blocked' AS _section,
       CONVERT(nvarchar(19), DATEADD(MINUTE, DATEDIFF(MINUTE, GETUTCDATE(), GETDATE()), ev.value('(event/@timestamp)[1]', 'datetime2')), 120) AS event_time,
       CAST(ev.value('(event/data[@name="duration"]/value)[1]', 'bigint') / 1000000 AS nvarchar(20)) AS blocked_s,
       ISNULL(ev.value('(event/data[@name="database_name"]/value)[1]', 'nvarchar(128)'), N'') AS db,
       ISNULL(ev.value('(event/data[@name="blocked_process"]/value/blocked-process-report/blocked-process/process/@spid)[1]', 'nvarchar(10)'), N'') AS blocked_spid,
       ISNULL(ev.value('(event/data[@name="blocked_process"]/value/blocked-process-report/blocking-process/process/@spid)[1]', 'nvarchar(10)'), N'') AS blocking_spid,
       ISNULL(LEFT(LTRIM(ev.value('(event/data[@name="blocked_process"]/value/blocked-process-report/blocked-process/process/inputbuf)[1]', 'nvarchar(max)')), 200), N'') AS blocked_sql,
       ISNULL(LEFT(LTRIM(ev.value('(event/data[@name="blocked_process"]/value/blocked-process-report/blocking-process/process/inputbuf)[1]', 'nvarchar(max)')), 200), N'') AS blocking_sql
FROM #xe WHERE ev.value('(event/@name)[1]', 'nvarchar(60)') = N'blocked_process_report'
ORDER BY ev.value('(event/data[@name="duration"]/value)[1]', 'bigint') DESC;

SELECT N'xe_deadlocks' AS _section,
       CONVERT(nvarchar(19), DATEADD(MINUTE, DATEDIFF(MINUTE, GETUTCDATE(), GETDATE()), ev.value('(event/@timestamp)[1]', 'datetime2')), 120) AS event_time,
       CAST(ev.value('count(event/data[@name="xml_report"]/value/deadlock/process-list/process)', 'int') AS nvarchar(10)) AS processes,
       ISNULL(ev.value('(event/data[@name="xml_report"]/value/deadlock/victim-list/victimProcess/@id)[1]', 'nvarchar(50)'), N'') AS victim,
       ISNULL(ev.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process/@currentdbname)[1]', 'nvarchar(128)'), N'') AS db,
       ISNULL(LEFT(LTRIM(ev.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process/inputbuf)[1]', 'nvarchar(max)')), 200), N'') AS sql_text
FROM #xe WHERE ev.value('(event/@name)[1]', 'nvarchar(60)') = N'xml_deadlock_report'
ORDER BY event_time;

SELECT TOP (200) N'xe_long' AS _section,
       CONVERT(nvarchar(19), DATEADD(MINUTE, DATEDIFF(MINUTE, GETUTCDATE(), GETDATE()), ev.value('(event/@timestamp)[1]', 'datetime2')), 120) AS end_time,
       CAST(CAST(ev.value('(event/data[@name="duration"]/value)[1]', 'bigint') / 1000000.0 AS decimal(18, 1)) AS nvarchar(30)) AS duration_s,
       CAST(ev.value('(event/data[@name="cpu_time"]/value)[1]', 'bigint') / 1000 AS nvarchar(30)) AS cpu_ms,
       CAST(ev.value('(event/data[@name="logical_reads"]/value)[1]', 'bigint') AS nvarchar(30)) AS logical_reads,
       ISNULL(ev.value('(event/action[@name="database_name"]/value)[1]', 'nvarchar(128)'), N'') AS db,
       ISNULL(ev.value('(event/action[@name="client_app_name"]/value)[1]', 'nvarchar(128)'), N'') AS app,
       ISNULL(ev.value('(event/action[@name="client_hostname"]/value)[1]', 'nvarchar(128)'), N'') AS host,
       ISNULL(ev.value('(event/action[@name="username"]/value)[1]', 'nvarchar(128)'), N'') AS login,
       ISNULL(LEFT(LTRIM(COALESCE(ev.value('(event/data[@name="statement"]/value)[1]', 'nvarchar(max)'),
                                  ev.value('(event/data[@name="batch_text"]/value)[1]', 'nvarchar(max)'))), 300), N'') AS sql_text
FROM #xe WHERE ev.value('(event/@name)[1]', 'nvarchar(60)') IN (N'rpc_completed', N'sql_batch_completed')
ORDER BY ev.value('(event/data[@name="duration"]/value)[1]', 'bigint') DESC;

-- Top queries of the window from the plan cache: sys.dm_exec_query_stats now minus the baseline taken at
-- PERF_START (#qstart, same connection), grouped by query_hash so the same query with different literals or
-- plans counts once. Not seen: plans evicted / recompiled during the window and OPTION (RECOMPILE) statements.
IF OBJECT_ID('tempdb..#qraw') IS NOT NULL DROP TABLE #qraw;
IF OBJECT_ID('tempdb..#qtop') IS NOT NULL DROP TABLE #qtop;
CREATE TABLE #qtop (query_hash binary(8), executions bigint, total_duration_ms decimal(19, 1), avg_duration_ms decimal(19, 1),
                    total_cpu_ms decimal(19, 1), total_logical_reads bigint, sql_handle varbinary(64), plan_handle varbinary(64),
                    stmt_start int, stmt_end int, rn_d int, rn_c int, rn_r int);
DECLARE @cached int = 0;
IF @p_TopQ = 1 AND OBJECT_ID('tempdb..#qstart') IS NOT NULL
BEGIN
    SELECT query_hash, sql_handle, plan_handle, statement_start_offset, statement_end_offset,
           execution_count, total_elapsed_time, total_worker_time, total_logical_reads,
           ROW_NUMBER() OVER (PARTITION BY query_hash ORDER BY total_elapsed_time DESC) AS rn
    INTO #qraw
    FROM sys.dm_exec_query_stats
    WHERE query_hash IS NOT NULL;
    SET @cached = @@ROWCOUNT;

    WITH e AS (
        SELECT query_hash, SUM(execution_count) AS ec, SUM(total_elapsed_time) AS el, SUM(total_worker_time) AS cpu, SUM(total_logical_reads) AS rd,
               MAX(CASE WHEN rn = 1 THEN sql_handle END) AS sh, MAX(CASE WHEN rn = 1 THEN plan_handle END) AS ph,
               MAX(CASE WHEN rn = 1 THEN statement_start_offset END) AS so, MAX(CASE WHEN rn = 1 THEN statement_end_offset END) AS eo
        FROM #qraw GROUP BY query_hash),
    d AS (   -- delta; if the plan was recompiled / re-cached (counters went down) use the current values
        SELECT e.query_hash, e.sh, e.ph, e.so, e.eo,
               CASE WHEN s.query_hash IS NULL OR e.ec < s.ec THEN e.ec  ELSE e.ec  - s.ec  END AS ec,
               CASE WHEN s.query_hash IS NULL OR e.ec < s.ec THEN e.el  ELSE e.el  - s.el  END AS el,
               CASE WHEN s.query_hash IS NULL OR e.ec < s.ec THEN e.cpu ELSE e.cpu - s.cpu END AS cpu,
               CASE WHEN s.query_hash IS NULL OR e.ec < s.ec THEN e.rd  ELSE e.rd  - s.rd  END AS rd
        FROM e LEFT JOIN #qstart AS s ON s.query_hash = e.query_hash),
    r AS (
        SELECT *, ROW_NUMBER() OVER (ORDER BY el DESC) AS rn_d, ROW_NUMBER() OVER (ORDER BY cpu DESC) AS rn_c, ROW_NUMBER() OVER (ORDER BY rd DESC) AS rn_r
        FROM d WHERE ec > 0)
    INSERT #qtop
    SELECT query_hash, ec, CAST(el / 1000.0 AS decimal(19, 1)), CAST(el / 1000.0 / ec AS decimal(19, 1)), CAST(cpu / 1000.0 AS decimal(19, 1)), rd,
           sh, ph, so, eo, rn_d, rn_c, rn_r
    FROM r WHERE rn_d <= 20 OR rn_c <= 20 OR rn_r <= 20;
END;

IF OBJECT_ID('tempdb..#qtx') IS NOT NULL DROP TABLE #qtx;
SELECT q.*, ISNULL(DB_NAME(COALESCE(t.dbid, CONVERT(int, pa.value))), N'') AS db,
       ISNULL(LEFT(LTRIM(SUBSTRING(t.text, q.stmt_start / 2 + 1,
              (CASE WHEN q.stmt_end = -1 THEN DATALENGTH(t.text) ELSE q.stmt_end END - q.stmt_start) / 2 + 1)), 300), N'') AS query_text,
       ISNULL(OBJECT_NAME(t.objectid, t.dbid), N'') AS object_name
INTO #qtx
FROM #qtop AS q
OUTER APPLY sys.dm_exec_sql_text(q.sql_handle) AS t
OUTER APPLY (SELECT value FROM sys.dm_exec_plan_attributes(q.plan_handle) WHERE attribute = N'dbid') AS pa;

SELECT N'topq_info' AS _section, CAST(@p_TopQ AS nvarchar(1)) AS collected, CAST(@cached AS nvarchar(20)) AS plan_cache_entries;
SELECT TOP (20) N'top_duration' AS _section, db, object_name, CONVERT(nvarchar(20), query_hash, 1) AS query_hash, CAST(executions AS nvarchar(20)) AS executions,
       CAST(total_duration_ms AS nvarchar(30)) AS total_duration_ms, CAST(avg_duration_ms AS nvarchar(30)) AS avg_duration_ms,
       CAST(total_cpu_ms AS nvarchar(30)) AS total_cpu_ms, CAST(total_logical_reads AS nvarchar(30)) AS total_logical_reads, query_text
FROM #qtx WHERE rn_d <= 20 ORDER BY rn_d;
SELECT TOP (20) N'top_cpu' AS _section, db, object_name, CONVERT(nvarchar(20), query_hash, 1) AS query_hash, CAST(executions AS nvarchar(20)) AS executions,
       CAST(total_cpu_ms AS nvarchar(30)) AS total_cpu_ms, CAST(total_duration_ms AS nvarchar(30)) AS total_duration_ms,
       CAST(total_logical_reads AS nvarchar(30)) AS total_logical_reads, query_text
FROM #qtx WHERE rn_c <= 20 ORDER BY rn_c;
SELECT TOP (20) N'top_reads' AS _section, db, object_name, CONVERT(nvarchar(20), query_hash, 1) AS query_hash, CAST(executions AS nvarchar(20)) AS executions,
       CAST(total_logical_reads AS nvarchar(30)) AS total_logical_reads, CAST(total_duration_ms AS nvarchar(30)) AS total_duration_ms,
       CAST(total_cpu_ms AS nvarchar(30)) AS total_cpu_ms, query_text
FROM #qtx WHERE rn_r <= 20 ORDER BY rn_r;

GO
--##PERF_TEARDOWN
SET NOCOUNT ON;
DECLARE @p_Restore bit = NULL;           -- 1 = restore the threshold; NULL = as recorded by PERF_START in this session
DECLARE @p_Orig int = NULL;              -- value to restore; NULL = as recorded by PERF_START in this session
DECLARE @adv int, @msg nvarchar(2000) = N'';
IF @p_Restore IS NULL AND OBJECT_ID('tempdb..#perf_state') IS NOT NULL
    SELECT @p_Restore = thr_set, @p_Orig = orig FROM #perf_state;
BEGIN TRY
    IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'DBA_PerfWindow')
        DROP EVENT SESSION DBA_PerfWindow ON SERVER;
END TRY
BEGIN CATCH SET @msg += N'XE session not dropped: ' + ERROR_MESSAGE() + N' '; END CATCH;
IF @p_Restore = 1 AND @p_Orig IS NOT NULL
BEGIN
    BEGIN TRY
        IF (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'blocked process threshold (s)') <> @p_Orig
        BEGIN
            SELECT @adv = CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'show advanced options';
            IF @adv = 0 BEGIN EXEC sys.sp_configure N'show advanced options', 1; RECONFIGURE; END;
            EXEC sys.sp_configure N'blocked process threshold (s)', @p_Orig; RECONFIGURE;
            IF @adv = 0 BEGIN EXEC sys.sp_configure N'show advanced options', 0; RECONFIGURE; END;
        END;
    END TRY
    BEGIN CATCH SET @msg += N'Threshold not restored: ' + ERROR_MESSAGE() + N' '; END CATCH;
END;
IF OBJECT_ID('tempdb..#qstart') IS NOT NULL DROP TABLE #qstart;
IF OBJECT_ID('tempdb..#perf_state') IS NOT NULL DROP TABLE #perf_state;
SELECT N'perf_teardown' AS _section,
       (SELECT CAST(value_in_use AS nvarchar(10)) FROM sys.configurations WHERE name = N'blocked process threshold (s)') AS threshold_now, @msg AS message;
GO
