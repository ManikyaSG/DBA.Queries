/*******************************************************************************
 File    : 01_wait_stats.sql
 Purpose : "Where is SQL Server spending its time?" - the first stop for any
           performance complaint.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] Managed Instance   [SQLDB] Azure SQL DB
 Note    : sys.dm_os_wait_stats is cumulative since restart (or last clear).
           Use 1.2 (delta snapshot) to see what is happening RIGHT NOW.
           Azure SQL DB: replace sys.dm_os_wait_stats with sys.dm_db_wait_stats.
*******************************************************************************/

/*=============================================================================
  1.1  TOP WAITS SINCE RESTART (benign waits filtered)                [BOX][MI]
  Benign-wait list based on Paul Randal's (SQLskills) well-known filter.
  Quick guide:
    CXPACKET/CXCONSUMER -> parallelism       PAGEIOLATCH_*   -> reads from disk
    LCK_M_*             -> blocking          WRITELOG        -> log disk latency
    SOS_SCHEDULER_YIELD -> CPU pressure      RESOURCE_SEMAPHORE -> memory grants
    HADR_SYNC_COMMIT    -> sync AG replica   PAGELATCH_* (db 2) -> tempdb contention
    THREADPOOL          -> worker exhaustion ASYNC_NETWORK_IO -> client not consuming
    LOG_RATE_GOVERNOR / INSTANCE_LOG_RATE_GOVERNOR -> Azure log throughput cap
=============================================================================*/
WITH waits AS (
    SELECT
        wait_type,
        wait_time_ms / 1000.0                              AS wait_s,
        (wait_time_ms - signal_wait_time_ms) / 1000.0      AS resource_s,
        signal_wait_time_ms / 1000.0                       AS signal_s,
        waiting_tasks_count,
        100.0 * wait_time_ms / SUM(wait_time_ms) OVER ()   AS pct,
        ROW_NUMBER() OVER (ORDER BY wait_time_ms DESC)     AS rn
    FROM sys.dm_os_wait_stats          -- Azure SQL DB: sys.dm_db_wait_stats
    WHERE waiting_tasks_count > 0
      AND wait_type NOT IN (
        N'BROKER_EVENTHANDLER', N'BROKER_RECEIVE_WAITFOR', N'BROKER_TASK_STOP',
        N'BROKER_TO_FLUSH', N'BROKER_TRANSMITTER', N'CHECKPOINT_QUEUE', N'CHKPT',
        N'CLR_AUTO_EVENT', N'CLR_MANUAL_EVENT', N'CLR_SEMAPHORE', N'CXCONSUMER',
        N'DBMIRROR_DBM_EVENT', N'DBMIRROR_EVENTS_QUEUE', N'DBMIRROR_WORKER_QUEUE',
        N'DBMIRRORING_CMD', N'DIRTY_PAGE_POLL', N'DISPATCHER_QUEUE_SEMAPHORE',
        N'EXECSYNC', N'FSAGENT', N'FT_IFTS_SCHEDULER_IDLE_WAIT', N'FT_IFTSHC_MUTEX',
        N'HADR_CLUSAPI_CALL', N'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
        N'HADR_LOGCAPTURE_WAIT', N'HADR_NOTIFICATION_DEQUEUE', N'HADR_TIMER_TASK',
        N'HADR_WORK_QUEUE', N'KSOURCE_WAKEUP', N'LAZYWRITER_SLEEP', N'LOGMGR_QUEUE',
        N'MEMORY_ALLOCATION_EXT', N'ONDEMAND_TASK_QUEUE',
        N'PARALLEL_REDO_DRAIN_WORKER', N'PARALLEL_REDO_LOG_CACHE',
        N'PARALLEL_REDO_TRAN_LIST', N'PARALLEL_REDO_WORKER_SYNC',
        N'PARALLEL_REDO_WORKER_WAIT_WORK', N'PREEMPTIVE_OS_FLUSHFILEBUFFERS',
        N'PREEMPTIVE_XE_GETTARGETSTATE', N'PVS_PREALLOCATE',
        N'PWAIT_ALL_COMPONENTS_INITIALIZED', N'PWAIT_DIRECTLOGCONSUMER_GETNEXT',
        N'PWAIT_EXTENSIBILITY_CLEANUP_TASK', N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP',
        N'QDS_ASYNC_QUEUE', N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
        N'QDS_SHUTDOWN_QUEUE', N'REDO_THREAD_PENDING_WORK',
        N'REQUEST_FOR_DEADLOCK_SEARCH', N'RESOURCE_QUEUE', N'SERVER_IDLE_CHECK',
        N'SLEEP_BPOOL_FLUSH', N'SLEEP_DBSTARTUP', N'SLEEP_DCOMSTARTUP',
        N'SLEEP_MASTERDBREADY', N'SLEEP_MASTERMDREADY', N'SLEEP_MASTERUPGRADED',
        N'SLEEP_MSDBSTARTUP', N'SLEEP_SYSTEMTASK', N'SLEEP_TASK',
        N'SLEEP_TEMPDBSTARTUP', N'SNI_HTTP_ACCEPT', N'SOS_WORK_DISPATCHER',
        N'SP_SERVER_DIAGNOSTICS_SLEEP', N'SQLTRACE_BUFFER_FLUSH',
        N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP', N'SQLTRACE_WAIT_ENTRIES',
        N'VDI_CLIENT_OTHER', N'WAIT_FOR_RESULTS', N'WAITFOR', N'WAITFOR_TASKSHUTDOWN',
        N'WAIT_XTP_RECOVERY', N'WAIT_XTP_HOST_WAIT', N'WAIT_XTP_OFFLINE_CKPT_NEW_LOG',
        N'WAIT_XTP_CKPT_CLOSE', N'XE_DISPATCHER_JOIN', N'XE_DISPATCHER_WAIT',
        N'XE_TIMER_EVENT', N'XE_LIVE_TARGET_TVF')
)
SELECT
    w.wait_type,
    CAST(w.wait_s     AS decimal(18,1)) AS wait_s,
    CAST(w.resource_s AS decimal(18,1)) AS resource_s,
    CAST(w.signal_s   AS decimal(18,1)) AS signal_s,
    w.waiting_tasks_count,
    CAST(w.wait_s * 1000 / w.waiting_tasks_count AS decimal(18,2)) AS avg_wait_ms,
    CAST(w.pct AS decimal(5,2))                                     AS pct,
    CAST(SUM(w.pct) OVER (ORDER BY w.rn ROWS UNBOUNDED PRECEDING) AS decimal(5,2)) AS running_pct
FROM waits AS w
WHERE w.rn <= 25
ORDER BY w.rn;


/*=============================================================================
  1.2  WAITS RIGHT NOW - DELTA OVER N SECONDS                  [BOX][MI][SQLDB]
  Takes two snapshots @delay apart and shows the difference.
  Azure SQL DB: change both FROM clauses to sys.dm_db_wait_stats.
=============================================================================*/
DECLARE @delay char(8) = '00:01:00';   -- hh:mm:ss

IF OBJECT_ID('tempdb..#w1') IS NOT NULL DROP TABLE #w1;
SELECT wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms
INTO #w1 FROM sys.dm_os_wait_stats;

WAITFOR DELAY @delay;

SELECT TOP (20)
    w2.wait_type,
    w2.wait_time_ms        - w1.wait_time_ms        AS wait_ms_delta,
    w2.signal_wait_time_ms - w1.signal_wait_time_ms AS signal_ms_delta,
    w2.waiting_tasks_count - w1.waiting_tasks_count AS tasks_delta,
    CAST((w2.wait_time_ms - w1.wait_time_ms) * 1.0
         / NULLIF(w2.waiting_tasks_count - w1.waiting_tasks_count, 0) AS decimal(18,2)) AS avg_wait_ms
FROM sys.dm_os_wait_stats AS w2
JOIN #w1 AS w1 ON w1.wait_type = w2.wait_type
WHERE w2.wait_time_ms - w1.wait_time_ms > 0
  AND w2.wait_type NOT LIKE N'SLEEP%'
  AND w2.wait_type NOT LIKE N'%QUEUE%'
  AND w2.wait_type NOT IN (N'LAZYWRITER_SLEEP', N'XE_TIMER_EVENT', N'XE_DISPATCHER_WAIT',
        N'REQUEST_FOR_DEADLOCK_SEARCH', N'CHECKPOINT_QUEUE', N'DIRTY_PAGE_POLL',
        N'HADR_FILESTREAM_IOMGR_IOCOMPLETION', N'SP_SERVER_DIAGNOSTICS_SLEEP',
        N'BROKER_TO_FLUSH', N'HADR_TIMER_TASK', N'HADR_WORK_QUEUE', N'WAITFOR',
        N'CXCONSUMER', N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP', N'PWAIT_EXTENSIBILITY_CLEANUP_TASK')
ORDER BY wait_ms_delta DESC;


/*=============================================================================
  1.3  WHO IS WAITING ON WHAT - LIVE                          [BOX][MI][SQLDB]
=============================================================================*/
SELECT
    wt.session_id, wt.exec_context_id, wt.wait_type, wt.wait_duration_ms,
    wt.blocking_session_id, wt.resource_description,
    s.login_name, s.host_name, s.program_name,
    DB_NAME(r.database_id) AS database_name,
    t.text                 AS sql_text
FROM sys.dm_os_waiting_tasks AS wt
JOIN sys.dm_exec_sessions    AS s ON s.session_id = wt.session_id
LEFT JOIN sys.dm_exec_requests AS r ON r.session_id = wt.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE s.is_user_process = 1
ORDER BY wt.wait_duration_ms DESC;


/*=============================================================================
  1.4  WAIT STATS FOR ONE SESSION (2016+)                     [BOX][MI][SQLDB]
=============================================================================*/
DECLARE @spid int = 55;   -- <== change
SELECT session_id, wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms
FROM sys.dm_exec_session_wait_stats
WHERE session_id = @spid
ORDER BY wait_time_ms DESC;


/*=============================================================================
  1.5  SIGNAL WAIT % (CPU PRESSURE INDICATOR)                         [BOX][MI]
  > ~20-25% signal waits suggests tasks are waiting for CPU after resources
  became available.
=============================================================================*/
SELECT
    CAST(100.0 * SUM(signal_wait_time_ms) / SUM(wait_time_ms) AS decimal(5,2))                       AS signal_wait_pct,
    CAST(100.0 * SUM(wait_time_ms - signal_wait_time_ms) / SUM(wait_time_ms) AS decimal(5,2))        AS resource_wait_pct
FROM sys.dm_os_wait_stats
WHERE wait_time_ms > 0;


/*=============================================================================
  1.6  LATCH STATS (non-buffer latches)                               [BOX][MI]
=============================================================================*/
SELECT TOP (15) latch_class, waiting_requests_count, wait_time_ms, max_wait_time_ms,
       CAST(wait_time_ms * 1.0 / NULLIF(waiting_requests_count,0) AS decimal(18,2)) AS avg_wait_ms
FROM sys.dm_os_latch_stats
WHERE latch_class NOT IN (N'BUFFER')
ORDER BY wait_time_ms DESC;


/*=============================================================================
  1.7  CLEAR WAIT STATS (use with care - resets baseline)             [BOX][MI]
=============================================================================*/
-- DBCC SQLPERF('sys.dm_os_wait_stats', CLEAR);
