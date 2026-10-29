/*******************************************************************************
 File    : 36_connectivity_service_troubleshooting.sql
 Purpose : "Can't connect", "Login failed", Kerberos/SPN, ports, TLS,
           connection storms, linked servers, DTC orphans, Service Broker,
           memory dumps, non-yielding schedulers / hangs.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] Managed Instance   [SQLDB] Azure SQL DB
*******************************************************************************/

/*=============================================================================
  36.1 FAILED LOGINS DECODED (error 18456 state -> reason)              [BOX][MI]
=============================================================================*/
IF OBJECT_ID('tempdb..#el') IS NOT NULL DROP TABLE #el;
CREATE TABLE #el (LogDate datetime, ProcessInfo nvarchar(50), [Text] nvarchar(max));
INSERT #el EXEC sys.xp_readerrorlog 0, 1, N'Login failed';
INSERT #el EXEC sys.xp_readerrorlog 0, 1, N'Error: 18456';

WITH states AS (
    SELECT * FROM (VALUES
        (2,  'Login does not exist (invalid user ID)'),
        (5,  'Login does not exist (invalid user ID)'),
        (6,  'Windows login name used with SQL authentication'),
        (7,  'Login disabled AND wrong password'),
        (8,  'Wrong password'),
        (9,  'Invalid password (policy)'),
        (11, 'Valid login, no server access (e.g. CONNECT SQL denied / UAC / group removed)'),
        (12, 'Valid login, no server access'),
        (13, 'SQL Server service paused'),
        (18, 'Password must be changed'),
        (23, 'Server shutting down'),
        (38, 'Cannot open the database requested in the connection string'),
        (40, 'Cannot open the login''s DEFAULT database'),
        (58, 'SQL login used but server is Windows-authentication only')
    ) AS v(state, reason)
),
errs AS (
    SELECT LogDate, ProcessInfo,
           TRY_CAST(REPLACE(SUBSTRING([Text], CHARINDEX('State:', [Text]) + 7, 5), '.', '') AS int) AS state
    FROM #el WHERE [Text] LIKE N'Error: 18456%'
)
SELECT l.LogDate, e.state, ISNULL(s.reason, 'see docs: MSSQLSERVER_18456') AS reason, l.[Text] AS message
FROM #el AS l
LEFT JOIN errs AS e ON e.LogDate = l.LogDate AND e.ProcessInfo = l.ProcessInfo
LEFT JOIN states AS s ON s.state = e.state
WHERE l.[Text] LIKE N'Login failed%'
ORDER BY l.LogDate DESC;

-- Fixes: state 40/46 -> ALTER LOGIN [x] WITH DEFAULT_DATABASE = [master];
--        state 58    -> enable Mixed Mode (restart) or use Windows/Entra auth
--        state 18    -> ALTER LOGIN [x] WITH PASSWORD = N'...' (or uncheck MUST_CHANGE)
-- Failed login auditing must be on: Server properties > Security > "Failed logins only" / "Both".


/*=============================================================================
  36.2 CONNECTIVITY RING BUFFER (closed connections, login timeouts)     [BOX][MI]
=============================================================================*/
DECLARE @ms_now bigint = (SELECT ms_ticks FROM sys.dm_os_sys_info);
SELECT TOP (100)
    DATEADD(MILLISECOND, -1 * (@ms_now - rb.[timestamp]), SYSDATETIME())                             AS event_time,
    x.r.value('(Record/ConnectivityTraceRecord/RecordType)[1]', 'varchar(50)')                      AS record_type,
    x.r.value('(Record/ConnectivityTraceRecord/RecordSource)[1]', 'varchar(50)')                    AS record_source,
    x.r.value('(Record/ConnectivityTraceRecord/Spid)[1]', 'int')                                    AS spid,
    x.r.value('(Record/ConnectivityTraceRecord/RemoteHost)[1]', 'varchar(50)')                      AS remote_host,
    x.r.value('(Record/ConnectivityTraceRecord/RemotePort)[1]', 'int')                              AS remote_port,
    x.r.value('(Record/ConnectivityTraceRecord/LocalPort)[1]', 'int')                               AS local_port,
    x.r.value('(Record/ConnectivityTraceRecord/SniConsumerError)[1]', 'int')                        AS sni_error,
    x.r.value('(Record/ConnectivityTraceRecord/State)[1]', 'int')                                   AS state,
    x.r.value('(Record/ConnectivityTraceRecord/OSError)[1]', 'int')                                 AS os_error,
    x.r                                                                                              AS full_record
FROM sys.dm_os_ring_buffers AS rb
CROSS APPLY (SELECT CAST(rb.record AS xml)) AS x(r)
WHERE rb.ring_buffer_type = N'RING_BUFFER_CONNECTIVITY'
ORDER BY rb.[timestamp] DESC;

-- Security errors (Kerberos / SSPI / TLS handshake failures)
SELECT TOP (50)
    DATEADD(MILLISECOND, -1 * (@ms_now - rb.[timestamp]), SYSDATETIME()) AS event_time,
    x.r.value('(Record/Error/ErrorCode)[1]', 'varchar(20)')               AS error_code,
    x.r.value('(Record/Error/CallingAPIName)[1]', 'varchar(100)')         AS calling_api,
    x.r.value('(Record/Error/APIName)[1]', 'varchar(100)')                AS api_name,
    x.r.value('(Record/Error/SPID)[1]', 'int')                            AS spid
FROM sys.dm_os_ring_buffers AS rb
CROSS APPLY (SELECT CAST(rb.record AS xml)) AS x(r)
WHERE rb.ring_buffer_type = N'RING_BUFFER_SECURITY_ERROR'
ORDER BY rb.[timestamp] DESC;


/*=============================================================================
  36.3 KERBEROS OR NTLM? + SPN CHECKS                                   [BOX][MI]
  Remote Windows connections should be KERBEROS (needed for double-hop to
  linked servers / delegation). NTLM remotely = SPN missing or duplicated.
=============================================================================*/
SELECT c.auth_scheme, c.net_transport, COUNT(*) AS connections,
       SUM(CASE WHEN c.client_net_address NOT IN ('<local machine>', '127.0.0.1', '::1') THEN 1 ELSE 0 END) AS remote_connections
FROM sys.dm_exec_connections AS c
GROUP BY c.auth_scheme, c.net_transport;

SELECT auth_scheme FROM sys.dm_exec_connections WHERE session_id = @@SPID;   -- your own connection

/*
 SPN commands (run on a domain machine; needs read rights in AD):
   setspn -L DOMAIN\sqlsvc                                    -- SPNs on the service account
   setspn -Q MSSQLSvc/SQLVM1.domain.local:1433                -- who owns this SPN
   setspn -X                                                  -- duplicates (break Kerberos)
   setspn -S MSSQLSvc/SQLVM1.domain.local:1433 DOMAIN\sqlsvc  -- add (domain admin)
   AG listener: SPN for the LISTENER name + port on the SQL service account (all replicas same account).
 dbatools:  Test-DbaSpn -ComputerName SQLVM1   |   Set-DbaSpn
 Kerberos Configuration Manager (Microsoft) also diagnoses and generates fix scripts.
*/


/*=============================================================================
  36.4 WHAT IS SQL LISTENING ON? (ports, protocols, TLS)               [BOX]
=============================================================================*/
SELECT listener_id, ip_address, is_ipv4, port, type_desc, state_desc, start_time
FROM sys.dm_tcp_listener_states;

SELECT DISTINCT local_net_address, local_tcp_port, net_transport, protocol_type, encrypt_option
FROM sys.dm_exec_connections WHERE local_tcp_port IS NOT NULL;

-- Port / dynamic port / forced encryption / certificate from registry
SELECT registry_key, value_name, value_data
FROM sys.dm_server_registry
WHERE value_name IN (N'TcpPort', N'TcpDynamicPorts', N'ForceEncryption', N'Certificate', N'Enabled', N'ListenOnAllIPs')
ORDER BY registry_key, value_name;

/*
 Client-side checks (from the APP server):
   Test-NetConnection SQLVM1 -Port 1433                       -- firewall / NSG
   Test-NetConnection SQLVM1 -Port 1434                       -- SQL Browser (UDP; named instances w/o fixed port)
   Resolve-DnsName ag1-listener                               -- listener resolves to all subnet IPs? use MultiSubnetFailover=True
 Error 26/40   -> server name / instance / Browser / firewall
 Error 10060/10061 -> nothing listening / port blocked
 "certificate chain not trusted" -> TrustServerCertificate or install proper CA cert (Encrypt=True is default in new drivers)
*/


/*=============================================================================
  36.5 CONNECTION STORMS / POOL LEAKS                          [BOX][MI][SQLDB]
=============================================================================*/
-- Sessions per host/app with idle time (pool leak = many sleeping, long idle)
SELECT s.host_name, s.program_name, s.login_name, COUNT(*) AS sessions,
       SUM(CASE WHEN s.status = 'sleeping' THEN 1 ELSE 0 END) AS sleeping,
       MAX(DATEDIFF(MINUTE, s.last_request_end_time, SYSDATETIME())) AS max_idle_min,
       SUM(CASE WHEN s.open_transaction_count > 0 THEN 1 ELSE 0 END) AS with_open_tran
FROM sys.dm_exec_sessions AS s
WHERE s.is_user_process = 1
GROUP BY s.host_name, s.program_name, s.login_name
ORDER BY sessions DESC;

-- Logins/sec and connection resets (sample twice)
SELECT RTRIM(counter_name) AS counter_name, cntr_value
FROM sys.dm_os_performance_counters
WHERE counter_name IN (N'Logins/sec', N'Logouts/sec', N'User Connections', N'Connection Reset/sec');
-- High Logins/sec with low User Connections = app not using pooling.
-- THREADPOOL waits = worker exhaustion -> 07_cpu.sql 7.3 ; connect via DAC (35.10).


/*=============================================================================
  36.6 LINKED SERVER TROUBLESHOOTING                                    [BOX][MI]
=============================================================================*/
/*
EXEC sp_testlinkedserver N'LinkedServerName';                                  -- connectivity + login mapping
EXEC sp_helplinkedsrvlogin N'LinkedServerName';
SELECT * FROM OPENQUERY([LinkedServerName], 'SELECT @@SERVERNAME, SUSER_SNAME()');   -- who am I on the other side?
*/
-- Sessions currently waiting on a linked server / remote provider
SELECT r.session_id, r.wait_type, r.wait_time, s.login_name, t.text
FROM sys.dm_exec_requests r
JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.wait_type IN (N'OLEDB', N'PREEMPTIVE_OLEDBOPS', N'PREEMPTIVE_OS_AUTHENTICATIONOPS', N'MSQL_DQ');
-- "Login failed for NT AUTHORITY\ANONYMOUS LOGON" = Kerberos double-hop failing -> 36.3


/*=============================================================================
  36.7 DISTRIBUTED TRANSACTIONS (DTC) & ORPHANED SPID -2                 [BOX]
=============================================================================*/
SELECT at.transaction_id, at.name, at.transaction_begin_time, at.transaction_type,
       at.dtc_state, at.transaction_uow
FROM sys.dm_tran_active_transactions AS at
WHERE at.transaction_type = 4                         -- distributed
ORDER BY at.transaction_begin_time;

-- Orphaned DTC transactions show as session -2 holding locks (blocking everyone)
SELECT DISTINCT tl.request_owner_guid AS uow,
       N'KILL ''' + CAST(tl.request_owner_guid AS nvarchar(40)) + N''';' AS kill_cmd
FROM sys.dm_tran_locks AS tl
WHERE tl.request_session_id = -2;


/*=============================================================================
  36.8 SERVICE BROKER HEALTH - CURRENT DB                      [BOX][MI]
=============================================================================*/
SELECT name, is_broker_enabled, service_broker_guid FROM sys.databases WHERE database_id = DB_ID();

-- Queues: disabled by poison message? activation running?
SELECT q.name, q.is_receive_enabled, q.is_enqueue_enabled, q.is_activation_enabled,
       q.activation_procedure, q.max_readers, q.is_poison_message_handling_enabled,
       (SELECT SUM(p.rows) FROM sys.partitions p JOIN sys.internal_tables it ON it.object_id = p.object_id
        WHERE it.parent_object_id = q.object_id AND p.index_id = 1) AS messages_in_queue
FROM sys.service_queues AS q
WHERE q.is_ms_shipped = 0;
-- Re-enable after poison message:  ALTER QUEUE dbo.YourQueue WITH STATUS = ON;

-- Messages stuck on the sender side + why
SELECT TOP (50) to_service_name, enqueue_time, transmission_status, message_type_name
FROM sys.transmission_queue ORDER BY enqueue_time;

-- Conversation leaks (endpoints never ended)
SELECT state_desc, COUNT(*) AS conversations FROM sys.conversation_endpoints GROUP BY state_desc ORDER BY conversations DESC;

-- Activation tasks running
SELECT DB_NAME(database_id) AS database_name, queue_id, procedure_name, execute_as, spid FROM sys.dm_broker_activated_tasks;


/*=============================================================================
  36.9 HANGS, STACK DUMPS, NON-YIELDING SCHEDULERS                       [BOX][MI]
=============================================================================*/
-- Memory dumps written by SQL Server (send to Microsoft support with the error log)
SELECT filename, creation_time, size_in_bytes / 1048576 AS size_mb
FROM sys.dm_server_memory_dumps
ORDER BY creation_time DESC;

EXEC sys.xp_readerrorlog 0, 1, N'non-yielding';
EXEC sys.xp_readerrorlog 0, 1, N'Stack Signature';
EXEC sys.xp_readerrorlog 0, 1, N'deadlocked schedulers';

-- system_health: scheduler / health component events
SELECT x.ev.value('(event/@timestamp)[1]', 'datetime2') AS event_time_utc,
       x.ev.value('(event/@name)[1]', 'nvarchar(100)')  AS event_name,
       x.ev.value('(event/data[@name="component"]/text)[1]', 'nvarchar(100)')  AS component,
       x.ev.value('(event/data[@name="state"]/text)[1]', 'nvarchar(50)')       AS state
FROM sys.fn_xe_file_target_read_file(N'system_health*.xel', NULL, NULL, NULL) AS f
CROSS APPLY (SELECT CAST(f.event_data AS xml)) AS x(ev)
WHERE f.object_name IN (N'scheduler_monitor_non_yielding_ring_buffer_recorded', N'scheduler_monitor_deadlock_ring_buffer_recorded',
                        N'sp_server_diagnostics_component_result')
  AND (f.object_name <> N'sp_server_diagnostics_component_result'
       OR x.ev.value('(event/data[@name="state"]/text)[1]', 'nvarchar(50)') <> N'CLEAN')
ORDER BY event_time_utc DESC;


/*=============================================================================
  36.10 AZURE SQL DB CONNECTIVITY QUICK CHECKS                          [SQLDB]
=============================================================================*/
/*
 - Firewall:  master: SELECT * FROM sys.firewall_rules;   user DB: SELECT * FROM sys.database_firewall_rules;
 - Connection policy Redirect needs ports 11000-11999 open from clients inside Azure (Proxy uses only 1433).
 - Private endpoint: DNS must resolve <server>.database.windows.net to the private IP (privatelink zone).
 - Error 40613 "database not currently available" = transient (failover / scaling) -> app needs retry logic.
 - Error 40501/40544/40549/40551 = throttling / limits -> 16_azure_sql_database.sql 16.2
 - Entra auth: user must exist in the DB (CREATE USER [x] FROM EXTERNAL PROVIDER).
*/
-- Connection failures over time: Azure portal > database > Metrics ("Failed connections") or
-- diagnostic settings -> Log Analytics (AzureDiagnostics / SQLSecurityAuditEvents).
