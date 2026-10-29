/*******************************************************************************
 File    : 42_incident_response.sql
 Purpose : Handle a P1 without making it worse - and without escalation:
           first-60-seconds triage, capture evidence BEFORE restart /
           failover / KILL (so RCA is possible), incident timeline for any
           time window, safety checks before KILL / restart / failover /
           clearing caches, RCA + status-update templates.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] Managed Instance
 Flow    : 42.1 triage -> 42.2 capture evidence -> fix (02/07/08/11/35...)
           -> 42.4 check before any drastic action -> 42.3 timeline -> 42.5 RCA
*******************************************************************************/

/*=============================================================================
  42.1 FIRST 60 SECONDS - WHAT IS WRONG RIGHT NOW?                    [BOX][MI]
  Read-only, fast (5-second wait sample). Six small result sets.
=============================================================================*/
-- (a) Vital signs
DECLARE @ms_now bigint = (SELECT ms_ticks FROM sys.dm_os_sys_info);
SELECT @@SERVERNAME AS server_name,
       (SELECT sqlserver_start_time FROM sys.dm_os_sys_info) AS up_since,
       (SELECT TOP (1) x.r.value('(Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int')
        FROM sys.dm_os_ring_buffers rb CROSS APPLY (SELECT CAST(rb.record AS xml)) x(r)
        WHERE rb.ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR' AND rb.record LIKE N'%<SystemHealth>%'
        ORDER BY rb.[timestamp] DESC) AS sql_cpu_pct,
       (SELECT TOP (1) 100 - x.r.value('(Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int')
        FROM sys.dm_os_ring_buffers rb CROSS APPLY (SELECT CAST(rb.record AS xml)) x(r)
        WHERE rb.ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR' AND rb.record LIKE N'%<SystemHealth>%'
        ORDER BY rb.[timestamp] DESC) AS total_cpu_pct,
       (SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE is_user_process = 1)                AS user_sessions,
       (SELECT COUNT(*) FROM sys.dm_exec_requests WHERE session_id > 50)                    AS active_requests,
       (SELECT COUNT(*) FROM sys.dm_exec_requests WHERE blocking_session_id > 0)            AS blocked_requests,
       (SELECT COUNT(*) FROM sys.dm_os_waiting_tasks WHERE wait_type = N'THREADPOOL')       AS threadpool_waiters,
       (SELECT SUM(runnable_tasks_count) FROM sys.dm_os_schedulers WHERE status = N'VISIBLE ONLINE') AS runnable_tasks,
       (SELECT cntr_value FROM sys.dm_os_performance_counters WHERE counter_name = N'Memory Grants Pending') AS memory_grants_pending,
       (SELECT MIN(cntr_value) FROM sys.dm_os_performance_counters WHERE counter_name = N'Page life expectancy')  AS min_ple;

-- (b) What everyone is waiting on - last 5 seconds
IF OBJECT_ID('tempdb..#w0') IS NOT NULL DROP TABLE #w0;
SELECT wait_type, wait_time_ms, waiting_tasks_count INTO #w0 FROM sys.dm_os_wait_stats;
WAITFOR DELAY '00:00:05';
SELECT TOP (10) w.wait_type, w.wait_time_ms - w0.wait_time_ms AS wait_ms_in_5s,
       w.waiting_tasks_count - w0.waiting_tasks_count AS waits_in_5s
FROM sys.dm_os_wait_stats w JOIN #w0 w0 ON w0.wait_type = w.wait_type
WHERE w.wait_time_ms - w0.wait_time_ms > 0
  AND w.wait_type NOT LIKE N'%SLEEP%' AND w.wait_type NOT LIKE N'%QUEUE%' AND w.wait_type NOT LIKE N'XE_%'
  AND w.wait_type NOT IN (N'CXCONSUMER', N'WAITFOR', N'BROKER_TO_FLUSH', N'BROKER_TASK_STOP', N'CHECKPOINT_QUEUE', N'DIRTY_PAGE_POLL',
                          N'HADR_FILESTREAM_IOMGR_IOCOMPLETION', N'SP_SERVER_DIAGNOSTICS_SLEEP', N'REQUEST_FOR_DEADLOCK_SEARCH',
                          N'HADR_WORK_QUEUE', N'HADR_TIMER_TASK', N'PWAIT_EXTENSIBILITY_CLEANUP_TASK', N'HADR_NOTIFICATION_DEQUEUE')
ORDER BY wait_ms_in_5s DESC;

-- (c) Head blockers (the sessions everyone is stuck behind)
SELECT hb.session_id AS head_blocker, s.login_name, s.host_name, s.program_name, s.status,
       (SELECT COUNT(*) FROM sys.dm_exec_requests v WHERE v.blocking_session_id = hb.session_id) AS direct_victims,
       s.open_transaction_count, s.last_request_start_time,
       ib.event_info AS last_sql
FROM (SELECT DISTINCT r.blocking_session_id AS session_id FROM sys.dm_exec_requests r
      WHERE r.blocking_session_id > 0
        AND r.blocking_session_id NOT IN (SELECT session_id FROM sys.dm_exec_requests WHERE blocking_session_id > 0)) AS hb
JOIN sys.dm_exec_sessions s ON s.session_id = hb.session_id
OUTER APPLY sys.dm_exec_input_buffer(hb.session_id, NULL) ib;

-- (d) Top 10 running requests
SELECT TOP (10) r.session_id, r.blocking_session_id AS blocked_by, s.login_name, s.program_name, DB_NAME(r.database_id) AS db,
       r.status, r.command, r.wait_type, r.total_elapsed_time / 1000 AS elapsed_s, r.cpu_time / 1000 AS cpu_s,
       r.logical_reads, r.granted_query_memory * 8 / 1024 AS grant_mb, r.dop,
       SUBSTRING(t.text, r.statement_start_offset / 2 + 1, 300) AS statement_start
FROM sys.dm_exec_requests r
JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE s.is_user_process = 1 AND r.session_id <> @@SPID
ORDER BY r.total_elapsed_time DESC;

-- (e) Red flags
SELECT 'DB not online' AS flag, name AS detail FROM sys.databases WHERE state_desc NOT IN (N'ONLINE', N'RESTORING')
UNION ALL
SELECT 'Log > 90% full', d.name + ' (' + d.log_reuse_wait_desc + ')'
FROM sys.databases d CROSS APPLY sys.dm_db_log_stats(d.database_id) ls
WHERE d.state_desc = N'ONLINE' AND ls.active_log_size_mb * 100.0 / NULLIF(ls.total_log_size_mb, 0) > 90
UNION ALL
SELECT 'tempdb < 10% free', CAST(CAST(100.0 * SUM(unallocated_extent_page_count) / SUM(total_page_count) AS decimal(5,1)) AS varchar(10)) + '%'
FROM tempdb.sys.dm_db_file_space_usage
HAVING 100.0 * SUM(unallocated_extent_page_count) / SUM(total_page_count) < 10
UNION ALL
SELECT 'AG not healthy', DB_NAME(drs.database_id) + ' ' + drs.synchronization_state_desc + CASE WHEN drs.is_suspended = 1 THEN ' SUSPENDED' ELSE '' END
FROM sys.dm_hadr_database_replica_states drs WHERE drs.is_local = 1 AND (drs.synchronization_health_desc <> 'HEALTHY' OR drs.is_suspended = 1)
UNION ALL
SELECT 'Long rollback in progress', CAST(session_id AS varchar(10)) + ' ' + CAST(percent_complete AS varchar(10)) + '%'
FROM sys.dm_exec_requests WHERE command IN (N'KILLED/ROLLBACK', N'ROLLBACK TRANSACTION')
UNION ALL
SELECT 'Backup/restore/DBCC running', command + ' on ' + DB_NAME(database_id) + ' ' + CAST(CAST(percent_complete AS int) AS varchar(5)) + '%'
FROM sys.dm_exec_requests WHERE command LIKE N'BACKUP%' OR command LIKE N'RESTORE%' OR command LIKE N'DBCC%';

-- (f) Error log - last 30 minutes (noise filtered)
DECLARE @el_from nvarchar(30) = CONVERT(nvarchar(30), DATEADD(MINUTE, -30, GETDATE()), 121),
        @el_to   nvarchar(30) = CONVERT(nvarchar(30), GETDATE(), 121);
IF OBJECT_ID('tempdb..#el1') IS NOT NULL DROP TABLE #el1;
CREATE TABLE #el1 (LogDate datetime, ProcessInfo nvarchar(50), [Text] nvarchar(max));
INSERT #el1 EXEC sys.xp_readerrorlog 0, 1, NULL, NULL, @el_from, @el_to, N'desc';
SELECT LogDate, ProcessInfo, [Text] FROM #el1
WHERE [Text] NOT LIKE N'Log was backed up%' AND [Text] NOT LIKE N'BACKUP DATABASE%successfully%'
  AND [Text] NOT LIKE N'Database backed up%' AND [Text] NOT LIKE N'Database differential changes were backed up%'
  AND [Text] NOT LIKE N'BACKUP LOG successfully%'
ORDER BY LogDate DESC;
-- Next: blocking -> 02 2.3 | CPU -> 07 7.4 + 03 3.1 | IO -> 08 8.2 | memory -> 06 6.7 | log full -> 08 8.7
--       AG -> 25.1/25.2 | THREADPOOL -> 07 7.3 + DAC (35.10) | errors -> 15.6 / 35.1


/*=============================================================================
  42.2 CAPTURE EVIDENCE BEFORE YOU RESTART / FAIL OVER / KILL         [BOX][MI]
  A restart wipes DMVs, waits, plan cache and the "why". Capture first
  (takes seconds), fix second. Setup once in DBAdmin; then during an
  incident:   EXEC DBAdmin.dbo.usp_DBA_CaptureIncident @Note = N'P1 INC12345 high CPU';
  Without setup: EXEC sp_WhoIsActive @get_plans = 1, @destination_table = ...  (33.2)
=============================================================================*/
/*
USE DBAdmin;
GO
CREATE OR ALTER PROCEDURE dbo.usp_DBA_CaptureIncident
    @Note nvarchar(400) = NULL,
    @IncludePlans bit = 0              -- 1 = also store query plans (bigger, slower)
AS
BEGIN
    SET NOCOUNT ON;
    IF OBJECT_ID(N'dbo.IR_Capture') IS NULL
        CREATE TABLE dbo.IR_Capture (capture_id int IDENTITY PRIMARY KEY, capture_time datetime2(0) NOT NULL DEFAULT SYSDATETIME(),
                                     server_name sysname NOT NULL DEFAULT @@SERVERNAME, captured_by sysname NOT NULL DEFAULT ORIGINAL_LOGIN(),
                                     note nvarchar(400) NULL);
    INSERT dbo.IR_Capture (note) VALUES (@Note);
    DECLARE @id int = SCOPE_IDENTITY();

    -- 1. Requests
    SELECT @id AS capture_id, r.session_id, r.blocking_session_id, s.login_name, s.host_name, s.program_name,
           DB_NAME(r.database_id) AS database_name, r.status, r.command, r.wait_type, r.wait_time, r.wait_resource, r.last_wait_type,
           r.cpu_time, r.total_elapsed_time, r.logical_reads, r.reads, r.writes, r.granted_query_memory, r.dop, r.open_transaction_count,
           r.query_hash, r.query_plan_hash, t.text AS sql_text,
           CAST(CASE WHEN @IncludePlans = 1 THEN CAST(qp.query_plan AS nvarchar(max)) END AS nvarchar(max)) AS query_plan
    INTO #req
    FROM sys.dm_exec_requests r
    JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
    OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
    OUTER APPLY (SELECT p.query_plan FROM sys.dm_exec_query_plan(r.plan_handle) p WHERE @IncludePlans = 1) qp
    WHERE r.session_id <> @@SPID;
    IF OBJECT_ID(N'dbo.IR_Requests') IS NULL SELECT * INTO dbo.IR_Requests FROM #req WHERE 1 = 0;
    INSERT dbo.IR_Requests SELECT * FROM #req;

    -- 2. Sessions (incl. sleeping with open transactions)
    SELECT @id AS capture_id, s.session_id, s.login_name, s.host_name, s.program_name, s.status, s.open_transaction_count,
           s.cpu_time, s.memory_usage, s.reads, s.writes, s.last_request_start_time, s.last_request_end_time,
           c.client_net_address, ib.event_info AS last_sql
    INTO #ses
    FROM sys.dm_exec_sessions s
    LEFT JOIN sys.dm_exec_connections c ON c.session_id = s.session_id
    OUTER APPLY sys.dm_exec_input_buffer(s.session_id, NULL) ib
    WHERE s.is_user_process = 1;
    IF OBJECT_ID(N'dbo.IR_Sessions') IS NULL SELECT * INTO dbo.IR_Sessions FROM #ses WHERE 1 = 0;
    INSERT dbo.IR_Sessions SELECT * FROM #ses;

    -- 3. Waiting tasks (blocking chains, resources)
    SELECT @id AS capture_id, wt.session_id, wt.exec_context_id, wt.wait_type, wt.wait_duration_ms, wt.blocking_session_id, wt.resource_description
    INTO #wt FROM sys.dm_os_waiting_tasks wt WHERE wt.session_id > 50;
    IF OBJECT_ID(N'dbo.IR_WaitingTasks') IS NULL SELECT * INTO dbo.IR_WaitingTasks FROM #wt WHERE 1 = 0;
    INSERT dbo.IR_WaitingTasks SELECT * FROM #wt;

    -- 4. Cumulative waits (diff two captures to see the incident window)
    SELECT @id AS capture_id, wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms
    INTO #ws FROM sys.dm_os_wait_stats WHERE waiting_tasks_count > 0;
    IF OBJECT_ID(N'dbo.IR_WaitStats') IS NULL SELECT * INTO dbo.IR_WaitStats FROM #ws WHERE 1 = 0;
    INSERT dbo.IR_WaitStats SELECT * FROM #ws;

    -- 5. Open transactions
    SELECT @id AS capture_id, st.session_id, at.transaction_id, at.name, at.transaction_begin_time, at.transaction_type,
           dt.database_id, dt.database_transaction_log_bytes_used, dt.database_transaction_log_record_count
    INTO #tr
    FROM sys.dm_tran_active_transactions at
    JOIN sys.dm_tran_session_transactions st ON st.transaction_id = at.transaction_id
    LEFT JOIN sys.dm_tran_database_transactions dt ON dt.transaction_id = at.transaction_id;
    IF OBJECT_ID(N'dbo.IR_Transactions') IS NULL SELECT * INTO dbo.IR_Transactions FROM #tr WHERE 1 = 0;
    INSERT dbo.IR_Transactions SELECT * FROM #tr;

    -- 6. Memory clerks + perf counters
    SELECT @id AS capture_id, [type] AS clerk_type, SUM(pages_kb) AS pages_kb
    INTO #mc FROM sys.dm_os_memory_clerks GROUP BY [type] HAVING SUM(pages_kb) > 10240;
    IF OBJECT_ID(N'dbo.IR_MemoryClerks') IS NULL SELECT * INTO dbo.IR_MemoryClerks FROM #mc WHERE 1 = 0;
    INSERT dbo.IR_MemoryClerks SELECT * FROM #mc;

    SELECT @id AS capture_id, RTRIM(object_name) AS object_name, RTRIM(counter_name) AS counter_name,
           RTRIM(instance_name) AS instance_name, cntr_value, cntr_type
    INTO #pc FROM sys.dm_os_performance_counters;
    IF OBJECT_ID(N'dbo.IR_PerfCounters') IS NULL SELECT * INTO dbo.IR_PerfCounters FROM #pc WHERE 1 = 0;
    INSERT dbo.IR_PerfCounters SELECT * FROM #pc;

    -- 7. Always On state
    SELECT @id AS capture_id, DB_NAME(drs.database_id) AS database_name, ar.replica_server_name, drs.is_primary_replica,
           drs.synchronization_state_desc, drs.synchronization_health_desc, drs.is_suspended, drs.suspend_reason_desc,
           drs.log_send_queue_size, drs.redo_queue_size, drs.last_commit_time
    INTO #ag
    FROM sys.dm_hadr_database_replica_states drs JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id;
    IF OBJECT_ID(N'dbo.IR_AGState') IS NULL SELECT * INTO dbo.IR_AGState FROM #ag WHERE 1 = 0;
    INSERT dbo.IR_AGState SELECT * FROM #ag;

    -- 8. Error log, last 60 minutes
    CREATE TABLE #el (LogDate datetime, ProcessInfo nvarchar(50), [Text] nvarchar(max));
    DECLARE @f nvarchar(30) = CONVERT(nvarchar(30), DATEADD(MINUTE, -60, GETDATE()), 121), @t nvarchar(30) = CONVERT(nvarchar(30), GETDATE(), 121);
    INSERT #el EXEC sys.xp_readerrorlog 0, 1, NULL, NULL, @f, @t, N'asc';
    SELECT @id AS capture_id, LogDate, ProcessInfo, [Text] INTO #el2 FROM #el;
    IF OBJECT_ID(N'dbo.IR_ErrorLog') IS NULL SELECT * INTO dbo.IR_ErrorLog FROM #el2 WHERE 1 = 0;
    INSERT dbo.IR_ErrorLog SELECT * FROM #el2;

    SELECT @id AS capture_id, SYSDATETIME() AS captured_at, @Note AS note;
END;
GO
-- Look at a capture:
--   SELECT * FROM DBAdmin.dbo.IR_Capture ORDER BY capture_id DESC;
--   SELECT * FROM DBAdmin.dbo.IR_Requests WHERE capture_id = 12 ORDER BY total_elapsed_time DESC;
-- Waits between two captures (incident window):
--   SELECT b.wait_type, b.wait_time_ms - a.wait_time_ms AS ms FROM DBAdmin.dbo.IR_WaitStats a
--   JOIN DBAdmin.dbo.IR_WaitStats b ON b.wait_type = a.wait_type AND a.capture_id = 11 AND b.capture_id = 12 ORDER BY ms DESC;
-- Housekeeping: delete captures older than 90 days from all IR_ tables.
*/


/*=============================================================================
  42.3 INCIDENT TIMELINE - EVERYTHING THAT HAPPENED IN A TIME WINDOW   [BOX][MI]
  Error log, job runs, backups, autogrowth / DDL / DBCC (default trace),
  AG state changes, deadlocks, CPU spikes, low-memory signals - one list.
  "What changed at 10:05?" is usually answered here.
=============================================================================*/
DECLARE @from datetime = DATEADD(HOUR, -2, GETDATE()),   -- <== incident window (server local time)
        @to   datetime = GETDATE();
DECLARE @utc_offset_min int = DATEDIFF(MINUTE, GETUTCDATE(), GETDATE());

IF OBJECT_ID('tempdb..#tl') IS NOT NULL DROP TABLE #tl;
CREATE TABLE #tl (event_time datetime, source varchar(30), detail nvarchar(4000));

-- Error log (current + previous file)
IF OBJECT_ID('tempdb..#tel') IS NOT NULL DROP TABLE #tel;
CREATE TABLE #tel (LogDate datetime, ProcessInfo nvarchar(50), [Text] nvarchar(max));
DECLARE @f2 nvarchar(30) = CONVERT(nvarchar(30), @from, 121), @t2 nvarchar(30) = CONVERT(nvarchar(30), @to, 121);
INSERT #tel EXEC sys.xp_readerrorlog 0, 1, NULL, NULL, @f2, @t2, N'asc';
INSERT #tel EXEC sys.xp_readerrorlog 1, 1, NULL, NULL, @f2, @t2, N'asc';
INSERT #tl SELECT LogDate, 'ErrorLog ' + ProcessInfo, LEFT([Text], 4000) FROM #tel
WHERE [Text] NOT LIKE N'Log was backed up%' AND [Text] NOT LIKE N'BACKUP LOG successfully%'
  AND [Text] NOT LIKE N'Database differential changes were backed up%';

-- Agent jobs that failed, or ran > 5 min, overlapping the window
INSERT #tl
SELECT msdb.dbo.agent_datetime(h.run_date, h.run_time), 'Agent job',
       j.name + ' - ' + CASE h.run_status WHEN 0 THEN 'FAILED' WHEN 1 THEN 'succeeded' WHEN 3 THEN 'canceled' ELSE 'status ' + CAST(h.run_status AS varchar(3)) END
     + ', duration ' + STUFF(STUFF(RIGHT('000000' + CAST(h.run_duration AS varchar(10)), 6), 5, 0, ':'), 3, 0, ':')
FROM msdb.dbo.sysjobhistory h JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
WHERE h.step_id = 0
  AND msdb.dbo.agent_datetime(h.run_date, h.run_time) <= @to
  AND DATEADD(SECOND, (h.run_duration / 10000) * 3600 + (h.run_duration / 100 % 100) * 60 + h.run_duration % 100,
              msdb.dbo.agent_datetime(h.run_date, h.run_time)) >= @from
  AND (h.run_status <> 1 OR h.run_duration >= 500);

-- Full / diff backups (heavy IO) in the window
INSERT #tl
SELECT backup_start_date, 'Backup', database_name + ' ' + CASE type WHEN 'D' THEN 'FULL' ELSE 'DIFF' END
     + ' until ' + CONVERT(varchar(8), backup_finish_date, 108) + ' (' + CAST(CAST(backup_size / 1073741824.0 AS decimal(10,1)) AS varchar(12)) + ' GB)'
FROM msdb.dbo.backupset
WHERE type IN ('D', 'I') AND backup_start_date <= @to AND backup_finish_date >= @from;

-- Default trace: autogrowth, shrink, DDL, DBCC, server memory change [BOX]
IF CAST(SERVERPROPERTY('EngineEdition') AS int) <> 8
BEGIN
    DECLARE @trc nvarchar(260);
    SELECT @trc = REVERSE(SUBSTRING(REVERSE(path), CHARINDEX(N'\', REVERSE(path)), 260)) + N'log.trc' FROM sys.traces WHERE is_default = 1;
    IF @trc IS NOT NULL
        INSERT #tl
        SELECT t.StartTime, 'Trace: ' + te.name,
               ISNULL(t.DatabaseName, '') + ' ' + ISNULL(t.ObjectName, '') + ' ' + ISNULL(t.FileName, '')
             + CASE WHEN t.EventClass IN (92, 93) THEN ' +' + CAST(t.IntegerData * 8 / 1024 AS varchar(20)) + ' MB in ' + CAST(t.Duration / 1000 AS varchar(20)) + ' ms' ELSE '' END
             + ' by ' + ISNULL(t.LoginName, '') + ' / ' + ISNULL(t.ApplicationName, '')
        FROM sys.fn_trace_gettable(@trc, DEFAULT) t
        JOIN sys.trace_events te ON te.trace_event_id = t.EventClass
        WHERE t.StartTime BETWEEN @from AND @to
          AND t.EventClass IN (46, 47, 164, 92, 93, 94, 95, 116, 81)
          AND ISNULL(t.DatabaseName, '') <> N'tempdb'
          AND (t.EventClass NOT IN (46, 47, 164) OR t.EventSubClass = 0);
END;

-- Always On state changes (AlwaysOn_health, UTC -> local)
DECLARE @logdir nvarchar(260) = (
    SELECT LEFT(CAST(SERVERPROPERTY('ErrorLogFileName') AS nvarchar(260)),
                LEN(CAST(SERVERPROPERTY('ErrorLogFileName') AS nvarchar(260))) - CHARINDEX(N'\', REVERSE(CAST(SERVERPROPERTY('ErrorLogFileName') AS nvarchar(260)))) + 1));
IF SERVERPROPERTY('IsHadrEnabled') = 1
    INSERT #tl
    SELECT DATEADD(MINUTE, @utc_offset_min, x.ev.value('(event/@timestamp)[1]', 'datetime2')), 'AlwaysOn ' + f.object_name,
           ISNULL(x.ev.value('(event/data[@name="availability_group_name"]/value)[1]', 'nvarchar(128)'), '') + ' '
         + ISNULL(x.ev.value('(event/data[@name="previous_state"]/text)[1]', 'nvarchar(60)') + ' -> ', '')
         + ISNULL(x.ev.value('(event/data[@name="current_state"]/text)[1]', 'nvarchar(60)'), '')
         + ISNULL(' ' + LEFT(x.ev.value('(event/data[@name="message"]/value)[1]', 'nvarchar(max)'), 300), '')
    FROM sys.fn_xe_file_target_read_file(@logdir + N'AlwaysOn_health*.xel', NULL, NULL, NULL) f
    CROSS APPLY (SELECT CAST(f.event_data AS xml)) x(ev)
    WHERE f.object_name IN (N'availability_replica_state_change', N'availability_group_lease_expired', N'error_reported',
                            N'alwayson_ddl_executed', N'availability_replica_automatic_failover_validation')
      AND DATEADD(MINUTE, @utc_offset_min, x.ev.value('(event/@timestamp)[1]', 'datetime2')) BETWEEN @from AND @to;

-- Deadlocks (system_health)
INSERT #tl
SELECT DATEADD(MINUTE, @utc_offset_min, x.ev.value('(event/@timestamp)[1]', 'datetime2')), 'Deadlock',
       'victim ' + ISNULL(x.ev.value('(event/data/value/deadlock/victim-list/victimProcess/@id)[1]', 'varchar(50)'), '?')
     + ' in ' + ISNULL(DB_NAME(x.ev.value('(event/data/value/deadlock/process-list/process/@currentdb)[1]', 'int')), '?')
     + ' - details: 12 12.6'
FROM sys.fn_xe_file_target_read_file(N'system_health*.xel', NULL, NULL, NULL) f
CROSS APPLY (SELECT CAST(f.event_data AS xml)) x(ev)
WHERE f.object_name = N'xml_deadlock_report'
  AND DATEADD(MINUTE, @utc_offset_min, x.ev.value('(event/@timestamp)[1]', 'datetime2')) BETWEEN @from AND @to;

-- CPU > 80% minutes and low-memory notifications (ring buffers - recent history only)
DECLARE @ticks bigint = (SELECT ms_ticks FROM sys.dm_os_sys_info);
INSERT #tl
SELECT DATEADD(MILLISECOND, -1 * (@ticks - rb.[timestamp]), GETDATE()), 'CPU',
       'SQL ' + CAST(x.r.value('(Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') AS varchar(5)) + '%, total '
     + CAST(100 - x.r.value('(Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') AS varchar(5)) + '%'
FROM sys.dm_os_ring_buffers rb CROSS APPLY (SELECT CAST(rb.record AS xml)) x(r)
WHERE rb.ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR' AND rb.record LIKE N'%<SystemHealth>%'
  AND 100 - x.r.value('(Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') > 80
  AND DATEADD(MILLISECOND, -1 * (@ticks - rb.[timestamp]), GETDATE()) BETWEEN @from AND @to;

INSERT #tl
SELECT DATEADD(MILLISECOND, -1 * (@ticks - rb.[timestamp]), GETDATE()), 'Memory',
       x.r.value('(Record/ResourceMonitor/Notification)[1]', 'varchar(60)')
FROM sys.dm_os_ring_buffers rb CROSS APPLY (SELECT CAST(rb.record AS xml)) x(r)
WHERE rb.ring_buffer_type = N'RING_BUFFER_RESOURCE_MONITOR'
  AND x.r.value('(Record/ResourceMonitor/Notification)[1]', 'varchar(60)') IN ('RESOURCE_MEMPHYSICAL_LOW', 'RESOURCE_MEMVIRTUAL_LOW')
  AND DATEADD(MILLISECOND, -1 * (@ticks - rb.[timestamp]), GETDATE()) BETWEEN @from AND @to;

-- New query plans that first appeared in the window (current DB, Query Store) - regression suspects
IF EXISTS (SELECT 1 FROM sys.database_query_store_options WHERE actual_state_desc <> N'OFF')
    INSERT #tl
    SELECT DATEADD(MINUTE, @utc_offset_min, CAST(p.initial_compile_start_time AS datetime2)), 'New plan (' + DB_NAME() + ')',
           'query_id ' + CAST(p.query_id AS varchar(20)) + ' plan_id ' + CAST(p.plan_id AS varchar(20))
         + ' - compare plans in 04 4.5: ' + LEFT(qt.query_sql_text, 200)
    FROM sys.query_store_plan p
    JOIN sys.query_store_query q ON q.query_id = p.query_id
    JOIN sys.query_store_query_text qt ON qt.query_text_id = q.query_text_id
    WHERE p.initial_compile_start_time BETWEEN TODATETIMEOFFSET(@from, @utc_offset_min) AND TODATETIMEOFFSET(@to, @utc_offset_min)
      AND EXISTS (SELECT 1 FROM sys.query_store_plan p2 WHERE p2.query_id = p.query_id AND p2.plan_id <> p.plan_id);   -- query had an older plan

SELECT event_time, source, detail FROM #tl ORDER BY event_time;


/*=============================================================================
  42.4 SAFETY CHECKS BEFORE DRASTIC ACTIONS                           [BOX][MI]
=============================================================================*/
-- (a) BEFORE KILL: what is this session, how long will rollback take?
DECLARE @kill_spid int = 55;   -- <== change
SELECT s.session_id, s.login_name, s.host_name, s.program_name, s.status,
       j.name AS agent_job_name,                                       -- decoded from "SQLAgent - TSQL JobStep (Job 0x...)"
       r.command, r.wait_type, r.percent_complete,
       at.transaction_begin_time,
       DATEDIFF(MINUTE, at.transaction_begin_time, GETDATE())          AS tran_open_min,
       SUM(dt.database_transaction_log_bytes_used) / 1048576           AS log_used_mb,
       SUM(dt.database_transaction_log_record_count)                   AS log_records,
       CASE WHEN SUM(dt.database_transaction_log_record_count) > 1000000 OR DATEDIFF(MINUTE, at.transaction_begin_time, GETDATE()) > 30
            THEN 'ROLLBACK MAY TAKE AS LONG AS THE WORK DONE SO FAR (or longer) - blocking continues during rollback'
            ELSE 'Small transaction - rollback should be quick' END     AS kill_impact,
       CASE WHEN s.program_name LIKE N'%Repl%' OR s.program_name LIKE N'%Distribution%' OR s.program_name LIKE N'%LogReader%' THEN 'REPLICATION AGENT'
            WHEN r.command LIKE N'BACKUP%' OR r.command LIKE N'RESTORE%'  THEN 'BACKUP/RESTORE - killing loses all progress'
            WHEN r.command LIKE N'DBCC%'                                 THEN 'DBCC - safe to kill, rerun later'
            WHEN r.command IN (N'ALTER INDEX', N'CREATE INDEX')          THEN 'INDEX BUILD - non-resumable rollback can be long (5.12 for resumable)'
            ELSE '' END                                                 AS special_case
FROM sys.dm_exec_sessions s
LEFT JOIN sys.dm_exec_requests r ON r.session_id = s.session_id
LEFT JOIN sys.dm_tran_session_transactions st ON st.session_id = s.session_id
LEFT JOIN sys.dm_tran_active_transactions at ON at.transaction_id = st.transaction_id
LEFT JOIN sys.dm_tran_database_transactions dt ON dt.transaction_id = st.transaction_id
LEFT JOIN msdb.dbo.sysjobs j ON s.program_name LIKE N'SQLAgent - TSQL JobStep (Job 0x%'
      AND j.job_id = TRY_CONVERT(uniqueidentifier, TRY_CONVERT(binary(16), SUBSTRING(s.program_name, CHARINDEX(N'0x', s.program_name), 34), 1))
WHERE s.session_id = @kill_spid
GROUP BY s.session_id, s.login_name, s.host_name, s.program_name, s.status, j.name, r.command, r.wait_type, r.percent_complete, at.transaction_begin_time;
-- After KILL: KILL 55 WITH STATUSONLY;  /  02 2.9.  Never restart the service to "stop a rollback" - it continues during recovery.

-- (b) BEFORE RESTARTING THE SERVICE: how long will databases take to come back?
SELECT d.name, d.state_desc, ls.log_recovery_size_mb, ls.total_vlf_count,
       (SELECT COUNT(*) FROM sys.dm_tran_database_transactions dt WHERE dt.database_id = d.database_id AND dt.database_transaction_begin_time IS NOT NULL) AS open_transactions,
       CASE WHEN drs.is_primary_replica = 1 THEN 'AG PRIMARY - restart = failover (auto) or outage (manual)' ELSE '' END AS ag_note
FROM sys.databases d
CROSS APPLY sys.dm_db_log_stats(d.database_id) ls
LEFT JOIN sys.dm_hadr_database_replica_states drs ON drs.database_id = d.database_id AND drs.is_local = 1
WHERE d.state_desc = N'ONLINE'
ORDER BY ls.log_recovery_size_mb DESC;
-- Prefer: capture evidence (42.2) -> planned AG failover (11.15) over restart -> restart only as last resort.
-- Restart also empties the buffer pool & plan cache: expect a slow period afterwards (cold cache + compile storm).

-- (c) BEFORE FAILOVER: data loss and readiness per database -> 40_rpo_rto_compliance.sql 40.11 (run on PRIMARY)

-- (d) BEFORE DBCC FREEPROCCACHE / DROPCLEANBUFFERS on production:
--     FREEPROCCACHE  -> every query recompiles at once (CPU spike, possibly worse than the problem).
--                      Remove ONE plan instead (03 3.9) or force a good plan (04 4.6).
--     DROPCLEANBUFFERS -> all reads go to disk until cache warms. Never on production.
--     sp_recompile 'dbo.Proc' -> targeted, safe.


/*=============================================================================
  42.5 TEMPLATES - STATUS UPDATES & RCA (keeps managers informed = fewer escalations)
=============================================================================*/
/*
 STATUS UPDATE (every 15-30 min during a P1, even if "no change"):
   [HH:MM IST] <Server/App> - <Investigating | Identified | Mitigating | Monitoring | Resolved>
   Impact     : who/what is affected, since when
   Cause      : known / suspected (evidence: 42.1 output, capture_id from 42.2)
   Action     : what we are doing now, and the risk of it (42.4)
   RPO/RTO    : data loss expected? (40.1 / 40.11) ETA to restore service
   Next update: HH:MM

 RCA (within 24-48 h):
   1. Timeline        - 42.3 output for the window (detection, actions, recovery times)
   2. Impact          - duration, users/transactions affected, data loss (actual RPO), time to recover (actual RTO)
   3. Root cause      - the first cause, not the symptom (e.g. "plan regression after stats update", not "high CPU")
   4. Detection       - alert (41.4) or user call? How long between start and detection?
   5. Resolution      - exact commands run, by whom, when
   6. Prevention      - alerts / thresholds (41), baseline (38), Query Store forcing (04), capacity (41.2), runbook updates
   7. Evidence        - DBAdmin.dbo.IR_* capture ids, error log extracts, XE files
*/
