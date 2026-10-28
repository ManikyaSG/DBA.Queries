/*******************************************************************************
 File    : 18_extended_events.sql
 Purpose : Ready-made XE sessions: blocked process report, long-running
           queries, errors. Plus how to list / read sessions.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] Managed Instance   [SQLDB] Azure SQL DB
 Note    : Change file paths to a folder that exists on your server.
           Azure SQL DB / MI event_file targets must point to Azure Blob
           Storage (https://<acct>.blob.core.windows.net/<container>/file.xel)
           with a database-scoped / server credential.
*******************************************************************************/

/*=============================================================================
  18.1 RUNNING XE SESSIONS & TARGETS                           [BOX][MI][SQLDB]
=============================================================================*/
SELECT s.name AS session_name, s.create_time, t.target_name,
       CAST(t.target_data AS xml).value('(EventFileTarget/File/@name)[1]', 'nvarchar(260)') AS current_file
FROM sys.dm_xe_sessions AS s
JOIN sys.dm_xe_session_targets AS t ON t.event_session_address = s.address
ORDER BY s.name;
-- Azure SQL DB: sys.dm_xe_database_sessions / sys.dm_xe_database_session_targets


/*=============================================================================
  18.2 BLOCKED PROCESS REPORT (who blocked whom, > N seconds)         [BOX][MI]
=============================================================================*/
/*
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'blocked process threshold (s)', 10; RECONFIGURE;   -- report blocks > 10s

CREATE EVENT SESSION [DBA_BlockedProcess] ON SERVER
ADD EVENT sqlserver.blocked_process_report (
    ACTION (sqlserver.database_name, sqlserver.client_app_name, sqlserver.client_hostname, sqlserver.username))
ADD TARGET package0.event_file (SET filename = N'D:\XE\DBA_BlockedProcess.xel', max_file_size = 100, max_rollover_files = 5)
WITH (MAX_DISPATCH_LATENCY = 15 SECONDS, STARTUP_STATE = ON);
ALTER EVENT SESSION [DBA_BlockedProcess] ON SERVER STATE = START;
*/

-- Read it:
SELECT
    x.ev.value('(event/@timestamp)[1]', 'datetime2')                     AS event_time_utc,
    x.ev.value('(event/data[@name="database_name"]/value)[1]', 'sysname') AS database_name,
    x.ev.value('(event/data[@name="duration"]/value)[1]', 'bigint') / 1000000 AS blocked_seconds,
    x.ev.query('(event/data[@name="blocked_process"]/value/blocked-process-report)[1]') AS report
FROM sys.fn_xe_file_target_read_file(N'D:\XE\DBA_BlockedProcess*.xel', NULL, NULL, NULL) AS f
CROSS APPLY (SELECT CAST(f.event_data AS xml)) AS x(ev)
ORDER BY event_time_utc DESC;


/*=============================================================================
  18.3 LONG-RUNNING QUERIES (> 5 seconds)                             [BOX][MI]
=============================================================================*/
/*
CREATE EVENT SESSION [DBA_LongQueries] ON SERVER
ADD EVENT sqlserver.rpc_completed (
    ACTION (sqlserver.database_name, sqlserver.client_app_name, sqlserver.client_hostname,
            sqlserver.username, sqlserver.query_hash, sqlserver.sql_text)
    WHERE duration > 5000000),                       -- microseconds
ADD EVENT sqlserver.sql_batch_completed (
    ACTION (sqlserver.database_name, sqlserver.client_app_name, sqlserver.client_hostname,
            sqlserver.username, sqlserver.query_hash, sqlserver.sql_text)
    WHERE duration > 5000000)
ADD TARGET package0.event_file (SET filename = N'D:\XE\DBA_LongQueries.xel', max_file_size = 100, max_rollover_files = 5)
WITH (MAX_DISPATCH_LATENCY = 15 SECONDS, STARTUP_STATE = ON);
ALTER EVENT SESSION [DBA_LongQueries] ON SERVER STATE = START;
*/

SELECT
    x.ev.value('(event/@timestamp)[1]', 'datetime2')                                    AS event_time_utc,
    x.ev.value('(event/@name)[1]', 'nvarchar(60)')                                      AS event_name,
    x.ev.value('(event/action[@name="database_name"]/value)[1]', 'sysname')             AS database_name,
    x.ev.value('(event/data[@name="duration"]/value)[1]', 'bigint') / 1000              AS duration_ms,
    x.ev.value('(event/data[@name="cpu_time"]/value)[1]', 'bigint') / 1000              AS cpu_ms,
    x.ev.value('(event/data[@name="logical_reads"]/value)[1]', 'bigint')                AS logical_reads,
    x.ev.value('(event/action[@name="client_app_name"]/value)[1]', 'nvarchar(256)')     AS app,
    x.ev.value('(event/action[@name="username"]/value)[1]', 'nvarchar(256)')            AS username,
    x.ev.value('(event/action[@name="sql_text"]/value)[1]', 'nvarchar(max)')            AS sql_text
FROM sys.fn_xe_file_target_read_file(N'D:\XE\DBA_LongQueries*.xel', NULL, NULL, NULL) AS f
CROSS APPLY (SELECT CAST(f.event_data AS xml)) AS x(ev)
ORDER BY duration_ms DESC;


/*=============================================================================
  18.4 ERRORS SEVERITY >= 16 (application errors, timeouts)           [BOX][MI]
=============================================================================*/
/*
CREATE EVENT SESSION [DBA_Errors] ON SERVER
ADD EVENT sqlserver.error_reported (
    ACTION (sqlserver.database_name, sqlserver.client_app_name, sqlserver.client_hostname,
            sqlserver.username, sqlserver.sql_text)
    WHERE severity >= 16),
ADD EVENT sqlserver.attention (                         -- client timeouts / cancels
    ACTION (sqlserver.database_name, sqlserver.client_app_name, sqlserver.sql_text))
ADD TARGET package0.event_file (SET filename = N'D:\XE\DBA_Errors.xel', max_file_size = 50, max_rollover_files = 5)
WITH (STARTUP_STATE = ON);
ALTER EVENT SESSION [DBA_Errors] ON SERVER STATE = START;
*/


/*=============================================================================
  18.5 AZURE SQL DB - DATABASE-SCOPED SESSION (ring buffer)            [SQLDB]
=============================================================================*/
/*
CREATE EVENT SESSION [DBA_Deadlocks] ON DATABASE
ADD EVENT sqlserver.database_xml_deadlock_report
ADD TARGET package0.ring_buffer (SET max_memory = 4096)
WITH (STARTUP_STATE = ON);
ALTER EVENT SESSION [DBA_Deadlocks] ON DATABASE STATE = START;

SELECT CAST(t.target_data AS xml) AS ring_buffer
FROM sys.dm_xe_database_session_targets AS t
JOIN sys.dm_xe_database_sessions AS s ON s.address = t.event_session_address
WHERE s.name = N'DBA_Deadlocks';
*/


/*=============================================================================
  18.6 STOP / DROP A SESSION                                   [BOX][MI][SQLDB]
=============================================================================*/
-- ALTER EVENT SESSION [DBA_LongQueries] ON SERVER STATE = STOP;
-- DROP EVENT SESSION  [DBA_LongQueries] ON SERVER;
