/*******************************************************************************
 File    : 25_alwayson_advanced.sql
 Purpose : Always On - beyond the health checks in 11: one-shot alert query,
           "not synchronizing" troubleshooting, readable-secondary impact,
           distributed / contained AGs, login & job drift between replicas,
           build/add/remove templates, Azure VM specifics.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] where noted
 See also: 11_alwayson_ag.sql (dashboard, lag, RPO/RTO, seeding, listeners)
*******************************************************************************/

/*=============================================================================
  25.1 SINGLE ALERT QUERY - RETURNS ROWS ONLY WHEN SOMETHING IS WRONG  [BOX]
  Good for an Agent job / monitoring tool: 0 rows = healthy.
=============================================================================*/
DECLARE @max_send_queue_kb bigint = 1048576,   -- 1 GB
        @max_redo_queue_kb bigint = 1048576,
        @max_lag_s         int    = 300;

SELECT 'AG' AS level, ag.name AS ag_name, NULL AS replica, NULL AS database_name,
       'AG health: ' + ags.synchronization_health_desc AS issue
FROM sys.dm_hadr_availability_group_states AS ags
JOIN sys.availability_groups AS ag ON ag.group_id = ags.group_id
WHERE ags.synchronization_health_desc <> 'HEALTHY'
UNION ALL
SELECT 'REPLICA', ag.name, ar.replica_server_name, NULL,
       'Replica ' + ISNULL(ars.connected_state_desc, 'UNKNOWN') + ' / ' + ISNULL(ars.synchronization_health_desc, 'UNKNOWN')
       + ISNULL(' / last error: ' + ars.last_connect_error_description, '')
FROM sys.availability_replicas AS ar
JOIN sys.availability_groups AS ag ON ag.group_id = ar.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states AS ars ON ars.replica_id = ar.replica_id
WHERE ars.connected_state_desc <> 'CONNECTED' OR ars.synchronization_health_desc <> 'HEALTHY'
UNION ALL
SELECT 'DATABASE', ag.name, ar.replica_server_name, DB_NAME(drs.database_id),
       CASE WHEN drs.is_suspended = 1 THEN 'SUSPENDED (' + drs.suspend_reason_desc + ')'
            WHEN drs.synchronization_health_desc <> 'HEALTHY' THEN 'Health: ' + drs.synchronization_health_desc + ' / ' + drs.synchronization_state_desc
            WHEN drs.log_send_queue_size > @max_send_queue_kb THEN 'Log send queue ' + CAST(drs.log_send_queue_size / 1024 AS varchar(20)) + ' MB'
            WHEN drs.redo_queue_size > @max_redo_queue_kb THEN 'Redo queue ' + CAST(drs.redo_queue_size / 1024 AS varchar(20)) + ' MB'
            ELSE 'Secondary lag ' + CAST(drs.secondary_lag_seconds AS varchar(20)) + ' s' END
FROM sys.dm_hadr_database_replica_states AS drs
JOIN sys.availability_replicas AS ar ON ar.replica_id = drs.replica_id
JOIN sys.availability_groups AS ag ON ag.group_id = drs.group_id
WHERE drs.is_suspended = 1
   OR drs.synchronization_health_desc <> 'HEALTHY'
   OR drs.log_send_queue_size > @max_send_queue_kb
   OR drs.redo_queue_size > @max_redo_queue_kb
   OR drs.secondary_lag_seconds > @max_lag_s;


/*=============================================================================
  25.2 "NOT SYNCHRONIZING" TROUBLESHOOTING CHECKLIST                   [BOX]
  Run on the affected SECONDARY.
=============================================================================*/
-- a) DB state & suspend reason on this replica
SELECT DB_NAME(database_id) AS database_name, synchronization_state_desc, is_suspended,
       suspend_reason_desc, database_state_desc, last_received_time, last_redone_time
FROM sys.dm_hadr_database_replica_states
WHERE is_local = 1;

-- b) Endpoint started? (STOPPED endpoint = no data movement)
SELECT name, state_desc FROM sys.database_mirroring_endpoints;

-- c) Recent connection errors to partners
SELECT ar.replica_server_name, ars.connected_state_desc,
       ars.last_connect_error_number, ars.last_connect_error_description, ars.last_connect_error_timestamp
FROM sys.dm_hadr_availability_replica_states AS ars
JOIN sys.availability_replicas AS ar ON ar.replica_id = ars.replica_id;

-- d) Error log messages about HADR / endpoints / transport
EXEC sys.xp_readerrorlog 0, 1, N'Always On';
-- EXEC sys.xp_readerrorlog 0, 1, N'connection';      -- 35206 / 35201 timeouts
-- EXEC sys.xp_readerrorlog 0, 1, N'1480';            -- role change

-- e) Is redo blocked by a reader on this readable secondary? (see 25.3)

-- Common fixes:
-- ALTER DATABASE [YourDB] SET HADR RESUME;
-- ALTER ENDPOINT [Hadr_endpoint] STATE = STOPPED;  ALTER ENDPOINT [Hadr_endpoint] STATE = STARTED;
-- Missing TDE cert on secondary -> 22_tde_encryption.sql 22.7 / 22.11
-- Log backup chain broken on primary while secondary was disconnected -> re-seed DB


/*=============================================================================
  25.3 READABLE SECONDARY: REDO BLOCKED BY REPORTING QUERIES           [BOX]
  Redo thread (command 'DB STARTUP' / 'PARALLEL REDO TASK') blocked by a
  long query holding Sch-S -> redo queue grows. Run on the SECONDARY.
=============================================================================*/
SELECT r.session_id, r.command, DB_NAME(r.database_id) AS database_name,
       r.wait_type, r.wait_time, r.blocking_session_id,
       bs.login_name AS blocker_login, bs.program_name AS blocker_program,
       bib.event_info AS blocker_sql
FROM sys.dm_exec_requests AS r
LEFT JOIN sys.dm_exec_sessions AS bs ON bs.session_id = r.blocking_session_id
OUTER APPLY sys.dm_exec_input_buffer(r.blocking_session_id, NULL) AS bib
WHERE r.command IN (N'DB STARTUP', N'PARALLEL REDO TASK', N'PARALLEL REDO HELP TASK')
ORDER BY r.wait_time DESC;

-- Redo blocked counter (non-zero and rising = problem)
SELECT RTRIM(instance_name) AS database_name, cntr_value AS redo_blocked
FROM sys.dm_os_performance_counters
WHERE object_name LIKE N'%Database Replica%' AND counter_name = N'Redo blocked/sec' AND cntr_value > 0;


/*=============================================================================
  25.4 READABLE SECONDARY: VERSION STORE / GHOST CLEANUP IMPACT        [BOX]
  Reads on secondaries use snapshot isolation -> long queries there hold
  version store on the secondary and delay ghost cleanup on the PRIMARY.
=============================================================================*/
SELECT TOP (10) ast.session_id, ast.elapsed_time_seconds, s.login_name, s.program_name,
       ib.event_info AS sql_text
FROM sys.dm_tran_active_snapshot_database_transactions AS ast
JOIN sys.dm_exec_sessions AS s ON s.session_id = ast.session_id
OUTER APPLY sys.dm_exec_input_buffer(ast.session_id, NULL) AS ib
ORDER BY ast.elapsed_time_seconds DESC;

SELECT DB_NAME(database_id) AS database_name, reserved_page_count * 8 / 1024 AS version_store_mb
FROM sys.dm_tran_version_store_space_usage
ORDER BY reserved_page_count DESC;


/*=============================================================================
  25.5 COMMIT LATENCY ON THE PRIMARY (sync replicas)                   [BOX]
  Transaction Delay / Mirrored Write Transactions = avg ms each commit waited
  for the synchronous secondary. Sample twice and diff.
=============================================================================*/
SELECT RTRIM(instance_name) AS database_name,
       MAX(CASE WHEN counter_name = N'Transaction Delay' THEN cntr_value END)                AS transaction_delay_ms_total,
       MAX(CASE WHEN counter_name = N'Mirrored Write Transactions/sec' THEN cntr_value END)  AS mirrored_write_tx_total
FROM sys.dm_os_performance_counters
WHERE object_name LIKE N'%Database Replica%'
  AND counter_name IN (N'Transaction Delay', N'Mirrored Write Transactions/sec')
GROUP BY instance_name;


/*=============================================================================
  25.6 DISTRIBUTED AVAILABILITY GROUPS                                 [BOX]
=============================================================================*/
SELECT ag.name AS distributed_ag, ar.replica_server_name AS member_ag,
       ar.endpoint_url AS listener_url, ar.availability_mode_desc, ar.failover_mode_desc,
       ar.seeding_mode_desc, ars.role_desc, ars.connected_state_desc, ars.synchronization_health_desc
FROM sys.availability_groups AS ag
JOIN sys.availability_replicas AS ar ON ar.group_id = ag.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states AS ars ON ars.replica_id = ar.replica_id
WHERE ag.is_distributed = 1;

-- DAG database lag (run on global primary)
SELECT ag.name AS distributed_ag, DB_NAME(drs.database_id) AS database_name,
       drs.synchronization_state_desc, drs.log_send_queue_size, drs.redo_queue_size,
       drs.last_hardened_lsn, drs.last_commit_time
FROM sys.dm_hadr_database_replica_states AS drs
JOIN sys.availability_groups AS ag ON ag.group_id = drs.group_id
WHERE ag.is_distributed = 1;


/*=============================================================================
  25.7 CONTAINED AVAILABILITY GROUPS (2022+)                           [BOX]
  Logins, jobs, linked servers live in the AG's own master/msdb.
=============================================================================*/
SELECT name, is_contained, cluster_type_desc FROM sys.availability_groups WHERE is_contained = 1;
-- Connect through the LISTENER to see/manage the contained master & msdb.


/*=============================================================================
  25.8 LOGIN DRIFT BETWEEN REPLICAS                                    [BOX]
  Run on each replica, compare the result sets (name + SID must match for
  SQL logins, else users become orphaned after failover).
=============================================================================*/
SELECT @@SERVERNAME AS replica, name, type_desc, sid, is_disabled, default_database_name,
       CONVERT(varchar(100), LOGINPROPERTY(name, 'PasswordHash'), 1) AS password_hash
FROM sys.server_principals
WHERE type IN ('S', 'U', 'G') AND name NOT LIKE N'##%' AND name NOT LIKE N'NT %'
ORDER BY name;
-- Easiest sync: dbatools  Copy-DbaLogin / Sync-DbaAvailabilityGroup


/*=============================================================================
  25.9 JOB DRIFT BETWEEN REPLICAS + "AM I PRIMARY" JOB GUARD           [BOX]
=============================================================================*/
SELECT @@SERVERNAME AS replica, j.name, j.enabled, j.date_modified
FROM msdb.dbo.sysjobs AS j
ORDER BY j.name;

/*  Put this as STEP 1 of every job that must only run on the primary:
IF sys.fn_hadr_is_primary_replica(N'YourDB') <> 1
BEGIN
    PRINT 'Not primary - exiting.';
    RETURN;          -- or RAISERROR + "quit reporting success" step logic
END
*/


/*=============================================================================
  25.10 BACKUP PREFERENCE CHECK PER DATABASE (run on each replica)     [BOX]
=============================================================================*/
SELECT ag.name AS ag_name, ag.automated_backup_preference_desc, ar.replica_server_name, ar.backup_priority,
       adc.database_name,
       sys.fn_hadr_backup_is_preferred_replica(adc.database_name) AS backup_here
FROM sys.availability_groups AS ag
JOIN sys.availability_replicas AS ar ON ar.group_id = ag.group_id AND ar.replica_server_name = @@SERVERNAME
JOIN sys.availability_databases_cluster AS adc ON adc.group_id = ag.group_id;


/*=============================================================================
  25.11 TEMPLATES - BUILD AN AG (T-SQL)                                [BOX]
=============================================================================*/
/*
-- On EVERY replica:
CREATE ENDPOINT [Hadr_endpoint] STATE = STARTED AS TCP (LISTENER_PORT = 5022)
  FOR DATABASE_MIRRORING (ROLE = ALL, AUTHENTICATION = WINDOWS NEGOTIATE, ENCRYPTION = REQUIRED ALGORITHM AES);
GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [DOMAIN\sqlsvc];

-- On PRIMARY:
CREATE AVAILABILITY GROUP [AG1]
WITH (AUTOMATED_BACKUP_PREFERENCE = SECONDARY, DB_FAILOVER = ON, DTC_SUPPORT = NONE)
FOR DATABASE [YourDB]
REPLICA ON
  N'SQLVM1' WITH (ENDPOINT_URL = N'TCP://SQLVM1.domain.local:5022', AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
                  FAILOVER_MODE = AUTOMATIC, SEEDING_MODE = AUTOMATIC, BACKUP_PRIORITY = 50,
                  SECONDARY_ROLE (ALLOW_CONNECTIONS = READ_ONLY, READ_ONLY_ROUTING_URL = N'TCP://SQLVM1.domain.local:1433')),
  N'SQLVM2' WITH (ENDPOINT_URL = N'TCP://SQLVM2.domain.local:5022', AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
                  FAILOVER_MODE = AUTOMATIC, SEEDING_MODE = AUTOMATIC, BACKUP_PRIORITY = 50,
                  SECONDARY_ROLE (ALLOW_CONNECTIONS = READ_ONLY, READ_ONLY_ROUTING_URL = N'TCP://SQLVM2.domain.local:1433'));

-- On each SECONDARY:
ALTER AVAILABILITY GROUP [AG1] JOIN;
ALTER AVAILABILITY GROUP [AG1] GRANT CREATE ANY DATABASE;      -- for automatic seeding

-- Listener (Azure VM: also needs ILB + probe port, or use a DNN listener instead):
ALTER AVAILABILITY GROUP [AG1] ADD LISTENER N'AG1-LSN' (WITH IP ((N'10.0.0.50', N'255.255.255.0')), PORT = 1433);

-- Read-only routing:
ALTER AVAILABILITY GROUP [AG1] MODIFY REPLICA ON N'SQLVM1' WITH (PRIMARY_ROLE (READ_ONLY_ROUTING_LIST = (N'SQLVM2', N'SQLVM1')));
ALTER AVAILABILITY GROUP [AG1] MODIFY REPLICA ON N'SQLVM2' WITH (PRIMARY_ROLE (READ_ONLY_ROUTING_LIST = (N'SQLVM1', N'SQLVM2')));
*/


/*=============================================================================
  25.12 TEMPLATES - ADD / REMOVE DATABASE, ADD REPLICA                 [BOX]
=============================================================================*/
/*
-- Add DB with automatic seeding (DB must be FULL recovery + have a full backup):
ALTER AVAILABILITY GROUP [AG1] ADD DATABASE [NewDB];

-- Add DB with manual backup/restore (large DBs / slow links):
--   primary:   BACKUP DATABASE [NewDB] ...;  BACKUP LOG [NewDB] ...;
--   secondary: RESTORE DATABASE [NewDB] ... WITH NORECOVERY; RESTORE LOG [NewDB] ... WITH NORECOVERY;
--   primary:   ALTER AVAILABILITY GROUP [AG1] ADD DATABASE [NewDB];
--   secondary: ALTER DATABASE [NewDB] SET HADR AVAILABILITY GROUP = [AG1];

-- Remove a DB from the AG (run on primary; secondary copy goes to RESTORING):
ALTER AVAILABILITY GROUP [AG1] REMOVE DATABASE [OldDB];

-- Add a new replica:
ALTER AVAILABILITY GROUP [AG1] ADD REPLICA ON N'SQLVM3'
  WITH (ENDPOINT_URL = N'TCP://SQLVM3.domain.local:5022', AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL, SEEDING_MODE = AUTOMATIC);
-- then on SQLVM3: ALTER AVAILABILITY GROUP [AG1] JOIN; ... GRANT CREATE ANY DATABASE;
*/


/*=============================================================================
  25.13 AZURE VM AG NOTES                                              [BOX]
=============================================================================*/
/*
 - Listener: classic = Azure Internal Load Balancer with floating IP + probe port
   configured on the cluster IP resource; modern = Distributed Network Name (DNN)
   listener (no load balancer; clients should use MultiSubnetFailover=True).
   Multi-subnet AG deployments avoid the load balancer entirely.
 - Use relaxed cluster monitoring (SameSubnet/CrossSubnet delay & threshold),
   larger lease timeout and HEALTH_CHECK_TIMEOUT as Microsoft documents for
   Azure VMs - transient Azure host maintenance otherwise causes failovers.
   PowerShell:  (Get-Cluster).SameSubnetThreshold ; Get-ClusterResource "AG1" | Get-ClusterParameter
 - Put the quorum witness in a Cloud Witness (Azure storage) or a disk/file share witness.
 - Use Premium/Ultra SSD v2 for log, enable read caching on data disks only.
 - Endpoint port (5022) and listener/probe ports must be open in NSGs and Windows Firewall.
*/
