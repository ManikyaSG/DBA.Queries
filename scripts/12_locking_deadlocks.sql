/*******************************************************************************
 File    : 12_locking_deadlocks.sql
 Purpose : Lock detail, lock escalation, deadlock history.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] Managed Instance   [SQLDB] Azure SQL DB
 See also: 02_sessions_blocking.sql for live blocking chains.
*******************************************************************************/

/*=============================================================================
  12.1 LOCK SUMMARY BY SESSION                                 [BOX][MI][SQLDB]
=============================================================================*/
SELECT tl.request_session_id AS session_id, DB_NAME(tl.resource_database_id) AS database_name,
       tl.resource_type, tl.request_mode, tl.request_status, COUNT(*) AS lock_count
FROM sys.dm_tran_locks AS tl
WHERE tl.request_session_id <> @@SPID
GROUP BY tl.request_session_id, tl.resource_database_id, tl.resource_type, tl.request_mode, tl.request_status
ORDER BY lock_count DESC;


/*=============================================================================
  12.2 WAITING LOCKS WITH OBJECT NAMES - CURRENT DB            [BOX][MI][SQLDB]
=============================================================================*/
SELECT tl.request_session_id AS waiting_session, wt.blocking_session_id,
       tl.resource_type, tl.request_mode, tl.resource_description,
       wt.wait_duration_ms,
       COALESCE(OBJECT_SCHEMA_NAME(p.object_id) + N'.' + OBJECT_NAME(p.object_id),
                OBJECT_SCHEMA_NAME(tl.resource_associated_entity_id) + N'.' + OBJECT_NAME(tl.resource_associated_entity_id)) AS object_name,
       i.name AS index_name
FROM sys.dm_tran_locks AS tl
JOIN sys.dm_os_waiting_tasks AS wt ON wt.resource_address = tl.lock_owner_address
LEFT JOIN sys.partitions AS p
       ON tl.resource_type IN (N'KEY', N'PAGE', N'RID', N'HOBT') AND p.hobt_id = tl.resource_associated_entity_id
LEFT JOIN sys.indexes AS i ON i.object_id = p.object_id AND i.index_id = p.index_id
WHERE tl.request_status = N'WAIT'
  AND tl.resource_database_id = DB_ID();


/*=============================================================================
  12.3 ALL LOCKS HELD BY ONE SESSION - CURRENT DB              [BOX][MI][SQLDB]
=============================================================================*/
DECLARE @spid int = 55;   -- <== change
SELECT tl.resource_type, tl.request_mode, tl.request_status, tl.resource_description,
       CASE WHEN tl.resource_type = N'OBJECT' THEN OBJECT_NAME(tl.resource_associated_entity_id)
            ELSE OBJECT_NAME(p.object_id) END AS object_name,
       COUNT(*) AS locks
FROM sys.dm_tran_locks AS tl
LEFT JOIN sys.partitions AS p ON p.hobt_id = tl.resource_associated_entity_id
WHERE tl.request_session_id = @spid AND tl.resource_database_id = DB_ID()
GROUP BY tl.resource_type, tl.request_mode, tl.request_status, tl.resource_description,
         tl.resource_associated_entity_id, p.object_id
ORDER BY locks DESC;


/*=============================================================================
  12.4 LOCK ESCALATION HOTSPOTS - CURRENT DB                   [BOX][MI][SQLDB]
=============================================================================*/
SELECT OBJECT_SCHEMA_NAME(os.object_id) + N'.' + OBJECT_NAME(os.object_id) AS table_name,
       i.name AS index_name, t.lock_escalation_desc,
       os.index_lock_promotion_attempt_count, os.index_lock_promotion_count,
       os.row_lock_wait_count, os.row_lock_wait_in_ms, os.page_lock_wait_count, os.page_lock_wait_in_ms
FROM sys.dm_db_index_operational_stats(DB_ID(), NULL, NULL, NULL) AS os
JOIN sys.indexes AS i ON i.object_id = os.object_id AND i.index_id = os.index_id
JOIN sys.tables  AS t ON t.object_id = os.object_id
WHERE os.index_lock_promotion_count > 0
ORDER BY os.index_lock_promotion_count DESC;


/*=============================================================================
  12.5 DEADLOCKS FROM system_health (event_file)                      [BOX][MI]
  Click deadlock_graph -> Save As .xdl -> open in SSMS for the graph.
=============================================================================*/
SELECT
    x.ev.value('(event/@timestamp)[1]', 'datetime2')  AS deadlock_time_utc,
    x.ev.query('(event/data/value/deadlock)[1]')      AS deadlock_graph,
    x.ev.value('(event/data/value/deadlock/victim-list/victimProcess/@id)[1]', 'varchar(50)') AS victim_process_id
FROM sys.fn_xe_file_target_read_file(N'system_health*.xel', NULL, NULL, NULL) AS f
CROSS APPLY (SELECT CAST(f.event_data AS xml)) AS x(ev)
WHERE f.object_name = N'xml_deadlock_report'
ORDER BY deadlock_time_utc DESC;


/*=============================================================================
  12.6 DEADLOCK DETAIL - SHRED PROCESSES (who, what statement) [BOX][MI]
=============================================================================*/
WITH dl AS (
    SELECT CAST(f.event_data AS xml) AS ev
    FROM sys.fn_xe_file_target_read_file(N'system_health*.xel', NULL, NULL, NULL) AS f
    WHERE f.object_name = N'xml_deadlock_report'
)
SELECT
    dl.ev.value('(event/@timestamp)[1]', 'datetime2')                     AS deadlock_time_utc,
    p.n.value('@id', 'varchar(50)')                                       AS process_id,
    CASE WHEN p.n.value('@id', 'varchar(50)') =
              dl.ev.value('(event/data/value/deadlock/victim-list/victimProcess/@id)[1]', 'varchar(50)')
         THEN 'VICTIM' ELSE '' END                                         AS is_victim,
    p.n.value('@spid', 'int')                                             AS spid,
    p.n.value('@loginname', 'nvarchar(128)')                              AS login_name,
    p.n.value('@hostname', 'nvarchar(128)')                               AS host_name,
    p.n.value('@clientapp', 'nvarchar(256)')                              AS client_app,
    DB_NAME(p.n.value('@currentdb', 'int'))                               AS database_name,
    p.n.value('@isolationlevel', 'nvarchar(50)')                          AS isolation_level,
    p.n.value('@waitresource', 'nvarchar(256)')                           AS wait_resource,
    p.n.value('@lockMode', 'nvarchar(10)')                                AS lock_mode,
    p.n.value('(inputbuf)[1]', 'nvarchar(max)')                           AS input_buffer
FROM dl
CROSS APPLY dl.ev.nodes('event/data/value/deadlock/process-list/process') AS p(n)
ORDER BY deadlock_time_utc DESC, is_victim DESC;


/*=============================================================================
  12.7 DEADLOCK COUNTER SINCE RESTART                          [BOX][MI][SQLDB]
=============================================================================*/
SELECT RTRIM(instance_name) AS lock_type, cntr_value AS deadlocks
FROM sys.dm_os_performance_counters
WHERE counter_name = N'Number of Deadlocks/sec' AND cntr_value > 0;


/*=============================================================================
  12.8 AZURE SQL DB - DEADLOCKS                                        [SQLDB]
  Option 1 (run in master): built-in deadlock telemetry (if available in your region/tier)
=============================================================================*/
/*
SELECT CAST(event_data AS xml).value('(event/@timestamp)[1]', 'datetime2') AS deadlock_time_utc,
       CAST(event_data AS xml) AS deadlock_xml
FROM sys.fn_xe_telemetry_blob_target_read_file('dl', NULL, NULL, NULL)
ORDER BY deadlock_time_utc DESC;
*/
-- Option 2: create a database-scoped XE session with ring_buffer / event_file
-- target (see 18_extended_events.sql, Azure section).


/*=============================================================================
  12.9 ISOLATION LEVEL OF ACTIVE SESSIONS                      [BOX][MI][SQLDB]
=============================================================================*/
SELECT session_id, login_name, program_name,
       CASE transaction_isolation_level
           WHEN 0 THEN 'Unspecified' WHEN 1 THEN 'ReadUncommitted' WHEN 2 THEN 'ReadCommitted'
           WHEN 3 THEN 'RepeatableRead' WHEN 4 THEN 'Serializable' WHEN 5 THEN 'Snapshot' END AS isolation_level
FROM sys.dm_exec_sessions
WHERE is_user_process = 1
ORDER BY transaction_isolation_level DESC;
