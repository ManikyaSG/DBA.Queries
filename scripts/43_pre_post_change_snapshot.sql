/*******************************************************************************
 File    : 43_pre_post_change_snapshot.sql
 Purpose : Full health-check SNAPSHOT before an in-place upgrade, CU / OS
           patching, failover test or any planned change - and an automatic
           PRE vs POST comparison afterwards.
           Captures: instance & build, services, configuration, trace flags,
           databases (state, recovery model, compat, owner, options), last
           full / diff / log backup + paths, data & log files (paths, sizes,
           growth), disks, Always On (AGs, replicas & roles, nodes, listeners,
           DB sync state), cluster nodes & quorum, jobs, logins / sysadmins,
           linked servers, endpoints, certificates, XE sessions, triggers.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] (services/disks skipped)
 Usage   : 43.1  quick report, no setup (save the grids to Excel)
           43.2  one-time setup: DBAdmin + snapshot procedure
           43.3  BEFORE the change:  EXEC DBAdmin.dbo.usp_DBA_ChangeSnapshot @Label = 'PRE',  @Note = 'CHG12345 CU16';
           43.3  AFTER the change:   EXEC DBAdmin.dbo.usp_DBA_ChangeSnapshot @Label = 'POST', @Note = 'CHG12345 CU16';
           43.4  compare PRE vs POST (unexpected differences first)
           43.5  post-change go / no-go verdict
           Always On: run on EVERY replica (each replica keeps its own snapshots).
*******************************************************************************/

/*=============================================================================
  43.1 QUICK SNAPSHOT REPORT (no setup)                               [BOX][MI]
  Ten result sets. In SSMS: Results to Grid -> right-click -> Save Results As
  (CSV), or Ctrl+Shift+F (results to file) before running.
=============================================================================*/
-- (a) Instance
SELECT @@SERVERNAME AS server_name,
       SERVERPROPERTY('MachineName')            AS machine_name,
       SERVERPROPERTY('InstanceName')           AS instance_name,
       SERVERPROPERTY('Edition')                AS edition,
       SERVERPROPERTY('ProductVersion')         AS build,
       SERVERPROPERTY('ProductLevel')           AS sp_level,
       SERVERPROPERTY('ProductUpdateLevel')     AS cu,
       SERVERPROPERTY('ProductUpdateReference') AS kb,
       SERVERPROPERTY('Collation')              AS collation,
       SERVERPROPERTY('IsClustered')            AS is_fci,
       SERVERPROPERTY('IsHadrEnabled')          AS is_hadr_enabled,
       i.sqlserver_start_time, i.cpu_count, i.physical_memory_kb / 1024 AS physical_memory_mb,
       (SELECT value_in_use FROM sys.configurations WHERE name = N'max server memory (MB)')      AS max_server_memory_mb,
       (SELECT value_in_use FROM sys.configurations WHERE name = N'max degree of parallelism')   AS maxdop,
       (SELECT value_in_use FROM sys.configurations WHERE name = N'cost threshold for parallelism') AS ctfp,
       GETDATE() AS snapshot_time
FROM sys.dm_os_sys_info AS i;

-- (b) Services (not on MI)
IF CAST(SERVERPROPERTY('EngineEdition') AS int) <> 8
    EXEC (N'SELECT servicename, status_desc, startup_type_desc, service_account, last_startup_time,
                   is_clustered, cluster_nodename, instant_file_initialization_enabled
            FROM sys.dm_server_services;');

-- (c) Databases + recovery model + last backups + backup paths + HA role
SELECT d.name, d.state_desc, d.user_access_desc, d.recovery_model_desc, d.compatibility_level,
       SUSER_SNAME(d.owner_sid) AS owner_name, d.is_read_only, d.log_reuse_wait_desc,
       CAST(sz.size_mb AS decimal(18,0)) AS size_mb,
       ag.name AS availability_group,
       CASE WHEN drs.is_primary_replica = 1 THEN 'PRIMARY' WHEN drs.database_id IS NOT NULL THEN 'SECONDARY' ELSE '' END AS ag_role_here,
       drs.synchronization_state_desc AS ag_sync_state,
       bf.backup_finish_date AS last_full,  bf.physical_device_name AS last_full_path,
       bd.backup_finish_date AS last_diff,  bd.physical_device_name AS last_diff_path,
       bl.backup_finish_date AS last_log,   bl.physical_device_name AS last_log_path
FROM sys.databases AS d
OUTER APPLY (SELECT SUM(CAST(size AS bigint)) * 8 / 1024.0 AS size_mb FROM sys.master_files mf WHERE mf.database_id = d.database_id) AS sz
LEFT JOIN sys.availability_databases_cluster AS adc ON adc.database_name = d.name
LEFT JOIN sys.availability_groups AS ag ON ag.group_id = adc.group_id
LEFT JOIN sys.dm_hadr_database_replica_states AS drs ON drs.database_id = d.database_id AND drs.is_local = 1
OUTER APPLY (SELECT TOP (1) b.backup_finish_date, m.physical_device_name FROM msdb.dbo.backupset b
             JOIN msdb.dbo.backupmediafamily m ON m.media_set_id = b.media_set_id
             WHERE b.database_name = d.name AND b.type = 'D' ORDER BY b.backup_finish_date DESC) AS bf
OUTER APPLY (SELECT TOP (1) b.backup_finish_date, m.physical_device_name FROM msdb.dbo.backupset b
             JOIN msdb.dbo.backupmediafamily m ON m.media_set_id = b.media_set_id
             WHERE b.database_name = d.name AND b.type = 'I' ORDER BY b.backup_finish_date DESC) AS bd
OUTER APPLY (SELECT TOP (1) b.backup_finish_date, m.physical_device_name FROM msdb.dbo.backupset b
             JOIN msdb.dbo.backupmediafamily m ON m.media_set_id = b.media_set_id
             WHERE b.database_name = d.name AND b.type = 'L' ORDER BY b.backup_finish_date DESC) AS bl
ORDER BY d.database_id;

-- (d) Always On: AGs, replicas (nodes), roles, modes, health, endpoints, listeners
SELECT ag.name AS availability_group, ags.primary_replica, ar.replica_server_name AS replica_node,
       ars.role_desc, ar.availability_mode_desc, ar.failover_mode_desc, ar.seeding_mode_desc,
       ar.secondary_role_allow_connections_desc, ars.connected_state_desc, ars.synchronization_health_desc,
       ar.endpoint_url, ar.backup_priority, ag.automated_backup_preference_desc,
       STUFF((SELECT N', ' + l.dns_name + N':' + CAST(l.port AS nvarchar(10))
              FROM sys.availability_group_listeners l WHERE l.group_id = ag.group_id
              FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'') AS listeners
FROM sys.availability_groups AS ag
JOIN sys.dm_hadr_availability_group_states AS ags ON ags.group_id = ag.group_id
JOIN sys.availability_replicas AS ar ON ar.group_id = ag.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states AS ars ON ars.replica_id = ar.replica_id
ORDER BY ag.name, ars.role_desc, ar.replica_server_name;

-- (e) Always On: database state per replica (on the primary you see all replicas)
SELECT ag.name AS availability_group, DB_NAME(drs.database_id) AS database_name, ar.replica_server_name,
       drs.is_primary_replica, drs.synchronization_state_desc, drs.synchronization_health_desc,
       drs.is_suspended, drs.suspend_reason_desc, drs.log_send_queue_size AS send_queue_kb, drs.redo_queue_size AS redo_queue_kb,
       drs.last_commit_time
FROM sys.dm_hadr_database_replica_states AS drs
JOIN sys.availability_replicas AS ar ON ar.replica_id = drs.replica_id
JOIN sys.availability_groups AS ag ON ag.group_id = drs.group_id
ORDER BY ag.name, database_name, drs.is_primary_replica DESC;

-- (f) Cluster nodes & quorum (AG / FCI)
SELECT c.cluster_name, c.quorum_type_desc, c.quorum_state_desc,
       m.member_name, m.member_type_desc, m.member_state_desc, m.number_of_quorum_votes
FROM sys.dm_hadr_cluster AS c
CROSS JOIN sys.dm_hadr_cluster_members AS m;
SELECT NodeName, status_description, is_current_owner FROM sys.dm_os_cluster_nodes;   -- FCI nodes

-- (g) Disk space (not on MI)
IF CAST(SERVERPROPERTY('EngineEdition') AS int) <> 8
    EXEC (N'SELECT DISTINCT vs.volume_mount_point, vs.logical_volume_name,
                   vs.total_bytes / 1073741824 AS total_gb, vs.available_bytes / 1073741824 AS free_gb,
                   CAST(100.0 * vs.available_bytes / vs.total_bytes AS decimal(5,1)) AS free_pct
            FROM sys.master_files mf CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs
            ORDER BY vs.volume_mount_point;');

-- (h) Data & log files: paths, sizes, growth
SELECT DB_NAME(database_id) AS database_name, file_id, name AS logical_name, type_desc, physical_name, state_desc,
       CAST(size AS bigint) * 8 / 1024 AS size_mb,
       CASE WHEN is_percent_growth = 1 THEN CAST(growth AS varchar(10)) + ' %' ELSE CAST(CAST(growth AS bigint) * 8 / 1024 AS varchar(20)) + ' MB' END AS growth,
       CASE max_size WHEN -1 THEN 'unlimited' WHEN 0 THEN 'no growth' ELSE CAST(CAST(max_size AS bigint) * 8 / 1024 AS varchar(20)) + ' MB' END AS max_size
FROM sys.master_files
ORDER BY database_id, file_id;

-- (i) Agent jobs: enabled + last outcome
SELECT j.name, j.enabled, SUSER_SNAME(j.owner_sid) AS owner_name,
       CASE js.last_run_outcome WHEN 0 THEN 'Failed' WHEN 1 THEN 'Succeeded' WHEN 3 THEN 'Canceled' ELSE 'Unknown' END AS last_outcome,
       CASE WHEN js.last_run_date > 0 THEN msdb.dbo.agent_datetime(js.last_run_date, js.last_run_time) END AS last_run
FROM msdb.dbo.sysjobs AS j
LEFT JOIN msdb.dbo.sysjobservers AS js ON js.job_id = j.job_id
ORDER BY j.name;

-- (j) Trace flags + endpoints + linked servers
DBCC TRACESTATUS(-1) WITH NO_INFOMSGS;
SELECT e.name, e.type_desc, e.state_desc, t.port FROM sys.endpoints e LEFT JOIN sys.tcp_endpoints t ON t.endpoint_id = e.endpoint_id WHERE e.endpoint_id > 5;
SELECT name, product, provider, data_source FROM sys.servers WHERE is_linked = 1;


/*=============================================================================
  43.2 ONE-TIME SETUP: DBAdmin + SNAPSHOT TABLES + PROCEDURE           [BOX][MI]
  Snapshots are stored as category / item / attribute / value rows, so ANY
  two snapshots can be compared generically (43.4). Highlight from here to
  the end of this section and run once (or re-run to update the procedure).
=============================================================================*/
/*
IF DB_ID(N'DBAdmin') IS NULL CREATE DATABASE DBAdmin;
GO
USE DBAdmin;
GO
IF OBJECT_ID(N'dbo.ChangeSnapshot') IS NULL
CREATE TABLE dbo.ChangeSnapshot (
    snapshot_id     int IDENTITY(1,1) PRIMARY KEY,
    label           nvarchar(50)  NOT NULL,                       -- PRE / POST / BASELINE ...
    note            nvarchar(400) NULL,                           -- change ticket, CU, etc.
    server_name     sysname       NOT NULL DEFAULT @@SERVERNAME,
    product_version nvarchar(50)  NULL,
    taken_at        datetime2(0)  NOT NULL DEFAULT SYSDATETIME(),
    taken_by        sysname       NOT NULL DEFAULT ORIGINAL_LOGIN());
GO
IF OBJECT_ID(N'dbo.ChangeSnapshotItem') IS NULL
CREATE TABLE dbo.ChangeSnapshotItem (
    snapshot_id int           NOT NULL,
    category    varchar(30)   NOT NULL,
    item_key    nvarchar(450) NOT NULL,
    attribute   varchar(60)   NOT NULL,
    value       nvarchar(4000) NULL,
    is_volatile bit           NOT NULL DEFAULT 0,      -- 1 = expected to change (sizes, dates, build...)
    INDEX CIX_ChangeSnapshotItem CLUSTERED (snapshot_id, category, item_key, attribute));
GO
CREATE OR ALTER PROCEDURE dbo.usp_DBA_ChangeSnapshot
    @Label nvarchar(50) = N'PRE',
    @Note  nvarchar(400) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @is_mi bit = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 8 THEN 1 ELSE 0 END;

    INSERT dbo.ChangeSnapshot (label, note, product_version)
    VALUES (@Label, @Note, CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(50)));
    DECLARE @id int = SCOPE_IDENTITY();

    -- INSTANCE ----------------------------------------------------------------
    INSERT dbo.ChangeSnapshotItem (snapshot_id, category, item_key, attribute, value, is_volatile)
    SELECT @id, 'INSTANCE', @@SERVERNAME, v.a, v.v, v.vol
    FROM sys.dm_os_sys_info AS i
    CROSS APPLY (VALUES
        ('edition',          CAST(SERVERPROPERTY('Edition') AS nvarchar(4000)), 0),
        ('build',            CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(4000)), 1),
        ('sp_level',         CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(4000)), 1),
        ('cu',               CAST(SERVERPROPERTY('ProductUpdateLevel') AS nvarchar(4000)), 1),
        ('kb',               CAST(SERVERPROPERTY('ProductUpdateReference') AS nvarchar(4000)), 1),
        ('collation',        CAST(SERVERPROPERTY('Collation') AS nvarchar(4000)), 0),
        ('is_fci',           CAST(SERVERPROPERTY('IsClustered') AS nvarchar(4000)), 0),
        ('is_hadr_enabled',  CAST(SERVERPROPERTY('IsHadrEnabled') AS nvarchar(4000)), 0),
        ('machine_name',     CAST(SERVERPROPERTY('MachineName') AS nvarchar(4000)), 0),
        ('cpu_count',        CAST(i.cpu_count AS nvarchar(4000)), 0),
        ('scheduler_count',  CAST(i.scheduler_count AS nvarchar(4000)), 0),
        ('physical_memory_mb', CAST(i.physical_memory_kb / 1024 AS nvarchar(4000)), 0),
        ('memory_model',     CAST(i.sql_memory_model_desc AS nvarchar(4000)), 0),
        ('sqlserver_start_time', CONVERT(nvarchar(4000), i.sqlserver_start_time, 120), 1)
    ) AS v(a, v, vol);

    -- CONFIGURATION (all sp_configure options) --------------------------------
    INSERT dbo.ChangeSnapshotItem (snapshot_id, category, item_key, attribute, value, is_volatile)
    SELECT @id, 'CONFIG', name, 'value_in_use', CAST(value_in_use AS nvarchar(4000)), 0 FROM sys.configurations;

    -- TRACE FLAGS -------------------------------------------------------------
    CREATE TABLE #tf (TraceFlag int, Status int, Global int, Session int);
    INSERT #tf EXEC (N'DBCC TRACESTATUS(-1) WITH NO_INFOMSGS');
    INSERT dbo.ChangeSnapshotItem (snapshot_id, category, item_key, attribute, value, is_volatile)
    SELECT @id, 'TRACEFLAG', CAST(TraceFlag AS nvarchar(10)), 'global', CAST(Global AS nvarchar(10)), 0 FROM #tf WHERE Global = 1;

    -- SERVICES & DISKS (not on MI) ---------------------------------------------
    IF @is_mi = 0
    BEGIN
        CREATE TABLE #svc (servicename nvarchar(256), status_desc nvarchar(60), startup_type_desc nvarchar(60),
                           service_account nvarchar(256), ifi nvarchar(1));
        INSERT #svc EXEC (N'SELECT servicename, status_desc, startup_type_desc, service_account, instant_file_initialization_enabled FROM sys.dm_server_services');
        INSERT dbo.ChangeSnapshotItem (snapshot_id, category, item_key, attribute, value, is_volatile)
        SELECT @id, 'SERVICE', s.servicename, v.a, v.v, 0
        FROM #svc AS s
        CROSS APPLY (VALUES ('status', s.status_desc), ('startup_type', s.startup_type_desc),
                            ('service_account', s.service_account), ('ifi_enabled', s.ifi)) AS v(a, v);

        CREATE TABLE #disk (volume nvarchar(256), total_gb bigint, free_gb bigint);
        INSERT #disk EXEC (N'SELECT DISTINCT vs.volume_mount_point, vs.total_bytes / 1073741824, vs.available_bytes / 1073741824
                             FROM sys.master_files mf CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs');
        INSERT dbo.ChangeSnapshotItem (snapshot_id, category, item_key, attribute, value, is_volatile)
        SELECT @id, 'DISK', d.volume, v.a, v.v, v.vol
        FROM #disk AS d
        CROSS APPLY (VALUES ('total_gb', CAST(d.total_gb AS nvarchar(4000)), 0), ('free_gb', CAST(d.free_gb AS nvarchar(4000)), 1)) AS v(a, v, vol);
    END;

    -- DATABASES -----------------------------------------------------------------
    INSERT dbo.ChangeSnapshotItem (snapshot_id, category, item_key, attribute, value, is_volatile)
    SELECT @id, 'DATABASE', d.name, v.a, v.v, v.vol
    FROM sys.databases AS d
    CROSS APPLY (VALUES
        ('state',               CAST(d.state_desc AS nvarchar(4000)), 0),
        ('user_access',         CAST(d.user_access_desc AS nvarchar(4000)), 0),
        ('is_read_only',        CAST(d.is_read_only AS nvarchar(4000)), 0),
        ('recovery_model',      CAST(d.recovery_model_desc AS nvarchar(4000)), 0),
        ('compatibility_level', CAST(d.compatibility_level AS nvarchar(4000)), 0),
        ('owner',               CAST(SUSER_SNAME(d.owner_sid) AS nvarchar(4000)), 0),
        ('collation',           CAST(d.collation_name AS nvarchar(4000)), 0),
        ('page_verify',         CAST(d.page_verify_option_desc AS nvarchar(4000)), 0),
        ('rcsi',                CAST(d.is_read_committed_snapshot_on AS nvarchar(4000)), 0),
        ('snapshot_isolation',  CAST(d.snapshot_isolation_state_desc AS nvarchar(4000)), 0),
        ('is_encrypted',        CAST(d.is_encrypted AS nvarchar(4000)), 0),
        ('is_broker_enabled',   CAST(d.is_broker_enabled AS nvarchar(4000)), 0),
        ('is_trustworthy_on',   CAST(d.is_trustworthy_on AS nvarchar(4000)), 0),
        ('is_query_store_on',   CAST(d.is_query_store_on AS nvarchar(4000)), 0),
        ('auto_close',          CAST(d.is_auto_close_on AS nvarchar(4000)), 0),
        ('auto_shrink',         CAST(d.is_auto_shrink_on AS nvarchar(4000)), 0),
        ('is_cdc_enabled',      CAST(d.is_cdc_enabled AS nvarchar(4000)), 0),
        ('is_published',        CAST(d.is_published AS nvarchar(4000)), 0),
        ('is_subscribed',       CAST(d.is_subscribed AS nvarchar(4000)), 0),
        ('target_recovery_time',CAST(d.target_recovery_time_in_seconds AS nvarchar(4000)), 0),
        ('delayed_durability',  CAST(d.delayed_durability_desc AS nvarchar(4000)), 0),
        ('log_reuse_wait',      CAST(d.log_reuse_wait_desc AS nvarchar(4000)), 1),
        ('last_good_checkdb',   CONVERT(nvarchar(4000), CAST(DATABASEPROPERTYEX(d.name, 'LastGoodCheckDbTime') AS datetime), 120), 1)
    ) AS v(a, v, vol);

    -- BACKUPS: last full / diff / log + path (dates volatile, paths not) ----------
    INSERT dbo.ChangeSnapshotItem (snapshot_id, category, item_key, attribute, value, is_volatile)
    SELECT @id, 'BACKUP', d.name, v.a, v.v, v.vol
    FROM sys.databases AS d
    OUTER APPLY (SELECT TOP (1) b.backup_finish_date, m.physical_device_name FROM msdb.dbo.backupset b
                 JOIN msdb.dbo.backupmediafamily m ON m.media_set_id = b.media_set_id
                 WHERE b.database_name = d.name AND b.type = 'D' ORDER BY b.backup_finish_date DESC) AS bf
    OUTER APPLY (SELECT TOP (1) b.backup_finish_date FROM msdb.dbo.backupset b
                 WHERE b.database_name = d.name AND b.type = 'I' ORDER BY b.backup_finish_date DESC) AS bd
    OUTER APPLY (SELECT TOP (1) b.backup_finish_date, m.physical_device_name FROM msdb.dbo.backupset b
                 JOIN msdb.dbo.backupmediafamily m ON m.media_set_id = b.media_set_id
                 WHERE b.database_name = d.name AND b.type = 'L' ORDER BY b.backup_finish_date DESC) AS bl
    -- folder part of the path (works for disk paths and URLs; file name stripped)
    OUTER APPLY (SELECT CASE WHEN CHARINDEX(N'\', x.p) > 0 THEN LEFT(x.p, LEN(x.p) - CHARINDEX(N'\', REVERSE(x.p))) ELSE x.p END AS folder
                 FROM (SELECT REPLACE(bf.physical_device_name, N'/', N'\') AS p) AS x) AS fp
    OUTER APPLY (SELECT CASE WHEN CHARINDEX(N'\', x.p) > 0 THEN LEFT(x.p, LEN(x.p) - CHARINDEX(N'\', REVERSE(x.p))) ELSE x.p END AS folder
                 FROM (SELECT REPLACE(bl.physical_device_name, N'/', N'\') AS p) AS x) AS lp
    CROSS APPLY (VALUES
        ('last_full',        CONVERT(nvarchar(4000), bf.backup_finish_date, 120), 1),
        ('last_diff',        CONVERT(nvarchar(4000), bd.backup_finish_date, 120), 1),
        ('last_log',         CONVERT(nvarchar(4000), bl.backup_finish_date, 120), 1),
        ('full_backup_folder', CAST(fp.folder AS nvarchar(4000)), 0),
        ('log_backup_folder',  CAST(lp.folder AS nvarchar(4000)), 0)
    ) AS v(a, v, vol)
    WHERE d.database_id <> 2;

    -- FILES --------------------------------------------------------------------
    INSERT dbo.ChangeSnapshotItem (snapshot_id, category, item_key, attribute, value, is_volatile)
    SELECT @id, 'FILE', DB_NAME(mf.database_id) + N'.' + mf.name, v.a, v.v, v.vol
    FROM sys.master_files AS mf
    CROSS APPLY (VALUES
        ('physical_name', CAST(mf.physical_name AS nvarchar(4000)), 0),
        ('type',          CAST(mf.type_desc AS nvarchar(4000)), 0),
        ('state',         CAST(mf.state_desc AS nvarchar(4000)), 0),
        ('size_mb',       CAST(CAST(mf.size AS bigint) * 8 / 1024 AS nvarchar(4000)), 1),
        ('growth',        CASE WHEN mf.is_percent_growth = 1 THEN CAST(mf.growth AS nvarchar(20)) + N' %'
                               ELSE CAST(CAST(mf.growth AS bigint) * 8 / 1024 AS nvarchar(20)) + N' MB' END, 0),
        ('max_size_mb',   CASE mf.max_size WHEN -1 THEN N'unlimited' ELSE CAST(CAST(mf.max_size AS bigint) * 8 / 1024 AS nvarchar(20)) END, 0)
    ) AS v(a, v, vol);

    -- ALWAYS ON -------------------------------------------------------------------
    INSERT dbo.ChangeSnapshotItem (snapshot_id, category, item_key, attribute, value, is_volatile)
    SELECT @id, 'AG', ag.name, v.a, v.v, 0
    FROM sys.availability_groups AS ag
    JOIN sys.dm_hadr_availability_group_states AS ags ON ags.group_id = ag.group_id
    CROSS APPLY (VALUES
        ('primary_replica',            CAST(ags.primary_replica AS nvarchar(4000))),
        ('synchronization_health',     CAST(ags.synchronization_health_desc AS nvarchar(4000))),
        ('automated_backup_preference',CAST(ag.automated_backup_preference_desc AS nvarchar(4000))),
        ('failure_condition_level',    CAST(ag.failure_condition_level AS nvarchar(4000))),
        ('health_check_timeout',       CAST(ag.health_check_timeout AS nvarchar(4000))),
        ('db_failover',                CAST(ag.db_failover AS nvarchar(4000))),
        ('listeners', STUFF((SELECT N', ' + l.dns_name + N':' + CAST(l.port AS nvarchar(10))
                             FROM sys.availability_group_listeners l WHERE l.group_id = ag.group_id ORDER BY l.dns_name
                             FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''))
    ) AS v(a, v);

    INSERT dbo.ChangeSnapshotItem (snapshot_id, category, item_key, attribute, value, is_volatile)
    SELECT @id, 'AG_REPLICA', ag.name + N' \ ' + ar.replica_server_name, v.a, v.v, 0
    FROM sys.availability_replicas AS ar
    JOIN sys.availability_groups AS ag ON ag.group_id = ar.group_id
    LEFT JOIN sys.dm_hadr_availability_replica_states AS ars ON ars.replica_id = ar.replica_id
    CROSS APPLY (VALUES
        ('role',                  CAST(ars.role_desc AS nvarchar(4000))),
        ('availability_mode',     CAST(ar.availability_mode_desc AS nvarchar(4000))),
        ('failover_mode',         CAST(ar.failover_mode_desc AS nvarchar(4000))),
        ('seeding_mode',          CAST(ar.seeding_mode_desc AS nvarchar(4000))),
        ('secondary_connections', CAST(ar.secondary_role_allow_connections_desc AS nvarchar(4000))),
        ('connected_state',       CAST(ars.connected_state_desc AS nvarchar(4000))),
        ('synchronization_health',CAST(ars.synchronization_health_desc AS nvarchar(4000))),
        ('endpoint_url',          CAST(ar.endpoint_url AS nvarchar(4000))),
        ('backup_priority',       CAST(ar.backup_priority AS nvarchar(4000))),
        ('read_only_routing_url', CAST(ar.read_only_routing_url AS nvarchar(4000)))
    ) AS v(a, v);

    INSERT dbo.ChangeSnapshotItem (snapshot_id, category, item_key, attribute, value, is_volatile)
    SELECT @id, 'AG_DATABASE', ag.name + N' \ ' + ar.replica_server_name + N' \ ' + DB_NAME(drs.database_id), v.a, v.v, 0
    FROM sys.dm_hadr_database_replica_states AS drs
    JOIN sys.availability_replicas AS ar ON ar.replica_id = drs.replica_id
    JOIN sys.availability_groups AS ag ON ag.group_id = drs.group_id
    CROSS APPLY (VALUES
        ('synchronization_state',  CAST(drs.synchronization_state_desc AS nvarchar(4000))),
        ('synchronization_health', CAST(drs.synchronization_health_desc AS nvarchar(4000))),
        ('is_suspended',           CAST(drs.is_suspended AS nvarchar(4000)))
    ) AS v(a, v);

    INSERT dbo.ChangeSnapshotItem (snapshot_id, category, item_key, attribute, value, is_volatile)
    SELECT @id, 'CLUSTER', m.member_name, v.a, v.v, 0
    FROM sys.dm_hadr_cluster_members AS m
    CROSS APPLY (VALUES ('member_type', CAST(m.member_type_desc AS nvarchar(4000))),
                        ('member_state', CAST(m.member_state_desc AS nvarchar(4000))),
                        ('quorum_votes', CAST(m.number_of_quorum_votes AS nvarchar(4000)))) AS v(a, v);
    INSERT dbo.ChangeSnapshotItem (snapshot_id, category, item_key, attribute, value, is_volatile)
    SELECT @id, 'CLUSTER', c.cluster_name, v.a, v.v, 0
    FROM sys.dm_hadr_cluster AS c
    CROSS APPLY (VALUES ('quorum_type', CAST(c.quorum_type_desc AS nvarchar(4000))),
                        ('quorum_state', CAST(c.quorum_state_desc AS nvarchar(4000)))) AS v(a, v);

    -- AGENT JOBS (enabled state matters most after patching) -----------------------
    INSERT dbo.ChangeSnapshotItem (snapshot_id, category, item_key, attribute, value, is_volatile)
    SELECT @id, 'JOB', j.name, v.a, v.v, v.vol
    FROM msdb.dbo.sysjobs AS j
    LEFT JOIN msdb.dbo.sysjobservers AS js ON js.job_id = j.job_id
    CROSS APPLY (VALUES ('enabled', CAST(j.enabled AS nvarchar(4000)), 0),
                        ('owner',   CAST(SUSER_SNAME(j.owner_sid) AS nvarchar(4000)), 0),
                        ('last_outcome', CAST(js.last_run_outcome AS nvarchar(4000)), 1)) AS v(a, v, vol);

    -- SECURITY: logins (enabled/disabled), sysadmin members ---------------------------
    INSERT dbo.ChangeSnapshotItem (snapshot_id, category, item_key, attribute, value, is_volatile)
    SELECT @id, 'LOGIN', name, 'is_disabled', CAST(is_disabled AS nvarchar(10)), 0
    FROM sys.server_principals WHERE type IN ('S', 'U', 'G', 'E', 'X') AND name NOT LIKE N'##%';

    INSERT dbo.ChangeSnapshotItem (snapshot_id, category, item_key, attribute, value, is_volatile)
    SELECT @id, 'SERVER_ROLE', r.name + N' \ ' + m.name, 'member', N'1', 0
    FROM sys.server_role_members rm
    JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id
    JOIN sys.server_principals m ON m.principal_id = rm.member_principal_id;

    -- LINKED SERVERS, ENDPOINTS, CERTIFICATES, SERVER TRIGGERS, XE SESSIONS -----------
    INSERT dbo.ChangeSnapshotItem (snapshot_id, category, item_key, attribute, value, is_volatile)
    SELECT @id, 'LINKED_SERVER', name, 'data_source', CAST(data_source AS nvarchar(4000)), 0 FROM sys.servers WHERE is_linked = 1;

    INSERT dbo.ChangeSnapshotItem (snapshot_id, category, item_key, attribute, value, is_volatile)
    SELECT @id, 'ENDPOINT', e.name, v.a, v.v, 0
    FROM sys.endpoints e LEFT JOIN sys.tcp_endpoints t ON t.endpoint_id = e.endpoint_id
    CROSS APPLY (VALUES ('state', CAST(e.state_desc AS nvarchar(4000))), ('port', CAST(t.port AS nvarchar(4000)))) AS v(a, v)
    WHERE e.endpoint_id > 5 OR e.name LIKE N'TSQL%';

    INSERT dbo.ChangeSnapshotItem (snapshot_id, category, item_key, attribute, value, is_volatile)
    SELECT @id, 'CERTIFICATE', name, v.a, v.v, 0
    FROM master.sys.certificates
    CROSS APPLY (VALUES ('thumbprint', CONVERT(nvarchar(4000), thumbprint, 1)), ('expiry', CONVERT(nvarchar(4000), expiry_date, 120))) AS v(a, v)
    WHERE name NOT LIKE N'##%';

    INSERT dbo.ChangeSnapshotItem (snapshot_id, category, item_key, attribute, value, is_volatile)
    SELECT @id, 'SERVER_TRIGGER', name, 'is_disabled', CAST(is_disabled AS nvarchar(10)), 0 FROM sys.server_triggers;

    INSERT dbo.ChangeSnapshotItem (snapshot_id, category, item_key, attribute, value, is_volatile)
    SELECT @id, 'XE_SESSION', s.name, 'running', CASE WHEN r.name IS NULL THEN N'0' ELSE N'1' END, 0
    FROM sys.server_event_sessions s LEFT JOIN sys.dm_xe_sessions r ON r.name = s.name;

    -- LOG SHIPPING / DATABASE MAIL ----------------------------------------------------
    INSERT dbo.ChangeSnapshotItem (snapshot_id, category, item_key, attribute, value, is_volatile)
    SELECT @id, 'LOG_SHIPPING', primary_database, 'backup_directory', CAST(backup_directory AS nvarchar(4000)), 0
    FROM msdb.dbo.log_shipping_primary_databases;

    INSERT dbo.ChangeSnapshotItem (snapshot_id, category, item_key, attribute, value, is_volatile)
    SELECT @id, 'DBMAIL', name, 'profile', N'1', 0 FROM msdb.dbo.sysmail_profile;

    SELECT @id AS snapshot_id, @Label AS label, @Note AS note, SYSDATETIME() AS taken_at,
           (SELECT COUNT(*) FROM dbo.ChangeSnapshotItem WHERE snapshot_id = @id) AS items_captured;
END;
GO
*/


/*=============================================================================
  43.3 TAKE THE SNAPSHOTS                                             [BOX][MI]
=============================================================================*/
/*
-- BEFORE the change (after the pre-checks in 27.5 / 30.2 pass):
EXEC DBAdmin.dbo.usp_DBA_ChangeSnapshot @Label = N'PRE',  @Note = N'CHG12345 - SQL 2022 CU16';
-- AFTER the change (services up, AG synchronized):
EXEC DBAdmin.dbo.usp_DBA_ChangeSnapshot @Label = N'POST', @Note = N'CHG12345 - SQL 2022 CU16';

-- List snapshots:
SELECT snapshot_id, label, note, server_name, product_version, taken_at, taken_by
FROM DBAdmin.dbo.ChangeSnapshot ORDER BY snapshot_id DESC;
*/


/*=============================================================================
  43.4 COMPARE PRE vs POST - ONLY DIFFERENCES                          [BOX][MI]
  Defaults to the latest PRE and latest POST for this server.
  expected_change = 1: things that normally change (build, CU, start time,
  free space, sizes, backup dates). Review expected_change = 0 rows first.
=============================================================================*/
DECLARE @pre_id int, @post_id int;   -- <== or set explicit ids from 43.3 list
SELECT @pre_id  = MAX(snapshot_id) FROM DBAdmin.dbo.ChangeSnapshot WHERE label = N'PRE'  AND server_name = @@SERVERNAME;
SELECT @post_id = MAX(snapshot_id) FROM DBAdmin.dbo.ChangeSnapshot WHERE label = N'POST' AND server_name = @@SERVERNAME;

SELECT s.snapshot_id, s.label, s.note, s.product_version, s.taken_at
FROM DBAdmin.dbo.ChangeSnapshot s WHERE s.snapshot_id IN (@pre_id, @post_id);

WITH pre  AS (SELECT * FROM DBAdmin.dbo.ChangeSnapshotItem WHERE snapshot_id = @pre_id),
     post AS (SELECT * FROM DBAdmin.dbo.ChangeSnapshotItem WHERE snapshot_id = @post_id)
SELECT COALESCE(pre.category, post.category)   AS category,
       COALESCE(pre.item_key, post.item_key)   AS item,
       COALESCE(pre.attribute, post.attribute) AS attribute,
       pre.value  AS before_value,
       post.value AS after_value,
       CASE WHEN pre.snapshot_id IS NULL  THEN 'NEW AFTER CHANGE'
            WHEN post.snapshot_id IS NULL THEN 'MISSING AFTER CHANGE'
            ELSE 'CHANGED' END                  AS change_type,
       CAST(COALESCE(pre.is_volatile, post.is_volatile) AS int) AS expected_change
FROM pre
FULL JOIN post ON post.category = pre.category AND post.item_key = pre.item_key AND post.attribute = pre.attribute
WHERE ISNULL(pre.value, N'<null>') <> ISNULL(post.value, N'<null>')
   OR pre.snapshot_id IS NULL OR post.snapshot_id IS NULL
ORDER BY expected_change,
         CASE COALESCE(pre.category, post.category)
              WHEN 'DATABASE' THEN 1 WHEN 'AG' THEN 2 WHEN 'AG_REPLICA' THEN 3 WHEN 'AG_DATABASE' THEN 4
              WHEN 'SERVICE' THEN 5 WHEN 'CLUSTER' THEN 6 WHEN 'JOB' THEN 7 WHEN 'FILE' THEN 8 ELSE 9 END,
         category, item, attribute;

-- Summary per category (unexpected differences only)
WITH pre  AS (SELECT * FROM DBAdmin.dbo.ChangeSnapshotItem WHERE snapshot_id = @pre_id),
     post AS (SELECT * FROM DBAdmin.dbo.ChangeSnapshotItem WHERE snapshot_id = @post_id)
SELECT COALESCE(pre.category, post.category) AS category, COUNT(*) AS unexpected_differences
FROM pre
FULL JOIN post ON post.category = pre.category AND post.item_key = pre.item_key AND post.attribute = pre.attribute
WHERE (ISNULL(pre.value, N'<null>') <> ISNULL(post.value, N'<null>') OR pre.snapshot_id IS NULL OR post.snapshot_id IS NULL)
  AND COALESCE(pre.is_volatile, post.is_volatile) = 0
GROUP BY COALESCE(pre.category, post.category)
ORDER BY unexpected_differences DESC;


/*=============================================================================
  43.5 POST-CHANGE GO / NO-GO VERDICT (run right after the change)     [BOX][MI]
  Every row must say PASS before you close the change / hand back to apps.
=============================================================================*/
DECLARE @pre int = (SELECT MAX(snapshot_id) FROM DBAdmin.dbo.ChangeSnapshot WHERE label = N'PRE' AND server_name = @@SERVERNAME);

SELECT 'All databases ONLINE / MULTI_USER as before' AS check_item,
       CASE WHEN EXISTS (SELECT 1 FROM DBAdmin.dbo.ChangeSnapshotItem p
                         JOIN sys.databases d ON d.name = p.item_key COLLATE DATABASE_DEFAULT
                         WHERE p.snapshot_id = @pre AND p.category = 'DATABASE' AND p.attribute = 'state' AND p.value <> d.state_desc COLLATE DATABASE_DEFAULT)
              OR EXISTS (SELECT 1 FROM DBAdmin.dbo.ChangeSnapshotItem p
                         WHERE p.snapshot_id = @pre AND p.category = 'DATABASE' AND p.attribute = 'state' AND DB_ID(p.item_key) IS NULL)
            THEN 'FAIL' ELSE 'PASS' END AS result
UNION ALL
SELECT 'No database in RECOVERY_PENDING / SUSPECT / RECOVERING',
       CASE WHEN EXISTS (SELECT 1 FROM sys.databases WHERE state_desc IN (N'RECOVERY_PENDING', N'SUSPECT', N'RECOVERING', N'EMERGENCY')) THEN 'FAIL' ELSE 'PASS' END
UNION ALL
SELECT 'AG replicas connected & healthy',
       CASE WHEN EXISTS (SELECT 1 FROM sys.dm_hadr_availability_replica_states WHERE connected_state_desc <> 'CONNECTED' OR synchronization_health_desc <> 'HEALTHY')
            THEN 'FAIL' ELSE 'PASS' END
UNION ALL
SELECT 'AG databases synchronized / not suspended',
       CASE WHEN EXISTS (SELECT 1 FROM sys.dm_hadr_database_replica_states WHERE synchronization_health_desc <> 'HEALTHY' OR is_suspended = 1)
            THEN 'FAIL' ELSE 'PASS' END
UNION ALL
SELECT 'Primary replica same as before (or intentionally changed)',
       CASE WHEN EXISTS (SELECT 1 FROM DBAdmin.dbo.ChangeSnapshotItem p
                         JOIN sys.availability_groups ag ON ag.name = p.item_key COLLATE DATABASE_DEFAULT
                         JOIN sys.dm_hadr_availability_group_states s ON s.group_id = ag.group_id
                         WHERE p.snapshot_id = @pre AND p.category = 'AG' AND p.attribute = 'primary_replica' AND p.value <> s.primary_replica COLLATE DATABASE_DEFAULT)
            THEN 'CHECK' ELSE 'PASS' END
UNION ALL
SELECT 'Jobs enabled exactly as before',
       CASE WHEN EXISTS (SELECT 1 FROM DBAdmin.dbo.ChangeSnapshotItem p
                         JOIN msdb.dbo.sysjobs j ON j.name = p.item_key COLLATE DATABASE_DEFAULT
                         WHERE p.snapshot_id = @pre AND p.category = 'JOB' AND p.attribute = 'enabled' AND p.value <> CAST(j.enabled AS nvarchar(10)))
            THEN 'FAIL' ELSE 'PASS' END
UNION ALL
SELECT 'Global trace flags same as before',
       CASE WHEN (SELECT COUNT(*) FROM DBAdmin.dbo.ChangeSnapshotItem WHERE snapshot_id = @pre AND category = 'TRACEFLAG')
                 <> (SELECT COUNT(*) FROM DBAdmin.dbo.ChangeSnapshotItem WHERE snapshot_id = (SELECT MAX(snapshot_id) FROM DBAdmin.dbo.ChangeSnapshot WHERE label = N'POST' AND server_name = @@SERVERNAME) AND category = 'TRACEFLAG')
            THEN 'CHECK (run 43.4)' ELSE 'PASS' END
UNION ALL
SELECT 'Max server memory unchanged',
       CASE WHEN EXISTS (SELECT 1 FROM DBAdmin.dbo.ChangeSnapshotItem p JOIN sys.configurations c ON c.name = p.item_key COLLATE DATABASE_DEFAULT
                         WHERE p.snapshot_id = @pre AND p.category = 'CONFIG' AND p.item_key = N'max server memory (MB)'
                           AND p.value <> CAST(c.value_in_use AS nvarchar(4000)))
            THEN 'FAIL' ELSE 'PASS' END
UNION ALL
SELECT 'No upgrade-script errors in error log',
       'Run: EXEC sys.xp_readerrorlog 0, 1, N''Script level upgrade''; and N''error'' (30.7)'
UNION ALL
SELECT 'Build now', CAST(SERVERPROPERTY('ProductVersion') AS varchar(30)) + ' ' + ISNULL(CAST(SERVERPROPERTY('ProductUpdateLevel') AS varchar(10)), '');
-- Service state (BOX): 43.1 (b).  Full diff: 43.4.  Then take a fresh full backup if the change was an upgrade.


/*=============================================================================
  43.6 HOUSEKEEPING & EXTRAS
=============================================================================*/
/*
-- Keep 12 months of snapshots:
DELETE i FROM DBAdmin.dbo.ChangeSnapshotItem i JOIN DBAdmin.dbo.ChangeSnapshot s ON s.snapshot_id = i.snapshot_id
WHERE s.taken_at < DATEADD(MONTH, -12, SYSDATETIME());
DELETE DBAdmin.dbo.ChangeSnapshot WHERE taken_at < DATEADD(MONTH, -12, SYSDATETIME());

-- Compare the SAME server across months (config drift):  set @pre_id / @post_id in 43.4 to any two snapshot ids.
-- Compare two DIFFERENT servers (e.g. AG replicas): copy both snapshots into one DBAdmin, then 43.4 with their ids
--   (item keys containing the server name, like AG_REPLICA, will show as expected differences).

-- Belt and braces before an in-place upgrade - script the whole instance to files (dbatools):
--   Export-DbaInstance -SqlInstance SQLVM1 -Path D:\DBA\PreUpgrade\SQLVM1
--   (logins with SIDs/passwords, jobs, linked servers, credentials, mail, endpoints, sp_configure...)
*/
