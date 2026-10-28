/*******************************************************************************
 File    : 11_alwayson_ag.sql
 Purpose : Always On Availability Group health, lag, RPO/RTO, seeding,
           listeners, endpoints, cluster, failover readiness.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] Managed Instance (partial)
 Note    : Run on the PRIMARY to see every replica. On a secondary you only
           see local state. Azure VM AG: listener uses an Azure Load Balancer
           or a Distributed Network Name (DNN) - see 11.8.
 See also: 25_alwayson_advanced.sql (alert query, troubleshooting, templates)
*******************************************************************************/

/*=============================================================================
  11.1 AG DASHBOARD - ONE ROW PER AG                                  [BOX]
=============================================================================*/
SELECT ag.name AS ag_name, ags.primary_replica, ags.primary_recovery_health_desc,
       ags.synchronization_health_desc,
       ag.cluster_type_desc,                   -- WSFC / NONE / EXTERNAL
       ag.automated_backup_preference_desc,
       ag.failure_condition_level, ag.health_check_timeout,
       ag.db_failover, ag.dtc_support, ag.is_distributed,
       ag.required_synchronized_secondaries_to_commit   -- 2017+ (remove this line on 2016)
FROM sys.availability_groups AS ag
JOIN sys.dm_hadr_availability_group_states AS ags ON ags.group_id = ag.group_id;


/*=============================================================================
  11.2 REPLICA STATE & CONFIGURATION                                  [BOX]
=============================================================================*/
SELECT ag.name AS ag_name, ar.replica_server_name,
       ars.role_desc, ars.operational_state_desc, ars.connected_state_desc,
       ars.synchronization_health_desc, ars.recovery_health_desc,
       ar.availability_mode_desc, ar.failover_mode_desc, ar.seeding_mode_desc,
       ar.primary_role_allow_connections_desc, ar.secondary_role_allow_connections_desc,
       ar.backup_priority, ar.session_timeout, ar.endpoint_url,
       ar.read_only_routing_url,
       ars.last_connect_error_number, ars.last_connect_error_description, ars.last_connect_error_timestamp
FROM sys.availability_groups AS ag
JOIN sys.availability_replicas AS ar ON ar.group_id = ag.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states AS ars ON ars.replica_id = ar.replica_id
ORDER BY ag.name, ars.role_desc, ar.replica_server_name;


/*=============================================================================
  11.3 DATABASE SYNC STATE, LAG, RPO / RTO ESTIMATES          [BOX][MI]
  log_send_queue -> data not yet sent to secondary (RPO risk for async)
  redo_queue     -> data received but not yet applied (RTO / stale reads)
  est_rto_s      = redo_queue_kb / redo_rate (time to come online after failover)
=============================================================================*/
SELECT
    ag.name AS ag_name, ar.replica_server_name,
    DB_NAME(drs.database_id) AS database_name,
    drs.is_local, drs.is_primary_replica,
    drs.synchronization_state_desc, drs.synchronization_health_desc,
    drs.is_suspended, drs.suspend_reason_desc,
    drs.database_state_desc,
    drs.log_send_queue_size                               AS log_send_queue_kb,
    drs.log_send_rate                                     AS log_send_rate_kb_s,
    drs.redo_queue_size                                   AS redo_queue_kb,
    drs.redo_rate                                         AS redo_rate_kb_s,
    CAST(drs.redo_queue_size * 1.0 / NULLIF(drs.redo_rate, 0) AS decimal(18,1))         AS est_rto_s,
    CAST(drs.log_send_queue_size * 1.0 / NULLIF(drs.log_send_rate, 0) AS decimal(18,1)) AS est_send_catchup_s,
    drs.secondary_lag_seconds,
    drs.last_sent_time, drs.last_received_time, drs.last_hardened_time,
    drs.last_redone_time, drs.last_commit_time
FROM sys.dm_hadr_database_replica_states AS drs
JOIN sys.availability_replicas  AS ar ON ar.replica_id = drs.replica_id
JOIN sys.availability_groups    AS ag ON ag.group_id = drs.group_id
ORDER BY ag.name, database_name, drs.is_primary_replica DESC, ar.replica_server_name;


/*=============================================================================
  11.4 DATA LOSS WINDOW: primary vs secondary last_commit_time        [BOX]
  (run on primary) - seconds of committed work the secondary doesn't have.
=============================================================================*/
SELECT ag.name AS ag_name, DB_NAME(s.database_id) AS database_name,
       ar.replica_server_name AS secondary_replica,
       p.last_commit_time AS primary_last_commit,
       s.last_commit_time AS secondary_last_commit,
       DATEDIFF(SECOND, s.last_commit_time, p.last_commit_time) AS potential_data_loss_s
FROM sys.dm_hadr_database_replica_states AS p
JOIN sys.dm_hadr_database_replica_states AS s
     ON s.group_database_id = p.group_database_id AND s.is_primary_replica = 0
JOIN sys.availability_replicas AS ar ON ar.replica_id = s.replica_id
JOIN sys.availability_groups   AS ag ON ag.group_id = s.group_id
WHERE p.is_primary_replica = 1
ORDER BY potential_data_loss_s DESC;


/*=============================================================================
  11.5 FAILOVER READINESS (is_failover_ready must be 1 on sync targets)
                                                                      [BOX]
=============================================================================*/
SELECT ag.name AS ag_name, ar.replica_server_name, dcs.database_name,
       dcs.is_failover_ready, dcs.is_pending_secondary_suspend, dcs.is_database_joined,
       dcs.recovery_lsn, dcs.truncation_lsn
FROM sys.dm_hadr_database_replica_cluster_states AS dcs
JOIN sys.availability_replicas AS ar ON ar.replica_id = dcs.replica_id
JOIN sys.availability_groups   AS ag ON ag.group_id = ar.group_id
ORDER BY ag.name, dcs.database_name, ar.replica_server_name;


/*=============================================================================
  11.6 HELPER FUNCTIONS (per database)                                [BOX]
=============================================================================*/
SELECT d.name,
       sys.fn_hadr_is_primary_replica(d.name)          AS is_primary_here,
       sys.fn_hadr_backup_is_preferred_replica(d.name) AS is_preferred_backup_replica,
       d.replica_id, d.group_database_id
FROM sys.databases AS d
WHERE d.replica_id IS NOT NULL;


/*=============================================================================
  11.7 DATABASES NOT IN ANY AG (on an AG-enabled server)              [BOX]
=============================================================================*/
SELECT name, recovery_model_desc, state_desc
FROM sys.databases
WHERE database_id > 4 AND replica_id IS NULL
ORDER BY name;


/*=============================================================================
  11.8 LISTENERS (Azure VM: check ILB probe port / DNN)               [BOX]
=============================================================================*/
SELECT ag.name AS ag_name, agl.dns_name, agl.port, agl.is_conformant,
       agl.ip_configuration_string_from_cluster,
       lip.ip_address, lip.ip_subnet_mask, lip.state_desc, lip.network_subnet_ip
FROM sys.availability_group_listeners AS agl
JOIN sys.availability_groups AS ag ON ag.group_id = agl.group_id
LEFT JOIN sys.availability_group_listener_ip_addresses AS lip ON lip.listener_id = agl.listener_id;
-- DNN listeners are not listed here - check FailoverCluster: Get-ClusterResource | ? ResourceType -eq 'Distributed Network Name'


/*=============================================================================
  11.9 READ-ONLY ROUTING                                              [BOX]
=============================================================================*/
SELECT ag.name AS ag_name, src.replica_server_name AS when_primary_is,
       rl.routing_priority, dst.replica_server_name AS route_reads_to, dst.read_only_routing_url
FROM sys.availability_read_only_routing_lists AS rl
JOIN sys.availability_replicas AS src ON src.replica_id = rl.replica_id
JOIN sys.availability_replicas AS dst ON dst.replica_id = rl.read_only_replica_id
JOIN sys.availability_groups   AS ag  ON ag.group_id = src.group_id
ORDER BY ag.name, src.replica_server_name, rl.routing_priority;


/*=============================================================================
  11.10 HADR ENDPOINT (state, port, encryption, connect permission)   [BOX]
=============================================================================*/
SELECT e.name, e.state_desc, e.role_desc, e.connection_auth_desc,
       e.encryption_algorithm_desc, t.port, SUSER_NAME(e.principal_id) AS endpoint_owner
FROM sys.database_mirroring_endpoints AS e
JOIN sys.tcp_endpoints AS t ON t.endpoint_id = e.endpoint_id;

SELECT ep.name AS endpoint_name, SUSER_NAME(sp.grantee_principal_id) AS grantee,
       sp.permission_name, sp.state_desc
FROM sys.server_permissions AS sp
JOIN sys.endpoints AS ep ON ep.endpoint_id = sp.major_id
WHERE sp.class_desc = 'ENDPOINT';


/*=============================================================================
  11.11 AUTOMATIC SEEDING PROGRESS                                    [BOX]
=============================================================================*/
SELECT ag.name AS ag_name, adc.database_name,
       s.start_time, s.completion_time, s.current_state, s.performed_seeding,
       s.failure_state_desc, s.error_code, s.number_of_attempts
FROM sys.dm_hadr_automatic_seeding AS s
JOIN sys.availability_groups AS ag ON ag.group_id = s.ag_id
LEFT JOIN sys.availability_databases_cluster AS adc ON adc.group_database_id = s.ag_db_id
ORDER BY s.start_time DESC;

SELECT local_database_name, remote_machine_name, role_desc, internal_state_desc,
       transfer_rate_bytes_per_second / 1048576.0 AS transfer_mb_s,
       transferred_size_bytes / 1048576 AS transferred_mb,
       database_size_bytes / 1048576    AS database_mb,
       CAST(100.0 * transferred_size_bytes / NULLIF(database_size_bytes, 0) AS decimal(5,2)) AS pct_done,
       start_time_utc, estimate_time_complete_utc, failure_message
FROM sys.dm_hadr_physical_seeding_stats;


/*=============================================================================
  11.12 WSFC CLUSTER, NODES, NETWORKS, QUORUM                         [BOX]
=============================================================================*/
SELECT cluster_name, quorum_type_desc, quorum_state_desc FROM sys.dm_hadr_cluster;
SELECT member_name, member_type_desc, member_state_desc, number_of_quorum_votes FROM sys.dm_hadr_cluster_members;
SELECT member_name, network_subnet_ip, network_subnet_prefix_length, is_public, is_ipv4 FROM sys.dm_hadr_cluster_networks;


/*=============================================================================
  11.13 AG-RELATED WAITS (commit latency on sync replicas)            [BOX][MI]
  HADR_SYNC_COMMIT avg > ~5-10ms = secondary log hardening / network slow.
=============================================================================*/
SELECT wait_type, waiting_tasks_count, wait_time_ms,
       CAST(wait_time_ms * 1.0 / NULLIF(waiting_tasks_count, 0) AS decimal(10,2)) AS avg_wait_ms
FROM sys.dm_os_wait_stats
WHERE wait_type IN (N'HADR_SYNC_COMMIT', N'HADR_GROUP_COMMIT', N'HADR_LOGCAPTURE_SYNC',
                    N'HADR_DATABASE_FLOW_CONTROL', N'HADR_TRANSPORT_FLOW_CONTROL',
                    N'HADR_SEND_QUEUE', N'PARALLEL_REDO_FLOW_CONTROL', N'WRITELOG')
ORDER BY wait_time_ms DESC;

-- Perf counters on the secondary: redo / log flow
SELECT RTRIM(object_name) AS object_name, RTRIM(counter_name) AS counter_name,
       RTRIM(instance_name) AS database_name, cntr_value
FROM sys.dm_os_performance_counters
WHERE object_name LIKE N'%Database Replica%'
  AND counter_name IN (N'Redo blocked/sec', N'Redone Bytes/sec', N'Log Send Queue',
                       N'Recovery Queue', N'Transaction Delay', N'Mirrored Write Transactions/sec')
ORDER BY database_name, counter_name;


/*=============================================================================
  11.14 FAILOVER / ROLE CHANGE HISTORY (AlwaysOn_health XE)           [BOX]
=============================================================================*/
DECLARE @logdir nvarchar(260) = (
    SELECT LEFT(CAST(SERVERPROPERTY('ErrorLogFileName') AS nvarchar(260)),
                LEN(CAST(SERVERPROPERTY('ErrorLogFileName') AS nvarchar(260)))
                - CHARINDEX(N'\', REVERSE(CAST(SERVERPROPERTY('ErrorLogFileName') AS nvarchar(260)))) + 1));

SELECT
    x.ev.value('(event/@timestamp)[1]', 'datetime2')                                         AS event_time_utc,
    x.ev.value('(event/@name)[1]', 'nvarchar(100)')                                          AS event_name,
    x.ev.value('(event/data[@name="availability_group_name"]/value)[1]', 'nvarchar(128)')    AS ag_name,
    x.ev.value('(event/data[@name="availability_replica_name"]/value)[1]', 'nvarchar(128)')  AS replica,
    x.ev.value('(event/data[@name="previous_state"]/text)[1]', 'nvarchar(60)')               AS previous_state,
    x.ev.value('(event/data[@name="current_state"]/text)[1]', 'nvarchar(60)')                AS current_state,
    x.ev.value('(event/data[@name="error_number"]/value)[1]', 'int')                         AS error_number,
    x.ev.value('(event/data[@name="message"]/value)[1]', 'nvarchar(max)')                    AS message
FROM sys.fn_xe_file_target_read_file(@logdir + N'AlwaysOn_health*.xel', NULL, NULL, NULL) AS f
CROSS APPLY (SELECT CAST(f.event_data AS xml)) AS x(ev)
WHERE f.object_name IN (N'availability_replica_state_change', N'error_reported',
                        N'availability_group_lease_expired', N'availability_replica_automatic_failover_validation')
ORDER BY event_time_utc DESC;


/*=============================================================================
  11.15 COMMON AG ACTIONS (templates - run deliberately)              [BOX]
=============================================================================*/
/*
-- Planned manual failover (run on the TARGET synchronous secondary):
ALTER AVAILABILITY GROUP [AG1] FAILOVER;

-- Forced failover with possible data loss (DR only, run on target):
ALTER AVAILABILITY GROUP [AG1] FORCE_FAILOVER_ALLOW_DATA_LOSS;

-- Suspend / resume data movement for one database:
ALTER DATABASE [YourDB] SET HADR SUSPEND;
ALTER DATABASE [YourDB] SET HADR RESUME;

-- Switch a replica between sync / async:
ALTER AVAILABILITY GROUP [AG1] MODIFY REPLICA ON N'SQLVM2' WITH (AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT);
ALTER AVAILABILITY GROUP [AG1] MODIFY REPLICA ON N'SQLVM2' WITH (FAILOVER_MODE = MANUAL);

-- Grant automatic seeding on the secondary:
ALTER AVAILABILITY GROUP [AG1] GRANT CREATE ANY DATABASE;

-- Azure VM tip: Microsoft recommends relaxed cluster heartbeat / lease / health-check
-- settings for Azure VMs (SameSubnetThreshold, lease timeout, HEALTH_CHECK_TIMEOUT).
-- Check the current "HADR settings for SQL Server on Azure VMs" doc before changing:
ALTER AVAILABILITY GROUP [AG1] SET (HEALTH_CHECK_TIMEOUT = 60000);
ALTER AVAILABILITY GROUP [AG1] SET (FAILURE_CONDITION_LEVEL = 3);
*/
