/*******************************************************************************
 File    : 02_sessions_blocking.sql
 Purpose : What is running right now, who is blocking whom, open transactions.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] Managed Instance   [SQLDB] Azure SQL DB
 Tip     : For deeper live diagnostics, Adam Machanic's sp_WhoIsActive is the
           community standard - this file covers the same ground with plain DMVs.
*******************************************************************************/

/*=============================================================================
  2.1  ACTIVE REQUESTS ("sp_who2 on steroids")                 [BOX][MI][SQLDB]
=============================================================================*/
SELECT
    r.session_id,
    r.blocking_session_id                            AS blocked_by,
    s.login_name, s.host_name, s.program_name,
    DB_NAME(r.database_id)                           AS database_name,
    r.status, r.command,
    r.wait_type, r.wait_time AS wait_ms, r.wait_resource, r.last_wait_type,
    r.cpu_time                                       AS cpu_ms,
    r.total_elapsed_time / 1000                      AS elapsed_s,
    r.logical_reads, r.reads, r.writes,
    r.granted_query_memory * 8 / 1024                AS grant_mb,
    r.dop,
    r.open_transaction_count,
    r.percent_complete,
    SUBSTRING(t.text, (r.statement_start_offset / 2) + 1,
        ((CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(t.text)
          ELSE r.statement_end_offset END - r.statement_start_offset) / 2) + 1) AS current_statement,
    OBJECT_SCHEMA_NAME(t.objectid, t.dbid) + N'.' + OBJECT_NAME(t.objectid, t.dbid) AS object_name,
    t.text                                           AS batch_text,
    qp.query_plan                                    AS estimated_plan
FROM sys.dm_exec_requests AS r
JOIN sys.dm_exec_sessions AS s ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle)  AS t
OUTER APPLY sys.dm_exec_query_plan(r.plan_handle) AS qp
WHERE s.is_user_process = 1
  AND r.session_id <> @@SPID
ORDER BY r.total_elapsed_time DESC;


/*=============================================================================
  2.2  LIVE (IN-FLIGHT) ACTUAL PLAN FOR A SESSION       2016 SP1+ [BOX][MI][SQLDB]
  2019+ has lightweight profiling on by default; earlier versions need
  TF 7412 or the query_thread_profile XE for this to return data.
=============================================================================*/
DECLARE @spid int = 55;   -- <== change
SELECT session_id, query_plan
FROM sys.dm_exec_query_statistics_xml(@spid);

-- Operator-level progress of a running query
SELECT session_id, node_id, physical_operator_name, row_count, estimate_row_count,
       elapsed_time_ms, cpu_time_ms, logical_read_count
FROM sys.dm_exec_query_profiles
WHERE session_id = @spid
ORDER BY node_id;


/*=============================================================================
  2.3  BLOCKING TREE (head blocker at top, victims indented)   [BOX][MI][SQLDB]
=============================================================================*/
IF OBJECT_ID('tempdb..#blk') IS NOT NULL DROP TABLE #blk;

SELECT
    s.session_id,
    ISNULL(r.blocking_session_id, 0)                AS blocking_session_id,
    s.status, r.wait_type, r.wait_time AS wait_ms, r.wait_resource,
    s.login_name, s.host_name, s.program_name,
    DB_NAME(COALESCE(r.database_id, s.database_id)) AS database_name,
    s.open_transaction_count,
    t.text                                          AS running_sql
INTO #blk
FROM sys.dm_exec_sessions AS s
LEFT JOIN sys.dm_exec_requests AS r ON r.session_id = s.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE s.is_user_process = 1;

WITH chain AS (
    -- head blockers: block someone, but are not blocked themselves
    SELECT b.session_id, b.blocking_session_id, 0 AS lvl,
           CAST(RIGHT('00000' + CAST(b.session_id AS varchar(10)), 5) AS varchar(4000)) AS sort_path
    FROM #blk AS b
    WHERE b.blocking_session_id = 0
      AND EXISTS (SELECT 1 FROM #blk AS x WHERE x.blocking_session_id = b.session_id
                                            AND x.session_id <> b.session_id)
    UNION ALL
    SELECT b.session_id, b.blocking_session_id, c.lvl + 1,
           CAST(c.sort_path + '>' + RIGHT('00000' + CAST(b.session_id AS varchar(10)), 5) AS varchar(4000))
    FROM #blk AS b
    JOIN chain AS c ON b.blocking_session_id = c.session_id
    WHERE b.session_id <> b.blocking_session_id
)
SELECT
    REPLICATE('    ', c.lvl) + CAST(c.session_id AS varchar(10)) AS blocking_tree,
    CASE WHEN c.lvl = 0 THEN 'HEAD BLOCKER' ELSE '' END       AS role,
    b.status, b.wait_type, b.wait_ms, b.wait_resource,
    b.login_name, b.host_name, b.program_name, b.database_name,
    b.open_transaction_count,
    COALESCE(b.running_sql, ib.event_info)                    AS sql_text   -- sleeping heads show last input buffer
FROM chain AS c
JOIN #blk AS b ON b.session_id = c.session_id
OUTER APPLY sys.dm_exec_input_buffer(c.session_id, NULL) AS ib
ORDER BY c.sort_path
OPTION (MAXRECURSION 200);


/*=============================================================================
  2.4  QUICK BLOCKING SUMMARY (how many victims per blocker)   [BOX][MI][SQLDB]
=============================================================================*/
SELECT r.blocking_session_id      AS blocker,
       COUNT(*)                   AS sessions_blocked,
       MAX(r.wait_time) / 1000    AS longest_wait_s,
       MIN(r.wait_type)           AS sample_wait_type
FROM sys.dm_exec_requests AS r
WHERE r.blocking_session_id > 0
GROUP BY r.blocking_session_id
ORDER BY sessions_blocked DESC;


/*=============================================================================
  2.5  OPEN TRANSACTIONS (oldest first) - log growth / blocking culprits
                                                               [BOX][MI][SQLDB]
=============================================================================*/
SELECT
    st.session_id,
    s.login_name, s.host_name, s.program_name, s.status AS session_status,
    at.transaction_id, at.name AS tran_name,
    at.transaction_begin_time,
    DATEDIFF(SECOND, at.transaction_begin_time, SYSDATETIME()) AS open_seconds,
    CASE at.transaction_state
        WHEN 0 THEN 'Not initialized' WHEN 1 THEN 'Initialized, not started'
        WHEN 2 THEN 'Active'          WHEN 3 THEN 'Ended (read-only)'
        WHEN 4 THEN 'Commit initiated (DTC)' WHEN 5 THEN 'Prepared'
        WHEN 6 THEN 'Committed'       WHEN 7 THEN 'Rolling back'
        WHEN 8 THEN 'Rolled back' END                  AS tran_state,
    DB_NAME(dt.database_id)                            AS database_name,
    dt.database_transaction_log_record_count           AS log_records,
    dt.database_transaction_log_bytes_used / 1048576.0 AS log_used_mb,
    ib.event_info                                      AS last_input_buffer
FROM sys.dm_tran_active_transactions  AS at
JOIN sys.dm_tran_session_transactions AS st ON st.transaction_id = at.transaction_id
JOIN sys.dm_exec_sessions             AS s  ON s.session_id = st.session_id
LEFT JOIN sys.dm_tran_database_transactions AS dt ON dt.transaction_id = at.transaction_id
OUTER APPLY sys.dm_exec_input_buffer(st.session_id, NULL) AS ib
ORDER BY at.transaction_begin_time;


/*=============================================================================
  2.6  SLEEPING SESSIONS HOLDING OPEN TRANSACTIONS (forgotten COMMITs)
                                                               [BOX][MI][SQLDB]
=============================================================================*/
SELECT s.session_id, s.login_name, s.host_name, s.program_name,
       s.open_transaction_count, s.last_request_end_time,
       DATEDIFF(MINUTE, s.last_request_end_time, SYSDATETIME()) AS idle_minutes,
       ib.event_info AS last_sql
FROM sys.dm_exec_sessions AS s
OUTER APPLY sys.dm_exec_input_buffer(s.session_id, NULL) AS ib
WHERE s.status = 'sleeping'
  AND s.open_transaction_count > 0
ORDER BY s.last_request_end_time;


/*=============================================================================
  2.7  CONNECTION DETAILS (IP, protocol, encryption, auth)     [BOX][MI][SQLDB]
=============================================================================*/
SELECT c.session_id, s.login_name, s.host_name, s.program_name,
       c.client_net_address, c.local_net_address, c.local_tcp_port,
       c.net_transport, c.protocol_type, c.encrypt_option, c.auth_scheme,
       c.connect_time, s.last_request_start_time
FROM sys.dm_exec_connections AS c
JOIN sys.dm_exec_sessions    AS s ON s.session_id = c.session_id
ORDER BY c.connect_time;


/*=============================================================================
  2.8  LAST SQL SENT BY A SESSION                              [BOX][MI][SQLDB]
=============================================================================*/
DECLARE @spid2 int = 55;   -- <== change
SELECT event_type, parameters, event_info FROM sys.dm_exec_input_buffer(@spid2, NULL);


/*=============================================================================
  2.9  ROLLBACK / KILL PROGRESS                                [BOX][MI][SQLDB]
=============================================================================*/
SELECT session_id, command, status, percent_complete,
       estimated_completion_time / 60000 AS est_minutes_left,
       total_elapsed_time / 60000        AS elapsed_minutes
FROM sys.dm_exec_requests
WHERE command IN ('KILLED/ROLLBACK', 'ROLLBACK TRANSACTION')
   OR status = 'rollback';
-- KILL 55 WITH STATUSONLY;


/*=============================================================================
  2.10 GENERATE KILL FOR HEAD BLOCKERS (review before running!) [BOX][MI][SQLDB]
=============================================================================*/
SELECT DISTINCT 'KILL ' + CAST(r.blocking_session_id AS varchar(10)) + ';' AS kill_cmd
FROM sys.dm_exec_requests AS r
WHERE r.blocking_session_id > 0
  AND r.blocking_session_id NOT IN (SELECT session_id FROM sys.dm_exec_requests
                                    WHERE blocking_session_id > 0);
