/*******************************************************************************
 File    : 00_instance_overview.sql
 Purpose : First look at any instance - version, hardware, config, databases.
 Tags    : [BOX] = SQL 2016-2025 on-prem / Azure VM   [MI] = Managed Instance
           [SQLDB] = Azure SQL Database
 Usage   : Highlight ONE section and execute. Sections are independent.
*******************************************************************************/

/*=============================================================================
  0.1  VERSION, EDITION, PATCH LEVEL                         [BOX][MI][SQLDB]
  EngineEdition: 2=Standard 3=Enterprise 4=Express 5=Azure SQL DB 8=Managed Instance
=============================================================================*/
SELECT
    SERVERPROPERTY('ServerName')             AS server_name,
    SERVERPROPERTY('MachineName')            AS machine_name,
    SERVERPROPERTY('InstanceName')           AS instance_name,
    SERVERPROPERTY('Edition')                AS edition,
    SERVERPROPERTY('EngineEdition')          AS engine_edition,
    SERVERPROPERTY('ProductVersion')         AS product_version,
    SERVERPROPERTY('ProductLevel')           AS product_level,      -- RTM / SPn
    SERVERPROPERTY('ProductUpdateLevel')     AS cu_level,           -- CUnn
    SERVERPROPERTY('ProductUpdateReference') AS kb_article,
    SERVERPROPERTY('IsClustered')            AS is_fci,
    SERVERPROPERTY('IsHadrEnabled')          AS is_hadr_enabled,
    SERVERPROPERTY('Collation')              AS server_collation,
    @@VERSION                                AS full_version;


/*=============================================================================
  0.2  UPTIME + HARDWARE (CPU / MEMORY / NUMA)                        [BOX][MI]
  socket_count / cores_per_socket / numa_node_count need 2016 SP2+
=============================================================================*/
SELECT
    sqlserver_start_time,
    DATEDIFF(HOUR, sqlserver_start_time, SYSDATETIME())     AS uptime_hours,
    cpu_count                                               AS logical_cpus,
    hyperthread_ratio,
    socket_count,
    cores_per_socket,
    numa_node_count,
    scheduler_count,
    max_workers_count,
    physical_memory_kb / 1024                               AS physical_memory_mb,
    committed_kb / 1024                                     AS sql_committed_mb,
    committed_target_kb / 1024                              AS sql_target_mb,
    sql_memory_model_desc,          -- CONVENTIONAL / LOCK_PAGES / LARGE_PAGES
    virtual_machine_type_desc,
    affinity_type_desc
FROM sys.dm_os_sys_info;


/*=============================================================================
  0.3  HOST OS INFO (2017+)                                           [BOX][MI]
=============================================================================*/
SELECT host_platform, host_distribution, host_release, host_service_pack_level, host_sku
FROM sys.dm_os_host_info;


/*=============================================================================
  0.4  KEY INSTANCE SETTINGS (sp_configure)                           [BOX][MI]
  Things to check: max server memory set (not 2147483647), MAXDOP not 0 on big
  boxes, cost threshold > 5, backup compression/checksum on, DAC enabled.
=============================================================================*/
SELECT name, value, value_in_use, is_dynamic, is_advanced
FROM sys.configurations
WHERE name IN (
    N'max server memory (MB)', N'min server memory (MB)',
    N'max degree of parallelism', N'cost threshold for parallelism',
    N'optimize for ad hoc workloads', N'backup compression default',
    N'backup checksum default', N'remote admin connections',
    N'clr enabled', N'clr strict security', N'xp_cmdshell', N'Database Mail XPs',
    N'contained database authentication', N'blocked process threshold (s)',
    N'fill factor (%)', N'priority boost', N'lightweight pooling',
    N'max worker threads', N'Agent XPs', N'remote access')
ORDER BY name;

-- All non-default-looking values (value <> value_in_use = pending RECONFIGURE / restart)
SELECT name, value, value_in_use
FROM sys.configurations
WHERE value <> value_in_use;


/*=============================================================================
  0.5  DATABASE-SCOPED CONFIGURATION (current DB)             [BOX][MI][SQLDB]
=============================================================================*/
SELECT name, value, value_for_secondary, is_value_default
FROM sys.database_scoped_configurations
ORDER BY name;


/*=============================================================================
  0.6  GLOBAL TRACE FLAGS                                             [BOX][MI]
=============================================================================*/
DBCC TRACESTATUS(-1);


/*=============================================================================
  0.7  SQL SERVICES, ACCOUNTS, IFI                                       [BOX]
  instant_file_initialization_enabled = Y is what you want.
=============================================================================*/
SELECT servicename, status_desc, startup_type_desc, service_account,
       last_startup_time, is_clustered, cluster_nodename,
       instant_file_initialization_enabled
FROM sys.dm_server_services;

-- Startup parameters (-T trace flags, -d/-l/-e paths)
SELECT value_name, value_data
FROM sys.dm_server_registry
WHERE value_name LIKE N'SQLArg%';


/*=============================================================================
  0.8  ALL DATABASES - PROPERTIES AT A GLANCE                 [BOX][MI][SQLDB]
=============================================================================*/
SELECT
    d.name, d.database_id, d.state_desc, d.user_access_desc,
    d.recovery_model_desc, d.compatibility_level, d.collation_name,
    d.page_verify_option_desc,
    d.is_auto_close_on, d.is_auto_shrink_on,
    d.is_auto_create_stats_on, d.is_auto_update_stats_on, d.is_auto_update_stats_async_on,
    d.is_read_committed_snapshot_on, d.snapshot_isolation_state_desc,
    d.is_query_store_on, d.is_encrypted, d.is_trustworthy_on,
    d.log_reuse_wait_desc, d.target_recovery_time_in_seconds,
    d.delayed_durability_desc, d.containment_desc,
    SUSER_SNAME(d.owner_sid) AS owner_name,
    d.create_date
FROM sys.databases AS d
ORDER BY d.name;


/*=============================================================================
  0.9  DATABASE SIZES (data / log)                                    [BOX][MI]
=============================================================================*/
SELECT
    DB_NAME(mf.database_id)                                                     AS database_name,
    CAST(SUM(CASE WHEN mf.type = 0 THEN CAST(mf.size AS bigint) END) * 8 / 1024.0 AS decimal(18,2)) AS data_mb,
    CAST(SUM(CASE WHEN mf.type = 1 THEN CAST(mf.size AS bigint) END) * 8 / 1024.0 AS decimal(18,2)) AS log_mb,
    CAST(SUM(CAST(mf.size AS bigint)) * 8 / 1024.0 / 1024.0 AS decimal(18,2))               AS total_gb
FROM sys.master_files AS mf
GROUP BY mf.database_id
ORDER BY total_gb DESC;


/*=============================================================================
  0.10 CONNECTION COUNTS BY DB / LOGIN / HOST / APP          [BOX][MI][SQLDB]
=============================================================================*/
SELECT DB_NAME(s.database_id) AS database_name, s.login_name, s.host_name, s.program_name,
       COUNT(*)                                          AS sessions,
       SUM(CASE WHEN s.status = 'running' THEN 1 ELSE 0 END) AS running
FROM sys.dm_exec_sessions AS s
WHERE s.is_user_process = 1
GROUP BY DB_NAME(s.database_id), s.login_name, s.host_name, s.program_name
ORDER BY sessions DESC;
