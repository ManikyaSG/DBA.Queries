/*******************************************************************************
 File    : DBAdmin_HC_Deploy.sql            (GENERATED - do not edit by hand)
 Source  : the numbered scripts in this repo, rebuilt with dba-database/build_hc_deploy.py
 Purpose : Installs the toolkit's diagnostic queries as objects in the DBAdmin
           database, so the team can run them without opening the script files:

               SELECT * FROM DBAdmin.dbo.HC_catalog;          -- what is installed + how to call it
               SELECT * FROM DBAdmin.dbo.HC_active_sessions;  -- views
               SELECT * FROM DBAdmin.dbo.HC_top_queries(DEFAULT, DEFAULT);   -- functions with inputs
               EXEC DBAdmin.dbo.HC_blocking_tree;             -- multi-step checks
               EXEC DBAdmin.dbo.HC_index_usage @database_name = N'Sales';   -- per-database checks

 Runs on : SQL Server 2016 SP2 - 2025, Azure SQL Managed Instance, Azure SQL Database
           * Box / Azure VM / MI : creates DBAdmin if missing and installs into it.
             Install on EVERY AG replica (DBAdmin is a local database - keep it out of AGs).
           * Azure SQL Database  : connect to the user database you want it in and run
                                   the script there (the USE below errors harmlessly).
 Safe to  : re-run any time. Every object is CREATE OR ALTER inside TRY/CATCH, so one
            failure never stops the rest. Objects that need a newer version or another
            platform are skipped and listed in dbo.HC_catalog with the reason.
 Security : objects run with the CALLER's permissions. Users still need
            VIEW SERVER STATE (2022+: VIEW SERVER PERFORMANCE STATE / VIEW SERVER SECURITY STATE)
            and access to msdb / the databases they query. Grant example at the end.
*******************************************************************************/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

IF CAST(SERVERPROPERTY('EngineEdition') AS int) <> 5 AND DB_ID(N'DBAdmin') IS NULL
BEGIN
    CREATE DATABASE DBAdmin;
    ALTER DATABASE DBAdmin SET RECOVERY SIMPLE;
    PRINT 'Created database DBAdmin.';
END;
GO

USE DBAdmin;   -- Azure SQL Database: this line errors; that is expected, the script continues in the current DB
GO

IF (CAST(SERVERPROPERTY('EngineEdition') AS int) <> 5 AND DB_NAME() <> N'DBAdmin')
OR (CAST(SERVERPROPERTY('EngineEdition') AS int) = 5 AND DB_NAME() = N'master')
BEGIN
    RAISERROR(N'Not in DBAdmin (or in master on Azure SQL Database) - nothing will be installed.', 16, 1);
    SET NOEXEC ON;
END;
GO

/*----------------------------------------------------------------------------
  Registry + deploy helper
----------------------------------------------------------------------------*/
IF OBJECT_ID(N'dbo.HC_objects', N'U') IS NULL
CREATE TABLE dbo.HC_objects
(
    name          sysname        NOT NULL CONSTRAINT PK_HC_objects PRIMARY KEY,
    section       varchar(10)    NOT NULL,
    source_file   nvarchar(128)  NOT NULL,
    title         nvarchar(400)  NOT NULL,
    tags          varchar(30)    NOT NULL,
    usage         nvarchar(1000) NOT NULL,
    sort_hint     nvarchar(1000) NULL,
    status        varchar(30)    NOT NULL,
    message       nvarchar(4000) NULL,
    deployed_at   datetime2(0)   NOT NULL CONSTRAINT DF_HC_objects_deployed DEFAULT SYSDATETIME()
);
GO

CREATE OR ALTER PROCEDURE dbo.HC_usp_deploy
    @name                sysname,
    @section             varchar(10),
    @source_file         nvarchar(128),
    @title               nvarchar(400),
    @tags                varchar(30),
    @usage               nvarchar(1000),
    @sort_hint           nvarchar(1000) = NULL,
    @min_version         int            = NULL,   -- SQL Server major version: 13=2016 14=2017 15=2019 16=2022 17=2025
    @definition          nvarchar(max),
    @fallback_definition nvarchar(max)  = NULL
AS
SET NOCOUNT ON;
DECLARE @platform varchar(5) =
        CASE CAST(SERVERPROPERTY('EngineEdition') AS int) WHEN 5 THEN 'SQLDB' WHEN 8 THEN 'MI' ELSE 'BOX' END;
DECLARE @status varchar(30), @msg nvarchar(4000), @fq nvarchar(300) = N'dbo.' + QUOTENAME(@name),
        @want char(2), @have char(2), @try nvarchar(max), @attempt int = 1, @errno int,
        @major int = CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)), 4) AS int);

IF (@tags <> '' AND CHARINDEX(@platform, @tags) = 0)
OR (@platform = 'BOX' AND @min_version IS NOT NULL AND @major < @min_version)
BEGIN
    IF @tags <> '' AND CHARINDEX(@platform, @tags) = 0
        SELECT @status = 'NOT APPLICABLE', @msg = N'Written for ' + @tags + N'; this is ' + @platform + N'.';
    ELSE
        SELECT @status = 'NOT ON THIS VERSION',
               @msg = N'Needs major version ' + CAST(@min_version AS nvarchar(5)) + N'+; this is ' + CAST(@major AS nvarchar(5)) + N'.';
    IF OBJECT_ID(@fq) IS NOT NULL
    BEGIN
        SET @try = N'DROP ' + CASE (SELECT type FROM sys.objects WHERE object_id = OBJECT_ID(@fq))
                                WHEN 'V' THEN N'VIEW' WHEN 'P' THEN N'PROCEDURE' ELSE N'FUNCTION' END + N' ' + @fq;
        EXEC sys.sp_executesql @try;
    END;
END
ELSE
BEGIN
    SET @try = @definition;
    WHILE @try IS NOT NULL
    BEGIN
        SET @want = CASE WHEN @try LIKE N'CREATE OR ALTER VIEW%'     THEN 'V'
                         WHEN @try LIKE N'CREATE OR ALTER FUNCTION%' THEN 'IF'
                         ELSE 'P' END;
        BEGIN TRY
            SELECT @have = type FROM sys.objects WHERE object_id = OBJECT_ID(@fq);
            IF @have IS NOT NULL AND RTRIM(@have) <> RTRIM(@want)
            BEGIN
                DECLARE @drop nvarchar(400) = N'DROP ' + CASE RTRIM(@have) WHEN 'V' THEN N'VIEW' WHEN 'P' THEN N'PROCEDURE'
                                                          ELSE N'FUNCTION' END + N' ' + @fq;
                EXEC sys.sp_executesql @drop;
            END;
            EXEC sys.sp_executesql @try;
            SELECT @status = CASE WHEN @attempt = 1 THEN 'OK' ELSE 'OK (as procedure)' END,
                   @msg    = CASE WHEN @attempt = 1 THEN NULL ELSE N'Created as a procedure instead: ' + @msg END,
                   @try    = NULL;
        END TRY
        BEGIN CATCH
            SELECT @msg = CASE WHEN @msg IS NULL THEN N'' ELSE @msg + N' | ' END + ERROR_MESSAGE(),
                   @errno = ERROR_NUMBER();
            IF @attempt = 1 AND @fallback_definition IS NOT NULL
                SELECT @try = @fallback_definition, @attempt = 2;
            ELSE      -- 207/208/195/4121 on older builds = column/function/syntax the version lacks
                SELECT @status = CASE WHEN @errno IN (207, 208, 195, 4121) THEN 'NOT ON THIS VERSION' ELSE 'FAILED' END,
                       @try = NULL;
        END CATCH;
        SET @have = NULL;
    END;
END;

MERGE dbo.HC_objects AS t
USING (SELECT @name AS name) AS s ON t.name = s.name
WHEN MATCHED THEN UPDATE SET section = @section, source_file = @source_file, title = @title, tags = @tags,
     usage = @usage, sort_hint = @sort_hint, status = @status, message = LEFT(@msg, 4000), deployed_at = SYSDATETIME()
WHEN NOT MATCHED THEN INSERT (name, section, source_file, title, tags, usage, sort_hint, status, message)
     VALUES (@name, @section, @source_file, @title, @tags, @usage, @sort_hint, @status, LEFT(@msg, 4000));
GO

/*============================================================================
  OBJECTS (one EXEC per toolkit section)
============================================================================*/

/* 0.1  VERSION, EDITION, PATCH LEVEL   (00_instance_overview.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_version', @section = N'0.1', @source_file = N'00_instance_overview.sql',
    @title = N'VERSION, EDITION, PATCH LEVEL', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_version;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_version
AS
-- Toolkit 00_instance_overview.sql section 0.1: VERSION, EDITION, PATCH LEVEL
SELECT
    SERVERPROPERTY(''ServerName'')             AS server_name,
    SERVERPROPERTY(''MachineName'')            AS machine_name,
    SERVERPROPERTY(''InstanceName'')           AS instance_name,
    SERVERPROPERTY(''Edition'')                AS edition,
    SERVERPROPERTY(''EngineEdition'')          AS engine_edition,
    SERVERPROPERTY(''ProductVersion'')         AS product_version,
    SERVERPROPERTY(''ProductLevel'')           AS product_level,
    SERVERPROPERTY(''ProductUpdateLevel'')     AS cu_level,
    SERVERPROPERTY(''ProductUpdateReference'') AS kb_article,
    SERVERPROPERTY(''IsClustered'')            AS is_fci,
    SERVERPROPERTY(''IsHadrEnabled'')          AS is_hadr_enabled,
    SERVERPROPERTY(''Collation'')              AS server_collation,
    @@VERSION                                AS full_version;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_version
AS
-- Toolkit 00_instance_overview.sql section 0.1: VERSION, EDITION, PATCH LEVEL
SET NOCOUNT ON;
SELECT
    SERVERPROPERTY(''ServerName'')             AS server_name,
    SERVERPROPERTY(''MachineName'')            AS machine_name,
    SERVERPROPERTY(''InstanceName'')           AS instance_name,
    SERVERPROPERTY(''Edition'')                AS edition,
    SERVERPROPERTY(''EngineEdition'')          AS engine_edition,
    SERVERPROPERTY(''ProductVersion'')         AS product_version,
    SERVERPROPERTY(''ProductLevel'')           AS product_level,
    SERVERPROPERTY(''ProductUpdateLevel'')     AS cu_level,
    SERVERPROPERTY(''ProductUpdateReference'') AS kb_article,
    SERVERPROPERTY(''IsClustered'')            AS is_fci,
    SERVERPROPERTY(''IsHadrEnabled'')          AS is_hadr_enabled,
    SERVERPROPERTY(''Collation'')              AS server_collation,
    @@VERSION                                AS full_version;
';
GO

/* 0.2  UPTIME + HARDWARE (CPU / MEMORY / NUMA)   (00_instance_overview.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_uptime_hardware', @section = N'0.2', @source_file = N'00_instance_overview.sql',
    @title = N'UPTIME + HARDWARE (CPU / MEMORY / NUMA)', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_uptime_hardware;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_uptime_hardware
AS
-- Toolkit 00_instance_overview.sql section 0.2: UPTIME + HARDWARE (CPU / MEMORY / NUMA)
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
    sql_memory_model_desc,
    virtual_machine_type_desc,
    affinity_type_desc
FROM sys.dm_os_sys_info;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_uptime_hardware
AS
-- Toolkit 00_instance_overview.sql section 0.2: UPTIME + HARDWARE (CPU / MEMORY / NUMA)
SET NOCOUNT ON;
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
    sql_memory_model_desc,
    virtual_machine_type_desc,
    affinity_type_desc
FROM sys.dm_os_sys_info;
';
GO

/* 0.3  HOST OS INFO (2017+)   (00_instance_overview.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_host_os', @section = N'0.3', @source_file = N'00_instance_overview.sql',
    @title = N'HOST OS INFO (2017+)', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_host_os;',
    @min_version = 14,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_host_os
AS
-- Toolkit 00_instance_overview.sql section 0.3: HOST OS INFO (2017+)
SELECT host_platform, host_distribution, host_release, host_service_pack_level, host_sku
FROM sys.dm_os_host_info;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_host_os
AS
-- Toolkit 00_instance_overview.sql section 0.3: HOST OS INFO (2017+)
SET NOCOUNT ON;
SELECT host_platform, host_distribution, host_release, host_service_pack_level, host_sku
FROM sys.dm_os_host_info;
';
GO

/* 0.4  KEY INSTANCE SETTINGS (sp_configure)   (00_instance_overview.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_instance_settings', @section = N'0.4', @source_file = N'00_instance_overview.sql',
    @title = N'KEY INSTANCE SETTINGS (sp_configure)', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_instance_settings;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_instance_settings
AS
-- Toolkit 00_instance_overview.sql section 0.4: KEY INSTANCE SETTINGS (sp_configure)
SET NOCOUNT ON;
SELECT name, value, value_in_use, is_dynamic, is_advanced
FROM sys.configurations
WHERE name IN (
    N''max server memory (MB)'', N''min server memory (MB)'',
    N''max degree of parallelism'', N''cost threshold for parallelism'',
    N''optimize for ad hoc workloads'', N''backup compression default'',
    N''backup checksum default'', N''remote admin connections'',
    N''clr enabled'', N''clr strict security'', N''xp_cmdshell'', N''Database Mail XPs'',
    N''contained database authentication'', N''blocked process threshold (s)'',
    N''fill factor (%)'', N''priority boost'', N''lightweight pooling'',
    N''max worker threads'', N''Agent XPs'', N''remote access'')
ORDER BY name;

SELECT name, value, value_in_use
FROM sys.configurations
WHERE value <> value_in_use;
',
    @fallback_definition = NULL;
GO

/* 0.5  DATABASE-SCOPED CONFIGURATION (current DB)   (00_instance_overview.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_db_scoped_config', @section = N'0.5', @source_file = N'00_instance_overview.sql',
    @title = N'DATABASE-SCOPED CONFIGURATION (current DB)', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_db_scoped_config @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_db_scoped_config
    @database_name sysname = NULL
AS
-- Toolkit 00_instance_overview.sql section 0.5: DATABASE-SCOPED CONFIGURATION (current DB)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT name, value, value_for_secondary, is_value_default
FROM sys.database_scoped_configurations
ORDER BY name;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 0.6  GLOBAL TRACE FLAGS   (00_instance_overview.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_trace_flags', @section = N'0.6', @source_file = N'00_instance_overview.sql',
    @title = N'GLOBAL TRACE FLAGS', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_trace_flags;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_trace_flags
AS
-- Toolkit 00_instance_overview.sql section 0.6: GLOBAL TRACE FLAGS
SET NOCOUNT ON;
DBCC TRACESTATUS(-1);
',
    @fallback_definition = NULL;
GO

/* 0.7  SQL SERVICES, ACCOUNTS, IFI   (00_instance_overview.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_services', @section = N'0.7', @source_file = N'00_instance_overview.sql',
    @title = N'SQL SERVICES, ACCOUNTS, IFI', @tags = N'BOX',
    @usage = N'EXEC dbo.HC_services;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_services
AS
-- Toolkit 00_instance_overview.sql section 0.7: SQL SERVICES, ACCOUNTS, IFI
SET NOCOUNT ON;
SELECT servicename, status_desc, startup_type_desc, service_account,
       last_startup_time, is_clustered, cluster_nodename,
       instant_file_initialization_enabled
FROM sys.dm_server_services;

SELECT value_name, value_data
FROM sys.dm_server_registry
WHERE value_name LIKE N''SQLArg%'';
',
    @fallback_definition = NULL;
GO

/* 0.8  ALL DATABASES - PROPERTIES AT A GLANCE   (00_instance_overview.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_database_properties', @section = N'0.8', @source_file = N'00_instance_overview.sql',
    @title = N'ALL DATABASES - PROPERTIES AT A GLANCE', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_database_properties ORDER BY name;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY d.name',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_database_properties
AS
-- Toolkit 00_instance_overview.sql section 0.8: ALL DATABASES - PROPERTIES AT A GLANCE
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
FROM sys.databases AS d;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_database_properties
AS
-- Toolkit 00_instance_overview.sql section 0.8: ALL DATABASES - PROPERTIES AT A GLANCE
SET NOCOUNT ON;
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
';
GO

/* 0.9  DATABASE SIZES (data / log)   (00_instance_overview.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_database_sizes', @section = N'0.9', @source_file = N'00_instance_overview.sql',
    @title = N'DATABASE SIZES (data / log)', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_database_sizes ORDER BY total_gb DESC;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY total_gb DESC',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_database_sizes
AS
-- Toolkit 00_instance_overview.sql section 0.9: DATABASE SIZES (data / log)
SELECT
    DB_NAME(mf.database_id)                                                     AS database_name,
    CAST(SUM(CASE WHEN mf.type = 0 THEN CAST(mf.size AS bigint) END) * 8 / 1024.0 AS decimal(18,2)) AS data_mb,
    CAST(SUM(CASE WHEN mf.type = 1 THEN CAST(mf.size AS bigint) END) * 8 / 1024.0 AS decimal(18,2)) AS log_mb,
    CAST(SUM(CAST(mf.size AS bigint)) * 8 / 1024.0 / 1024.0 AS decimal(18,2))               AS total_gb
FROM sys.master_files AS mf
GROUP BY mf.database_id;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_database_sizes
AS
-- Toolkit 00_instance_overview.sql section 0.9: DATABASE SIZES (data / log)
SET NOCOUNT ON;
SELECT
    DB_NAME(mf.database_id)                                                     AS database_name,
    CAST(SUM(CASE WHEN mf.type = 0 THEN CAST(mf.size AS bigint) END) * 8 / 1024.0 AS decimal(18,2)) AS data_mb,
    CAST(SUM(CASE WHEN mf.type = 1 THEN CAST(mf.size AS bigint) END) * 8 / 1024.0 AS decimal(18,2)) AS log_mb,
    CAST(SUM(CAST(mf.size AS bigint)) * 8 / 1024.0 / 1024.0 AS decimal(18,2))               AS total_gb
FROM sys.master_files AS mf
GROUP BY mf.database_id
ORDER BY total_gb DESC;
';
GO

/* 0.10  CONNECTION COUNTS BY DB / LOGIN / HOST / APP   (00_instance_overview.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_connection_counts', @section = N'0.10', @source_file = N'00_instance_overview.sql',
    @title = N'CONNECTION COUNTS BY DB / LOGIN / HOST / APP', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_connection_counts ORDER BY sessions DESC;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY sessions DESC',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_connection_counts
AS
-- Toolkit 00_instance_overview.sql section 0.10: CONNECTION COUNTS BY DB / LOGIN / HOST / APP
SELECT DB_NAME(s.database_id) AS database_name, s.login_name, s.host_name, s.program_name,
       COUNT(*)                                          AS sessions,
       SUM(CASE WHEN s.status = ''running'' THEN 1 ELSE 0 END) AS running
FROM sys.dm_exec_sessions AS s
WHERE s.is_user_process = 1
GROUP BY DB_NAME(s.database_id), s.login_name, s.host_name, s.program_name;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_connection_counts
AS
-- Toolkit 00_instance_overview.sql section 0.10: CONNECTION COUNTS BY DB / LOGIN / HOST / APP
SET NOCOUNT ON;
SELECT DB_NAME(s.database_id) AS database_name, s.login_name, s.host_name, s.program_name,
       COUNT(*)                                          AS sessions,
       SUM(CASE WHEN s.status = ''running'' THEN 1 ELSE 0 END) AS running
FROM sys.dm_exec_sessions AS s
WHERE s.is_user_process = 1
GROUP BY DB_NAME(s.database_id), s.login_name, s.host_name, s.program_name
ORDER BY sessions DESC;
';
GO

/* 1.1  TOP WAITS SINCE RESTART (benign waits filtered)   (01_wait_stats.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_top_waits', @section = N'1.1', @source_file = N'01_wait_stats.sql',
    @title = N'TOP WAITS SINCE RESTART (benign waits filtered)', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_top_waits;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY w.rn',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_top_waits
AS
-- Toolkit 01_wait_stats.sql section 1.1: TOP WAITS SINCE RESTART (benign waits filtered)
WITH waits AS (
    SELECT
        wait_type,
        wait_time_ms / 1000.0                              AS wait_s,
        (wait_time_ms - signal_wait_time_ms) / 1000.0      AS resource_s,
        signal_wait_time_ms / 1000.0                       AS signal_s,
        waiting_tasks_count,
        100.0 * wait_time_ms / SUM(wait_time_ms) OVER ()   AS pct,
        ROW_NUMBER() OVER (ORDER BY wait_time_ms DESC)     AS rn
    FROM sys.dm_os_wait_stats
    WHERE waiting_tasks_count > 0
      AND wait_type NOT IN (
        N''BROKER_EVENTHANDLER'', N''BROKER_RECEIVE_WAITFOR'', N''BROKER_TASK_STOP'',
        N''BROKER_TO_FLUSH'', N''BROKER_TRANSMITTER'', N''CHECKPOINT_QUEUE'', N''CHKPT'',
        N''CLR_AUTO_EVENT'', N''CLR_MANUAL_EVENT'', N''CLR_SEMAPHORE'', N''CXCONSUMER'',
        N''DBMIRROR_DBM_EVENT'', N''DBMIRROR_EVENTS_QUEUE'', N''DBMIRROR_WORKER_QUEUE'',
        N''DBMIRRORING_CMD'', N''DIRTY_PAGE_POLL'', N''DISPATCHER_QUEUE_SEMAPHORE'',
        N''EXECSYNC'', N''FSAGENT'', N''FT_IFTS_SCHEDULER_IDLE_WAIT'', N''FT_IFTSHC_MUTEX'',
        N''HADR_CLUSAPI_CALL'', N''HADR_FILESTREAM_IOMGR_IOCOMPLETION'',
        N''HADR_LOGCAPTURE_WAIT'', N''HADR_NOTIFICATION_DEQUEUE'', N''HADR_TIMER_TASK'',
        N''HADR_WORK_QUEUE'', N''KSOURCE_WAKEUP'', N''LAZYWRITER_SLEEP'', N''LOGMGR_QUEUE'',
        N''MEMORY_ALLOCATION_EXT'', N''ONDEMAND_TASK_QUEUE'',
        N''PARALLEL_REDO_DRAIN_WORKER'', N''PARALLEL_REDO_LOG_CACHE'',
        N''PARALLEL_REDO_TRAN_LIST'', N''PARALLEL_REDO_WORKER_SYNC'',
        N''PARALLEL_REDO_WORKER_WAIT_WORK'', N''PREEMPTIVE_OS_FLUSHFILEBUFFERS'',
        N''PREEMPTIVE_XE_GETTARGETSTATE'', N''PVS_PREALLOCATE'',
        N''PWAIT_ALL_COMPONENTS_INITIALIZED'', N''PWAIT_DIRECTLOGCONSUMER_GETNEXT'',
        N''PWAIT_EXTENSIBILITY_CLEANUP_TASK'', N''QDS_PERSIST_TASK_MAIN_LOOP_SLEEP'',
        N''QDS_ASYNC_QUEUE'', N''QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP'',
        N''QDS_SHUTDOWN_QUEUE'', N''REDO_THREAD_PENDING_WORK'',
        N''REQUEST_FOR_DEADLOCK_SEARCH'', N''RESOURCE_QUEUE'', N''SERVER_IDLE_CHECK'',
        N''SLEEP_BPOOL_FLUSH'', N''SLEEP_DBSTARTUP'', N''SLEEP_DCOMSTARTUP'',
        N''SLEEP_MASTERDBREADY'', N''SLEEP_MASTERMDREADY'', N''SLEEP_MASTERUPGRADED'',
        N''SLEEP_MSDBSTARTUP'', N''SLEEP_SYSTEMTASK'', N''SLEEP_TASK'',
        N''SLEEP_TEMPDBSTARTUP'', N''SNI_HTTP_ACCEPT'', N''SOS_WORK_DISPATCHER'',
        N''SP_SERVER_DIAGNOSTICS_SLEEP'', N''SQLTRACE_BUFFER_FLUSH'',
        N''SQLTRACE_INCREMENTAL_FLUSH_SLEEP'', N''SQLTRACE_WAIT_ENTRIES'',
        N''VDI_CLIENT_OTHER'', N''WAIT_FOR_RESULTS'', N''WAITFOR'', N''WAITFOR_TASKSHUTDOWN'',
        N''WAIT_XTP_RECOVERY'', N''WAIT_XTP_HOST_WAIT'', N''WAIT_XTP_OFFLINE_CKPT_NEW_LOG'',
        N''WAIT_XTP_CKPT_CLOSE'', N''XE_DISPATCHER_JOIN'', N''XE_DISPATCHER_WAIT'',
        N''XE_TIMER_EVENT'', N''XE_LIVE_TARGET_TVF'')
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
WHERE w.rn <= 25;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_top_waits
AS
-- Toolkit 01_wait_stats.sql section 1.1: TOP WAITS SINCE RESTART (benign waits filtered)
SET NOCOUNT ON;
WITH waits AS (
    SELECT
        wait_type,
        wait_time_ms / 1000.0                              AS wait_s,
        (wait_time_ms - signal_wait_time_ms) / 1000.0      AS resource_s,
        signal_wait_time_ms / 1000.0                       AS signal_s,
        waiting_tasks_count,
        100.0 * wait_time_ms / SUM(wait_time_ms) OVER ()   AS pct,
        ROW_NUMBER() OVER (ORDER BY wait_time_ms DESC)     AS rn
    FROM sys.dm_os_wait_stats
    WHERE waiting_tasks_count > 0
      AND wait_type NOT IN (
        N''BROKER_EVENTHANDLER'', N''BROKER_RECEIVE_WAITFOR'', N''BROKER_TASK_STOP'',
        N''BROKER_TO_FLUSH'', N''BROKER_TRANSMITTER'', N''CHECKPOINT_QUEUE'', N''CHKPT'',
        N''CLR_AUTO_EVENT'', N''CLR_MANUAL_EVENT'', N''CLR_SEMAPHORE'', N''CXCONSUMER'',
        N''DBMIRROR_DBM_EVENT'', N''DBMIRROR_EVENTS_QUEUE'', N''DBMIRROR_WORKER_QUEUE'',
        N''DBMIRRORING_CMD'', N''DIRTY_PAGE_POLL'', N''DISPATCHER_QUEUE_SEMAPHORE'',
        N''EXECSYNC'', N''FSAGENT'', N''FT_IFTS_SCHEDULER_IDLE_WAIT'', N''FT_IFTSHC_MUTEX'',
        N''HADR_CLUSAPI_CALL'', N''HADR_FILESTREAM_IOMGR_IOCOMPLETION'',
        N''HADR_LOGCAPTURE_WAIT'', N''HADR_NOTIFICATION_DEQUEUE'', N''HADR_TIMER_TASK'',
        N''HADR_WORK_QUEUE'', N''KSOURCE_WAKEUP'', N''LAZYWRITER_SLEEP'', N''LOGMGR_QUEUE'',
        N''MEMORY_ALLOCATION_EXT'', N''ONDEMAND_TASK_QUEUE'',
        N''PARALLEL_REDO_DRAIN_WORKER'', N''PARALLEL_REDO_LOG_CACHE'',
        N''PARALLEL_REDO_TRAN_LIST'', N''PARALLEL_REDO_WORKER_SYNC'',
        N''PARALLEL_REDO_WORKER_WAIT_WORK'', N''PREEMPTIVE_OS_FLUSHFILEBUFFERS'',
        N''PREEMPTIVE_XE_GETTARGETSTATE'', N''PVS_PREALLOCATE'',
        N''PWAIT_ALL_COMPONENTS_INITIALIZED'', N''PWAIT_DIRECTLOGCONSUMER_GETNEXT'',
        N''PWAIT_EXTENSIBILITY_CLEANUP_TASK'', N''QDS_PERSIST_TASK_MAIN_LOOP_SLEEP'',
        N''QDS_ASYNC_QUEUE'', N''QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP'',
        N''QDS_SHUTDOWN_QUEUE'', N''REDO_THREAD_PENDING_WORK'',
        N''REQUEST_FOR_DEADLOCK_SEARCH'', N''RESOURCE_QUEUE'', N''SERVER_IDLE_CHECK'',
        N''SLEEP_BPOOL_FLUSH'', N''SLEEP_DBSTARTUP'', N''SLEEP_DCOMSTARTUP'',
        N''SLEEP_MASTERDBREADY'', N''SLEEP_MASTERMDREADY'', N''SLEEP_MASTERUPGRADED'',
        N''SLEEP_MSDBSTARTUP'', N''SLEEP_SYSTEMTASK'', N''SLEEP_TASK'',
        N''SLEEP_TEMPDBSTARTUP'', N''SNI_HTTP_ACCEPT'', N''SOS_WORK_DISPATCHER'',
        N''SP_SERVER_DIAGNOSTICS_SLEEP'', N''SQLTRACE_BUFFER_FLUSH'',
        N''SQLTRACE_INCREMENTAL_FLUSH_SLEEP'', N''SQLTRACE_WAIT_ENTRIES'',
        N''VDI_CLIENT_OTHER'', N''WAIT_FOR_RESULTS'', N''WAITFOR'', N''WAITFOR_TASKSHUTDOWN'',
        N''WAIT_XTP_RECOVERY'', N''WAIT_XTP_HOST_WAIT'', N''WAIT_XTP_OFFLINE_CKPT_NEW_LOG'',
        N''WAIT_XTP_CKPT_CLOSE'', N''XE_DISPATCHER_JOIN'', N''XE_DISPATCHER_WAIT'',
        N''XE_TIMER_EVENT'', N''XE_LIVE_TARGET_TVF'')
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
';
GO

/* 1.2  WAITS RIGHT NOW - DELTA OVER N SECONDS   (01_wait_stats.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_waits_delta', @section = N'1.2', @source_file = N'01_wait_stats.sql',
    @title = N'WAITS RIGHT NOW - DELTA OVER N SECONDS', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_waits_delta @delay = ''00:01:00'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_waits_delta
    @delay char(8) = ''00:01:00''
AS
-- Toolkit 01_wait_stats.sql section 1.2: WAITS RIGHT NOW - DELTA OVER N SECONDS
SET NOCOUNT ON;
IF OBJECT_ID(''tempdb..#w1'') IS NOT NULL DROP TABLE #w1;
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
  AND w2.wait_type NOT LIKE N''SLEEP%''
  AND w2.wait_type NOT LIKE N''%QUEUE%''
  AND w2.wait_type NOT IN (N''LAZYWRITER_SLEEP'', N''XE_TIMER_EVENT'', N''XE_DISPATCHER_WAIT'',
        N''REQUEST_FOR_DEADLOCK_SEARCH'', N''CHECKPOINT_QUEUE'', N''DIRTY_PAGE_POLL'',
        N''HADR_FILESTREAM_IOMGR_IOCOMPLETION'', N''SP_SERVER_DIAGNOSTICS_SLEEP'',
        N''BROKER_TO_FLUSH'', N''HADR_TIMER_TASK'', N''HADR_WORK_QUEUE'', N''WAITFOR'',
        N''CXCONSUMER'', N''QDS_PERSIST_TASK_MAIN_LOOP_SLEEP'', N''PWAIT_EXTENSIBILITY_CLEANUP_TASK'')
ORDER BY wait_ms_delta DESC;
',
    @fallback_definition = NULL;
GO

/* 1.3  WHO IS WAITING ON WHAT - LIVE   (01_wait_stats.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_waiting_tasks', @section = N'1.3', @source_file = N'01_wait_stats.sql',
    @title = N'WHO IS WAITING ON WHAT - LIVE', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_waiting_tasks ORDER BY wait_duration_ms DESC;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY wt.wait_duration_ms DESC',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_waiting_tasks
AS
-- Toolkit 01_wait_stats.sql section 1.3: WHO IS WAITING ON WHAT - LIVE
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
WHERE s.is_user_process = 1;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_waiting_tasks
AS
-- Toolkit 01_wait_stats.sql section 1.3: WHO IS WAITING ON WHAT - LIVE
SET NOCOUNT ON;
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
';
GO

/* 1.4  WAIT STATS FOR ONE SESSION (2016+)   (01_wait_stats.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_session_waits', @section = N'1.4', @source_file = N'01_wait_stats.sql',
    @title = N'WAIT STATS FOR ONE SESSION (2016+)', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_session_waits(DEFAULT) ORDER BY wait_time_ms DESC;  -- @spid = 55',
    @min_version = NULL,
    @sort_hint = N'ORDER BY wait_time_ms DESC',
    @definition = N'CREATE OR ALTER FUNCTION dbo.HC_session_waits
(
    @spid int = 55
)
RETURNS TABLE
AS
-- Toolkit 01_wait_stats.sql section 1.4: WAIT STATS FOR ONE SESSION (2016+)
RETURN
(
SELECT session_id, wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms
FROM sys.dm_exec_session_wait_stats
WHERE session_id = @spid
);
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_session_waits
    @spid int = 55
AS
-- Toolkit 01_wait_stats.sql section 1.4: WAIT STATS FOR ONE SESSION (2016+)
SET NOCOUNT ON;
SELECT session_id, wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms
FROM sys.dm_exec_session_wait_stats
WHERE session_id = @spid
ORDER BY wait_time_ms DESC;
';
GO

/* 1.5  SIGNAL WAIT % (CPU PRESSURE INDICATOR)   (01_wait_stats.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_signal_waits', @section = N'1.5', @source_file = N'01_wait_stats.sql',
    @title = N'SIGNAL WAIT % (CPU PRESSURE INDICATOR)', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_signal_waits;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_signal_waits
AS
-- Toolkit 01_wait_stats.sql section 1.5: SIGNAL WAIT % (CPU PRESSURE INDICATOR)
SELECT
    CAST(100.0 * SUM(signal_wait_time_ms) / SUM(wait_time_ms) AS decimal(5,2))                       AS signal_wait_pct,
    CAST(100.0 * SUM(wait_time_ms - signal_wait_time_ms) / SUM(wait_time_ms) AS decimal(5,2))        AS resource_wait_pct
FROM sys.dm_os_wait_stats
WHERE wait_time_ms > 0;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_signal_waits
AS
-- Toolkit 01_wait_stats.sql section 1.5: SIGNAL WAIT % (CPU PRESSURE INDICATOR)
SET NOCOUNT ON;
SELECT
    CAST(100.0 * SUM(signal_wait_time_ms) / SUM(wait_time_ms) AS decimal(5,2))                       AS signal_wait_pct,
    CAST(100.0 * SUM(wait_time_ms - signal_wait_time_ms) / SUM(wait_time_ms) AS decimal(5,2))        AS resource_wait_pct
FROM sys.dm_os_wait_stats
WHERE wait_time_ms > 0;
';
GO

/* 1.6  LATCH STATS (non-buffer latches)   (01_wait_stats.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_latch_stats', @section = N'1.6', @source_file = N'01_wait_stats.sql',
    @title = N'LATCH STATS (non-buffer latches)', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_latch_stats ORDER BY wait_time_ms DESC;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_latch_stats
AS
-- Toolkit 01_wait_stats.sql section 1.6: LATCH STATS (non-buffer latches)
SELECT TOP (15) latch_class, waiting_requests_count, wait_time_ms, max_wait_time_ms,
       CAST(wait_time_ms * 1.0 / NULLIF(waiting_requests_count,0) AS decimal(18,2)) AS avg_wait_ms
FROM sys.dm_os_latch_stats
WHERE latch_class NOT IN (N''BUFFER'')
ORDER BY wait_time_ms DESC;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_latch_stats
AS
-- Toolkit 01_wait_stats.sql section 1.6: LATCH STATS (non-buffer latches)
SET NOCOUNT ON;
SELECT TOP (15) latch_class, waiting_requests_count, wait_time_ms, max_wait_time_ms,
       CAST(wait_time_ms * 1.0 / NULLIF(waiting_requests_count,0) AS decimal(18,2)) AS avg_wait_ms
FROM sys.dm_os_latch_stats
WHERE latch_class NOT IN (N''BUFFER'')
ORDER BY wait_time_ms DESC;
';
GO

/* 2.1  ACTIVE REQUESTS ("sp_who2 on steroids")   (02_sessions_blocking.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_active_sessions', @section = N'2.1', @source_file = N'02_sessions_blocking.sql',
    @title = N'ACTIVE REQUESTS ("sp_who2 on steroids")', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_active_sessions ORDER BY elapsed_s DESC;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY r.total_elapsed_time DESC',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_active_sessions
AS
-- Toolkit 02_sessions_blocking.sql section 2.1: ACTIVE REQUESTS ("sp_who2 on steroids")
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
    OBJECT_SCHEMA_NAME(t.objectid, t.dbid) + N''.'' + OBJECT_NAME(t.objectid, t.dbid) AS object_name,
    t.text                                           AS batch_text,
    qp.query_plan                                    AS estimated_plan
FROM sys.dm_exec_requests AS r
JOIN sys.dm_exec_sessions AS s ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle)  AS t
OUTER APPLY sys.dm_exec_query_plan(r.plan_handle) AS qp
WHERE s.is_user_process = 1
  AND r.session_id <> @@SPID;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_active_sessions
AS
-- Toolkit 02_sessions_blocking.sql section 2.1: ACTIVE REQUESTS ("sp_who2 on steroids")
SET NOCOUNT ON;
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
    OBJECT_SCHEMA_NAME(t.objectid, t.dbid) + N''.'' + OBJECT_NAME(t.objectid, t.dbid) AS object_name,
    t.text                                           AS batch_text,
    qp.query_plan                                    AS estimated_plan
FROM sys.dm_exec_requests AS r
JOIN sys.dm_exec_sessions AS s ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle)  AS t
OUTER APPLY sys.dm_exec_query_plan(r.plan_handle) AS qp
WHERE s.is_user_process = 1
  AND r.session_id <> @@SPID
ORDER BY r.total_elapsed_time DESC;
';
GO

/* 2.2  LIVE (IN-FLIGHT) ACTUAL PLAN FOR A SESSION 2016 SP1+   (02_sessions_blocking.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_live_plan', @section = N'2.2', @source_file = N'02_sessions_blocking.sql',
    @title = N'LIVE (IN-FLIGHT) ACTUAL PLAN FOR A SESSION 2016 SP1+', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_live_plan @spid = 55;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_live_plan
    @spid int = 55
AS
-- Toolkit 02_sessions_blocking.sql section 2.2: LIVE (IN-FLIGHT) ACTUAL PLAN FOR A SESSION 2016 SP1+
SET NOCOUNT ON;
SELECT session_id, query_plan
FROM sys.dm_exec_query_statistics_xml(@spid);

SELECT session_id, node_id, physical_operator_name, row_count, estimate_row_count,
       elapsed_time_ms, cpu_time_ms, logical_read_count
FROM sys.dm_exec_query_profiles
WHERE session_id = @spid
ORDER BY node_id;
',
    @fallback_definition = NULL;
GO

/* 2.3  BLOCKING TREE (head blocker at top, victims indented)   (02_sessions_blocking.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_blocking_tree', @section = N'2.3', @source_file = N'02_sessions_blocking.sql',
    @title = N'BLOCKING TREE (head blocker at top, victims indented)', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_blocking_tree;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_blocking_tree
AS
-- Toolkit 02_sessions_blocking.sql section 2.3: BLOCKING TREE (head blocker at top, victims indented)
SET NOCOUNT ON;
IF OBJECT_ID(''tempdb..#blk'') IS NOT NULL DROP TABLE #blk;

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

    SELECT b.session_id, b.blocking_session_id, 0 AS lvl,
           CAST(RIGHT(''00000'' + CAST(b.session_id AS varchar(10)), 5) AS varchar(4000)) AS sort_path
    FROM #blk AS b
    WHERE b.blocking_session_id = 0
      AND EXISTS (SELECT 1 FROM #blk AS x WHERE x.blocking_session_id = b.session_id
                                            AND x.session_id <> b.session_id)
    UNION ALL
    SELECT b.session_id, b.blocking_session_id, c.lvl + 1,
           CAST(c.sort_path + ''>'' + RIGHT(''00000'' + CAST(b.session_id AS varchar(10)), 5) AS varchar(4000))
    FROM #blk AS b
    JOIN chain AS c ON b.blocking_session_id = c.session_id
    WHERE b.session_id <> b.blocking_session_id
)
SELECT
    REPLICATE(''    '', c.lvl) + CAST(c.session_id AS varchar(10)) AS blocking_tree,
    CASE WHEN c.lvl = 0 THEN ''HEAD BLOCKER'' ELSE '''' END       AS role,
    b.status, b.wait_type, b.wait_ms, b.wait_resource,
    b.login_name, b.host_name, b.program_name, b.database_name,
    b.open_transaction_count,
    COALESCE(b.running_sql, ib.event_info)                    AS sql_text
FROM chain AS c
JOIN #blk AS b ON b.session_id = c.session_id
OUTER APPLY sys.dm_exec_input_buffer(c.session_id, NULL) AS ib
ORDER BY c.sort_path
OPTION (MAXRECURSION 200);
',
    @fallback_definition = NULL;
GO

/* 2.4  QUICK BLOCKING SUMMARY (how many victims per blocker)   (02_sessions_blocking.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_blocking_summary', @section = N'2.4', @source_file = N'02_sessions_blocking.sql',
    @title = N'QUICK BLOCKING SUMMARY (how many victims per blocker)', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_blocking_summary ORDER BY sessions_blocked DESC;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY sessions_blocked DESC',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_blocking_summary
AS
-- Toolkit 02_sessions_blocking.sql section 2.4: QUICK BLOCKING SUMMARY (how many victims per blocker)
SELECT r.blocking_session_id      AS blocker,
       COUNT(*)                   AS sessions_blocked,
       MAX(r.wait_time) / 1000    AS longest_wait_s,
       MIN(r.wait_type)           AS sample_wait_type
FROM sys.dm_exec_requests AS r
WHERE r.blocking_session_id > 0
GROUP BY r.blocking_session_id;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_blocking_summary
AS
-- Toolkit 02_sessions_blocking.sql section 2.4: QUICK BLOCKING SUMMARY (how many victims per blocker)
SET NOCOUNT ON;
SELECT r.blocking_session_id      AS blocker,
       COUNT(*)                   AS sessions_blocked,
       MAX(r.wait_time) / 1000    AS longest_wait_s,
       MIN(r.wait_type)           AS sample_wait_type
FROM sys.dm_exec_requests AS r
WHERE r.blocking_session_id > 0
GROUP BY r.blocking_session_id
ORDER BY sessions_blocked DESC;
';
GO

/* 2.5  OPEN TRANSACTIONS (oldest first) - log growth / blocking culprits   (02_sessions_blocking.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_open_transactions', @section = N'2.5', @source_file = N'02_sessions_blocking.sql',
    @title = N'OPEN TRANSACTIONS (oldest first) - log growth / blocking culprits', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_open_transactions;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_open_transactions
AS
-- Toolkit 02_sessions_blocking.sql section 2.5: OPEN TRANSACTIONS (oldest first) - log growth / blocking culprits
SET NOCOUNT ON;
SELECT
    st.session_id,
    s.login_name, s.host_name, s.program_name, s.status AS session_status,
    at.transaction_id, at.name AS tran_name,
    at.transaction_begin_time,
    DATEDIFF(SECOND, at.transaction_begin_time, SYSDATETIME()) AS open_seconds,
    CASE at.transaction_state
        WHEN 0 THEN ''Not initialized'' WHEN 1 THEN ''Initialized, not started''
        WHEN 2 THEN ''Active''          WHEN 3 THEN ''Ended (read-only)''
        WHEN 4 THEN ''Commit initiated (DTC)'' WHEN 5 THEN ''Prepared''
        WHEN 6 THEN ''Committed''       WHEN 7 THEN ''Rolling back''
        WHEN 8 THEN ''Rolled back'' END                  AS tran_state,
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
',
    @fallback_definition = NULL;
GO

/* 2.6  SLEEPING SESSIONS HOLDING OPEN TRANSACTIONS (forgotten COMMITs)   (02_sessions_blocking.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_sleeping_open_trans', @section = N'2.6', @source_file = N'02_sessions_blocking.sql',
    @title = N'SLEEPING SESSIONS HOLDING OPEN TRANSACTIONS (forgotten COMMITs)', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_sleeping_open_trans ORDER BY last_request_end_time;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY s.last_request_end_time',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_sleeping_open_trans
AS
-- Toolkit 02_sessions_blocking.sql section 2.6: SLEEPING SESSIONS HOLDING OPEN TRANSACTIONS (forgotten COMMITs)
SELECT s.session_id, s.login_name, s.host_name, s.program_name,
       s.open_transaction_count, s.last_request_end_time,
       DATEDIFF(MINUTE, s.last_request_end_time, SYSDATETIME()) AS idle_minutes,
       ib.event_info AS last_sql
FROM sys.dm_exec_sessions AS s
OUTER APPLY sys.dm_exec_input_buffer(s.session_id, NULL) AS ib
WHERE s.status = ''sleeping''
  AND s.open_transaction_count > 0;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_sleeping_open_trans
AS
-- Toolkit 02_sessions_blocking.sql section 2.6: SLEEPING SESSIONS HOLDING OPEN TRANSACTIONS (forgotten COMMITs)
SET NOCOUNT ON;
SELECT s.session_id, s.login_name, s.host_name, s.program_name,
       s.open_transaction_count, s.last_request_end_time,
       DATEDIFF(MINUTE, s.last_request_end_time, SYSDATETIME()) AS idle_minutes,
       ib.event_info AS last_sql
FROM sys.dm_exec_sessions AS s
OUTER APPLY sys.dm_exec_input_buffer(s.session_id, NULL) AS ib
WHERE s.status = ''sleeping''
  AND s.open_transaction_count > 0
ORDER BY s.last_request_end_time;
';
GO

/* 2.7  CONNECTION DETAILS (IP, protocol, encryption, auth)   (02_sessions_blocking.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_connection_details', @section = N'2.7', @source_file = N'02_sessions_blocking.sql',
    @title = N'CONNECTION DETAILS (IP, protocol, encryption, auth)', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_connection_details ORDER BY connect_time;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY c.connect_time',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_connection_details
AS
-- Toolkit 02_sessions_blocking.sql section 2.7: CONNECTION DETAILS (IP, protocol, encryption, auth)
SELECT c.session_id, s.login_name, s.host_name, s.program_name,
       c.client_net_address, c.local_net_address, c.local_tcp_port,
       c.net_transport, c.protocol_type, c.encrypt_option, c.auth_scheme,
       c.connect_time, s.last_request_start_time
FROM sys.dm_exec_connections AS c
JOIN sys.dm_exec_sessions    AS s ON s.session_id = c.session_id;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_connection_details
AS
-- Toolkit 02_sessions_blocking.sql section 2.7: CONNECTION DETAILS (IP, protocol, encryption, auth)
SET NOCOUNT ON;
SELECT c.session_id, s.login_name, s.host_name, s.program_name,
       c.client_net_address, c.local_net_address, c.local_tcp_port,
       c.net_transport, c.protocol_type, c.encrypt_option, c.auth_scheme,
       c.connect_time, s.last_request_start_time
FROM sys.dm_exec_connections AS c
JOIN sys.dm_exec_sessions    AS s ON s.session_id = c.session_id
ORDER BY c.connect_time;
';
GO

/* 2.8  LAST SQL SENT BY A SESSION   (02_sessions_blocking.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_last_sql_by_session', @section = N'2.8', @source_file = N'02_sessions_blocking.sql',
    @title = N'LAST SQL SENT BY A SESSION', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_last_sql_by_session(DEFAULT);  -- @spid = 55',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER FUNCTION dbo.HC_last_sql_by_session
(
    @spid int = 55
)
RETURNS TABLE
AS
-- Toolkit 02_sessions_blocking.sql section 2.8: LAST SQL SENT BY A SESSION
RETURN
(
SELECT event_type, parameters, event_info FROM sys.dm_exec_input_buffer(@spid, NULL)
);
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_last_sql_by_session
    @spid int = 55
AS
-- Toolkit 02_sessions_blocking.sql section 2.8: LAST SQL SENT BY A SESSION
SET NOCOUNT ON;
SELECT event_type, parameters, event_info FROM sys.dm_exec_input_buffer(@spid, NULL);
';
GO

/* 2.9  ROLLBACK / KILL PROGRESS   (02_sessions_blocking.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_rollback_progress', @section = N'2.9', @source_file = N'02_sessions_blocking.sql',
    @title = N'ROLLBACK / KILL PROGRESS', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_rollback_progress;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_rollback_progress
AS
-- Toolkit 02_sessions_blocking.sql section 2.9: ROLLBACK / KILL PROGRESS
SELECT session_id, command, status, percent_complete,
       estimated_completion_time / 60000 AS est_minutes_left,
       total_elapsed_time / 60000        AS elapsed_minutes
FROM sys.dm_exec_requests
WHERE command IN (''KILLED/ROLLBACK'', ''ROLLBACK TRANSACTION'')
   OR status = ''rollback'';
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_rollback_progress
AS
-- Toolkit 02_sessions_blocking.sql section 2.9: ROLLBACK / KILL PROGRESS
SET NOCOUNT ON;
SELECT session_id, command, status, percent_complete,
       estimated_completion_time / 60000 AS est_minutes_left,
       total_elapsed_time / 60000        AS elapsed_minutes
FROM sys.dm_exec_requests
WHERE command IN (''KILLED/ROLLBACK'', ''ROLLBACK TRANSACTION'')
   OR status = ''rollback'';
';
GO

/* 2.10  GENERATE KILL FOR HEAD BLOCKERS (review before running!)   (02_sessions_blocking.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_generate_kill_head_blockers', @section = N'2.10', @source_file = N'02_sessions_blocking.sql',
    @title = N'GENERATE KILL FOR HEAD BLOCKERS (review before running!)', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_generate_kill_head_blockers;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_generate_kill_head_blockers
AS
-- Toolkit 02_sessions_blocking.sql section 2.10: GENERATE KILL FOR HEAD BLOCKERS (review before running!)
SELECT DISTINCT ''KILL '' + CAST(r.blocking_session_id AS varchar(10)) + '';'' AS kill_cmd
FROM sys.dm_exec_requests AS r
WHERE r.blocking_session_id > 0
  AND r.blocking_session_id NOT IN (SELECT session_id FROM sys.dm_exec_requests
                                    WHERE blocking_session_id > 0);
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_generate_kill_head_blockers
AS
-- Toolkit 02_sessions_blocking.sql section 2.10: GENERATE KILL FOR HEAD BLOCKERS (review before running!)
SET NOCOUNT ON;
SELECT DISTINCT ''KILL '' + CAST(r.blocking_session_id AS varchar(10)) + '';'' AS kill_cmd
FROM sys.dm_exec_requests AS r
WHERE r.blocking_session_id > 0
  AND r.blocking_session_id NOT IN (SELECT session_id FROM sys.dm_exec_requests
                                    WHERE blocking_session_id > 0);
';
GO

/* 3.1  TOP N STATEMENTS - CHOOSE THE SORT   (03_query_performance_plan_cache.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_top_queries', @section = N'3.1', @source_file = N'03_query_performance_plan_cache.sql',
    @title = N'TOP N STATEMENTS - CHOOSE THE SORT', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_top_queries @sort_by = ''CPU'', @top = 25;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_top_queries
    @sort_by varchar(10) = ''CPU'',
    @top int = 25
AS
-- Toolkit 03_query_performance_plan_cache.sql section 3.1: TOP N STATEMENTS - CHOOSE THE SORT
SET NOCOUNT ON;
SELECT TOP (@top)
    DB_NAME(t.dbid)                                         AS database_name,
    OBJECT_SCHEMA_NAME(t.objectid, t.dbid) + N''.'' + OBJECT_NAME(t.objectid, t.dbid) AS object_name,
    qs.execution_count,
    qs.total_worker_time / 1000                             AS total_cpu_ms,
    qs.total_worker_time / qs.execution_count / 1000        AS avg_cpu_ms,
    qs.total_elapsed_time / qs.execution_count / 1000       AS avg_duration_ms,
    qs.total_logical_reads / qs.execution_count             AS avg_logical_reads,
    qs.total_logical_writes / qs.execution_count            AS avg_logical_writes,
    qs.total_physical_reads / qs.execution_count            AS avg_physical_reads,
    qs.total_rows / qs.execution_count                      AS avg_rows,
    qs.total_grant_kb / qs.execution_count / 1024           AS avg_grant_mb,
    qs.total_spills / qs.execution_count                    AS avg_spills,
    qs.creation_time                                        AS plan_cached_at,
    qs.last_execution_time,
    SUBSTRING(t.text, (qs.statement_start_offset / 2) + 1,
        ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(t.text)
          ELSE qs.statement_end_offset END - qs.statement_start_offset) / 2) + 1) AS statement_text,
    qs.query_hash, qs.query_plan_hash, qs.plan_handle,
    qp.query_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)      AS t
OUTER APPLY sys.dm_exec_query_plan(qs.plan_handle)   AS qp
ORDER BY
    CASE @sort_by
        WHEN ''CPU''      THEN qs.total_worker_time
        WHEN ''READS''    THEN qs.total_logical_reads
        WHEN ''WRITES''   THEN qs.total_logical_writes
        WHEN ''DURATION'' THEN qs.total_elapsed_time
        WHEN ''EXECS''    THEN qs.execution_count
        WHEN ''GRANT''    THEN qs.total_grant_kb
        WHEN ''SPILLS''   THEN qs.total_spills
    END DESC;
',
    @fallback_definition = NULL;
GO

/* 3.2  TOP STORED PROCEDURES   (03_query_performance_plan_cache.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_top_procedures', @section = N'3.2', @source_file = N'03_query_performance_plan_cache.sql',
    @title = N'TOP STORED PROCEDURES', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_top_procedures ORDER BY total_cpu_ms DESC;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_top_procedures
AS
-- Toolkit 03_query_performance_plan_cache.sql section 3.2: TOP STORED PROCEDURES
SELECT TOP (25)
    DB_NAME(ps.database_id)                               AS database_name,
    OBJECT_SCHEMA_NAME(ps.object_id, ps.database_id) + N''.'' + OBJECT_NAME(ps.object_id, ps.database_id) AS proc_name,
    ps.execution_count,
    ps.total_worker_time / 1000                           AS total_cpu_ms,
    ps.total_worker_time / ps.execution_count / 1000      AS avg_cpu_ms,
    ps.total_elapsed_time / ps.execution_count / 1000     AS avg_duration_ms,
    ps.total_logical_reads / ps.execution_count           AS avg_logical_reads,
    ps.cached_time, ps.last_execution_time
FROM sys.dm_exec_procedure_stats AS ps
ORDER BY ps.total_worker_time DESC;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_top_procedures
AS
-- Toolkit 03_query_performance_plan_cache.sql section 3.2: TOP STORED PROCEDURES
SET NOCOUNT ON;
SELECT TOP (25)
    DB_NAME(ps.database_id)                               AS database_name,
    OBJECT_SCHEMA_NAME(ps.object_id, ps.database_id) + N''.'' + OBJECT_NAME(ps.object_id, ps.database_id) AS proc_name,
    ps.execution_count,
    ps.total_worker_time / 1000                           AS total_cpu_ms,
    ps.total_worker_time / ps.execution_count / 1000      AS avg_cpu_ms,
    ps.total_elapsed_time / ps.execution_count / 1000     AS avg_duration_ms,
    ps.total_logical_reads / ps.execution_count           AS avg_logical_reads,
    ps.cached_time, ps.last_execution_time
FROM sys.dm_exec_procedure_stats AS ps
ORDER BY ps.total_worker_time DESC;
';
GO

/* 3.3  TOP QUERIES AGGREGATED BY query_hash   (03_query_performance_plan_cache.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_top_query_hash', @section = N'3.3', @source_file = N'03_query_performance_plan_cache.sql',
    @title = N'TOP QUERIES AGGREGATED BY query_hash', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_top_query_hash ORDER BY total_cpu_ms DESC;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_top_query_hash
AS
-- Toolkit 03_query_performance_plan_cache.sql section 3.3: TOP QUERIES AGGREGATED BY query_hash
SELECT TOP (25)
    qs.query_hash,
    COUNT(*)                                      AS cached_plan_entries,
    SUM(qs.execution_count)                       AS executions,
    SUM(qs.total_worker_time) / 1000              AS total_cpu_ms,
    SUM(qs.total_logical_reads)                   AS total_reads,
    MAX(CAST(SUBSTRING(t.text, (qs.statement_start_offset / 2) + 1, 4000) AS nvarchar(4000))) AS sample_text
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
GROUP BY qs.query_hash
ORDER BY total_cpu_ms DESC;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_top_query_hash
AS
-- Toolkit 03_query_performance_plan_cache.sql section 3.3: TOP QUERIES AGGREGATED BY query_hash
SET NOCOUNT ON;
SELECT TOP (25)
    qs.query_hash,
    COUNT(*)                                      AS cached_plan_entries,
    SUM(qs.execution_count)                       AS executions,
    SUM(qs.total_worker_time) / 1000              AS total_cpu_ms,
    SUM(qs.total_logical_reads)                   AS total_reads,
    MAX(CAST(SUBSTRING(t.text, (qs.statement_start_offset / 2) + 1, 4000) AS nvarchar(4000))) AS sample_text
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
GROUP BY qs.query_hash
ORDER BY total_cpu_ms DESC;
';
GO

/* 3.4  PARAMETER SNIFFING SUSPECTS (large min/max variance)   (03_query_performance_plan_cache.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_param_sniffing_suspects', @section = N'3.4', @source_file = N'03_query_performance_plan_cache.sql',
    @title = N'PARAMETER SNIFFING SUSPECTS (large min/max variance)', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_param_sniffing_suspects;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_param_sniffing_suspects
AS
-- Toolkit 03_query_performance_plan_cache.sql section 3.4: PARAMETER SNIFFING SUSPECTS (large min/max variance)
SELECT TOP (25)
    DB_NAME(t.dbid) AS database_name,
    OBJECT_NAME(t.objectid, t.dbid) AS object_name,
    qs.execution_count,
    qs.min_worker_time / 1000  AS min_cpu_ms,
    qs.max_worker_time / 1000  AS max_cpu_ms,
    qs.min_logical_reads, qs.max_logical_reads,
    qs.min_rows, qs.max_rows,
    SUBSTRING(t.text, (qs.statement_start_offset / 2) + 1,
        ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(t.text)
          ELSE qs.statement_end_offset END - qs.statement_start_offset) / 2) + 1) AS statement_text,
    qs.plan_handle
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
WHERE qs.execution_count > 10
  AND qs.max_logical_reads > 10 * (qs.min_logical_reads + 1)
ORDER BY qs.max_logical_reads - qs.min_logical_reads DESC;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_param_sniffing_suspects
AS
-- Toolkit 03_query_performance_plan_cache.sql section 3.4: PARAMETER SNIFFING SUSPECTS (large min/max variance)
SET NOCOUNT ON;
SELECT TOP (25)
    DB_NAME(t.dbid) AS database_name,
    OBJECT_NAME(t.objectid, t.dbid) AS object_name,
    qs.execution_count,
    qs.min_worker_time / 1000  AS min_cpu_ms,
    qs.max_worker_time / 1000  AS max_cpu_ms,
    qs.min_logical_reads, qs.max_logical_reads,
    qs.min_rows, qs.max_rows,
    SUBSTRING(t.text, (qs.statement_start_offset / 2) + 1,
        ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(t.text)
          ELSE qs.statement_end_offset END - qs.statement_start_offset) / 2) + 1) AS statement_text,
    qs.plan_handle
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
WHERE qs.execution_count > 10
  AND qs.max_logical_reads > 10 * (qs.min_logical_reads + 1)
ORDER BY qs.max_logical_reads - qs.min_logical_reads DESC;
';
GO

/* 3.5  FIND A QUERY IN CACHE BY TEXT   (03_query_performance_plan_cache.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_find_query_in_cache', @section = N'3.5', @source_file = N'03_query_performance_plan_cache.sql',
    @title = N'FIND A QUERY IN CACHE BY TEXT', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_find_query_in_cache(DEFAULT) ORDER BY last_execution_time DESC;  -- @search_text = N''%YourTableOrProcName%''',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER FUNCTION dbo.HC_find_query_in_cache
(
    @search_text nvarchar(200) = N''%YourTableOrProcName%''
)
RETURNS TABLE
AS
-- Toolkit 03_query_performance_plan_cache.sql section 3.5: FIND A QUERY IN CACHE BY TEXT
RETURN
(
SELECT TOP (50)
    DB_NAME(t.dbid) AS database_name, qs.execution_count,
    qs.total_worker_time / qs.execution_count / 1000 AS avg_cpu_ms,
    qs.last_execution_time, t.text, qs.plan_handle, qp.query_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS t
OUTER APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE t.text LIKE @search_text
  AND t.text NOT LIKE N''%dm_exec_query_stats%''
ORDER BY qs.last_execution_time DESC
);
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_find_query_in_cache
    @search_text nvarchar(200) = N''%YourTableOrProcName%''
AS
-- Toolkit 03_query_performance_plan_cache.sql section 3.5: FIND A QUERY IN CACHE BY TEXT
SET NOCOUNT ON;
SELECT TOP (50)
    DB_NAME(t.dbid) AS database_name, qs.execution_count,
    qs.total_worker_time / qs.execution_count / 1000 AS avg_cpu_ms,
    qs.last_execution_time, t.text, qs.plan_handle, qp.query_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS t
OUTER APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE t.text LIKE @search_text
  AND t.text NOT LIKE N''%dm_exec_query_stats%''
ORDER BY qs.last_execution_time DESC;
';
GO

/* 3.6  PLAN CACHE COMPOSITION & SINGLE-USE PLAN BLOAT   (03_query_performance_plan_cache.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_plan_cache_bloat', @section = N'3.6', @source_file = N'03_query_performance_plan_cache.sql',
    @title = N'PLAN CACHE COMPOSITION & SINGLE-USE PLAN BLOAT', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_plan_cache_bloat ORDER BY total_mb DESC;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY total_mb DESC',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_plan_cache_bloat
AS
-- Toolkit 03_query_performance_plan_cache.sql section 3.6: PLAN CACHE COMPOSITION & SINGLE-USE PLAN BLOAT
SELECT cp.objtype, cp.cacheobjtype,
       COUNT(*)                                                    AS plan_count,
       SUM(CAST(cp.size_in_bytes AS bigint)) / 1048576             AS total_mb,
       SUM(CASE WHEN cp.usecounts = 1 THEN 1 ELSE 0 END)           AS single_use_plans,
       SUM(CASE WHEN cp.usecounts = 1 THEN CAST(cp.size_in_bytes AS bigint) ELSE 0 END) / 1048576 AS single_use_mb
FROM sys.dm_exec_cached_plans AS cp
GROUP BY cp.objtype, cp.cacheobjtype;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_plan_cache_bloat
AS
-- Toolkit 03_query_performance_plan_cache.sql section 3.6: PLAN CACHE COMPOSITION & SINGLE-USE PLAN BLOAT
SET NOCOUNT ON;
SELECT cp.objtype, cp.cacheobjtype,
       COUNT(*)                                                    AS plan_count,
       SUM(CAST(cp.size_in_bytes AS bigint)) / 1048576             AS total_mb,
       SUM(CASE WHEN cp.usecounts = 1 THEN 1 ELSE 0 END)           AS single_use_plans,
       SUM(CASE WHEN cp.usecounts = 1 THEN CAST(cp.size_in_bytes AS bigint) ELSE 0 END) / 1048576 AS single_use_mb
FROM sys.dm_exec_cached_plans AS cp
GROUP BY cp.objtype, cp.cacheobjtype
ORDER BY total_mb DESC;
';
GO

/* 3.7  PLANS WITH IMPLICIT CONVERSIONS / MISSING INDEX / WARNINGS   (03_query_performance_plan_cache.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_plan_warnings', @section = N'3.7', @source_file = N'03_query_performance_plan_cache.sql',
    @title = N'PLANS WITH IMPLICIT CONVERSIONS / MISSING INDEX / WARNINGS', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_plan_warnings ORDER BY total_cpu_ms DESC;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_plan_warnings
AS
-- Toolkit 03_query_performance_plan_cache.sql section 3.7: PLANS WITH IMPLICIT CONVERSIONS / MISSING INDEX / WARNINGS
WITH XMLNAMESPACES (DEFAULT ''http://schemas.microsoft.com/sqlserver/2004/07/showplan'')
SELECT TOP (50)
    DB_NAME(t.dbid)                                                         AS database_name,
    qs.execution_count,
    qs.total_worker_time / 1000                                             AS total_cpu_ms,
    qp.query_plan.exist(''//PlanAffectingConvert'')                           AS has_implicit_convert,
    qp.query_plan.exist(''//MissingIndexes'')                                 AS has_missing_index,
    qp.query_plan.exist(''//Warnings/SpillToTempDb'')                         AS has_spill,
    qp.query_plan.exist(''//Warnings/NoJoinPredicate'')                       AS has_no_join_predicate,
    t.text, qp.query_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS t
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE qp.query_plan.exist(''//PlanAffectingConvert'') = 1
   OR qp.query_plan.exist(''//Warnings'') = 1
ORDER BY qs.total_worker_time DESC;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_plan_warnings
AS
-- Toolkit 03_query_performance_plan_cache.sql section 3.7: PLANS WITH IMPLICIT CONVERSIONS / MISSING INDEX / WARNINGS
SET NOCOUNT ON;
WITH XMLNAMESPACES (DEFAULT ''http://schemas.microsoft.com/sqlserver/2004/07/showplan'')
SELECT TOP (50)
    DB_NAME(t.dbid)                                                         AS database_name,
    qs.execution_count,
    qs.total_worker_time / 1000                                             AS total_cpu_ms,
    qp.query_plan.exist(''//PlanAffectingConvert'')                           AS has_implicit_convert,
    qp.query_plan.exist(''//MissingIndexes'')                                 AS has_missing_index,
    qp.query_plan.exist(''//Warnings/SpillToTempDb'')                         AS has_spill,
    qp.query_plan.exist(''//Warnings/NoJoinPredicate'')                       AS has_no_join_predicate,
    t.text, qp.query_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS t
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE qp.query_plan.exist(''//PlanAffectingConvert'') = 1
   OR qp.query_plan.exist(''//Warnings'') = 1
ORDER BY qs.total_worker_time DESC;
';
GO

/* 3.8  RECOMPILES / COMPILATIONS RATE   (03_query_performance_plan_cache.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_compilations', @section = N'3.8', @source_file = N'03_query_performance_plan_cache.sql',
    @title = N'RECOMPILES / COMPILATIONS RATE', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_compilations;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_compilations
AS
-- Toolkit 03_query_performance_plan_cache.sql section 3.8: RECOMPILES / COMPILATIONS RATE
SELECT counter_name, cntr_value
FROM sys.dm_os_performance_counters
WHERE object_name LIKE N''%SQL Statistics%''
  AND counter_name IN (N''Batch Requests/sec'', N''SQL Compilations/sec'', N''SQL Re-Compilations/sec'');
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_compilations
AS
-- Toolkit 03_query_performance_plan_cache.sql section 3.8: RECOMPILES / COMPILATIONS RATE
SET NOCOUNT ON;
SELECT counter_name, cntr_value
FROM sys.dm_os_performance_counters
WHERE object_name LIKE N''%SQL Statistics%''
  AND counter_name IN (N''Batch Requests/sec'', N''SQL Compilations/sec'', N''SQL Re-Compilations/sec'');
';
GO

/* 4.1  QUERY STORE STATUS - CURRENT DB   (04_query_store.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_qs_status', @section = N'4.1', @source_file = N'04_query_store.sql',
    @title = N'QUERY STORE STATUS - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_qs_status @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_qs_status
    @database_name sysname = NULL
AS
-- Toolkit 04_query_store.sql section 4.1: QUERY STORE STATUS - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT DB_NAME()                     AS database_name,
       desired_state_desc, actual_state_desc, readonly_reason,
       current_storage_size_mb, max_storage_size_mb,
       query_capture_mode_desc, size_based_cleanup_mode_desc,
       stale_query_threshold_days, interval_length_minutes,
       flush_interval_seconds, max_plans_per_query, wait_stats_capture_mode_desc
FROM sys.database_query_store_options;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 4.2  QUERY STORE STATUS - ALL DATABASES   (04_query_store.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_qs_status_all_dbs', @section = N'4.2', @source_file = N'04_query_store.sql',
    @title = N'QUERY STORE STATUS - ALL DATABASES', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_qs_status_all_dbs ORDER BY name;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY name',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_qs_status_all_dbs
AS
-- Toolkit 04_query_store.sql section 4.2: QUERY STORE STATUS - ALL DATABASES
SELECT name, is_query_store_on FROM sys.databases WHERE database_id > 4;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_qs_status_all_dbs
AS
-- Toolkit 04_query_store.sql section 4.2: QUERY STORE STATUS - ALL DATABASES
SET NOCOUNT ON;
SELECT name, is_query_store_on FROM sys.databases WHERE database_id > 4 ORDER BY name;
';
GO

/* 4.3  TOP QUERIES IN LAST N HOURS (choose metric)   (04_query_store.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_qs_top_queries', @section = N'4.3', @source_file = N'04_query_store.sql',
    @title = N'TOP QUERIES IN LAST N HOURS (choose metric)', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_qs_top_queries @database_name = N''YourDB'', @hours = 24, @metric = ''CPU'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_qs_top_queries
    @database_name sysname = NULL,
    @hours int = 24,
    @metric varchar(10) = ''CPU''
AS
-- Toolkit 04_query_store.sql section 4.3: TOP QUERIES IN LAST N HOURS (choose metric)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''WITH agg AS (
    SELECT
        q.query_id,
        SUM(rs.count_executions)                                       AS execs,
        SUM(rs.avg_cpu_time        * rs.count_executions) / 1000.0     AS total_cpu_ms,
        SUM(rs.avg_duration        * rs.count_executions) / 1000.0     AS total_duration_ms,
        SUM(rs.avg_logical_io_reads* rs.count_executions)              AS total_reads,
        SUM(rs.avg_query_max_used_memory * rs.count_executions) * 8 / 1024.0 AS total_mem_mb,
        COUNT(DISTINCT p.plan_id)                                      AS plan_count
    FROM sys.query_store_runtime_stats          AS rs
    JOIN sys.query_store_runtime_stats_interval AS i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
    JOIN sys.query_store_plan                   AS p ON p.plan_id = rs.plan_id
    JOIN sys.query_store_query                  AS q ON q.query_id = p.query_id
    WHERE i.start_time >= DATEADD(HOUR, -@hours, SYSDATETIMEOFFSET())
    GROUP BY q.query_id
)
SELECT TOP (25)
    a.query_id,
    OBJECT_SCHEMA_NAME(q.object_id) + N''''.'''' + OBJECT_NAME(q.object_id) AS object_name,
    a.execs, a.plan_count,
    CAST(a.total_cpu_ms                AS decimal(18,0)) AS total_cpu_ms,
    CAST(a.total_cpu_ms / a.execs      AS decimal(18,2)) AS avg_cpu_ms,
    CAST(a.total_duration_ms / a.execs AS decimal(18,2)) AS avg_duration_ms,
    CAST(a.total_reads / a.execs       AS decimal(18,0)) AS avg_reads,
    qt.query_sql_text
FROM agg AS a
JOIN sys.query_store_query      AS q  ON q.query_id = a.query_id
JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
ORDER BY CASE @metric
            WHEN ''''CPU''''      THEN a.total_cpu_ms
            WHEN ''''DURATION'''' THEN a.total_duration_ms
            WHEN ''''READS''''    THEN a.total_reads
            WHEN ''''EXECS''''    THEN a.execs
            WHEN ''''MEMORY''''   THEN a.total_mem_mb END DESC;'';
EXEC @hc_exec @hc_sql, N''@hours int, @metric varchar(10)'', @hours = @hours, @metric = @metric;
',
    @fallback_definition = NULL;
GO

/* 4.4  REGRESSED QUERIES: RECENT vs HISTORY (avg duration)   (04_query_store.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_qs_regressed', @section = N'4.4', @source_file = N'04_query_store.sql',
    @title = N'REGRESSED QUERIES: RECENT vs HISTORY (avg duration)', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_qs_regressed @database_name = N''YourDB'', @recent_hours = 4, @history_days = 7;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_qs_regressed
    @database_name sysname = NULL,
    @recent_hours int = 4,
    @history_days int = 7
AS
-- Toolkit 04_query_store.sql section 4.4: REGRESSED QUERIES: RECENT vs HISTORY (avg duration)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''WITH recent AS (
    SELECT p.query_id, SUM(rs.avg_duration * rs.count_executions) / SUM(rs.count_executions) AS avg_dur, SUM(rs.count_executions) AS execs
    FROM sys.query_store_runtime_stats AS rs
    JOIN sys.query_store_runtime_stats_interval AS i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
    JOIN sys.query_store_plan AS p ON p.plan_id = rs.plan_id
    WHERE i.start_time >= DATEADD(HOUR, -@recent_hours, SYSDATETIMEOFFSET())
    GROUP BY p.query_id
), hist AS (
    SELECT p.query_id, SUM(rs.avg_duration * rs.count_executions) / SUM(rs.count_executions) AS avg_dur, SUM(rs.count_executions) AS execs
    FROM sys.query_store_runtime_stats AS rs
    JOIN sys.query_store_runtime_stats_interval AS i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
    JOIN sys.query_store_plan AS p ON p.plan_id = rs.plan_id
    WHERE i.start_time >= DATEADD(DAY, -@history_days, SYSDATETIMEOFFSET())
      AND i.start_time <  DATEADD(HOUR, -@recent_hours, SYSDATETIMEOFFSET())
    GROUP BY p.query_id
)
SELECT TOP (25)
    r.query_id,
    CAST(h.avg_dur / 1000.0 AS decimal(18,2)) AS hist_avg_ms,
    CAST(r.avg_dur / 1000.0 AS decimal(18,2)) AS recent_avg_ms,
    CAST(r.avg_dur / NULLIF(h.avg_dur, 0) AS decimal(10,2)) AS times_slower,
    r.execs AS recent_execs, h.execs AS hist_execs,
    qt.query_sql_text
FROM recent AS r
JOIN hist   AS h ON h.query_id = r.query_id
JOIN sys.query_store_query      AS q  ON q.query_id = r.query_id
JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
WHERE r.avg_dur > 2 * h.avg_dur
  AND r.execs >= 5
ORDER BY (r.avg_dur - h.avg_dur) * r.execs DESC;'';
EXEC @hc_exec @hc_sql, N''@recent_hours int, @history_days int'', @recent_hours = @recent_hours, @history_days = @history_days;
',
    @fallback_definition = NULL;
GO

/* 4.5  QUERIES WITH MULTIPLE PLANS (plan instability)   (04_query_store.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_qs_multi_plan', @section = N'4.5', @source_file = N'04_query_store.sql',
    @title = N'QUERIES WITH MULTIPLE PLANS (plan instability)', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_qs_multi_plan @database_name = N''YourDB'', @query_id = 1;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_qs_multi_plan
    @database_name sysname = NULL,
    @query_id bigint = 1
AS
-- Toolkit 04_query_store.sql section 4.5: QUERIES WITH MULTIPLE PLANS (plan instability)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''WITH mp AS (
    SELECT q.query_id, q.query_text_id,
           COUNT(DISTINCT p.plan_id)          AS plan_count,
           MAX(CAST(p.is_forced_plan AS int)) AS has_forced_plan
    FROM sys.query_store_query AS q
    JOIN sys.query_store_plan  AS p ON p.query_id = q.query_id
    GROUP BY q.query_id, q.query_text_id
    HAVING COUNT(DISTINCT p.plan_id) > 1
)
SELECT TOP (25) mp.query_id, mp.plan_count, mp.has_forced_plan, qt.query_sql_text
FROM mp
JOIN sys.query_store_query_text AS qt ON qt.query_text_id = mp.query_text_id
ORDER BY mp.plan_count DESC;


WITH s AS (
    SELECT rs.plan_id,
           SUM(rs.count_executions) AS execs,
           SUM(rs.avg_duration * rs.count_executions) / SUM(rs.count_executions) / 1000.0 AS avg_duration_ms,
           SUM(rs.avg_cpu_time * rs.count_executions) / SUM(rs.count_executions) / 1000.0 AS avg_cpu_ms,
           SUM(rs.avg_logical_io_reads * rs.count_executions) / SUM(rs.count_executions)  AS avg_reads
    FROM sys.query_store_runtime_stats AS rs
    JOIN sys.query_store_plan AS p ON p.plan_id = rs.plan_id
    WHERE p.query_id = @query_id
    GROUP BY rs.plan_id
)
SELECT p.plan_id, p.is_forced_plan, p.last_execution_time, s.execs,
       CAST(s.avg_duration_ms AS decimal(18,2)) AS avg_duration_ms,
       CAST(s.avg_cpu_ms      AS decimal(18,2)) AS avg_cpu_ms,
       CAST(s.avg_reads       AS decimal(18,0)) AS avg_reads,
       TRY_CAST(p.query_plan AS xml) AS query_plan
FROM s
JOIN sys.query_store_plan AS p ON p.plan_id = s.plan_id
ORDER BY s.avg_duration_ms;'';
EXEC @hc_exec @hc_sql, N''@query_id bigint'', @query_id = @query_id;
',
    @fallback_definition = NULL;
GO

/* 4.6  FORCED PLANS & FORCING FAILURES   (04_query_store.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_qs_forced_plans', @section = N'4.6', @source_file = N'04_query_store.sql',
    @title = N'FORCED PLANS & FORCING FAILURES', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_qs_forced_plans @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_qs_forced_plans
    @database_name sysname = NULL
AS
-- Toolkit 04_query_store.sql section 4.6: FORCED PLANS & FORCING FAILURES
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT p.query_id, p.plan_id, p.plan_forcing_type_desc,
       p.force_failure_count, p.last_force_failure_reason_desc,
       p.last_execution_time, qt.query_sql_text
FROM sys.query_store_plan       AS p
JOIN sys.query_store_query      AS q  ON q.query_id = p.query_id
JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
WHERE p.is_forced_plan = 1;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 4.7  WAIT CATEGORIES PER QUERY (2017+)   (04_query_store.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_qs_wait_categories', @section = N'4.7', @source_file = N'04_query_store.sql',
    @title = N'WAIT CATEGORIES PER QUERY (2017+)', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_qs_wait_categories @database_name = N''YourDB'', @hours = 24;',
    @min_version = 14,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_qs_wait_categories
    @database_name sysname = NULL,
    @hours int = 24
AS
-- Toolkit 04_query_store.sql section 4.7: WAIT CATEGORIES PER QUERY (2017+)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT TOP (25) p.query_id, ws.wait_category_desc,
       SUM(ws.total_query_wait_time_ms) AS total_wait_ms
FROM sys.query_store_wait_stats AS ws
JOIN sys.query_store_runtime_stats_interval AS i ON i.runtime_stats_interval_id = ws.runtime_stats_interval_id
JOIN sys.query_store_plan AS p ON p.plan_id = ws.plan_id
WHERE i.start_time >= DATEADD(HOUR, -@hours, SYSDATETIMEOFFSET())
GROUP BY p.query_id, ws.wait_category_desc
ORDER BY total_wait_ms DESC;'';
EXEC @hc_exec @hc_sql, N''@hours int'', @hours = @hours;
',
    @fallback_definition = NULL;
GO

/* 4.8  QUERY STORE HINTS (2022+, Azure SQL DB, MI)   (04_query_store.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_qs_hints', @section = N'4.8', @source_file = N'04_query_store.sql',
    @title = N'QUERY STORE HINTS (2022+, Azure SQL DB, MI)', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_qs_hints @database_name = N''YourDB'';',
    @min_version = 16,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_qs_hints
    @database_name sysname = NULL
AS
-- Toolkit 04_query_store.sql section 4.8: QUERY STORE HINTS (2022+, Azure SQL DB, MI)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT query_hint_id, query_id, query_hint_text, last_query_hint_failure_reason_desc,
       query_hint_failure_count, source_desc
FROM sys.query_store_query_hints;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 4.9  FIND A QUERY IN QUERY STORE BY TEXT   (04_query_store.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_qs_find_query', @section = N'4.9', @source_file = N'04_query_store.sql',
    @title = N'FIND A QUERY IN QUERY STORE BY TEXT', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_qs_find_query @database_name = N''YourDB'', @search_text = N''%YourText%'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_qs_find_query
    @database_name sysname = NULL,
    @search_text nvarchar(400) = N''%YourText%''
AS
-- Toolkit 04_query_store.sql section 4.9: FIND A QUERY IN QUERY STORE BY TEXT
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT q.query_id, q.last_execution_time, OBJECT_NAME(q.object_id) AS object_name, qt.query_sql_text
FROM sys.query_store_query      AS q
JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
WHERE qt.query_sql_text LIKE @search_text
ORDER BY q.last_execution_time DESC;'';
EXEC @hc_exec @hc_sql, N''@search_text nvarchar(400)'', @search_text = @search_text;
',
    @fallback_definition = NULL;
GO

/* 5.1  MISSING INDEXES - ALL DATABASES, WITH CREATE STATEMENT   (05_indexes_statistics.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_missing_indexes', @section = N'5.1', @source_file = N'05_indexes_statistics.sql',
    @title = N'MISSING INDEXES - ALL DATABASES, WITH CREATE STATEMENT', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_missing_indexes;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_missing_indexes
AS
-- Toolkit 05_indexes_statistics.sql section 5.1: MISSING INDEXES - ALL DATABASES, WITH CREATE STATEMENT
SET NOCOUNT ON;
SELECT TOP (50)
    DB_NAME(mid.database_id)                                        AS database_name,
    mid.statement                                                   AS table_name,
    CAST(migs.avg_total_user_cost * (migs.avg_user_impact / 100.0)
         * (migs.user_seeks + migs.user_scans) AS decimal(18,0))    AS improvement_score,
    migs.user_seeks, migs.user_scans, migs.avg_user_impact, migs.last_user_seek,
    mid.equality_columns, mid.inequality_columns, mid.included_columns,
    N''CREATE NONCLUSTERED INDEX [IX_'' + OBJECT_NAME(mid.object_id, mid.database_id) + N''_''
        + CAST(mid.index_handle AS nvarchar(10)) + N''] ON '' + mid.statement + N'' (''
        + ISNULL(mid.equality_columns, N'''')
        + CASE WHEN mid.equality_columns IS NOT NULL AND mid.inequality_columns IS NOT NULL THEN N'', '' ELSE N'''' END
        + ISNULL(mid.inequality_columns, N'''') + N'')''
        + ISNULL(N'' INCLUDE ('' + mid.included_columns + N'')'', N'''')
        + N'' WITH (ONLINE = ON);  -- ONLINE needs Enterprise/Azure''  AS create_statement
FROM sys.dm_db_missing_index_groups      AS mig
JOIN sys.dm_db_missing_index_group_stats AS migs ON migs.group_handle = mig.index_group_handle
JOIN sys.dm_db_missing_index_details     AS mid  ON mid.index_handle  = mig.index_handle
ORDER BY improvement_score DESC;
',
    @fallback_definition = NULL;
GO

/* 5.2  INDEX USAGE - CURRENT DB (reads vs writes, size)   (05_indexes_statistics.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_index_usage', @section = N'5.2', @source_file = N'05_indexes_statistics.sql',
    @title = N'INDEX USAGE - CURRENT DB (reads vs writes, size)', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_index_usage @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_index_usage
    @database_name sysname = NULL
AS
-- Toolkit 05_indexes_statistics.sql section 5.2: INDEX USAGE - CURRENT DB (reads vs writes, size)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT
    OBJECT_SCHEMA_NAME(i.object_id) + N''''.'''' + OBJECT_NAME(i.object_id) AS table_name,
    i.name AS index_name, i.index_id, i.type_desc, i.is_primary_key, i.is_unique,
    ISNULL(us.user_seeks, 0)   AS seeks,
    ISNULL(us.user_scans, 0)   AS scans,
    ISNULL(us.user_lookups, 0) AS lookups,
    ISNULL(us.user_updates, 0) AS writes,
    us.last_user_seek, us.last_user_scan, us.last_user_update,
    sz.size_mb, sz.row_count
FROM sys.indexes AS i
LEFT JOIN sys.dm_db_index_usage_stats AS us
       ON us.object_id = i.object_id AND us.index_id = i.index_id AND us.database_id = DB_ID()
OUTER APPLY (SELECT CAST(SUM(ps.used_page_count) * 8 / 1024.0 AS decimal(18,2)) AS size_mb,
                    SUM(CASE WHEN ps.index_id < 2 THEN ps.row_count ELSE 0 END) AS row_count
             FROM sys.dm_db_partition_stats AS ps
             WHERE ps.object_id = i.object_id AND ps.index_id = i.index_id) AS sz
WHERE OBJECTPROPERTY(i.object_id, ''''IsUserTable'''') = 1
ORDER BY table_name, i.index_id;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 5.3  UNUSED / WRITE-ONLY NONCLUSTERED INDEXES - CURRENT DB   (05_indexes_statistics.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_unused_indexes', @section = N'5.3', @source_file = N'05_indexes_statistics.sql',
    @title = N'UNUSED / WRITE-ONLY NONCLUSTERED INDEXES - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_unused_indexes @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_unused_indexes
    @database_name sysname = NULL
AS
-- Toolkit 05_indexes_statistics.sql section 5.3: UNUSED / WRITE-ONLY NONCLUSTERED INDEXES - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT
    OBJECT_SCHEMA_NAME(i.object_id) + N''''.'''' + OBJECT_NAME(i.object_id) AS table_name,
    i.name AS index_name,
    ISNULL(us.user_seeks + us.user_scans + us.user_lookups, 0) AS total_reads,
    ISNULL(us.user_updates, 0)                                  AS total_writes,
    CAST(SUM(ps.used_page_count) * 8 / 1024.0 AS decimal(18,2)) AS size_mb,
    N''''DROP INDEX '''' + QUOTENAME(i.name) + N'''' ON ''''
        + QUOTENAME(OBJECT_SCHEMA_NAME(i.object_id)) + N''''.'''' + QUOTENAME(OBJECT_NAME(i.object_id)) + N'''';'''' AS drop_statement
FROM sys.indexes AS i
JOIN sys.dm_db_partition_stats AS ps ON ps.object_id = i.object_id AND ps.index_id = i.index_id
LEFT JOIN sys.dm_db_index_usage_stats AS us
       ON us.object_id = i.object_id AND us.index_id = i.index_id AND us.database_id = DB_ID()
WHERE OBJECTPROPERTY(i.object_id, ''''IsUserTable'''') = 1
  AND i.type_desc = ''''NONCLUSTERED''''
  AND i.is_primary_key = 0 AND i.is_unique_constraint = 0
  AND ISNULL(us.user_seeks + us.user_scans + us.user_lookups, 0) = 0
GROUP BY i.object_id, i.name, us.user_seeks, us.user_scans, us.user_lookups, us.user_updates
ORDER BY total_writes DESC;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 5.4  DUPLICATE & OVERLAPPING INDEXES - CURRENT DB   (05_indexes_statistics.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_duplicate_indexes', @section = N'5.4', @source_file = N'05_indexes_statistics.sql',
    @title = N'DUPLICATE & OVERLAPPING INDEXES - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_duplicate_indexes @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_duplicate_indexes
    @database_name sysname = NULL
AS
-- Toolkit 05_indexes_statistics.sql section 5.4: DUPLICATE & OVERLAPPING INDEXES - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''WITH idx AS (
    SELECT i.object_id, i.index_id, i.name, i.type_desc, i.is_unique, i.filter_definition,
        key_cols = STUFF((
            SELECT N'''','''' + QUOTENAME(c.name) + CASE WHEN ic.is_descending_key = 1 THEN N'''' DESC'''' ELSE N'''''''' END
            FROM sys.index_columns AS ic
            JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
            WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
            ORDER BY ic.key_ordinal
            FOR XML PATH(''''''''), TYPE).value(''''.'''', ''''nvarchar(max)''''), 1, 1, N''''''''),
        incl_cols = STUFF((
            SELECT N'''','''' + QUOTENAME(c.name)
            FROM sys.index_columns AS ic
            JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
            WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1
            ORDER BY c.name
            FOR XML PATH(''''''''), TYPE).value(''''.'''', ''''nvarchar(max)''''), 1, 1, N'''''''')
    FROM sys.indexes AS i
    WHERE OBJECTPROPERTY(i.object_id, ''''IsUserTable'''') = 1 AND i.type IN (1, 2)
)
SELECT
    OBJECT_SCHEMA_NAME(a.object_id) + N''''.'''' + OBJECT_NAME(a.object_id) AS table_name,
    a.name AS index_1, a.key_cols AS keys_1, a.incl_cols AS includes_1,
    b.name AS index_2, b.key_cols AS keys_2, b.incl_cols AS includes_2,
    CASE WHEN a.key_cols = b.key_cols AND ISNULL(a.incl_cols, N'''''''') = ISNULL(b.incl_cols, N'''''''')
         THEN ''''EXACT DUPLICATE''''
         WHEN a.key_cols = b.key_cols THEN ''''SAME KEYS, DIFFERENT INCLUDES''''
         ELSE ''''OVERLAPPING (left-prefix)'''' END AS finding
FROM idx AS a
JOIN idx AS b ON b.object_id = a.object_id AND b.index_id > a.index_id
WHERE ISNULL(a.filter_definition, N'''''''') = ISNULL(b.filter_definition, N'''''''')
  AND (a.key_cols = b.key_cols
       OR b.key_cols LIKE a.key_cols + N'''',%''''
       OR a.key_cols LIKE b.key_cols + N'''',%'''')
ORDER BY table_name;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 5.5  FRAGMENTATION - CURRENT DB (LIMITED mode, >1000 pages)   (05_indexes_statistics.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_index_fragmentation', @section = N'5.5', @source_file = N'05_indexes_statistics.sql',
    @title = N'FRAGMENTATION - CURRENT DB (LIMITED mode, >1000 pages)', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_index_fragmentation @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_index_fragmentation
    @database_name sysname = NULL
AS
-- Toolkit 05_indexes_statistics.sql section 5.5: FRAGMENTATION - CURRENT DB (LIMITED mode, >1000 pages)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT
    OBJECT_SCHEMA_NAME(ips.object_id) + N''''.'''' + OBJECT_NAME(ips.object_id) AS table_name,
    i.name AS index_name, ips.index_type_desc, ips.partition_number,
    CAST(ips.avg_fragmentation_in_percent AS decimal(5,2)) AS frag_pct,
    ips.page_count, ips.fragment_count, i.fill_factor
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, ''''LIMITED'''') AS ips
JOIN sys.indexes AS i ON i.object_id = ips.object_id AND i.index_id = ips.index_id
WHERE ips.page_count > 1000
  AND ips.index_id > 0
  AND ips.alloc_unit_type_desc = ''''IN_ROW_DATA''''
ORDER BY ips.avg_fragmentation_in_percent DESC;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 5.6  HEAPS WITH FORWARDED RECORDS - CURRENT DB   (05_indexes_statistics.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_heaps_forwarded', @section = N'5.6', @source_file = N'05_indexes_statistics.sql',
    @title = N'HEAPS WITH FORWARDED RECORDS - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_heaps_forwarded @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_heaps_forwarded
    @database_name sysname = NULL
AS
-- Toolkit 05_indexes_statistics.sql section 5.6: HEAPS WITH FORWARDED RECORDS - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT OBJECT_SCHEMA_NAME(ips.object_id) + N''''.'''' + OBJECT_NAME(ips.object_id) AS heap_name,
       ips.page_count, ips.record_count, ips.forwarded_record_count,
       CAST(100.0 * ips.forwarded_record_count / NULLIF(ips.record_count, 0) AS decimal(5,2)) AS forwarded_pct
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, 0, NULL, ''''SAMPLED'''') AS ips
WHERE ips.index_type_desc = ''''HEAP''''
  AND ips.page_count > 100
ORDER BY ips.forwarded_record_count DESC;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 5.7  ALL INDEXES ON ONE TABLE (better sp_helpindex)   (05_indexes_statistics.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_table_indexes', @section = N'5.7', @source_file = N'05_indexes_statistics.sql',
    @title = N'ALL INDEXES ON ONE TABLE (better sp_helpindex)', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_table_indexes @database_name = N''YourDB'', @table = N''dbo.YourTable'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_table_indexes
    @database_name sysname = NULL,
    @table sysname = N''dbo.YourTable''
AS
-- Toolkit 05_indexes_statistics.sql section 5.7: ALL INDEXES ON ONE TABLE (better sp_helpindex)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT i.index_id, i.name, i.type_desc, i.is_primary_key, i.is_unique, i.fill_factor,
       i.has_filter, i.filter_definition, p.data_compression_desc,
       STUFF((SELECT N'''', '''' + c.name + CASE WHEN ic.is_descending_key = 1 THEN N'''' DESC'''' ELSE N'''''''' END
              FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
              WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
              ORDER BY ic.key_ordinal FOR XML PATH(''''''''), TYPE).value(''''.'''', ''''nvarchar(max)''''), 1, 2, N'''''''') AS key_columns,
       STUFF((SELECT N'''', '''' + c.name
              FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
              WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1
              FOR XML PATH(''''''''), TYPE).value(''''.'''', ''''nvarchar(max)''''), 1, 2, N'''''''') AS included_columns,
       CAST(SUM(ps.used_page_count) * 8 / 1024.0 AS decimal(18,2)) AS size_mb
FROM sys.indexes AS i
JOIN sys.partitions AS p ON p.object_id = i.object_id AND p.index_id = i.index_id AND p.partition_number = 1
JOIN sys.dm_db_partition_stats AS ps ON ps.object_id = i.object_id AND ps.index_id = i.index_id
WHERE i.object_id = OBJECT_ID(@table)
GROUP BY i.object_id, i.index_id, i.name, i.type_desc, i.is_primary_key, i.is_unique, i.fill_factor,
         i.has_filter, i.filter_definition, p.data_compression_desc
ORDER BY i.index_id;'';
EXEC @hc_exec @hc_sql, N''@table sysname'', @table = @table;
',
    @fallback_definition = NULL;
GO

/* 5.8  STATISTICS HEALTH - CURRENT DB (stale / low sample)   (05_indexes_statistics.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_stats_health', @section = N'5.8', @source_file = N'05_indexes_statistics.sql',
    @title = N'STATISTICS HEALTH - CURRENT DB (stale / low sample)', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_stats_health @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_stats_health
    @database_name sysname = NULL
AS
-- Toolkit 05_indexes_statistics.sql section 5.8: STATISTICS HEALTH - CURRENT DB (stale / low sample)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT
    OBJECT_SCHEMA_NAME(s.object_id) + N''''.'''' + OBJECT_NAME(s.object_id) AS table_name,
    s.name AS stats_name, s.auto_created, s.user_created, s.no_recompute, s.is_incremental,
    sp.last_updated, DATEDIFF(DAY, sp.last_updated, SYSDATETIME()) AS days_old,
    sp.rows, sp.rows_sampled,
    CAST(100.0 * sp.rows_sampled / NULLIF(sp.rows, 0) AS decimal(5,2)) AS sample_pct,
    sp.modification_counter,
    CAST(100.0 * sp.modification_counter / NULLIF(sp.rows, 0) AS decimal(10,2)) AS modified_pct,
    sp.steps
FROM sys.stats AS s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
WHERE OBJECTPROPERTY(s.object_id, ''''IsUserTable'''') = 1
ORDER BY sp.modification_counter DESC;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 5.9  INDEX OPERATIONAL STATS (lock/latch waits, splits proxy)   (05_indexes_statistics.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_index_operational_stats', @section = N'5.9', @source_file = N'05_indexes_statistics.sql',
    @title = N'INDEX OPERATIONAL STATS (lock/latch waits, splits proxy)', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_index_operational_stats @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_index_operational_stats
    @database_name sysname = NULL
AS
-- Toolkit 05_indexes_statistics.sql section 5.9: INDEX OPERATIONAL STATS (lock/latch waits, splits proxy)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT TOP (25)
    OBJECT_SCHEMA_NAME(os.object_id) + N''''.'''' + OBJECT_NAME(os.object_id) AS table_name,
    i.name AS index_name,
    os.leaf_insert_count, os.leaf_update_count, os.leaf_delete_count,
    os.leaf_allocation_count            AS leaf_page_splits_approx,
    os.row_lock_wait_count, os.row_lock_wait_in_ms,
    os.page_lock_wait_count, os.page_lock_wait_in_ms,
    os.page_latch_wait_count, os.page_latch_wait_in_ms,
    os.page_io_latch_wait_count, os.page_io_latch_wait_in_ms,
    os.index_lock_promotion_attempt_count, os.index_lock_promotion_count
FROM sys.dm_db_index_operational_stats(DB_ID(), NULL, NULL, NULL) AS os
JOIN sys.indexes AS i ON i.object_id = os.object_id AND i.index_id = os.index_id
WHERE OBJECTPROPERTY(os.object_id, ''''IsUserTable'''') = 1
ORDER BY os.row_lock_wait_in_ms + os.page_lock_wait_in_ms DESC;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 5.10  COLUMNSTORE ROWGROUP HEALTH - CURRENT DB   (05_indexes_statistics.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_columnstore_health', @section = N'5.10', @source_file = N'05_indexes_statistics.sql',
    @title = N'COLUMNSTORE ROWGROUP HEALTH - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_columnstore_health @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_columnstore_health
    @database_name sysname = NULL
AS
-- Toolkit 05_indexes_statistics.sql section 5.10: COLUMNSTORE ROWGROUP HEALTH - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT OBJECT_NAME(rg.object_id) AS table_name, i.name AS index_name,
       rg.state_desc, COUNT(*) AS rowgroups,
       SUM(rg.total_rows) AS total_rows, SUM(rg.deleted_rows) AS deleted_rows,
       CAST(100.0 * SUM(rg.deleted_rows) / NULLIF(SUM(rg.total_rows), 0) AS decimal(5,2)) AS deleted_pct,
       MIN(rg.trim_reason_desc) AS sample_trim_reason
FROM sys.dm_db_column_store_row_group_physical_stats AS rg
JOIN sys.indexes AS i ON i.object_id = rg.object_id AND i.index_id = rg.index_id
GROUP BY rg.object_id, i.name, rg.state_desc
ORDER BY table_name, rg.state_desc;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 5.11  TABLES WITHOUT A CLUSTERED INDEX / PRIMARY KEY   (05_indexes_statistics.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_tables_without_ci_pk', @section = N'5.11', @source_file = N'05_indexes_statistics.sql',
    @title = N'TABLES WITHOUT A CLUSTERED INDEX / PRIMARY KEY', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_tables_without_ci_pk @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_tables_without_ci_pk
    @database_name sysname = NULL
AS
-- Toolkit 05_indexes_statistics.sql section 5.11: TABLES WITHOUT A CLUSTERED INDEX / PRIMARY KEY
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT OBJECT_SCHEMA_NAME(t.object_id) + N''''.'''' + t.name AS table_name,
       OBJECTPROPERTY(t.object_id, ''''TableHasClustIndex'''') AS has_clustered,
       OBJECTPROPERTY(t.object_id, ''''TableHasPrimaryKey'''') AS has_pk,
       (SELECT SUM(row_count) FROM sys.dm_db_partition_stats ps WHERE ps.object_id = t.object_id AND ps.index_id IN (0,1)) AS row_count
FROM sys.tables AS t
WHERE t.is_ms_shipped = 0
  AND (OBJECTPROPERTY(t.object_id, ''''TableHasClustIndex'''') = 0 OR OBJECTPROPERTY(t.object_id, ''''TableHasPrimaryKey'''') = 0)
ORDER BY row_count DESC;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 5.12  RESUMABLE INDEX OPERATIONS IN PROGRESS (2017+)   (05_indexes_statistics.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_resumable_index_ops', @section = N'5.12', @source_file = N'05_indexes_statistics.sql',
    @title = N'RESUMABLE INDEX OPERATIONS IN PROGRESS (2017+)', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_resumable_index_ops @database_name = N''YourDB'';',
    @min_version = 14,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_resumable_index_ops
    @database_name sysname = NULL
AS
-- Toolkit 05_indexes_statistics.sql section 5.12: RESUMABLE INDEX OPERATIONS IN PROGRESS (2017+)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT OBJECT_NAME(object_id) AS table_name, index_id, name, state_desc,
       percent_complete, start_time, last_pause_time, total_execution_time, sql_text
FROM sys.index_resumable_operations;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 6.1  OS + SQL PROCESS MEMORY OVERVIEW   (06_memory.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_memory_overview', @section = N'6.1', @source_file = N'06_memory.sql',
    @title = N'OS + SQL PROCESS MEMORY OVERVIEW', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_memory_overview;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_memory_overview
AS
-- Toolkit 06_memory.sql section 6.1: OS + SQL PROCESS MEMORY OVERVIEW
SET NOCOUNT ON;
SELECT total_physical_memory_kb / 1024     AS os_total_mb,
       available_physical_memory_kb / 1024 AS os_available_mb,
       total_page_file_kb / 1024           AS page_file_mb,
       system_memory_state_desc
FROM sys.dm_os_sys_memory;

SELECT physical_memory_in_use_kb / 1024     AS sql_physical_in_use_mb,
       locked_page_allocations_kb / 1024    AS locked_pages_mb,
       large_page_allocations_kb / 1024     AS large_pages_mb,
       memory_utilization_percentage,
       available_commit_limit_kb / 1024     AS available_commit_mb,
       process_physical_memory_low, process_virtual_memory_low,
       page_fault_count
FROM sys.dm_os_process_memory;
',
    @fallback_definition = NULL;
GO

/* 6.2  KEY MEMORY COUNTERS   (06_memory.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_memory_counters', @section = N'6.2', @source_file = N'06_memory.sql',
    @title = N'KEY MEMORY COUNTERS', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_memory_counters ORDER BY object_name, counter_name;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY object_name, counter_name',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_memory_counters
AS
-- Toolkit 06_memory.sql section 6.2: KEY MEMORY COUNTERS
SELECT RTRIM(object_name) AS object_name, RTRIM(counter_name) AS counter_name,
       RTRIM(instance_name) AS instance_name, cntr_value
FROM sys.dm_os_performance_counters
WHERE (object_name LIKE N''%Memory Manager%'' AND counter_name IN (
          N''Total Server Memory (KB)'', N''Target Server Memory (KB)'',
          N''Stolen Server Memory (KB)'', N''Database Cache Memory (KB)'',
          N''Free Memory (KB)'', N''Memory Grants Pending'', N''Memory Grants Outstanding''))
   OR (object_name LIKE N''%Buffer Manager%'' AND counter_name IN (
          N''Page life expectancy'', N''Lazy writes/sec'', N''Page reads/sec'', N''Checkpoint pages/sec''));
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_memory_counters
AS
-- Toolkit 06_memory.sql section 6.2: KEY MEMORY COUNTERS
SET NOCOUNT ON;
SELECT RTRIM(object_name) AS object_name, RTRIM(counter_name) AS counter_name,
       RTRIM(instance_name) AS instance_name, cntr_value
FROM sys.dm_os_performance_counters
WHERE (object_name LIKE N''%Memory Manager%'' AND counter_name IN (
          N''Total Server Memory (KB)'', N''Target Server Memory (KB)'',
          N''Stolen Server Memory (KB)'', N''Database Cache Memory (KB)'',
          N''Free Memory (KB)'', N''Memory Grants Pending'', N''Memory Grants Outstanding''))
   OR (object_name LIKE N''%Buffer Manager%'' AND counter_name IN (
          N''Page life expectancy'', N''Lazy writes/sec'', N''Page reads/sec'', N''Checkpoint pages/sec''))
ORDER BY object_name, counter_name;
';
GO

/* 6.3  PAGE LIFE EXPECTANCY PER NUMA NODE   (06_memory.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_ple_per_numa', @section = N'6.3', @source_file = N'06_memory.sql',
    @title = N'PAGE LIFE EXPECTANCY PER NUMA NODE', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_ple_per_numa;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_ple_per_numa
AS
-- Toolkit 06_memory.sql section 6.3: PAGE LIFE EXPECTANCY PER NUMA NODE
SELECT RTRIM(object_name) AS object_name, RTRIM(instance_name) AS numa_node, cntr_value AS ple_seconds
FROM sys.dm_os_performance_counters
WHERE counter_name = N''Page life expectancy'';
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_ple_per_numa
AS
-- Toolkit 06_memory.sql section 6.3: PAGE LIFE EXPECTANCY PER NUMA NODE
SET NOCOUNT ON;
SELECT RTRIM(object_name) AS object_name, RTRIM(instance_name) AS numa_node, cntr_value AS ple_seconds
FROM sys.dm_os_performance_counters
WHERE counter_name = N''Page life expectancy'';
';
GO

/* 6.4  BUFFER POOL USAGE BY DATABASE   (06_memory.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_buffer_pool_by_db', @section = N'6.4', @source_file = N'06_memory.sql',
    @title = N'BUFFER POOL USAGE BY DATABASE', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_buffer_pool_by_db;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_buffer_pool_by_db
AS
-- Toolkit 06_memory.sql section 6.4: BUFFER POOL USAGE BY DATABASE
SET NOCOUNT ON;
SELECT
    CASE database_id WHEN 32767 THEN ''ResourceDb'' ELSE DB_NAME(database_id) END AS database_name,
    COUNT_BIG(*) * 8 / 1024                                       AS cached_mb,
    SUM(CAST(is_modified AS int)) * 8 / 1024                      AS dirty_mb,
    CAST(100.0 * COUNT_BIG(*) / SUM(COUNT_BIG(*)) OVER () AS decimal(5,2)) AS pct_of_bp
FROM sys.dm_os_buffer_descriptors
GROUP BY database_id
ORDER BY cached_mb DESC;
',
    @fallback_definition = NULL;
GO

/* 6.5  BUFFER POOL USAGE BY OBJECT - CURRENT DB   (06_memory.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_buffer_pool_by_object', @section = N'6.5', @source_file = N'06_memory.sql',
    @title = N'BUFFER POOL USAGE BY OBJECT - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_buffer_pool_by_object @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_buffer_pool_by_object
    @database_name sysname = NULL
AS
-- Toolkit 06_memory.sql section 6.5: BUFFER POOL USAGE BY OBJECT - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT TOP (25)
    OBJECT_SCHEMA_NAME(p.object_id) + N''''.'''' + OBJECT_NAME(p.object_id) AS object_name,
    i.name AS index_name,
    COUNT_BIG(*) * 8 / 1024 AS cached_mb,
    SUM(CAST(bd.is_modified AS int)) * 8 / 1024 AS dirty_mb
FROM sys.dm_os_buffer_descriptors AS bd
JOIN sys.allocation_units AS au ON au.allocation_unit_id = bd.allocation_unit_id
JOIN sys.partitions       AS p  ON (au.type IN (1, 3) AND au.container_id = p.hobt_id)
                                OR (au.type = 2      AND au.container_id = p.partition_id)
LEFT JOIN sys.indexes     AS i  ON i.object_id = p.object_id AND i.index_id = p.index_id
WHERE bd.database_id = DB_ID()
  AND OBJECTPROPERTY(p.object_id, ''''IsMSShipped'''') = 0
GROUP BY p.object_id, i.name
ORDER BY cached_mb DESC;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 6.6  TOP MEMORY CLERKS (who is using non-buffer memory)   (06_memory.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_memory_clerks', @section = N'6.6', @source_file = N'06_memory.sql',
    @title = N'TOP MEMORY CLERKS (who is using non-buffer memory)', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_memory_clerks ORDER BY memory_mb DESC;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_memory_clerks
AS
-- Toolkit 06_memory.sql section 6.6: TOP MEMORY CLERKS (who is using non-buffer memory)
SELECT TOP (20) [type] AS clerk_type, name,
       SUM(pages_kb) / 1024 AS memory_mb
FROM sys.dm_os_memory_clerks
GROUP BY [type], name
ORDER BY memory_mb DESC;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_memory_clerks
AS
-- Toolkit 06_memory.sql section 6.6: TOP MEMORY CLERKS (who is using non-buffer memory)
SET NOCOUNT ON;
SELECT TOP (20) [type] AS clerk_type, name,
       SUM(pages_kb) / 1024 AS memory_mb
FROM sys.dm_os_memory_clerks
GROUP BY [type], name
ORDER BY memory_mb DESC;
';
GO

/* 6.7  MEMORY GRANTS - WAITING AND RUNNING   (06_memory.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_memory_grants', @section = N'6.7', @source_file = N'06_memory.sql',
    @title = N'MEMORY GRANTS - WAITING AND RUNNING', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_memory_grants;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_memory_grants
AS
-- Toolkit 06_memory.sql section 6.7: MEMORY GRANTS - WAITING AND RUNNING
SET NOCOUNT ON;
SELECT mg.session_id, mg.request_time, mg.grant_time,
       mg.requested_memory_kb / 1024 AS requested_mb,
       mg.granted_memory_kb / 1024   AS granted_mb,
       mg.used_memory_kb / 1024      AS used_mb,
       mg.ideal_memory_kb / 1024     AS ideal_mb,
       mg.wait_time_ms, mg.dop, mg.query_cost, mg.resource_semaphore_id,
       t.text AS sql_text, qp.query_plan
FROM sys.dm_exec_query_memory_grants AS mg
OUTER APPLY sys.dm_exec_sql_text(mg.sql_handle)    AS t
OUTER APPLY sys.dm_exec_query_plan(mg.plan_handle) AS qp
ORDER BY mg.requested_memory_kb DESC;

SELECT resource_semaphore_id, pool_id, target_memory_kb / 1024 AS target_mb,
       total_memory_kb / 1024 AS total_mb, available_memory_kb / 1024 AS available_mb,
       granted_memory_kb / 1024 AS granted_mb, grantee_count, waiter_count, timeout_error_count
FROM sys.dm_exec_query_resource_semaphores;
',
    @fallback_definition = NULL;
GO

/* 6.8  LOW MEMORY NOTIFICATIONS FROM RING BUFFER   (06_memory.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_low_memory_events', @section = N'6.8', @source_file = N'06_memory.sql',
    @title = N'LOW MEMORY NOTIFICATIONS FROM RING BUFFER', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_low_memory_events;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_low_memory_events
AS
-- Toolkit 06_memory.sql section 6.8: LOW MEMORY NOTIFICATIONS FROM RING BUFFER
SET NOCOUNT ON;
DECLARE @ms_now bigint = (SELECT ms_ticks FROM sys.dm_os_sys_info);
SELECT TOP (50)
    DATEADD(MILLISECOND, -1 * (@ms_now - rb.[timestamp]), SYSDATETIME()) AS event_time,
    x.record.value(''(./Record/ResourceMonitor/Notification)[1]'', ''varchar(50)'')        AS notification,
    x.record.value(''(./Record/MemoryRecord/AvailablePhysicalMemory)[1]'', ''bigint'') / 1024 AS os_available_mb,
    x.record.value(''(./Record/MemoryNode/TargetMemory)[1]'', ''bigint'') / 1024           AS sql_target_mb,
    x.record.value(''(./Record/MemoryNode/CommittedMemory)[1]'', ''bigint'') / 1024        AS sql_committed_mb
FROM sys.dm_os_ring_buffers AS rb
CROSS APPLY (SELECT CAST(rb.record AS xml)) AS x(record)
WHERE rb.ring_buffer_type = N''RING_BUFFER_RESOURCE_MONITOR''
ORDER BY rb.[timestamp] DESC;
',
    @fallback_definition = NULL;
GO

/* 6.9  OUT-OF-MEMORY EVENTS (2022+, Azure SQL DB, MI)   (06_memory.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_oom_events', @section = N'6.9', @source_file = N'06_memory.sql',
    @title = N'OUT-OF-MEMORY EVENTS (2022+, Azure SQL DB, MI)', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_oom_events;',
    @min_version = 16,
    @sort_hint = N'ORDER BY event_time DESC',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_oom_events
AS
-- Toolkit 06_memory.sql section 6.9: OUT-OF-MEMORY EVENTS (2022+, Azure SQL DB, MI)
SELECT *
FROM sys.dm_os_out_of_memory_events;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_oom_events
AS
-- Toolkit 06_memory.sql section 6.9: OUT-OF-MEMORY EVENTS (2022+, Azure SQL DB, MI)
SET NOCOUNT ON;
SELECT *
FROM sys.dm_os_out_of_memory_events
ORDER BY event_time DESC;
';
GO

/* 6.10  MEMORY SETTINGS CHECK   (06_memory.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_memory_settings', @section = N'6.10', @source_file = N'06_memory.sql',
    @title = N'MEMORY SETTINGS CHECK', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_memory_settings;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_memory_settings
AS
-- Toolkit 06_memory.sql section 6.10: MEMORY SETTINGS CHECK
SELECT
    (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = N''max server memory (MB)'') AS max_server_memory_mb,
    (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = N''min server memory (MB)'') AS min_server_memory_mb,
    (SELECT physical_memory_kb / 1024 FROM sys.dm_os_sys_info)                                      AS physical_memory_mb,
    (SELECT sql_memory_model_desc FROM sys.dm_os_sys_info)                                          AS memory_model;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_memory_settings
AS
-- Toolkit 06_memory.sql section 6.10: MEMORY SETTINGS CHECK
SET NOCOUNT ON;
SELECT
    (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = N''max server memory (MB)'') AS max_server_memory_mb,
    (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = N''min server memory (MB)'') AS min_server_memory_mb,
    (SELECT physical_memory_kb / 1024 FROM sys.dm_os_sys_info)                                      AS physical_memory_mb,
    (SELECT sql_memory_model_desc FROM sys.dm_os_sys_info)                                          AS memory_model;
';
GO

/* 7.1  CPU % - LAST ~256 MINUTES (1-minute samples)   (07_cpu.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_cpu_history', @section = N'7.1', @source_file = N'07_cpu.sql',
    @title = N'CPU % - LAST ~256 MINUTES (1-minute samples)', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_cpu_history;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_cpu_history
AS
-- Toolkit 07_cpu.sql section 7.1: CPU % - LAST ~256 MINUTES (1-minute samples)
SET NOCOUNT ON;
DECLARE @ms_now bigint = (SELECT ms_ticks FROM sys.dm_os_sys_info);

SELECT TOP (256)
    DATEADD(MILLISECOND, -1 * (@ms_now - y.[timestamp]), SYSDATETIME()) AS sample_time,
    y.sql_cpu,
    100 - y.system_idle - y.sql_cpu AS other_cpu,
    y.system_idle
FROM (
    SELECT x.[timestamp],
           x.rec.value(''(./Record/@id)[1]'', ''int'') AS record_id,
           x.rec.value(''(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]'', ''int'')         AS system_idle,
           x.rec.value(''(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]'', ''int'') AS sql_cpu
    FROM (SELECT [timestamp], CONVERT(xml, record) AS rec
          FROM sys.dm_os_ring_buffers
          WHERE ring_buffer_type = N''RING_BUFFER_SCHEDULER_MONITOR''
            AND record LIKE N''%<SystemHealth>%'') AS x
) AS y
ORDER BY y.record_id DESC;
',
    @fallback_definition = NULL;
GO

/* 7.2  SCHEDULER PRESSURE (runnable queue)   (07_cpu.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_scheduler_pressure', @section = N'7.2', @source_file = N'07_cpu.sql',
    @title = N'SCHEDULER PRESSURE (runnable queue)', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_scheduler_pressure;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_scheduler_pressure
AS
-- Toolkit 07_cpu.sql section 7.2: SCHEDULER PRESSURE (runnable queue)
SET NOCOUNT ON;
SELECT scheduler_id, cpu_id, parent_node_id, status, is_online,
       current_tasks_count, runnable_tasks_count, current_workers_count,
       active_workers_count, work_queue_count, pending_disk_io_count, load_factor
FROM sys.dm_os_schedulers
WHERE status = N''VISIBLE ONLINE''
ORDER BY runnable_tasks_count DESC;

SELECT SUM(runnable_tasks_count) AS total_runnable,
       AVG(runnable_tasks_count * 1.0) AS avg_runnable_per_scheduler,
       SUM(work_queue_count) AS tasks_waiting_for_worker
FROM sys.dm_os_schedulers
WHERE status = N''VISIBLE ONLINE'';
',
    @fallback_definition = NULL;
GO

/* 7.3  WORKER THREAD USAGE (THREADPOOL risk)   (07_cpu.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_worker_threads', @section = N'7.3', @source_file = N'07_cpu.sql',
    @title = N'WORKER THREAD USAGE (THREADPOOL risk)', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_worker_threads;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_worker_threads
AS
-- Toolkit 07_cpu.sql section 7.3: WORKER THREAD USAGE (THREADPOOL risk)
SELECT
    (SELECT max_workers_count FROM sys.dm_os_sys_info)                                AS max_workers,
    (SELECT SUM(current_workers_count) FROM sys.dm_os_schedulers WHERE status = N''VISIBLE ONLINE'') AS current_workers,
    (SELECT SUM(active_workers_count)  FROM sys.dm_os_schedulers WHERE status = N''VISIBLE ONLINE'') AS active_workers,
    (SELECT COUNT(*) FROM sys.dm_os_waiting_tasks WHERE wait_type = N''THREADPOOL'')    AS tasks_waiting_threadpool;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_worker_threads
AS
-- Toolkit 07_cpu.sql section 7.3: WORKER THREAD USAGE (THREADPOOL risk)
SET NOCOUNT ON;
SELECT
    (SELECT max_workers_count FROM sys.dm_os_sys_info)                                AS max_workers,
    (SELECT SUM(current_workers_count) FROM sys.dm_os_schedulers WHERE status = N''VISIBLE ONLINE'') AS current_workers,
    (SELECT SUM(active_workers_count)  FROM sys.dm_os_schedulers WHERE status = N''VISIBLE ONLINE'') AS active_workers,
    (SELECT COUNT(*) FROM sys.dm_os_waiting_tasks WHERE wait_type = N''THREADPOOL'')    AS tasks_waiting_threadpool;
';
GO

/* 7.4  TOP CPU CONSUMERS RIGHT NOW   (07_cpu.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_top_cpu_now', @section = N'7.4', @source_file = N'07_cpu.sql',
    @title = N'TOP CPU CONSUMERS RIGHT NOW', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_top_cpu_now ORDER BY cpu_ms DESC;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_top_cpu_now
AS
-- Toolkit 07_cpu.sql section 7.4: TOP CPU CONSUMERS RIGHT NOW
SELECT TOP (20)
    r.session_id, s.login_name, s.host_name, s.program_name, DB_NAME(r.database_id) AS database_name,
    r.cpu_time AS cpu_ms, r.total_elapsed_time / 1000 AS elapsed_s, r.dop,
    r.status, r.wait_type, r.logical_reads,
    SUBSTRING(t.text, (r.statement_start_offset / 2) + 1,
        ((CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(t.text)
          ELSE r.statement_end_offset END - r.statement_start_offset) / 2) + 1) AS statement_text
FROM sys.dm_exec_requests AS r
JOIN sys.dm_exec_sessions AS s ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE s.is_user_process = 1 AND r.session_id <> @@SPID
ORDER BY r.cpu_time DESC;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_top_cpu_now
AS
-- Toolkit 07_cpu.sql section 7.4: TOP CPU CONSUMERS RIGHT NOW
SET NOCOUNT ON;
SELECT TOP (20)
    r.session_id, s.login_name, s.host_name, s.program_name, DB_NAME(r.database_id) AS database_name,
    r.cpu_time AS cpu_ms, r.total_elapsed_time / 1000 AS elapsed_s, r.dop,
    r.status, r.wait_type, r.logical_reads,
    SUBSTRING(t.text, (r.statement_start_offset / 2) + 1,
        ((CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(t.text)
          ELSE r.statement_end_offset END - r.statement_start_offset) / 2) + 1) AS statement_text
FROM sys.dm_exec_requests AS r
JOIN sys.dm_exec_sessions AS s ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE s.is_user_process = 1 AND r.session_id <> @@SPID
ORDER BY r.cpu_time DESC;
';
GO

/* 7.5  CPU USAGE BY DATABASE (from plan cache - approximate)   (07_cpu.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_cpu_by_database', @section = N'7.5', @source_file = N'07_cpu.sql',
    @title = N'CPU USAGE BY DATABASE (from plan cache - approximate)', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_cpu_by_database;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_cpu_by_database
AS
-- Toolkit 07_cpu.sql section 7.5: CPU USAGE BY DATABASE (from plan cache - approximate)
SET NOCOUNT ON;
WITH db_cpu AS (
    SELECT CAST(pa.value AS int) AS database_id, SUM(qs.total_worker_time) AS cpu_us
    FROM sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_plan_attributes(qs.plan_handle) AS pa
    WHERE pa.attribute = N''dbid''
    GROUP BY CAST(pa.value AS int)
)
SELECT CASE database_id WHEN 32767 THEN ''ResourceDb'' ELSE DB_NAME(database_id) END AS database_name,
       cpu_us / 1000 AS cpu_ms,
       CAST(100.0 * cpu_us / SUM(cpu_us) OVER () AS decimal(5,2)) AS cpu_pct
FROM db_cpu
ORDER BY cpu_us DESC;
',
    @fallback_definition = NULL;
GO

/* 7.6  NUMA NODES & PARALLELISM SETTINGS   (07_cpu.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_numa_maxdop', @section = N'7.6', @source_file = N'07_cpu.sql',
    @title = N'NUMA NODES & PARALLELISM SETTINGS', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_numa_maxdop @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_numa_maxdop
    @database_name sysname = NULL
AS
-- Toolkit 07_cpu.sql section 7.6: NUMA NODES & PARALLELISM SETTINGS
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT node_id, node_state_desc, memory_node_id, online_scheduler_count,
       active_worker_count, avg_load_balance, cpu_affinity_mask
FROM sys.dm_os_nodes
WHERE node_state_desc NOT LIKE N''''%DAC%'''';

SELECT name, value_in_use FROM sys.configurations
WHERE name IN (N''''max degree of parallelism'''', N''''cost threshold for parallelism'''');

SELECT name, value FROM sys.database_scoped_configurations WHERE name = N''''MAXDOP'''';'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 8.1  FILE I/O LATENCY - ALL DATABASES (since restart)   (08_storage_io_files.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_file_latency', @section = N'8.1', @source_file = N'08_storage_io_files.sql',
    @title = N'FILE I/O LATENCY - ALL DATABASES (since restart)', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_file_latency ORDER BY avg_io_ms DESC;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY avg_io_ms DESC',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_file_latency
AS
-- Toolkit 08_storage_io_files.sql section 8.1: FILE I/O LATENCY - ALL DATABASES (since restart)
SELECT
    DB_NAME(vfs.database_id)                                                AS database_name,
    mf.name AS logical_name, mf.type_desc, mf.physical_name,
    vfs.num_of_reads, vfs.num_of_writes,
    CAST(vfs.io_stall_read_ms  * 1.0 / NULLIF(vfs.num_of_reads, 0)  AS decimal(10,2)) AS avg_read_ms,
    CAST(vfs.io_stall_write_ms * 1.0 / NULLIF(vfs.num_of_writes, 0) AS decimal(10,2)) AS avg_write_ms,
    CAST(vfs.io_stall * 1.0 / NULLIF(vfs.num_of_reads + vfs.num_of_writes, 0) AS decimal(10,2)) AS avg_io_ms,
    vfs.num_of_bytes_read    / 1048576 AS mb_read,
    vfs.num_of_bytes_written / 1048576 AS mb_written,
    vfs.size_on_disk_bytes   / 1048576 AS size_mb
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
JOIN sys.master_files AS mf ON mf.database_id = vfs.database_id AND mf.file_id = vfs.file_id;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_file_latency
AS
-- Toolkit 08_storage_io_files.sql section 8.1: FILE I/O LATENCY - ALL DATABASES (since restart)
SET NOCOUNT ON;
SELECT
    DB_NAME(vfs.database_id)                                                AS database_name,
    mf.name AS logical_name, mf.type_desc, mf.physical_name,
    vfs.num_of_reads, vfs.num_of_writes,
    CAST(vfs.io_stall_read_ms  * 1.0 / NULLIF(vfs.num_of_reads, 0)  AS decimal(10,2)) AS avg_read_ms,
    CAST(vfs.io_stall_write_ms * 1.0 / NULLIF(vfs.num_of_writes, 0) AS decimal(10,2)) AS avg_write_ms,
    CAST(vfs.io_stall * 1.0 / NULLIF(vfs.num_of_reads + vfs.num_of_writes, 0) AS decimal(10,2)) AS avg_io_ms,
    vfs.num_of_bytes_read    / 1048576 AS mb_read,
    vfs.num_of_bytes_written / 1048576 AS mb_written,
    vfs.size_on_disk_bytes   / 1048576 AS size_mb
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
JOIN sys.master_files AS mf ON mf.database_id = vfs.database_id AND mf.file_id = vfs.file_id
ORDER BY avg_io_ms DESC;
';
GO

/* 8.2  FILE I/O LATENCY - DELTA OVER N SECONDS (live)   (08_storage_io_files.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_file_latency_delta', @section = N'8.2', @source_file = N'08_storage_io_files.sql',
    @title = N'FILE I/O LATENCY - DELTA OVER N SECONDS (live)', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_file_latency_delta @delay = ''00:00:30'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_file_latency_delta
    @delay char(8) = ''00:00:30''
AS
-- Toolkit 08_storage_io_files.sql section 8.2: FILE I/O LATENCY - DELTA OVER N SECONDS (live)
SET NOCOUNT ON;
IF OBJECT_ID(''tempdb..#io1'') IS NOT NULL DROP TABLE #io1;
SELECT database_id, file_id, num_of_reads, num_of_writes, io_stall_read_ms, io_stall_write_ms
INTO #io1 FROM sys.dm_io_virtual_file_stats(NULL, NULL);
WAITFOR DELAY @delay;
SELECT DB_NAME(v.database_id) AS database_name, mf.name AS logical_name, mf.type_desc,
       v.num_of_reads  - a.num_of_reads  AS reads,
       v.num_of_writes - a.num_of_writes AS writes,
       CAST((v.io_stall_read_ms  - a.io_stall_read_ms)  * 1.0 / NULLIF(v.num_of_reads  - a.num_of_reads, 0)  AS decimal(10,2)) AS avg_read_ms,
       CAST((v.io_stall_write_ms - a.io_stall_write_ms) * 1.0 / NULLIF(v.num_of_writes - a.num_of_writes, 0) AS decimal(10,2)) AS avg_write_ms
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS v
JOIN #io1 AS a ON a.database_id = v.database_id AND a.file_id = v.file_id
JOIN sys.master_files AS mf ON mf.database_id = v.database_id AND mf.file_id = v.file_id
WHERE (v.num_of_reads - a.num_of_reads) + (v.num_of_writes - a.num_of_writes) > 0
ORDER BY (v.io_stall_read_ms - a.io_stall_read_ms) + (v.io_stall_write_ms - a.io_stall_write_ms) DESC;
',
    @fallback_definition = NULL;
GO

/* 8.3  PENDING I/O REQUESTS RIGHT NOW   (08_storage_io_files.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_pending_io', @section = N'8.3', @source_file = N'08_storage_io_files.sql',
    @title = N'PENDING I/O REQUESTS RIGHT NOW', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_pending_io ORDER BY io_pending_ms_ticks DESC;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY pio.io_pending_ms_ticks DESC',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_pending_io
AS
-- Toolkit 08_storage_io_files.sql section 8.3: PENDING I/O REQUESTS RIGHT NOW
SELECT DB_NAME(vfs.database_id) AS database_name, mf.physical_name,
       pio.io_type, pio.io_pending, pio.io_pending_ms_ticks
FROM sys.dm_io_pending_io_requests AS pio
JOIN sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs ON vfs.file_handle = pio.io_handle
JOIN sys.master_files AS mf ON mf.database_id = vfs.database_id AND mf.file_id = vfs.file_id;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_pending_io
AS
-- Toolkit 08_storage_io_files.sql section 8.3: PENDING I/O REQUESTS RIGHT NOW
SET NOCOUNT ON;
SELECT DB_NAME(vfs.database_id) AS database_name, mf.physical_name,
       pio.io_type, pio.io_pending, pio.io_pending_ms_ticks
FROM sys.dm_io_pending_io_requests AS pio
JOIN sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs ON vfs.file_handle = pio.io_handle
JOIN sys.master_files AS mf ON mf.database_id = vfs.database_id AND mf.file_id = vfs.file_id
ORDER BY pio.io_pending_ms_ticks DESC;
';
GO

/* 8.4  DRIVE / VOLUME FREE SPACE   (08_storage_io_files.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_volume_space', @section = N'8.4', @source_file = N'08_storage_io_files.sql',
    @title = N'DRIVE / VOLUME FREE SPACE', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_volume_space ORDER BY free_pct;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY free_pct',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_volume_space
AS
-- Toolkit 08_storage_io_files.sql section 8.4: DRIVE / VOLUME FREE SPACE
SELECT DISTINCT
    vs.volume_mount_point, vs.logical_volume_name, vs.file_system_type,
    vs.total_bytes / 1073741824     AS total_gb,
    vs.available_bytes / 1073741824 AS free_gb,
    CAST(100.0 * vs.available_bytes / vs.total_bytes AS decimal(5,2)) AS free_pct
FROM sys.master_files AS mf
CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_volume_space
AS
-- Toolkit 08_storage_io_files.sql section 8.4: DRIVE / VOLUME FREE SPACE
SET NOCOUNT ON;
SELECT DISTINCT
    vs.volume_mount_point, vs.logical_volume_name, vs.file_system_type,
    vs.total_bytes / 1073741824     AS total_gb,
    vs.available_bytes / 1073741824 AS free_gb,
    CAST(100.0 * vs.available_bytes / vs.total_bytes AS decimal(5,2)) AS free_pct
FROM sys.master_files AS mf
CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs
ORDER BY free_pct;
';
GO

/* 8.5  FILE SIZE & FREE SPACE - CURRENT DB   (08_storage_io_files.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_file_space', @section = N'8.5', @source_file = N'08_storage_io_files.sql',
    @title = N'FILE SIZE & FREE SPACE - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_file_space @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_file_space
    @database_name sysname = NULL
AS
-- Toolkit 08_storage_io_files.sql section 8.5: FILE SIZE & FREE SPACE - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT name AS logical_name, type_desc, physical_name,
       CAST(size / 128.0 AS decimal(18,2))                                         AS size_mb,
       CAST(FILEPROPERTY(name, ''''SpaceUsed'''') / 128.0 AS decimal(18,2))              AS used_mb,
       CAST((size - FILEPROPERTY(name, ''''SpaceUsed'''')) / 128.0 AS decimal(18,2))     AS free_mb,
       CAST(100.0 * (size - FILEPROPERTY(name, ''''SpaceUsed'''')) / NULLIF(size, 0) AS decimal(5,2)) AS free_pct,
       CASE WHEN is_percent_growth = 1 THEN CAST(growth AS varchar(10)) + ''''%''''
            ELSE CAST(growth / 128 AS varchar(10)) + '''' MB'''' END                    AS growth,
       CASE max_size WHEN -1 THEN ''''Unlimited'''' WHEN 0 THEN ''''No growth''''
            ELSE CAST(CAST(max_size AS bigint) / 128 AS varchar(20)) + '''' MB'''' END   AS max_size
FROM sys.database_files;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 8.6  FILE SIZE & FREE SPACE - ALL ONLINE DATABASES   (08_storage_io_files.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_file_space_all_dbs', @section = N'8.6', @source_file = N'08_storage_io_files.sql',
    @title = N'FILE SIZE & FREE SPACE - ALL ONLINE DATABASES', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_file_space_all_dbs;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_file_space_all_dbs
AS
-- Toolkit 08_storage_io_files.sql section 8.6: FILE SIZE & FREE SPACE - ALL ONLINE DATABASES
SET NOCOUNT ON;
IF OBJECT_ID(''tempdb..#files'') IS NOT NULL DROP TABLE #files;
CREATE TABLE #files (database_name sysname, logical_name sysname, type_desc nvarchar(60),
                     size_mb decimal(18,2), used_mb decimal(18,2), physical_name nvarchar(260));
DECLARE @sql nvarchar(max) = N'''';
SELECT @sql += N''USE '' + QUOTENAME(name) + N'';
INSERT #files SELECT DB_NAME(), name, type_desc, size/128.0, FILEPROPERTY(name,''''SpaceUsed'''')/128.0, physical_name FROM sys.database_files;
''
FROM sys.databases WHERE state_desc = N''ONLINE'' AND HAS_DBACCESS(name) = 1;
EXEC sys.sp_executesql @sql;
SELECT database_name, logical_name, type_desc, size_mb, used_mb,
       size_mb - used_mb AS free_mb,
       CAST(100.0 * (size_mb - used_mb) / NULLIF(size_mb, 0) AS decimal(5,2)) AS free_pct,
       physical_name
FROM #files ORDER BY free_mb DESC;
',
    @fallback_definition = NULL;
GO

/* 8.7  LOG SPACE - ALL DATABASES + WHY LOG CAN'T TRUNCATE   (08_storage_io_files.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_log_space', @section = N'8.7', @source_file = N'08_storage_io_files.sql',
    @title = N'LOG SPACE - ALL DATABASES + WHY LOG CAN''T TRUNCATE', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_log_space;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_log_space
AS
-- Toolkit 08_storage_io_files.sql section 8.7: LOG SPACE - ALL DATABASES + WHY LOG CAN''T TRUNCATE
SET NOCOUNT ON;
DBCC SQLPERF(LOGSPACE);

SELECT name, recovery_model_desc, log_reuse_wait_desc
FROM sys.databases
WHERE log_reuse_wait_desc <> N''NOTHING''
ORDER BY name;
',
    @fallback_definition = NULL;
GO

/* 8.8  LOG STATS PER DATABASE (2016 SP2+)   (08_storage_io_files.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_log_stats', @section = N'8.8', @source_file = N'08_storage_io_files.sql',
    @title = N'LOG STATS PER DATABASE (2016 SP2+)', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_log_stats ORDER BY total_log_size_mb DESC;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY ls.total_log_size_mb DESC',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_log_stats
AS
-- Toolkit 08_storage_io_files.sql section 8.8: LOG STATS PER DATABASE (2016 SP2+)
SELECT d.name, d.recovery_model_desc,
       ls.total_log_size_mb, ls.active_log_size_mb,
       ls.log_since_last_log_backup_mb, ls.log_backup_time,
       ls.log_since_last_checkpoint_mb, ls.total_vlf_count, ls.active_vlf_count,
       ls.log_truncation_holdup_reason, ls.log_recovery_size_mb
FROM sys.databases AS d
CROSS APPLY sys.dm_db_log_stats(d.database_id) AS ls
WHERE d.state_desc = N''ONLINE'';
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_log_stats
AS
-- Toolkit 08_storage_io_files.sql section 8.8: LOG STATS PER DATABASE (2016 SP2+)
SET NOCOUNT ON;
SELECT d.name, d.recovery_model_desc,
       ls.total_log_size_mb, ls.active_log_size_mb,
       ls.log_since_last_log_backup_mb, ls.log_backup_time,
       ls.log_since_last_checkpoint_mb, ls.total_vlf_count, ls.active_vlf_count,
       ls.log_truncation_holdup_reason, ls.log_recovery_size_mb
FROM sys.databases AS d
CROSS APPLY sys.dm_db_log_stats(d.database_id) AS ls
WHERE d.state_desc = N''ONLINE''
ORDER BY ls.total_log_size_mb DESC;
';
GO

/* 8.9  VLF COUNT PER DATABASE (2016 SP2+)   (08_storage_io_files.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_vlf_counts', @section = N'8.9', @source_file = N'08_storage_io_files.sql',
    @title = N'VLF COUNT PER DATABASE (2016 SP2+)', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_vlf_counts ORDER BY vlf_count DESC;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY vlf_count DESC',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_vlf_counts
AS
-- Toolkit 08_storage_io_files.sql section 8.9: VLF COUNT PER DATABASE (2016 SP2+)
SELECT d.name AS database_name, COUNT(li.database_id) AS vlf_count,
       SUM(CASE WHEN li.vlf_active = 1 THEN 1 ELSE 0 END) AS active_vlfs,
       CAST(SUM(li.vlf_size_mb) AS decimal(18,2)) AS log_size_mb
FROM sys.databases AS d
CROSS APPLY sys.dm_db_log_info(d.database_id) AS li
WHERE d.state_desc = N''ONLINE''
GROUP BY d.name;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_vlf_counts
AS
-- Toolkit 08_storage_io_files.sql section 8.9: VLF COUNT PER DATABASE (2016 SP2+)
SET NOCOUNT ON;
SELECT d.name AS database_name, COUNT(li.database_id) AS vlf_count,
       SUM(CASE WHEN li.vlf_active = 1 THEN 1 ELSE 0 END) AS active_vlfs,
       CAST(SUM(li.vlf_size_mb) AS decimal(18,2)) AS log_size_mb
FROM sys.databases AS d
CROSS APPLY sys.dm_db_log_info(d.database_id) AS li
WHERE d.state_desc = N''ONLINE''
GROUP BY d.name
ORDER BY vlf_count DESC;
';
GO

/* 8.10  AUTOGROWTH SETTINGS - FLAG % GROWTH & TINY INCREMENTS   (08_storage_io_files.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_autogrowth_settings', @section = N'8.10', @source_file = N'08_storage_io_files.sql',
    @title = N'AUTOGROWTH SETTINGS - FLAG % GROWTH & TINY INCREMENTS', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_autogrowth_settings;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_autogrowth_settings
AS
-- Toolkit 08_storage_io_files.sql section 8.10: AUTOGROWTH SETTINGS - FLAG % GROWTH & TINY INCREMENTS
SET NOCOUNT ON;
SELECT DB_NAME(database_id) AS database_name, name AS logical_name, type_desc,
       CAST(CAST(size AS bigint) * 8 / 1024 AS bigint) AS size_mb,
       CASE WHEN is_percent_growth = 1 THEN CAST(growth AS varchar(10)) + '' %''
            ELSE CAST(growth * 8 / 1024 AS varchar(10)) + '' MB'' END AS growth_setting,
       CASE WHEN is_percent_growth = 1 THEN ''WARN: percent growth''
            WHEN growth * 8 / 1024 < 64 AND growth <> 0 THEN ''WARN: growth < 64 MB''
            WHEN growth = 0 THEN ''WARN: autogrowth disabled''
            ELSE ''OK'' END AS finding
FROM sys.master_files
ORDER BY finding DESC, database_name;
',
    @fallback_definition = NULL;
GO

/* 8.11  RECENT AUTOGROWTH / SHRINK EVENTS (default trace)   (08_storage_io_files.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_autogrowth_events', @section = N'8.11', @source_file = N'08_storage_io_files.sql',
    @title = N'RECENT AUTOGROWTH / SHRINK EVENTS (default trace)', @tags = N'BOX',
    @usage = N'EXEC dbo.HC_autogrowth_events;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_autogrowth_events
AS
-- Toolkit 08_storage_io_files.sql section 8.11: RECENT AUTOGROWTH / SHRINK EVENTS (default trace)
SET NOCOUNT ON;
DECLARE @trc nvarchar(260);
SELECT @trc = REVERSE(SUBSTRING(REVERSE(path), CHARINDEX(N''\'', REVERSE(path)), 260)) + N''log.trc''
FROM sys.traces WHERE is_default = 1;

SELECT te.name AS event_name, t.DatabaseName, t.FileName, t.StartTime,
       t.Duration / 1000 AS duration_ms,
       t.IntegerData * 8 / 1024 AS growth_mb,
       t.LoginName, t.ApplicationName, t.HostName
FROM sys.fn_trace_gettable(@trc, DEFAULT) AS t
JOIN sys.trace_events AS te ON te.trace_event_id = t.EventClass
WHERE t.EventClass IN (92, 93, 94, 95)
ORDER BY t.StartTime DESC;
',
    @fallback_definition = NULL;
GO

/* 8.12  LARGEST TABLES - CURRENT DB   (08_storage_io_files.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_largest_tables', @section = N'8.12', @source_file = N'08_storage_io_files.sql',
    @title = N'LARGEST TABLES - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_largest_tables @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_largest_tables
    @database_name sysname = NULL
AS
-- Toolkit 08_storage_io_files.sql section 8.12: LARGEST TABLES - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT TOP (50)
    OBJECT_SCHEMA_NAME(ps.object_id) + N''''.'''' + OBJECT_NAME(ps.object_id) AS table_name,
    SUM(CASE WHEN ps.index_id < 2 THEN ps.row_count ELSE 0 END)          AS row_count,
    CAST(SUM(ps.reserved_page_count) * 8 / 1024.0 AS decimal(18,2))      AS reserved_mb,
    CAST(SUM(CASE WHEN ps.index_id < 2 THEN ps.used_page_count ELSE 0 END) * 8 / 1024.0 AS decimal(18,2)) AS data_mb,
    CAST(SUM(CASE WHEN ps.index_id > 1 THEN ps.used_page_count ELSE 0 END) * 8 / 1024.0 AS decimal(18,2)) AS index_mb
FROM sys.dm_db_partition_stats AS ps
WHERE OBJECTPROPERTY(ps.object_id, ''''IsMSShipped'''') = 0
GROUP BY ps.object_id
ORDER BY reserved_mb DESC;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 9.1  TEMPDB FILE LAYOUT (equal sizes? equal growth? # files vs cores)   (09_tempdb.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_tempdb_files', @section = N'9.1', @source_file = N'09_tempdb.sql',
    @title = N'TEMPDB FILE LAYOUT (equal sizes? equal growth? # files vs cores)', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_tempdb_files;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_tempdb_files
AS
-- Toolkit 09_tempdb.sql section 9.1: TEMPDB FILE LAYOUT (equal sizes? equal growth? # files vs cores)
SET NOCOUNT ON;
SELECT name, type_desc, physical_name,
       CAST(CAST(size AS bigint) * 8 / 1024 AS bigint) AS size_mb,
       CASE WHEN is_percent_growth = 1 THEN CAST(growth AS varchar(10)) + '' %''
            ELSE CAST(growth * 8 / 1024 AS varchar(10)) + '' MB'' END AS growth
FROM sys.master_files
WHERE database_id = 2
ORDER BY type_desc DESC, file_id;

SELECT (SELECT COUNT(*) FROM sys.master_files WHERE database_id = 2 AND type = 0) AS tempdb_data_files,
       (SELECT cpu_count FROM sys.dm_os_sys_info)                                AS logical_cpus,
       (SELECT COUNT(DISTINCT size) FROM sys.master_files WHERE database_id = 2 AND type = 0) AS distinct_sizes;
',
    @fallback_definition = NULL;
GO

/* 9.2  TEMPDB SPACE BY CATEGORY   (09_tempdb.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_tempdb_space', @section = N'9.2', @source_file = N'09_tempdb.sql',
    @title = N'TEMPDB SPACE BY CATEGORY', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_tempdb_space;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_tempdb_space
AS
-- Toolkit 09_tempdb.sql section 9.2: TEMPDB SPACE BY CATEGORY
SELECT
    SUM(total_page_count)                 * 8 / 1024 AS total_mb,
    SUM(unallocated_extent_page_count)    * 8 / 1024 AS free_mb,
    SUM(user_object_reserved_page_count)  * 8 / 1024 AS user_objects_mb,
    SUM(internal_object_reserved_page_count) * 8 / 1024 AS internal_objects_mb,
    SUM(version_store_reserved_page_count)   * 8 / 1024 AS version_store_mb,
    SUM(mixed_extent_page_count)          * 8 / 1024 AS mixed_extents_mb
FROM tempdb.sys.dm_db_file_space_usage;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_tempdb_space
AS
-- Toolkit 09_tempdb.sql section 9.2: TEMPDB SPACE BY CATEGORY
SET NOCOUNT ON;
SELECT
    SUM(total_page_count)                 * 8 / 1024 AS total_mb,
    SUM(unallocated_extent_page_count)    * 8 / 1024 AS free_mb,
    SUM(user_object_reserved_page_count)  * 8 / 1024 AS user_objects_mb,
    SUM(internal_object_reserved_page_count) * 8 / 1024 AS internal_objects_mb,
    SUM(version_store_reserved_page_count)   * 8 / 1024 AS version_store_mb,
    SUM(mixed_extent_page_count)          * 8 / 1024 AS mixed_extents_mb
FROM tempdb.sys.dm_db_file_space_usage;
';
GO

/* 9.3  TEMPDB USAGE BY SESSION (allocated incl. running tasks)   (09_tempdb.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_tempdb_by_session', @section = N'9.3', @source_file = N'09_tempdb.sql',
    @title = N'TEMPDB USAGE BY SESSION (allocated incl. running tasks)', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_tempdb_by_session;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_tempdb_by_session
AS
-- Toolkit 09_tempdb.sql section 9.3: TEMPDB USAGE BY SESSION (allocated incl. running tasks)
WITH task AS (
    SELECT session_id,
           SUM(user_objects_alloc_page_count - user_objects_dealloc_page_count)         AS task_user_pages,
           SUM(internal_objects_alloc_page_count - internal_objects_dealloc_page_count) AS task_internal_pages
    FROM tempdb.sys.dm_db_task_space_usage
    GROUP BY session_id
)
SELECT TOP (25)
    ss.session_id, s.login_name, s.host_name, s.program_name, s.status,
    (ss.user_objects_alloc_page_count - ss.user_objects_dealloc_page_count + ISNULL(t.task_user_pages, 0)) * 8 / 1024         AS user_obj_mb,
    (ss.internal_objects_alloc_page_count - ss.internal_objects_dealloc_page_count + ISNULL(t.task_internal_pages, 0)) * 8 / 1024 AS internal_obj_mb,
    ib.event_info AS last_sql
FROM tempdb.sys.dm_db_session_space_usage AS ss
JOIN sys.dm_exec_sessions AS s ON s.session_id = ss.session_id
LEFT JOIN task AS t ON t.session_id = ss.session_id
OUTER APPLY sys.dm_exec_input_buffer(ss.session_id, NULL) AS ib
WHERE s.is_user_process = 1
ORDER BY user_obj_mb + internal_obj_mb DESC;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_tempdb_by_session
AS
-- Toolkit 09_tempdb.sql section 9.3: TEMPDB USAGE BY SESSION (allocated incl. running tasks)
SET NOCOUNT ON;
WITH task AS (
    SELECT session_id,
           SUM(user_objects_alloc_page_count - user_objects_dealloc_page_count)         AS task_user_pages,
           SUM(internal_objects_alloc_page_count - internal_objects_dealloc_page_count) AS task_internal_pages
    FROM tempdb.sys.dm_db_task_space_usage
    GROUP BY session_id
)
SELECT TOP (25)
    ss.session_id, s.login_name, s.host_name, s.program_name, s.status,
    (ss.user_objects_alloc_page_count - ss.user_objects_dealloc_page_count + ISNULL(t.task_user_pages, 0)) * 8 / 1024         AS user_obj_mb,
    (ss.internal_objects_alloc_page_count - ss.internal_objects_dealloc_page_count + ISNULL(t.task_internal_pages, 0)) * 8 / 1024 AS internal_obj_mb,
    ib.event_info AS last_sql
FROM tempdb.sys.dm_db_session_space_usage AS ss
JOIN sys.dm_exec_sessions AS s ON s.session_id = ss.session_id
LEFT JOIN task AS t ON t.session_id = ss.session_id
OUTER APPLY sys.dm_exec_input_buffer(ss.session_id, NULL) AS ib
WHERE s.is_user_process = 1
ORDER BY user_obj_mb + internal_obj_mb DESC;
';
GO

/* 9.4  VERSION STORE BY DATABASE (2016 SP2+ / 2017+)   (09_tempdb.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_version_store', @section = N'9.4', @source_file = N'09_tempdb.sql',
    @title = N'VERSION STORE BY DATABASE (2016 SP2+ / 2017+)', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_version_store ORDER BY version_store_mb DESC;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY reserved_page_count DESC',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_version_store
AS
-- Toolkit 09_tempdb.sql section 9.4: VERSION STORE BY DATABASE (2016 SP2+ / 2017+)
SELECT DB_NAME(database_id) AS database_name,
       reserved_page_count * 8 / 1024 AS version_store_mb,
       reserved_space_kb / 1024       AS reserved_mb
FROM sys.dm_tran_version_store_space_usage;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_version_store
AS
-- Toolkit 09_tempdb.sql section 9.4: VERSION STORE BY DATABASE (2016 SP2+ / 2017+)
SET NOCOUNT ON;
SELECT DB_NAME(database_id) AS database_name,
       reserved_page_count * 8 / 1024 AS version_store_mb,
       reserved_space_kb / 1024       AS reserved_mb
FROM sys.dm_tran_version_store_space_usage
ORDER BY reserved_page_count DESC;
';
GO

/* 9.5  LONG-RUNNING SNAPSHOT TRANSACTIONS (hold version store)   (09_tempdb.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_snapshot_transactions', @section = N'9.5', @source_file = N'09_tempdb.sql',
    @title = N'LONG-RUNNING SNAPSHOT TRANSACTIONS (hold version store)', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_snapshot_transactions ORDER BY elapsed_time_seconds DESC;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_snapshot_transactions
AS
-- Toolkit 09_tempdb.sql section 9.5: LONG-RUNNING SNAPSHOT TRANSACTIONS (hold version store)
SELECT TOP (20) ast.session_id, ast.transaction_id, ast.elapsed_time_seconds,
       ast.is_snapshot, s.login_name, s.host_name, s.program_name, ib.event_info AS last_sql
FROM sys.dm_tran_active_snapshot_database_transactions AS ast
JOIN sys.dm_exec_sessions AS s ON s.session_id = ast.session_id
OUTER APPLY sys.dm_exec_input_buffer(ast.session_id, NULL) AS ib
ORDER BY ast.elapsed_time_seconds DESC;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_snapshot_transactions
AS
-- Toolkit 09_tempdb.sql section 9.5: LONG-RUNNING SNAPSHOT TRANSACTIONS (hold version store)
SET NOCOUNT ON;
SELECT TOP (20) ast.session_id, ast.transaction_id, ast.elapsed_time_seconds,
       ast.is_snapshot, s.login_name, s.host_name, s.program_name, ib.event_info AS last_sql
FROM sys.dm_tran_active_snapshot_database_transactions AS ast
JOIN sys.dm_exec_sessions AS s ON s.session_id = ast.session_id
OUTER APPLY sys.dm_exec_input_buffer(ast.session_id, NULL) AS ib
ORDER BY ast.elapsed_time_seconds DESC;
';
GO

/* 9.6  TEMPDB ALLOCATION CONTENTION (PAGELATCH on db 2)   (09_tempdb.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_tempdb_contention', @section = N'9.6', @source_file = N'09_tempdb.sql',
    @title = N'TEMPDB ALLOCATION CONTENTION (PAGELATCH on db 2)', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_tempdb_contention;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_tempdb_contention
AS
-- Toolkit 09_tempdb.sql section 9.6: TEMPDB ALLOCATION CONTENTION (PAGELATCH on db 2)
SELECT session_id, wait_type, wait_duration_ms, resource_description
FROM sys.dm_os_waiting_tasks
WHERE wait_type LIKE N''PAGELATCH%''
  AND resource_description LIKE N''2:%'';
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_tempdb_contention
AS
-- Toolkit 09_tempdb.sql section 9.6: TEMPDB ALLOCATION CONTENTION (PAGELATCH on db 2)
SET NOCOUNT ON;
SELECT session_id, wait_type, wait_duration_ms, resource_description
FROM sys.dm_os_waiting_tasks
WHERE wait_type LIKE N''PAGELATCH%''
  AND resource_description LIKE N''2:%'';
';
GO

/* 9.7  MEMORY-OPTIMIZED TEMPDB METADATA (2019+)   (09_tempdb.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_tempdb_metadata', @section = N'9.7', @source_file = N'09_tempdb.sql',
    @title = N'MEMORY-OPTIMIZED TEMPDB METADATA (2019+)', @tags = N'BOX',
    @usage = N'SELECT * FROM dbo.HC_tempdb_metadata;',
    @min_version = 15,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_tempdb_metadata
AS
-- Toolkit 09_tempdb.sql section 9.7: MEMORY-OPTIMIZED TEMPDB METADATA (2019+)
SELECT SERVERPROPERTY(''IsTempdbMetadataMemoryOptimized'') AS is_tempdb_metadata_memory_optimized;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_tempdb_metadata
AS
-- Toolkit 09_tempdb.sql section 9.7: MEMORY-OPTIMIZED TEMPDB METADATA (2019+)
SET NOCOUNT ON;
SELECT SERVERPROPERTY(''IsTempdbMetadataMemoryOptimized'') AS is_tempdb_metadata_memory_optimized;
';
GO

/* 10.1  LAST BACKUP PER DATABASE + RPO FLAGS   (10_backup_restore.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_last_backup', @section = N'10.1', @source_file = N'10_backup_restore.sql',
    @title = N'LAST BACKUP PER DATABASE + RPO FLAGS', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_last_backup;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_last_backup
AS
-- Toolkit 10_backup_restore.sql section 10.1: LAST BACKUP PER DATABASE + RPO FLAGS
SET NOCOUNT ON;
WITH last_bk AS (
    SELECT database_name,
           MAX(CASE WHEN type = ''D'' THEN backup_finish_date END) AS last_full,
           MAX(CASE WHEN type = ''I'' THEN backup_finish_date END) AS last_diff,
           MAX(CASE WHEN type = ''L'' THEN backup_finish_date END) AS last_log
    FROM msdb.dbo.backupset
    WHERE is_copy_only = 0
    GROUP BY database_name
)
SELECT d.name, d.recovery_model_desc, d.state_desc,
       b.last_full, b.last_diff, b.last_log,
       DATEDIFF(HOUR,   b.last_full, GETDATE()) AS hours_since_full,
       DATEDIFF(MINUTE, b.last_log,  GETDATE()) AS minutes_since_log,
       CASE
           WHEN b.last_full IS NULL                                          THEN ''CRITICAL: never had a full backup''
           WHEN DATEDIFF(DAY, b.last_full, GETDATE()) > 7
            AND (b.last_diff IS NULL OR DATEDIFF(DAY, b.last_diff, GETDATE()) > 1) THEN ''WARN: full > 7 days and no recent diff''
           WHEN d.recovery_model_desc <> ''SIMPLE'' AND b.last_log IS NULL      THEN ''CRITICAL: FULL recovery but no log backup''
           WHEN d.recovery_model_desc <> ''SIMPLE''
            AND DATEDIFF(MINUTE, b.last_log, GETDATE()) > 60                  THEN ''WARN: log backup > 60 min old''
           ELSE ''OK'' END AS finding
FROM sys.databases AS d
LEFT JOIN last_bk  AS b ON b.database_name = d.name
WHERE d.database_id <> 2
ORDER BY finding, d.name;
',
    @fallback_definition = NULL;
GO

/* 10.2  BACKUP HISTORY - LAST N DAYS (size, speed, location)   (10_backup_restore.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_backup_history', @section = N'10.2', @source_file = N'10_backup_restore.sql',
    @title = N'BACKUP HISTORY - LAST N DAYS (size, speed, location)', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_backup_history @days = 7;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_backup_history
    @days int = 7
AS
-- Toolkit 10_backup_restore.sql section 10.2: BACKUP HISTORY - LAST N DAYS (size, speed, location)
SET NOCOUNT ON;
SELECT
    bs.database_name,
    CASE bs.type WHEN ''D'' THEN ''FULL'' WHEN ''I'' THEN ''DIFF'' WHEN ''L'' THEN ''LOG''
                 WHEN ''F'' THEN ''FILE'' WHEN ''G'' THEN ''DIFF FILE'' ELSE bs.type END AS backup_type,
    bs.backup_start_date, bs.backup_finish_date,
    DATEDIFF(SECOND, bs.backup_start_date, bs.backup_finish_date)            AS duration_s,
    CAST(bs.backup_size / 1048576.0 AS decimal(18,2))                         AS size_mb,
    CAST(bs.compressed_backup_size / 1048576.0 AS decimal(18,2))              AS compressed_mb,
    CAST(bs.backup_size / 1048576.0
         / NULLIF(DATEDIFF(SECOND, bs.backup_start_date, bs.backup_finish_date), 0) AS decimal(18,2)) AS mb_per_sec,
    bs.is_copy_only, bs.has_backup_checksums, bs.is_damaged,
    bs.encryptor_type, bs.key_algorithm,
    bs.server_name, bs.user_name, bmf.physical_device_name
FROM msdb.dbo.backupset AS bs
JOIN msdb.dbo.backupmediafamily AS bmf ON bmf.media_set_id = bs.media_set_id
WHERE bs.backup_start_date >= DATEADD(DAY, -@days, GETDATE())
ORDER BY bs.backup_start_date DESC;
',
    @fallback_definition = NULL;
GO

/* 10.3  BACKUP / RESTORE / DBCC PROGRESS (live)   (10_backup_restore.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_backup_restore_progress', @section = N'10.3', @source_file = N'10_backup_restore.sql',
    @title = N'BACKUP / RESTORE / DBCC PROGRESS (live)', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_backup_restore_progress;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_backup_restore_progress
AS
-- Toolkit 10_backup_restore.sql section 10.3: BACKUP / RESTORE / DBCC PROGRESS (live)
SELECT r.session_id, r.command, DB_NAME(r.database_id) AS database_name,
       r.percent_complete,
       DATEADD(MILLISECOND, r.estimated_completion_time, SYSDATETIME()) AS est_finish_time,
       r.estimated_completion_time / 60000 AS est_minutes_left,
       r.total_elapsed_time / 60000        AS elapsed_minutes,
       r.wait_type, t.text
FROM sys.dm_exec_requests AS r
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE r.command LIKE N''BACKUP%'' OR r.command LIKE N''RESTORE%'' OR r.command LIKE N''DBCC%''
   OR r.command IN (N''DbccFilesCompact'', N''DbccSpaceReclaim'', N''ALTER INDEX'');
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_backup_restore_progress
AS
-- Toolkit 10_backup_restore.sql section 10.3: BACKUP / RESTORE / DBCC PROGRESS (live)
SET NOCOUNT ON;
SELECT r.session_id, r.command, DB_NAME(r.database_id) AS database_name,
       r.percent_complete,
       DATEADD(MILLISECOND, r.estimated_completion_time, SYSDATETIME()) AS est_finish_time,
       r.estimated_completion_time / 60000 AS est_minutes_left,
       r.total_elapsed_time / 60000        AS elapsed_minutes,
       r.wait_type, t.text
FROM sys.dm_exec_requests AS r
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE r.command LIKE N''BACKUP%'' OR r.command LIKE N''RESTORE%'' OR r.command LIKE N''DBCC%''
   OR r.command IN (N''DbccFilesCompact'', N''DbccSpaceReclaim'', N''ALTER INDEX'');
';
GO

/* 10.4  RESTORE HISTORY   (10_backup_restore.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_restore_history', @section = N'10.4', @source_file = N'10_backup_restore.sql',
    @title = N'RESTORE HISTORY', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_restore_history;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_restore_history
AS
-- Toolkit 10_backup_restore.sql section 10.4: RESTORE HISTORY
SET NOCOUNT ON;
SELECT TOP (100)
    rh.destination_database_name, rh.restore_date,
    CASE rh.restore_type WHEN ''D'' THEN ''FULL'' WHEN ''I'' THEN ''DIFF'' WHEN ''L'' THEN ''LOG'' ELSE rh.restore_type END AS restore_type,
    rh.user_name, rh.replace, rh.recovery,
    bs.database_name AS source_database, bs.server_name AS source_server,
    bs.backup_finish_date AS backup_taken, bmf.physical_device_name
FROM msdb.dbo.restorehistory AS rh
JOIN msdb.dbo.backupset       AS bs  ON bs.backup_set_id = rh.backup_set_id
JOIN msdb.dbo.backupmediafamily AS bmf ON bmf.media_set_id = bs.media_set_id
ORDER BY rh.restore_date DESC;
',
    @fallback_definition = NULL;
GO

/* 10.5  GENERATE RESTORE SCRIPT (latest FULL + DIFF + LOG chain)   (10_backup_restore.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_generate_restore_script', @section = N'10.5', @source_file = N'10_backup_restore.sql',
    @title = N'GENERATE RESTORE SCRIPT (latest FULL + DIFF + LOG chain)', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_generate_restore_script @database = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_generate_restore_script
    @database sysname = N''YourDB''
AS
-- Toolkit 10_backup_restore.sql section 10.5: GENERATE RESTORE SCRIPT (latest FULL + DIFF + LOG chain)
SET NOCOUNT ON;
DECLARE @full_id int, @full_lsn numeric(25,0), @base_last_lsn numeric(25,0), @diff_id int;

SELECT TOP (1) @full_id = backup_set_id, @full_lsn = checkpoint_lsn, @base_last_lsn = last_lsn
FROM msdb.dbo.backupset
WHERE database_name = @database AND type = ''D'' AND is_copy_only = 0
ORDER BY backup_finish_date DESC;

SELECT TOP (1) @diff_id = backup_set_id, @base_last_lsn = last_lsn
FROM msdb.dbo.backupset
WHERE database_name = @database AND type = ''I'' AND database_backup_lsn = @full_lsn
ORDER BY backup_finish_date DESC;

WITH files AS (
    SELECT bs.backup_set_id, bs.type, bs.first_lsn, bs.backup_finish_date,
           STUFF((SELECT N'', DISK = N'''''' + bmf.physical_device_name + N''''''''
                  FROM msdb.dbo.backupmediafamily AS bmf
                  WHERE bmf.media_set_id = bs.media_set_id
                  ORDER BY bmf.family_sequence_number
                  FOR XML PATH(''''), TYPE).value(''.'', ''nvarchar(max)''), 1, 2, N'''') AS disks
    FROM msdb.dbo.backupset AS bs
    WHERE bs.database_name = @database
      AND (bs.backup_set_id IN (@full_id, @diff_id)
           OR (bs.type = ''L'' AND bs.is_copy_only = 0 AND bs.last_lsn > @base_last_lsn))
)
SELECT CASE type WHEN ''D'' THEN 1 WHEN ''I'' THEN 2 ELSE 3 END AS step,
       backup_finish_date,
       CASE type WHEN ''L'' THEN N''RESTORE LOG '' ELSE N''RESTORE DATABASE '' END
         + QUOTENAME(@database) + N'' FROM '' + disks
         + N'' WITH NORECOVERY'' + CASE type WHEN ''D'' THEN N'', REPLACE, STATS = 10'' ELSE N'''' END + N'';'' AS restore_cmd
FROM files
UNION ALL
SELECT 9, NULL, N''RESTORE DATABASE '' + QUOTENAME(@database) + N'' WITH RECOVERY;''
ORDER BY step, backup_finish_date;
',
    @fallback_definition = NULL;
GO

/* 10.6  BACKUP SIZE TREND (monthly FULL size per DB)   (10_backup_restore.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_backup_size_trend', @section = N'10.6', @source_file = N'10_backup_restore.sql',
    @title = N'BACKUP SIZE TREND (monthly FULL size per DB)', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_backup_size_trend ORDER BY database_name, month_start;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY database_name, month_start',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_backup_size_trend
AS
-- Toolkit 10_backup_restore.sql section 10.6: BACKUP SIZE TREND (monthly FULL size per DB)
SELECT database_name,
       DATEFROMPARTS(YEAR(backup_start_date), MONTH(backup_start_date), 1) AS month_start,
       CAST(AVG(backup_size) / 1073741824.0 AS decimal(18,2))            AS avg_full_gb,
       CAST(AVG(compressed_backup_size) / 1073741824.0 AS decimal(18,2)) AS avg_compressed_gb
FROM msdb.dbo.backupset
WHERE type = ''D'' AND backup_start_date >= DATEADD(MONTH, -12, GETDATE())
GROUP BY database_name, DATEFROMPARTS(YEAR(backup_start_date), MONTH(backup_start_date), 1);
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_backup_size_trend
AS
-- Toolkit 10_backup_restore.sql section 10.6: BACKUP SIZE TREND (monthly FULL size per DB)
SET NOCOUNT ON;
SELECT database_name,
       DATEFROMPARTS(YEAR(backup_start_date), MONTH(backup_start_date), 1) AS month_start,
       CAST(AVG(backup_size) / 1073741824.0 AS decimal(18,2))            AS avg_full_gb,
       CAST(AVG(compressed_backup_size) / 1073741824.0 AS decimal(18,2)) AS avg_compressed_gb
FROM msdb.dbo.backupset
WHERE type = ''D'' AND backup_start_date >= DATEADD(MONTH, -12, GETDATE())
GROUP BY database_name, DATEFROMPARTS(YEAR(backup_start_date), MONTH(backup_start_date), 1)
ORDER BY database_name, month_start;
';
GO

/* 10.7  BACKUP TO URL CREDENTIALS (Azure blob)   (10_backup_restore.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_backup_url_credentials', @section = N'10.7', @source_file = N'10_backup_restore.sql',
    @title = N'BACKUP TO URL CREDENTIALS (Azure blob)', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_backup_url_credentials;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_backup_url_credentials
AS
-- Toolkit 10_backup_restore.sql section 10.7: BACKUP TO URL CREDENTIALS (Azure blob)
SELECT name, credential_identity, create_date, modify_date FROM sys.credentials;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_backup_url_credentials
AS
-- Toolkit 10_backup_restore.sql section 10.7: BACKUP TO URL CREDENTIALS (Azure blob)
SET NOCOUNT ON;
SELECT name, credential_identity, create_date, modify_date FROM sys.credentials;
';
GO

/* 11.1  AG DASHBOARD - ONE ROW PER AG   (11_alwayson_ag.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_ag_dashboard', @section = N'11.1', @source_file = N'11_alwayson_ag.sql',
    @title = N'AG DASHBOARD - ONE ROW PER AG', @tags = N'BOX',
    @usage = N'SELECT * FROM dbo.HC_ag_dashboard;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_ag_dashboard
AS
-- Toolkit 11_alwayson_ag.sql section 11.1: AG DASHBOARD - ONE ROW PER AG
SELECT ag.name AS ag_name, ags.primary_replica, ags.primary_recovery_health_desc,
       ags.synchronization_health_desc,
       ag.automated_backup_preference_desc,
       ag.failure_condition_level, ag.health_check_timeout,
       ag.db_failover, ag.dtc_support, ag.is_distributed

FROM sys.availability_groups AS ag
JOIN sys.dm_hadr_availability_group_states AS ags ON ags.group_id = ag.group_id;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_ag_dashboard
AS
-- Toolkit 11_alwayson_ag.sql section 11.1: AG DASHBOARD - ONE ROW PER AG
SET NOCOUNT ON;
SELECT ag.name AS ag_name, ags.primary_replica, ags.primary_recovery_health_desc,
       ags.synchronization_health_desc,
       ag.automated_backup_preference_desc,
       ag.failure_condition_level, ag.health_check_timeout,
       ag.db_failover, ag.dtc_support, ag.is_distributed

FROM sys.availability_groups AS ag
JOIN sys.dm_hadr_availability_group_states AS ags ON ags.group_id = ag.group_id;
';
GO

/* 11.2  REPLICA STATE & CONFIGURATION   (11_alwayson_ag.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_ag_replicas', @section = N'11.2', @source_file = N'11_alwayson_ag.sql',
    @title = N'REPLICA STATE & CONFIGURATION', @tags = N'BOX',
    @usage = N'SELECT * FROM dbo.HC_ag_replicas ORDER BY ag_name, role_desc, replica_server_name;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY ag.name, ars.role_desc, ar.replica_server_name',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_ag_replicas
AS
-- Toolkit 11_alwayson_ag.sql section 11.2: REPLICA STATE & CONFIGURATION
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
LEFT JOIN sys.dm_hadr_availability_replica_states AS ars ON ars.replica_id = ar.replica_id;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_ag_replicas
AS
-- Toolkit 11_alwayson_ag.sql section 11.2: REPLICA STATE & CONFIGURATION
SET NOCOUNT ON;
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
';
GO

/* 11.3  DATABASE SYNC STATE, LAG, RPO / RTO ESTIMATES   (11_alwayson_ag.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_ag_db_sync', @section = N'11.3', @source_file = N'11_alwayson_ag.sql',
    @title = N'DATABASE SYNC STATE, LAG, RPO / RTO ESTIMATES', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_ag_db_sync ORDER BY ag_name, database_name, is_primary_replica DESC, replica_server_name;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY ag.name, database_name, drs.is_primary_replica DESC, ar.replica_server_name',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_ag_db_sync
AS
-- Toolkit 11_alwayson_ag.sql section 11.3: DATABASE SYNC STATE, LAG, RPO / RTO ESTIMATES
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
JOIN sys.availability_groups    AS ag ON ag.group_id = drs.group_id;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_ag_db_sync
AS
-- Toolkit 11_alwayson_ag.sql section 11.3: DATABASE SYNC STATE, LAG, RPO / RTO ESTIMATES
SET NOCOUNT ON;
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
';
GO

/* 11.4  DATA LOSS WINDOW: primary vs secondary last_commit_time   (11_alwayson_ag.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_ag_data_loss_window', @section = N'11.4', @source_file = N'11_alwayson_ag.sql',
    @title = N'DATA LOSS WINDOW: primary vs secondary last_commit_time', @tags = N'BOX',
    @usage = N'SELECT * FROM dbo.HC_ag_data_loss_window ORDER BY potential_data_loss_s DESC;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY potential_data_loss_s DESC',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_ag_data_loss_window
AS
-- Toolkit 11_alwayson_ag.sql section 11.4: DATA LOSS WINDOW: primary vs secondary last_commit_time
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
WHERE p.is_primary_replica = 1;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_ag_data_loss_window
AS
-- Toolkit 11_alwayson_ag.sql section 11.4: DATA LOSS WINDOW: primary vs secondary last_commit_time
SET NOCOUNT ON;
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
';
GO

/* 11.5  FAILOVER READINESS (is_failover_ready must be 1 on sync targets)   (11_alwayson_ag.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_ag_failover_readiness', @section = N'11.5', @source_file = N'11_alwayson_ag.sql',
    @title = N'FAILOVER READINESS (is_failover_ready must be 1 on sync targets)', @tags = N'BOX',
    @usage = N'SELECT * FROM dbo.HC_ag_failover_readiness ORDER BY ag_name, database_name, replica_server_name;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY ag.name, dcs.database_name, ar.replica_server_name',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_ag_failover_readiness
AS
-- Toolkit 11_alwayson_ag.sql section 11.5: FAILOVER READINESS (is_failover_ready must be 1 on sync targets)
SELECT ag.name AS ag_name, ar.replica_server_name, dcs.database_name,
       dcs.is_failover_ready, dcs.is_pending_secondary_suspend, dcs.is_database_joined,
       dcs.recovery_lsn, dcs.truncation_lsn
FROM sys.dm_hadr_database_replica_cluster_states AS dcs
JOIN sys.availability_replicas AS ar ON ar.replica_id = dcs.replica_id
JOIN sys.availability_groups   AS ag ON ag.group_id = ar.group_id;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_ag_failover_readiness
AS
-- Toolkit 11_alwayson_ag.sql section 11.5: FAILOVER READINESS (is_failover_ready must be 1 on sync targets)
SET NOCOUNT ON;
SELECT ag.name AS ag_name, ar.replica_server_name, dcs.database_name,
       dcs.is_failover_ready, dcs.is_pending_secondary_suspend, dcs.is_database_joined,
       dcs.recovery_lsn, dcs.truncation_lsn
FROM sys.dm_hadr_database_replica_cluster_states AS dcs
JOIN sys.availability_replicas AS ar ON ar.replica_id = dcs.replica_id
JOIN sys.availability_groups   AS ag ON ag.group_id = ar.group_id
ORDER BY ag.name, dcs.database_name, ar.replica_server_name;
';
GO

/* 11.6  HELPER FUNCTIONS (per database)   (11_alwayson_ag.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_ag_helper_functions', @section = N'11.6', @source_file = N'11_alwayson_ag.sql',
    @title = N'HELPER FUNCTIONS (per database)', @tags = N'BOX',
    @usage = N'SELECT * FROM dbo.HC_ag_helper_functions;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_ag_helper_functions
AS
-- Toolkit 11_alwayson_ag.sql section 11.6: HELPER FUNCTIONS (per database)
SELECT d.name,
       sys.fn_hadr_is_primary_replica(d.name)          AS is_primary_here,
       sys.fn_hadr_backup_is_preferred_replica(d.name) AS is_preferred_backup_replica,
       d.replica_id, d.group_database_id
FROM sys.databases AS d
WHERE d.replica_id IS NOT NULL;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_ag_helper_functions
AS
-- Toolkit 11_alwayson_ag.sql section 11.6: HELPER FUNCTIONS (per database)
SET NOCOUNT ON;
SELECT d.name,
       sys.fn_hadr_is_primary_replica(d.name)          AS is_primary_here,
       sys.fn_hadr_backup_is_preferred_replica(d.name) AS is_preferred_backup_replica,
       d.replica_id, d.group_database_id
FROM sys.databases AS d
WHERE d.replica_id IS NOT NULL;
';
GO

/* 11.7  DATABASES NOT IN ANY AG (on an AG-enabled server)   (11_alwayson_ag.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_dbs_not_in_ag', @section = N'11.7', @source_file = N'11_alwayson_ag.sql',
    @title = N'DATABASES NOT IN ANY AG (on an AG-enabled server)', @tags = N'BOX',
    @usage = N'SELECT * FROM dbo.HC_dbs_not_in_ag ORDER BY name;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY name',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_dbs_not_in_ag
AS
-- Toolkit 11_alwayson_ag.sql section 11.7: DATABASES NOT IN ANY AG (on an AG-enabled server)
SELECT name, recovery_model_desc, state_desc
FROM sys.databases
WHERE database_id > 4 AND replica_id IS NULL;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_dbs_not_in_ag
AS
-- Toolkit 11_alwayson_ag.sql section 11.7: DATABASES NOT IN ANY AG (on an AG-enabled server)
SET NOCOUNT ON;
SELECT name, recovery_model_desc, state_desc
FROM sys.databases
WHERE database_id > 4 AND replica_id IS NULL
ORDER BY name;
';
GO

/* 11.8  LISTENERS (Azure VM: check ILB probe port / DNN)   (11_alwayson_ag.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_ag_listeners', @section = N'11.8', @source_file = N'11_alwayson_ag.sql',
    @title = N'LISTENERS (Azure VM: check ILB probe port / DNN)', @tags = N'BOX',
    @usage = N'SELECT * FROM dbo.HC_ag_listeners;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_ag_listeners
AS
-- Toolkit 11_alwayson_ag.sql section 11.8: LISTENERS (Azure VM: check ILB probe port / DNN)
SELECT ag.name AS ag_name, agl.dns_name, agl.port, agl.is_conformant,
       agl.ip_configuration_string_from_cluster,
       lip.ip_address, lip.ip_subnet_mask, lip.state_desc, lip.network_subnet_ip
FROM sys.availability_group_listeners AS agl
JOIN sys.availability_groups AS ag ON ag.group_id = agl.group_id
LEFT JOIN sys.availability_group_listener_ip_addresses AS lip ON lip.listener_id = agl.listener_id;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_ag_listeners
AS
-- Toolkit 11_alwayson_ag.sql section 11.8: LISTENERS (Azure VM: check ILB probe port / DNN)
SET NOCOUNT ON;
SELECT ag.name AS ag_name, agl.dns_name, agl.port, agl.is_conformant,
       agl.ip_configuration_string_from_cluster,
       lip.ip_address, lip.ip_subnet_mask, lip.state_desc, lip.network_subnet_ip
FROM sys.availability_group_listeners AS agl
JOIN sys.availability_groups AS ag ON ag.group_id = agl.group_id
LEFT JOIN sys.availability_group_listener_ip_addresses AS lip ON lip.listener_id = agl.listener_id;
';
GO

/* 11.9  READ-ONLY ROUTING   (11_alwayson_ag.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_ag_readonly_routing', @section = N'11.9', @source_file = N'11_alwayson_ag.sql',
    @title = N'READ-ONLY ROUTING', @tags = N'BOX',
    @usage = N'SELECT * FROM dbo.HC_ag_readonly_routing ORDER BY ag_name, when_primary_is, routing_priority;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY ag.name, src.replica_server_name, rl.routing_priority',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_ag_readonly_routing
AS
-- Toolkit 11_alwayson_ag.sql section 11.9: READ-ONLY ROUTING
SELECT ag.name AS ag_name, src.replica_server_name AS when_primary_is,
       rl.routing_priority, dst.replica_server_name AS route_reads_to, dst.read_only_routing_url
FROM sys.availability_read_only_routing_lists AS rl
JOIN sys.availability_replicas AS src ON src.replica_id = rl.replica_id
JOIN sys.availability_replicas AS dst ON dst.replica_id = rl.read_only_replica_id
JOIN sys.availability_groups   AS ag  ON ag.group_id = src.group_id;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_ag_readonly_routing
AS
-- Toolkit 11_alwayson_ag.sql section 11.9: READ-ONLY ROUTING
SET NOCOUNT ON;
SELECT ag.name AS ag_name, src.replica_server_name AS when_primary_is,
       rl.routing_priority, dst.replica_server_name AS route_reads_to, dst.read_only_routing_url
FROM sys.availability_read_only_routing_lists AS rl
JOIN sys.availability_replicas AS src ON src.replica_id = rl.replica_id
JOIN sys.availability_replicas AS dst ON dst.replica_id = rl.read_only_replica_id
JOIN sys.availability_groups   AS ag  ON ag.group_id = src.group_id
ORDER BY ag.name, src.replica_server_name, rl.routing_priority;
';
GO

/* 11.10  HADR ENDPOINT (state, port, encryption, connect permission)   (11_alwayson_ag.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_hadr_endpoint', @section = N'11.10', @source_file = N'11_alwayson_ag.sql',
    @title = N'HADR ENDPOINT (state, port, encryption, connect permission)', @tags = N'BOX',
    @usage = N'EXEC dbo.HC_hadr_endpoint;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_hadr_endpoint
AS
-- Toolkit 11_alwayson_ag.sql section 11.10: HADR ENDPOINT (state, port, encryption, connect permission)
SET NOCOUNT ON;
SELECT e.name, e.state_desc, e.role_desc, e.connection_auth_desc,
       e.encryption_algorithm_desc, t.port, SUSER_NAME(e.principal_id) AS endpoint_owner
FROM sys.database_mirroring_endpoints AS e
JOIN sys.tcp_endpoints AS t ON t.endpoint_id = e.endpoint_id;

SELECT ep.name AS endpoint_name, SUSER_NAME(sp.grantee_principal_id) AS grantee,
       sp.permission_name, sp.state_desc
FROM sys.server_permissions AS sp
JOIN sys.endpoints AS ep ON ep.endpoint_id = sp.major_id
WHERE sp.class_desc = ''ENDPOINT'';
',
    @fallback_definition = NULL;
GO

/* 11.11  AUTOMATIC SEEDING PROGRESS   (11_alwayson_ag.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_ag_seeding', @section = N'11.11', @source_file = N'11_alwayson_ag.sql',
    @title = N'AUTOMATIC SEEDING PROGRESS', @tags = N'BOX',
    @usage = N'EXEC dbo.HC_ag_seeding;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_ag_seeding
AS
-- Toolkit 11_alwayson_ag.sql section 11.11: AUTOMATIC SEEDING PROGRESS
SET NOCOUNT ON;
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
',
    @fallback_definition = NULL;
GO

/* 11.12  WSFC CLUSTER, NODES, NETWORKS, QUORUM   (11_alwayson_ag.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_wsfc', @section = N'11.12', @source_file = N'11_alwayson_ag.sql',
    @title = N'WSFC CLUSTER, NODES, NETWORKS, QUORUM', @tags = N'BOX',
    @usage = N'EXEC dbo.HC_wsfc;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_wsfc
AS
-- Toolkit 11_alwayson_ag.sql section 11.12: WSFC CLUSTER, NODES, NETWORKS, QUORUM
SET NOCOUNT ON;
SELECT cluster_name, quorum_type_desc, quorum_state_desc FROM sys.dm_hadr_cluster;
SELECT member_name, member_type_desc, member_state_desc, number_of_quorum_votes FROM sys.dm_hadr_cluster_members;
SELECT member_name, network_subnet_ip, network_subnet_prefix_length, is_public, is_ipv4 FROM sys.dm_hadr_cluster_networks;
',
    @fallback_definition = NULL;
GO

/* 11.13  AG-RELATED WAITS (commit latency on sync replicas)   (11_alwayson_ag.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_ag_waits', @section = N'11.13', @source_file = N'11_alwayson_ag.sql',
    @title = N'AG-RELATED WAITS (commit latency on sync replicas)', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_ag_waits;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_ag_waits
AS
-- Toolkit 11_alwayson_ag.sql section 11.13: AG-RELATED WAITS (commit latency on sync replicas)
SET NOCOUNT ON;
SELECT wait_type, waiting_tasks_count, wait_time_ms,
       CAST(wait_time_ms * 1.0 / NULLIF(waiting_tasks_count, 0) AS decimal(10,2)) AS avg_wait_ms
FROM sys.dm_os_wait_stats
WHERE wait_type IN (N''HADR_SYNC_COMMIT'', N''HADR_GROUP_COMMIT'', N''HADR_LOGCAPTURE_SYNC'',
                    N''HADR_DATABASE_FLOW_CONTROL'', N''HADR_TRANSPORT_FLOW_CONTROL'',
                    N''HADR_SEND_QUEUE'', N''PARALLEL_REDO_FLOW_CONTROL'', N''WRITELOG'')
ORDER BY wait_time_ms DESC;

SELECT RTRIM(object_name) AS object_name, RTRIM(counter_name) AS counter_name,
       RTRIM(instance_name) AS database_name, cntr_value
FROM sys.dm_os_performance_counters
WHERE object_name LIKE N''%Database Replica%''
  AND counter_name IN (N''Redo blocked/sec'', N''Redone Bytes/sec'', N''Log Send Queue'',
                       N''Recovery Queue'', N''Transaction Delay'', N''Mirrored Write Transactions/sec'')
ORDER BY database_name, counter_name;
',
    @fallback_definition = NULL;
GO

/* 11.14  FAILOVER / ROLE CHANGE HISTORY (AlwaysOn_health XE)   (11_alwayson_ag.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_ag_failover_history', @section = N'11.14', @source_file = N'11_alwayson_ag.sql',
    @title = N'FAILOVER / ROLE CHANGE HISTORY (AlwaysOn_health XE)', @tags = N'BOX',
    @usage = N'EXEC dbo.HC_ag_failover_history;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_ag_failover_history
AS
-- Toolkit 11_alwayson_ag.sql section 11.14: FAILOVER / ROLE CHANGE HISTORY (AlwaysOn_health XE)
SET NOCOUNT ON;
DECLARE @logdir nvarchar(260) = (
    SELECT LEFT(CAST(SERVERPROPERTY(''ErrorLogFileName'') AS nvarchar(260)),
                LEN(CAST(SERVERPROPERTY(''ErrorLogFileName'') AS nvarchar(260)))
                - CHARINDEX(N''\'', REVERSE(CAST(SERVERPROPERTY(''ErrorLogFileName'') AS nvarchar(260)))) + 1));

SELECT
    x.ev.value(''(event/@timestamp)[1]'', ''datetime2'')                                         AS event_time_utc,
    x.ev.value(''(event/@name)[1]'', ''nvarchar(100)'')                                          AS event_name,
    x.ev.value(''(event/data[@name="availability_group_name"]/value)[1]'', ''nvarchar(128)'')    AS ag_name,
    x.ev.value(''(event/data[@name="availability_replica_name"]/value)[1]'', ''nvarchar(128)'')  AS replica,
    x.ev.value(''(event/data[@name="previous_state"]/text)[1]'', ''nvarchar(60)'')               AS previous_state,
    x.ev.value(''(event/data[@name="current_state"]/text)[1]'', ''nvarchar(60)'')                AS current_state,
    x.ev.value(''(event/data[@name="error_number"]/value)[1]'', ''int'')                         AS error_number,
    x.ev.value(''(event/data[@name="message"]/value)[1]'', ''nvarchar(max)'')                    AS message
FROM sys.fn_xe_file_target_read_file(@logdir + N''AlwaysOn_health*.xel'', NULL, NULL, NULL) AS f
CROSS APPLY (SELECT CAST(f.event_data AS xml)) AS x(ev)
WHERE f.object_name IN (N''availability_replica_state_change'', N''error_reported'',
                        N''availability_group_lease_expired'', N''availability_replica_automatic_failover_validation'')
ORDER BY event_time_utc DESC;
',
    @fallback_definition = NULL;
GO

/* 12.1  LOCK SUMMARY BY SESSION   (12_locking_deadlocks.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_lock_summary', @section = N'12.1', @source_file = N'12_locking_deadlocks.sql',
    @title = N'LOCK SUMMARY BY SESSION', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_lock_summary ORDER BY lock_count DESC;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY lock_count DESC',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_lock_summary
AS
-- Toolkit 12_locking_deadlocks.sql section 12.1: LOCK SUMMARY BY SESSION
SELECT tl.request_session_id AS session_id, DB_NAME(tl.resource_database_id) AS database_name,
       tl.resource_type, tl.request_mode, tl.request_status, COUNT(*) AS lock_count
FROM sys.dm_tran_locks AS tl
WHERE tl.request_session_id <> @@SPID
GROUP BY tl.request_session_id, tl.resource_database_id, tl.resource_type, tl.request_mode, tl.request_status;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_lock_summary
AS
-- Toolkit 12_locking_deadlocks.sql section 12.1: LOCK SUMMARY BY SESSION
SET NOCOUNT ON;
SELECT tl.request_session_id AS session_id, DB_NAME(tl.resource_database_id) AS database_name,
       tl.resource_type, tl.request_mode, tl.request_status, COUNT(*) AS lock_count
FROM sys.dm_tran_locks AS tl
WHERE tl.request_session_id <> @@SPID
GROUP BY tl.request_session_id, tl.resource_database_id, tl.resource_type, tl.request_mode, tl.request_status
ORDER BY lock_count DESC;
';
GO

/* 12.2  WAITING LOCKS WITH OBJECT NAMES - CURRENT DB   (12_locking_deadlocks.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_waiting_locks', @section = N'12.2', @source_file = N'12_locking_deadlocks.sql',
    @title = N'WAITING LOCKS WITH OBJECT NAMES - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_waiting_locks @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_waiting_locks
    @database_name sysname = NULL
AS
-- Toolkit 12_locking_deadlocks.sql section 12.2: WAITING LOCKS WITH OBJECT NAMES - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT tl.request_session_id AS waiting_session, wt.blocking_session_id,
       tl.resource_type, tl.request_mode, tl.resource_description,
       wt.wait_duration_ms,
       COALESCE(OBJECT_SCHEMA_NAME(p.object_id) + N''''.'''' + OBJECT_NAME(p.object_id),
                OBJECT_SCHEMA_NAME(tl.resource_associated_entity_id) + N''''.'''' + OBJECT_NAME(tl.resource_associated_entity_id)) AS object_name,
       i.name AS index_name
FROM sys.dm_tran_locks AS tl
JOIN sys.dm_os_waiting_tasks AS wt ON wt.resource_address = tl.lock_owner_address
LEFT JOIN sys.partitions AS p
       ON tl.resource_type IN (N''''KEY'''', N''''PAGE'''', N''''RID'''', N''''HOBT'''') AND p.hobt_id = tl.resource_associated_entity_id
LEFT JOIN sys.indexes AS i ON i.object_id = p.object_id AND i.index_id = p.index_id
WHERE tl.request_status = N''''WAIT''''
  AND tl.resource_database_id = DB_ID();'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 12.3  ALL LOCKS HELD BY ONE SESSION - CURRENT DB   (12_locking_deadlocks.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_session_locks', @section = N'12.3', @source_file = N'12_locking_deadlocks.sql',
    @title = N'ALL LOCKS HELD BY ONE SESSION - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_session_locks @database_name = N''YourDB'', @spid = 55;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_session_locks
    @database_name sysname = NULL,
    @spid int = 55
AS
-- Toolkit 12_locking_deadlocks.sql section 12.3: ALL LOCKS HELD BY ONE SESSION - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT tl.resource_type, tl.request_mode, tl.request_status, tl.resource_description,
       CASE WHEN tl.resource_type = N''''OBJECT'''' THEN OBJECT_NAME(tl.resource_associated_entity_id)
            ELSE OBJECT_NAME(p.object_id) END AS object_name,
       COUNT(*) AS locks
FROM sys.dm_tran_locks AS tl
LEFT JOIN sys.partitions AS p ON p.hobt_id = tl.resource_associated_entity_id
WHERE tl.request_session_id = @spid AND tl.resource_database_id = DB_ID()
GROUP BY tl.resource_type, tl.request_mode, tl.request_status, tl.resource_description,
         tl.resource_associated_entity_id, p.object_id
ORDER BY locks DESC;'';
EXEC @hc_exec @hc_sql, N''@spid int'', @spid = @spid;
',
    @fallback_definition = NULL;
GO

/* 12.4  LOCK ESCALATION HOTSPOTS - CURRENT DB   (12_locking_deadlocks.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_lock_escalation', @section = N'12.4', @source_file = N'12_locking_deadlocks.sql',
    @title = N'LOCK ESCALATION HOTSPOTS - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_lock_escalation @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_lock_escalation
    @database_name sysname = NULL
AS
-- Toolkit 12_locking_deadlocks.sql section 12.4: LOCK ESCALATION HOTSPOTS - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT OBJECT_SCHEMA_NAME(os.object_id) + N''''.'''' + OBJECT_NAME(os.object_id) AS table_name,
       i.name AS index_name, t.lock_escalation_desc,
       os.index_lock_promotion_attempt_count, os.index_lock_promotion_count,
       os.row_lock_wait_count, os.row_lock_wait_in_ms, os.page_lock_wait_count, os.page_lock_wait_in_ms
FROM sys.dm_db_index_operational_stats(DB_ID(), NULL, NULL, NULL) AS os
JOIN sys.indexes AS i ON i.object_id = os.object_id AND i.index_id = os.index_id
JOIN sys.tables  AS t ON t.object_id = os.object_id
WHERE os.index_lock_promotion_count > 0
ORDER BY os.index_lock_promotion_count DESC;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 12.5  DEADLOCKS FROM system_health (event_file)   (12_locking_deadlocks.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_deadlocks', @section = N'12.5', @source_file = N'12_locking_deadlocks.sql',
    @title = N'DEADLOCKS FROM system_health (event_file)', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_deadlocks;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_deadlocks
AS
-- Toolkit 12_locking_deadlocks.sql section 12.5: DEADLOCKS FROM system_health (event_file)
SET NOCOUNT ON;
SELECT
    x.ev.value(''(event/@timestamp)[1]'', ''datetime2'')  AS deadlock_time_utc,
    x.ev.query(''(event/data/value/deadlock)[1]'')      AS deadlock_graph,
    x.ev.value(''(event/data/value/deadlock/victim-list/victimProcess/@id)[1]'', ''varchar(50)'') AS victim_process_id
FROM sys.fn_xe_file_target_read_file(N''system_health*.xel'', NULL, NULL, NULL) AS f
CROSS APPLY (SELECT CAST(f.event_data AS xml)) AS x(ev)
WHERE f.object_name = N''xml_deadlock_report''
ORDER BY deadlock_time_utc DESC;
',
    @fallback_definition = NULL;
GO

/* 12.6  DEADLOCK DETAIL - SHRED PROCESSES (who, what statement)   (12_locking_deadlocks.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_deadlock_detail', @section = N'12.6', @source_file = N'12_locking_deadlocks.sql',
    @title = N'DEADLOCK DETAIL - SHRED PROCESSES (who, what statement)', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_deadlock_detail;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_deadlock_detail
AS
-- Toolkit 12_locking_deadlocks.sql section 12.6: DEADLOCK DETAIL - SHRED PROCESSES (who, what statement)
SET NOCOUNT ON;
WITH dl AS (
    SELECT CAST(f.event_data AS xml) AS ev
    FROM sys.fn_xe_file_target_read_file(N''system_health*.xel'', NULL, NULL, NULL) AS f
    WHERE f.object_name = N''xml_deadlock_report''
)
SELECT
    dl.ev.value(''(event/@timestamp)[1]'', ''datetime2'')                     AS deadlock_time_utc,
    p.n.value(''@id'', ''varchar(50)'')                                       AS process_id,
    CASE WHEN p.n.value(''@id'', ''varchar(50)'') =
              dl.ev.value(''(event/data/value/deadlock/victim-list/victimProcess/@id)[1]'', ''varchar(50)'')
         THEN ''VICTIM'' ELSE '''' END                                         AS is_victim,
    p.n.value(''@spid'', ''int'')                                             AS spid,
    p.n.value(''@loginname'', ''nvarchar(128)'')                              AS login_name,
    p.n.value(''@hostname'', ''nvarchar(128)'')                               AS host_name,
    p.n.value(''@clientapp'', ''nvarchar(256)'')                              AS client_app,
    DB_NAME(p.n.value(''@currentdb'', ''int''))                               AS database_name,
    p.n.value(''@isolationlevel'', ''nvarchar(50)'')                          AS isolation_level,
    p.n.value(''@waitresource'', ''nvarchar(256)'')                           AS wait_resource,
    p.n.value(''@lockMode'', ''nvarchar(10)'')                                AS lock_mode,
    p.n.value(''(inputbuf)[1]'', ''nvarchar(max)'')                           AS input_buffer
FROM dl
CROSS APPLY dl.ev.nodes(''event/data/value/deadlock/process-list/process'') AS p(n)
ORDER BY deadlock_time_utc DESC, is_victim DESC;
',
    @fallback_definition = NULL;
GO

/* 12.7  DEADLOCK COUNTER SINCE RESTART   (12_locking_deadlocks.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_deadlock_count', @section = N'12.7', @source_file = N'12_locking_deadlocks.sql',
    @title = N'DEADLOCK COUNTER SINCE RESTART', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_deadlock_count;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_deadlock_count
AS
-- Toolkit 12_locking_deadlocks.sql section 12.7: DEADLOCK COUNTER SINCE RESTART
SELECT RTRIM(instance_name) AS lock_type, cntr_value AS deadlocks
FROM sys.dm_os_performance_counters
WHERE counter_name = N''Number of Deadlocks/sec'' AND cntr_value > 0;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_deadlock_count
AS
-- Toolkit 12_locking_deadlocks.sql section 12.7: DEADLOCK COUNTER SINCE RESTART
SET NOCOUNT ON;
SELECT RTRIM(instance_name) AS lock_type, cntr_value AS deadlocks
FROM sys.dm_os_performance_counters
WHERE counter_name = N''Number of Deadlocks/sec'' AND cntr_value > 0;
';
GO

/* 12.9  ISOLATION LEVEL OF ACTIVE SESSIONS   (12_locking_deadlocks.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_isolation_levels', @section = N'12.9', @source_file = N'12_locking_deadlocks.sql',
    @title = N'ISOLATION LEVEL OF ACTIVE SESSIONS', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_isolation_levels;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_isolation_levels
AS
-- Toolkit 12_locking_deadlocks.sql section 12.9: ISOLATION LEVEL OF ACTIVE SESSIONS
SET NOCOUNT ON;
SELECT session_id, login_name, program_name,
       CASE transaction_isolation_level
           WHEN 0 THEN ''Unspecified'' WHEN 1 THEN ''ReadUncommitted'' WHEN 2 THEN ''ReadCommitted''
           WHEN 3 THEN ''RepeatableRead'' WHEN 4 THEN ''Serializable'' WHEN 5 THEN ''Snapshot'' END AS isolation_level
FROM sys.dm_exec_sessions
WHERE is_user_process = 1
ORDER BY transaction_isolation_level DESC;
',
    @fallback_definition = NULL;
GO

/* 13.1  SERVER ROLE MEMBERS (who is sysadmin etc.)   (13_security.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_server_role_members', @section = N'13.1', @source_file = N'13_security.sql',
    @title = N'SERVER ROLE MEMBERS (who is sysadmin etc.)', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_server_role_members;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_server_role_members
AS
-- Toolkit 13_security.sql section 13.1: SERVER ROLE MEMBERS (who is sysadmin etc.)
SET NOCOUNT ON;
SELECT r.name AS server_role, m.name AS member_name, m.type_desc, m.is_disabled,
       m.create_date, m.modify_date
FROM sys.server_role_members AS rm
JOIN sys.server_principals AS r ON r.principal_id = rm.role_principal_id
JOIN sys.server_principals AS m ON m.principal_id = rm.member_principal_id
ORDER BY CASE r.name WHEN N''sysadmin'' THEN 0 ELSE 1 END, r.name, m.name;
',
    @fallback_definition = NULL;
GO

/* 13.2  LOGINS - STATUS, POLICY, LAST PASSWORD CHANGE   (13_security.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_logins', @section = N'13.2', @source_file = N'13_security.sql',
    @title = N'LOGINS - STATUS, POLICY, LAST PASSWORD CHANGE', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_logins ORDER BY type_desc, name;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY sp.type_desc, sp.name',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_logins
AS
-- Toolkit 13_security.sql section 13.2: LOGINS - STATUS, POLICY, LAST PASSWORD CHANGE
SELECT sp.name, sp.type_desc, sp.is_disabled, sp.default_database_name,
       sl.is_policy_checked, sl.is_expiration_checked,
       LOGINPROPERTY(sp.name, ''PasswordLastSetTime'') AS password_last_set,
       LOGINPROPERTY(sp.name, ''IsLocked'')            AS is_locked,
       LOGINPROPERTY(sp.name, ''IsExpired'')           AS is_expired,
       LOGINPROPERTY(sp.name, ''BadPasswordCount'')    AS bad_password_count,
       sp.create_date, sp.modify_date
FROM sys.server_principals AS sp
LEFT JOIN sys.sql_logins AS sl ON sl.principal_id = sp.principal_id
WHERE sp.type IN (''S'', ''U'', ''G'', ''E'', ''X'')
  AND sp.name NOT LIKE N''##%'';
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_logins
AS
-- Toolkit 13_security.sql section 13.2: LOGINS - STATUS, POLICY, LAST PASSWORD CHANGE
SET NOCOUNT ON;
SELECT sp.name, sp.type_desc, sp.is_disabled, sp.default_database_name,
       sl.is_policy_checked, sl.is_expiration_checked,
       LOGINPROPERTY(sp.name, ''PasswordLastSetTime'') AS password_last_set,
       LOGINPROPERTY(sp.name, ''IsLocked'')            AS is_locked,
       LOGINPROPERTY(sp.name, ''IsExpired'')           AS is_expired,
       LOGINPROPERTY(sp.name, ''BadPasswordCount'')    AS bad_password_count,
       sp.create_date, sp.modify_date
FROM sys.server_principals AS sp
LEFT JOIN sys.sql_logins AS sl ON sl.principal_id = sp.principal_id
WHERE sp.type IN (''S'', ''U'', ''G'', ''E'', ''X'')
  AND sp.name NOT LIKE N''##%''
ORDER BY sp.type_desc, sp.name;
';
GO

/* 13.3  WEAK SQL LOGIN PASSWORDS (blank or = login name)   (13_security.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_weak_passwords', @section = N'13.3', @source_file = N'13_security.sql',
    @title = N'WEAK SQL LOGIN PASSWORDS (blank or = login name)', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_weak_passwords;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_weak_passwords
AS
-- Toolkit 13_security.sql section 13.3: WEAK SQL LOGIN PASSWORDS (blank or = login name)
SET NOCOUNT ON;
SELECT name,
       CASE WHEN PWDCOMPARE(N'''', password_hash) = 1 THEN ''BLANK PASSWORD''
            WHEN PWDCOMPARE(name, password_hash) = 1 THEN ''PASSWORD = LOGIN NAME'' END AS finding
FROM sys.sql_logins
WHERE PWDCOMPARE(N'''', password_hash) = 1
   OR PWDCOMPARE(name, password_hash) = 1;
',
    @fallback_definition = NULL;
GO

/* 13.4  HIGH-RISK SERVER PERMISSIONS (CONTROL SERVER, IMPERSONATE...)   (13_security.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_risky_server_perms', @section = N'13.4', @source_file = N'13_security.sql',
    @title = N'HIGH-RISK SERVER PERMISSIONS (CONTROL SERVER, IMPERSONATE...)', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_risky_server_perms ORDER BY permission_name, grantee;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY sp.permission_name, grantee',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_risky_server_perms
AS
-- Toolkit 13_security.sql section 13.4: HIGH-RISK SERVER PERMISSIONS (CONTROL SERVER, IMPERSONATE...)
SELECT SUSER_NAME(sp.grantee_principal_id) AS grantee, sp.permission_name, sp.state_desc,
       sp.class_desc, SUSER_NAME(sp.grantor_principal_id) AS grantor
FROM sys.server_permissions AS sp
WHERE sp.permission_name IN (N''CONTROL SERVER'', N''IMPERSONATE'', N''ALTER ANY LOGIN'',
        N''ALTER ANY SERVER ROLE'', N''ALTER SERVER STATE'', N''VIEW SERVER STATE'',
        N''ALTER ANY DATABASE'', N''ADMINISTER BULK OPERATIONS'', N''UNSAFE ASSEMBLY'')
  AND SUSER_NAME(sp.grantee_principal_id) NOT LIKE N''##%'';
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_risky_server_perms
AS
-- Toolkit 13_security.sql section 13.4: HIGH-RISK SERVER PERMISSIONS (CONTROL SERVER, IMPERSONATE...)
SET NOCOUNT ON;
SELECT SUSER_NAME(sp.grantee_principal_id) AS grantee, sp.permission_name, sp.state_desc,
       sp.class_desc, SUSER_NAME(sp.grantor_principal_id) AS grantor
FROM sys.server_permissions AS sp
WHERE sp.permission_name IN (N''CONTROL SERVER'', N''IMPERSONATE'', N''ALTER ANY LOGIN'',
        N''ALTER ANY SERVER ROLE'', N''ALTER SERVER STATE'', N''VIEW SERVER STATE'',
        N''ALTER ANY DATABASE'', N''ADMINISTER BULK OPERATIONS'', N''UNSAFE ASSEMBLY'')
  AND SUSER_NAME(sp.grantee_principal_id) NOT LIKE N''##%''
ORDER BY sp.permission_name, grantee;
';
GO

/* 13.5  ORPHANED USERS - CURRENT DB (+ fix statement)   (13_security.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_orphaned_users', @section = N'13.5', @source_file = N'13_security.sql',
    @title = N'ORPHANED USERS - CURRENT DB (+ fix statement)', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_orphaned_users @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_orphaned_users
    @database_name sysname = NULL
AS
-- Toolkit 13_security.sql section 13.5: ORPHANED USERS - CURRENT DB (+ fix statement)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT dp.name AS user_name, dp.type_desc, dp.sid,
       N''''ALTER USER '''' + QUOTENAME(dp.name) + N'''' WITH LOGIN = '''' + QUOTENAME(dp.name) + N'''';'''' AS fix_if_login_exists
FROM sys.database_principals AS dp
LEFT JOIN sys.server_principals AS sp ON sp.sid = dp.sid
WHERE sp.sid IS NULL
  AND dp.type IN (''''S'''', ''''U'''', ''''G'''')
  AND dp.authentication_type_desc IN (N''''INSTANCE'''', N''''WINDOWS'''')
  AND dp.name NOT IN (N''''dbo'''', N''''guest'''', N''''INFORMATION_SCHEMA'''', N''''sys'''')
  AND dp.principal_id > 4;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 13.6  DATABASE ROLE MEMBERS - CURRENT DB   (13_security.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_db_role_members', @section = N'13.6', @source_file = N'13_security.sql',
    @title = N'DATABASE ROLE MEMBERS - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_db_role_members @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_db_role_members
    @database_name sysname = NULL
AS
-- Toolkit 13_security.sql section 13.6: DATABASE ROLE MEMBERS - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT r.name AS db_role, m.name AS member_name, m.type_desc, m.authentication_type_desc
FROM sys.database_role_members AS drm
JOIN sys.database_principals AS r ON r.principal_id = drm.role_principal_id
JOIN sys.database_principals AS m ON m.principal_id = drm.member_principal_id
ORDER BY CASE r.name WHEN N''''db_owner'''' THEN 0 ELSE 1 END, r.name, m.name;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 13.7  EXPLICIT PERMISSIONS - CURRENT DB   (13_security.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_db_permissions', @section = N'13.7', @source_file = N'13_security.sql',
    @title = N'EXPLICIT PERMISSIONS - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_db_permissions @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_db_permissions
    @database_name sysname = NULL
AS
-- Toolkit 13_security.sql section 13.7: EXPLICIT PERMISSIONS - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT pr.name AS principal_name, pr.type_desc, pe.state_desc, pe.permission_name,
       pe.class_desc,
       CASE pe.class WHEN 0 THEN DB_NAME()
                     WHEN 1 THEN OBJECT_SCHEMA_NAME(pe.major_id) + N''''.'''' + OBJECT_NAME(pe.major_id)
                     WHEN 3 THEN SCHEMA_NAME(pe.major_id) END AS securable,
       COL_NAME(pe.major_id, pe.minor_id) AS column_name
FROM sys.database_permissions AS pe
JOIN sys.database_principals  AS pr ON pr.principal_id = pe.grantee_principal_id
WHERE pr.name NOT IN (N''''public'''', N''''guest'''') OR pe.permission_name <> N''''CONNECT''''
ORDER BY principal_name, securable;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 13.9  GUEST ENABLED IN USER DATABASES (should be off)   (13_security.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_guest_enabled', @section = N'13.9', @source_file = N'13_security.sql',
    @title = N'GUEST ENABLED IN USER DATABASES (should be off)', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_guest_enabled;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_guest_enabled
AS
-- Toolkit 13_security.sql section 13.9: GUEST ENABLED IN USER DATABASES (should be off)
SET NOCOUNT ON;
IF OBJECT_ID(''tempdb..#guest'') IS NOT NULL DROP TABLE #guest;
CREATE TABLE #guest (database_name sysname, guest_has_connect bit);
DECLARE @sql nvarchar(max) = N'''';
SELECT @sql += N''USE '' + QUOTENAME(name) + N''; INSERT #guest SELECT DB_NAME(), 1 FROM sys.database_permissions
  WHERE grantee_principal_id = DATABASE_PRINCIPAL_ID(''''guest'''') AND permission_name = ''''CONNECT'''' AND state IN (''''G'''',''''W'''');
''
FROM sys.databases WHERE database_id > 4 AND state_desc = N''ONLINE'' AND HAS_DBACCESS(name) = 1;
EXEC sys.sp_executesql @sql;
SELECT * FROM #guest;
',
    @fallback_definition = NULL;
GO

/* 13.10  RISKY DATABASE SETTINGS (TRUSTWORTHY, odd owners, chaining)   (13_security.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_risky_db_settings', @section = N'13.10', @source_file = N'13_security.sql',
    @title = N'RISKY DATABASE SETTINGS (TRUSTWORTHY, odd owners, chaining)', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_risky_db_settings ORDER BY name;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY name',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_risky_db_settings
AS
-- Toolkit 13_security.sql section 13.10: RISKY DATABASE SETTINGS (TRUSTWORTHY, odd owners, chaining)
SELECT name, SUSER_SNAME(owner_sid) AS owner_name, is_trustworthy_on, is_db_chaining_on,
       containment_desc
FROM sys.databases
WHERE (is_trustworthy_on = 1 AND name <> N''msdb'')
   OR is_db_chaining_on = 1
   OR SUSER_SNAME(owner_sid) IS NULL;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_risky_db_settings
AS
-- Toolkit 13_security.sql section 13.10: RISKY DATABASE SETTINGS (TRUSTWORTHY, odd owners, chaining)
SET NOCOUNT ON;
SELECT name, SUSER_SNAME(owner_sid) AS owner_name, is_trustworthy_on, is_db_chaining_on,
       containment_desc
FROM sys.databases
WHERE (is_trustworthy_on = 1 AND name <> N''msdb'')
   OR is_db_chaining_on = 1
   OR SUSER_SNAME(owner_sid) IS NULL
ORDER BY name;
';
GO

/* 13.11  TDE STATUS & CERTIFICATE EXPIRY   (13_security.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_tde_cert_expiry', @section = N'13.11', @source_file = N'13_security.sql',
    @title = N'TDE STATUS & CERTIFICATE EXPIRY', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_tde_cert_expiry;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_tde_cert_expiry
AS
-- Toolkit 13_security.sql section 13.11: TDE STATUS & CERTIFICATE EXPIRY
SET NOCOUNT ON;
SELECT DB_NAME(dek.database_id) AS database_name, dek.encryption_state,
       CASE dek.encryption_state WHEN 0 THEN ''No key'' WHEN 1 THEN ''Unencrypted''
            WHEN 2 THEN ''Encryption in progress'' WHEN 3 THEN ''Encrypted''
            WHEN 4 THEN ''Key change in progress'' WHEN 5 THEN ''Decryption in progress''
            WHEN 6 THEN ''Protection change in progress'' END AS state_desc,
       dek.percent_complete, dek.key_algorithm, dek.key_length,
       dek.encryptor_type, dek.encryptor_thumbprint
FROM sys.dm_database_encryption_keys AS dek;

SELECT name, subject, start_date, expiry_date, thumbprint, pvt_key_encryption_type_desc,
       pvt_key_last_backup_date,
       DATEDIFF(DAY, GETDATE(), expiry_date) AS days_to_expiry
FROM master.sys.certificates
WHERE name NOT LIKE N''##%''
ORDER BY expiry_date;
',
    @fallback_definition = NULL;
GO

/* 13.12  UNENCRYPTED CONNECTIONS   (13_security.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_unencrypted_connections', @section = N'13.12', @source_file = N'13_security.sql',
    @title = N'UNENCRYPTED CONNECTIONS', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_unencrypted_connections;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_unencrypted_connections
AS
-- Toolkit 13_security.sql section 13.12: UNENCRYPTED CONNECTIONS
SELECT c.encrypt_option, c.auth_scheme, c.net_transport, COUNT(*) AS connections
FROM sys.dm_exec_connections AS c
GROUP BY c.encrypt_option, c.auth_scheme, c.net_transport;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_unencrypted_connections
AS
-- Toolkit 13_security.sql section 13.12: UNENCRYPTED CONNECTIONS
SET NOCOUNT ON;
SELECT c.encrypt_option, c.auth_scheme, c.net_transport, COUNT(*) AS connections
FROM sys.dm_exec_connections AS c
GROUP BY c.encrypt_option, c.auth_scheme, c.net_transport;
';
GO

/* 13.13  FAILED LOGINS FROM ERROR LOG   (13_security.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_failed_logins', @section = N'13.13', @source_file = N'13_security.sql',
    @title = N'FAILED LOGINS FROM ERROR LOG', @tags = N'BOX',
    @usage = N'EXEC dbo.HC_failed_logins @log_number = 0;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_failed_logins
    @log_number int = 0
AS
-- Toolkit 13_security.sql section 13.13: FAILED LOGINS FROM ERROR LOG
SET NOCOUNT ON;
EXEC sys.xp_readerrorlog @log_number, 1, N''Login failed'';
',
    @fallback_definition = NULL;
GO

/* 13.14  SQL SERVER AUDIT STATUS   (13_security.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_audit_status', @section = N'13.14', @source_file = N'13_security.sql',
    @title = N'SQL SERVER AUDIT STATUS', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_audit_status;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_audit_status
AS
-- Toolkit 13_security.sql section 13.14: SQL SERVER AUDIT STATUS
SET NOCOUNT ON;
SELECT a.name, a.type_desc, a.on_failure_desc, a.is_state_enabled, s.status_desc, s.audit_file_path
FROM sys.server_audits AS a
LEFT JOIN sys.dm_server_audit_status AS s ON s.audit_id = a.audit_id;

SELECT sas.name AS server_audit_spec, sas.is_state_enabled, sasd.audit_action_name
FROM sys.server_audit_specifications AS sas
JOIN sys.server_audit_specification_details AS sasd ON sasd.server_specification_id = sas.server_specification_id;
',
    @fallback_definition = NULL;
GO

/* 13.15  LINKED SERVERS & THEIR LOGIN MAPPINGS   (13_security.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_linked_servers', @section = N'13.15', @source_file = N'13_security.sql',
    @title = N'LINKED SERVERS & THEIR LOGIN MAPPINGS', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_linked_servers;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_linked_servers
AS
-- Toolkit 13_security.sql section 13.15: LINKED SERVERS & THEIR LOGIN MAPPINGS
SELECT s.name, s.product, s.provider, s.data_source, s.is_rpc_out_enabled, s.is_data_access_enabled,
       ll.uses_self_credential, ll.remote_name, SUSER_NAME(ll.local_principal_id) AS local_login
FROM sys.servers AS s
LEFT JOIN sys.linked_logins AS ll ON ll.server_id = s.server_id
WHERE s.is_linked = 1;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_linked_servers
AS
-- Toolkit 13_security.sql section 13.15: LINKED SERVERS & THEIR LOGIN MAPPINGS
SET NOCOUNT ON;
SELECT s.name, s.product, s.provider, s.data_source, s.is_rpc_out_enabled, s.is_data_access_enabled,
       ll.uses_self_credential, ll.remote_name, SUSER_NAME(ll.local_principal_id) AS local_login
FROM sys.servers AS s
LEFT JOIN sys.linked_logins AS ll ON ll.server_id = s.server_id
WHERE s.is_linked = 1;
';
GO

/* 14.1  FAILED JOB STEPS - LAST N HOURS   (14_agent_jobs_dbmail.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_failed_jobs', @section = N'14.1', @source_file = N'14_agent_jobs_dbmail.sql',
    @title = N'FAILED JOB STEPS - LAST N HOURS', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_failed_jobs(DEFAULT) ORDER BY run_datetime DESC;  -- @hours = 24',
    @min_version = NULL,
    @sort_hint = N'ORDER BY run_datetime DESC',
    @definition = N'CREATE OR ALTER FUNCTION dbo.HC_failed_jobs
(
    @hours int = 24
)
RETURNS TABLE
AS
-- Toolkit 14_agent_jobs_dbmail.sql section 14.1: FAILED JOB STEPS - LAST N HOURS
RETURN
(
SELECT j.name AS job_name, h.step_id, h.step_name,
       msdb.dbo.agent_datetime(h.run_date, h.run_time) AS run_datetime,
       STUFF(STUFF(RIGHT(''000000'' + CAST(h.run_duration AS varchar(10)), 6), 5, 0, '':''), 3, 0, '':'') AS duration_hhmmss,
       h.sql_message_id, h.sql_severity, h.message, h.server
FROM msdb.dbo.sysjobhistory AS h
JOIN msdb.dbo.sysjobs       AS j ON j.job_id = h.job_id
WHERE h.run_status = 0
  AND msdb.dbo.agent_datetime(h.run_date, h.run_time) >= DATEADD(HOUR, -@hours, GETDATE())
);
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_failed_jobs
    @hours int = 24
AS
-- Toolkit 14_agent_jobs_dbmail.sql section 14.1: FAILED JOB STEPS - LAST N HOURS
SET NOCOUNT ON;
SELECT j.name AS job_name, h.step_id, h.step_name,
       msdb.dbo.agent_datetime(h.run_date, h.run_time) AS run_datetime,
       STUFF(STUFF(RIGHT(''000000'' + CAST(h.run_duration AS varchar(10)), 6), 5, 0, '':''), 3, 0, '':'') AS duration_hhmmss,
       h.sql_message_id, h.sql_severity, h.message, h.server
FROM msdb.dbo.sysjobhistory AS h
JOIN msdb.dbo.sysjobs       AS j ON j.job_id = h.job_id
WHERE h.run_status = 0
  AND msdb.dbo.agent_datetime(h.run_date, h.run_time) >= DATEADD(HOUR, -@hours, GETDATE())
ORDER BY run_datetime DESC;
';
GO

/* 14.2  CURRENTLY RUNNING JOBS   (14_agent_jobs_dbmail.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_running_jobs', @section = N'14.2', @source_file = N'14_agent_jobs_dbmail.sql',
    @title = N'CURRENTLY RUNNING JOBS', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_running_jobs ORDER BY start_execution_date;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY ja.start_execution_date',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_running_jobs
AS
-- Toolkit 14_agent_jobs_dbmail.sql section 14.2: CURRENTLY RUNNING JOBS
SELECT j.name AS job_name, ja.start_execution_date,
       DATEDIFF(MINUTE, ja.start_execution_date, GETDATE()) AS running_minutes,
       ISNULL(ja.last_executed_step_id, 0) + 1              AS current_step_id,
       js.step_name AS current_step
FROM msdb.dbo.sysjobactivity AS ja
JOIN msdb.dbo.sysjobs AS j ON j.job_id = ja.job_id
LEFT JOIN msdb.dbo.sysjobsteps AS js ON js.job_id = ja.job_id AND js.step_id = ISNULL(ja.last_executed_step_id, 0) + 1
WHERE ja.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)
  AND ja.start_execution_date IS NOT NULL
  AND ja.stop_execution_date IS NULL;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_running_jobs
AS
-- Toolkit 14_agent_jobs_dbmail.sql section 14.2: CURRENTLY RUNNING JOBS
SET NOCOUNT ON;
SELECT j.name AS job_name, ja.start_execution_date,
       DATEDIFF(MINUTE, ja.start_execution_date, GETDATE()) AS running_minutes,
       ISNULL(ja.last_executed_step_id, 0) + 1              AS current_step_id,
       js.step_name AS current_step
FROM msdb.dbo.sysjobactivity AS ja
JOIN msdb.dbo.sysjobs AS j ON j.job_id = ja.job_id
LEFT JOIN msdb.dbo.sysjobsteps AS js ON js.job_id = ja.job_id AND js.step_id = ISNULL(ja.last_executed_step_id, 0) + 1
WHERE ja.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)
  AND ja.start_execution_date IS NOT NULL
  AND ja.stop_execution_date IS NULL
ORDER BY ja.start_execution_date;
';
GO

/* 14.3  JOB INVENTORY - OWNER, ENABLED, LAST OUTCOME, NEXT RUN   (14_agent_jobs_dbmail.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_job_inventory', @section = N'14.3', @source_file = N'14_agent_jobs_dbmail.sql',
    @title = N'JOB INVENTORY - OWNER, ENABLED, LAST OUTCOME, NEXT RUN', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_job_inventory;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_job_inventory
AS
-- Toolkit 14_agent_jobs_dbmail.sql section 14.3: JOB INVENTORY - OWNER, ENABLED, LAST OUTCOME, NEXT RUN
SET NOCOUNT ON;
SELECT j.name AS job_name, j.enabled, SUSER_SNAME(j.owner_sid) AS owner_name,
       c.name AS category,
       CASE js.last_run_outcome WHEN 0 THEN ''Failed'' WHEN 1 THEN ''Succeeded''
            WHEN 3 THEN ''Canceled'' WHEN 5 THEN ''Unknown'' END AS last_outcome,
       CASE WHEN js.last_run_date > 0 THEN msdb.dbo.agent_datetime(js.last_run_date, js.last_run_time) END AS last_run,
       (SELECT MIN(msdb.dbo.agent_datetime(s.next_run_date, s.next_run_time))
        FROM msdb.dbo.sysjobschedules AS s WHERE s.job_id = j.job_id AND s.next_run_date > 0) AS next_run,
       j.date_created, j.date_modified,
       CASE WHEN j.notify_level_email > 0 THEN ''Yes'' ELSE ''No'' END AS emails_on_failure
FROM msdb.dbo.sysjobs AS j
LEFT JOIN msdb.dbo.sysjobservers AS js ON js.job_id = j.job_id
LEFT JOIN msdb.dbo.syscategories AS c  ON c.category_id = j.category_id
ORDER BY j.name;
',
    @fallback_definition = NULL;
GO

/* 14.4  JOBS RUNNING LONGER THAN THEIR AVERAGE   (14_agent_jobs_dbmail.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_long_running_jobs', @section = N'14.4', @source_file = N'14_agent_jobs_dbmail.sql',
    @title = N'JOBS RUNNING LONGER THAN THEIR AVERAGE', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_long_running_jobs ORDER BY times_avg DESC;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY times_avg DESC',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_long_running_jobs
AS
-- Toolkit 14_agent_jobs_dbmail.sql section 14.4: JOBS RUNNING LONGER THAN THEIR AVERAGE
WITH avg_run AS (
    SELECT job_id,
           AVG((run_duration / 10000) * 3600 + (run_duration / 100 % 100) * 60 + run_duration % 100) AS avg_seconds
    FROM msdb.dbo.sysjobhistory
    WHERE step_id = 0 AND run_status = 1
    GROUP BY job_id
)
SELECT j.name AS job_name, ja.start_execution_date,
       DATEDIFF(SECOND, ja.start_execution_date, GETDATE()) AS running_seconds,
       a.avg_seconds,
       CAST(DATEDIFF(SECOND, ja.start_execution_date, GETDATE()) * 1.0 / NULLIF(a.avg_seconds, 0) AS decimal(10,1)) AS times_avg
FROM msdb.dbo.sysjobactivity AS ja
JOIN msdb.dbo.sysjobs AS j ON j.job_id = ja.job_id
LEFT JOIN avg_run AS a ON a.job_id = ja.job_id
WHERE ja.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)
  AND ja.start_execution_date IS NOT NULL AND ja.stop_execution_date IS NULL;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_long_running_jobs
AS
-- Toolkit 14_agent_jobs_dbmail.sql section 14.4: JOBS RUNNING LONGER THAN THEIR AVERAGE
SET NOCOUNT ON;
WITH avg_run AS (
    SELECT job_id,
           AVG((run_duration / 10000) * 3600 + (run_duration / 100 % 100) * 60 + run_duration % 100) AS avg_seconds
    FROM msdb.dbo.sysjobhistory
    WHERE step_id = 0 AND run_status = 1
    GROUP BY job_id
)
SELECT j.name AS job_name, ja.start_execution_date,
       DATEDIFF(SECOND, ja.start_execution_date, GETDATE()) AS running_seconds,
       a.avg_seconds,
       CAST(DATEDIFF(SECOND, ja.start_execution_date, GETDATE()) * 1.0 / NULLIF(a.avg_seconds, 0) AS decimal(10,1)) AS times_avg
FROM msdb.dbo.sysjobactivity AS ja
JOIN msdb.dbo.sysjobs AS j ON j.job_id = ja.job_id
LEFT JOIN avg_run AS a ON a.job_id = ja.job_id
WHERE ja.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)
  AND ja.start_execution_date IS NOT NULL AND ja.stop_execution_date IS NULL
ORDER BY times_avg DESC;
';
GO

/* 14.5  JOB STEP DETAILS (command, subsystem, proxy, database)   (14_agent_jobs_dbmail.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_job_steps', @section = N'14.5', @source_file = N'14_agent_jobs_dbmail.sql',
    @title = N'JOB STEP DETAILS (command, subsystem, proxy, database)', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_job_steps(DEFAULT) ORDER BY job_name, step_id;  -- @job_name = N''%''',
    @min_version = NULL,
    @sort_hint = N'ORDER BY j.name, s.step_id',
    @definition = N'CREATE OR ALTER FUNCTION dbo.HC_job_steps
(
    @job_name sysname = N''%''
)
RETURNS TABLE
AS
-- Toolkit 14_agent_jobs_dbmail.sql section 14.5: JOB STEP DETAILS (command, subsystem, proxy, database)
RETURN
(
SELECT j.name AS job_name, s.step_id, s.step_name, s.subsystem, s.database_name,
       s.command, s.on_success_action, s.on_fail_action, s.retry_attempts,
       p.name AS proxy_name, s.output_file_name
FROM msdb.dbo.sysjobs AS j
JOIN msdb.dbo.sysjobsteps AS s ON s.job_id = j.job_id
LEFT JOIN msdb.dbo.sysproxies AS p ON p.proxy_id = s.proxy_id
WHERE j.name LIKE @job_name
);
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_job_steps
    @job_name sysname = N''%''
AS
-- Toolkit 14_agent_jobs_dbmail.sql section 14.5: JOB STEP DETAILS (command, subsystem, proxy, database)
SET NOCOUNT ON;
SELECT j.name AS job_name, s.step_id, s.step_name, s.subsystem, s.database_name,
       s.command, s.on_success_action, s.on_fail_action, s.retry_attempts,
       p.name AS proxy_name, s.output_file_name
FROM msdb.dbo.sysjobs AS j
JOIN msdb.dbo.sysjobsteps AS s ON s.job_id = j.job_id
LEFT JOIN msdb.dbo.sysproxies AS p ON p.proxy_id = s.proxy_id
WHERE j.name LIKE @job_name
ORDER BY j.name, s.step_id;
';
GO

/* 14.6  JOBS OWNED BY INDIVIDUAL ACCOUNTS (break when person leaves)   (14_agent_jobs_dbmail.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_jobs_owned_by_people', @section = N'14.6', @source_file = N'14_agent_jobs_dbmail.sql',
    @title = N'JOBS OWNED BY INDIVIDUAL ACCOUNTS (break when person leaves)', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_jobs_owned_by_people;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_jobs_owned_by_people
AS
-- Toolkit 14_agent_jobs_dbmail.sql section 14.6: JOBS OWNED BY INDIVIDUAL ACCOUNTS (break when person leaves)
SET NOCOUNT ON;
SELECT j.name AS job_name, SUSER_SNAME(j.owner_sid) AS owner_name,
       N''EXEC msdb.dbo.sp_update_job @job_name = N'''''' + REPLACE(j.name, '''''''', '''''''''''') + N'''''', @owner_login_name = N''''sa'''';'' AS fix
FROM msdb.dbo.sysjobs AS j
WHERE SUSER_SNAME(j.owner_sid) <> N''sa'' OR SUSER_SNAME(j.owner_sid) IS NULL;
',
    @fallback_definition = NULL;
GO

/* 14.7  AGENT SERVICE / ALERTS / OPERATORS   (14_agent_jobs_dbmail.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_agent_alerts_operators', @section = N'14.7', @source_file = N'14_agent_jobs_dbmail.sql',
    @title = N'AGENT SERVICE / ALERTS / OPERATORS', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_agent_alerts_operators;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_agent_alerts_operators
AS
-- Toolkit 14_agent_jobs_dbmail.sql section 14.7: AGENT SERVICE / ALERTS / OPERATORS
SET NOCOUNT ON;
SELECT name, enabled, email_address, last_email_date FROM msdb.dbo.sysoperators;
SELECT name, enabled, message_id, severity, last_occurrence_date, occurrence_count, has_notification
FROM msdb.dbo.sysalerts ORDER BY severity, message_id;
',
    @fallback_definition = NULL;
GO

/* 14.8  DATABASE MAIL - FAILURES & QUEUE   (14_agent_jobs_dbmail.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_dbmail_failures', @section = N'14.8', @source_file = N'14_agent_jobs_dbmail.sql',
    @title = N'DATABASE MAIL - FAILURES & QUEUE', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_dbmail_failures;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_dbmail_failures
AS
-- Toolkit 14_agent_jobs_dbmail.sql section 14.8: DATABASE MAIL - FAILURES & QUEUE
SET NOCOUNT ON;
SELECT TOP (50) mailitem_id, recipients, subject, sent_status, send_request_date, sent_date
FROM msdb.dbo.sysmail_allitems
WHERE sent_status <> ''sent''
ORDER BY send_request_date DESC;

SELECT TOP (50) log_id, event_type, log_date, description, mailitem_id
FROM msdb.dbo.sysmail_event_log
WHERE event_type IN (''error'', ''warning'')
ORDER BY log_date DESC;
',
    @fallback_definition = NULL;
GO

/* 15.1  DATABASES NOT ONLINE / NOT MULTI_USER   (15_database_health_errorlog.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_dbs_not_online', @section = N'15.1', @source_file = N'15_database_health_errorlog.sql',
    @title = N'DATABASES NOT ONLINE / NOT MULTI_USER', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_dbs_not_online;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_dbs_not_online
AS
-- Toolkit 15_database_health_errorlog.sql section 15.1: DATABASES NOT ONLINE / NOT MULTI_USER
SELECT name, state_desc, user_access_desc, is_read_only, is_in_standby
FROM sys.databases
WHERE state_desc <> N''ONLINE'' OR user_access_desc <> N''MULTI_USER'';
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_dbs_not_online
AS
-- Toolkit 15_database_health_errorlog.sql section 15.1: DATABASES NOT ONLINE / NOT MULTI_USER
SET NOCOUNT ON;
SELECT name, state_desc, user_access_desc, is_read_only, is_in_standby
FROM sys.databases
WHERE state_desc <> N''ONLINE'' OR user_access_desc <> N''MULTI_USER'';
';
GO

/* 15.2  LAST KNOWN GOOD CHECKDB (2016 SP2+)   (15_database_health_errorlog.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_last_good_checkdb', @section = N'15.2', @source_file = N'15_database_health_errorlog.sql',
    @title = N'LAST KNOWN GOOD CHECKDB (2016 SP2+)', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_last_good_checkdb ORDER BY days_ago DESC;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY days_ago DESC',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_last_good_checkdb
AS
-- Toolkit 15_database_health_errorlog.sql section 15.2: LAST KNOWN GOOD CHECKDB (2016 SP2+)
SELECT name,
       DATABASEPROPERTYEX(name, ''LastGoodCheckDbTime'') AS last_good_checkdb,
       DATEDIFF(DAY, CAST(DATABASEPROPERTYEX(name, ''LastGoodCheckDbTime'') AS datetime), GETDATE()) AS days_ago
FROM sys.databases
WHERE database_id <> 2 AND state_desc = N''ONLINE'';
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_last_good_checkdb
AS
-- Toolkit 15_database_health_errorlog.sql section 15.2: LAST KNOWN GOOD CHECKDB (2016 SP2+)
SET NOCOUNT ON;
SELECT name,
       DATABASEPROPERTYEX(name, ''LastGoodCheckDbTime'') AS last_good_checkdb,
       DATEDIFF(DAY, CAST(DATABASEPROPERTYEX(name, ''LastGoodCheckDbTime'') AS datetime), GETDATE()) AS days_ago
FROM sys.databases
WHERE database_id <> 2 AND state_desc = N''ONLINE''
ORDER BY days_ago DESC;
';
GO

/* 15.3  SUSPECT PAGES (823/824 errors recorded in msdb)   (15_database_health_errorlog.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_suspect_pages', @section = N'15.3', @source_file = N'15_database_health_errorlog.sql',
    @title = N'SUSPECT PAGES (823/824 errors recorded in msdb)', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_suspect_pages;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_suspect_pages
AS
-- Toolkit 15_database_health_errorlog.sql section 15.3: SUSPECT PAGES (823/824 errors recorded in msdb)
SET NOCOUNT ON;
SELECT DB_NAME(database_id) AS database_name, file_id, page_id,
       CASE event_type WHEN 1 THEN ''823/824 error'' WHEN 2 THEN ''Bad checksum'' WHEN 3 THEN ''Torn page''
            WHEN 4 THEN ''Restored'' WHEN 5 THEN ''Repaired'' WHEN 7 THEN ''Deallocated by DBCC'' END AS event_desc,
       error_count, last_update_date
FROM msdb.dbo.suspect_pages
ORDER BY last_update_date DESC;
',
    @fallback_definition = NULL;
GO

/* 15.4  AG AUTOMATIC PAGE REPAIR HISTORY   (15_database_health_errorlog.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_ag_page_repair', @section = N'15.4', @source_file = N'15_database_health_errorlog.sql',
    @title = N'AG AUTOMATIC PAGE REPAIR HISTORY', @tags = N'BOX',
    @usage = N'SELECT * FROM dbo.HC_ag_page_repair ORDER BY modification_time DESC;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY modification_time DESC',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_ag_page_repair
AS
-- Toolkit 15_database_health_errorlog.sql section 15.4: AG AUTOMATIC PAGE REPAIR HISTORY
SELECT DB_NAME(database_id) AS database_name, file_id, page_id, error_type, page_status, modification_time
FROM sys.dm_hadr_auto_page_repair;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_ag_page_repair
AS
-- Toolkit 15_database_health_errorlog.sql section 15.4: AG AUTOMATIC PAGE REPAIR HISTORY
SET NOCOUNT ON;
SELECT DB_NAME(database_id) AS database_name, file_id, page_id, error_type, page_status, modification_time
FROM sys.dm_hadr_auto_page_repair
ORDER BY modification_time DESC;
';
GO

/* 15.5  CONFIGURATION ANTI-PATTERNS   (15_database_health_errorlog.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_config_antipatterns', @section = N'15.5', @source_file = N'15_database_health_errorlog.sql',
    @title = N'CONFIGURATION ANTI-PATTERNS', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_config_antipatterns;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY name, finding',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_config_antipatterns
AS
-- Toolkit 15_database_health_errorlog.sql section 15.5: CONFIGURATION ANTI-PATTERNS
SELECT name, finding FROM (
    SELECT name, ''AUTO_CLOSE is ON'' AS finding FROM sys.databases WHERE is_auto_close_on = 1
    UNION ALL SELECT name, ''AUTO_SHRINK is ON'' FROM sys.databases WHERE is_auto_shrink_on = 1
    UNION ALL SELECT name, ''PAGE_VERIFY is '' + page_verify_option_desc FROM sys.databases WHERE page_verify_option_desc <> N''CHECKSUM'' AND database_id <> 2
    UNION ALL SELECT name, ''AUTO_UPDATE_STATISTICS is OFF'' FROM sys.databases WHERE is_auto_update_stats_on = 0
    UNION ALL SELECT name, ''AUTO_CREATE_STATISTICS is OFF'' FROM sys.databases WHERE is_auto_create_stats_on = 0
    UNION ALL SELECT name, ''Owner is NULL / orphaned SID'' FROM sys.databases WHERE SUSER_SNAME(owner_sid) IS NULL
    UNION ALL SELECT name, ''Compat level '' + CAST(compatibility_level AS varchar(5)) + '' is below 130''
              FROM sys.databases WHERE compatibility_level < 130 AND database_id > 4
    UNION ALL SELECT name, ''Target recovery time is 0 (legacy checkpoints)'' FROM sys.databases WHERE target_recovery_time_in_seconds = 0 AND database_id > 4
    UNION ALL SELECT name, ''Query Store is OFF'' FROM sys.databases WHERE is_query_store_on = 0 AND database_id > 4
) AS x;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_config_antipatterns
AS
-- Toolkit 15_database_health_errorlog.sql section 15.5: CONFIGURATION ANTI-PATTERNS
SET NOCOUNT ON;
SELECT name, finding FROM (
    SELECT name, ''AUTO_CLOSE is ON'' AS finding FROM sys.databases WHERE is_auto_close_on = 1
    UNION ALL SELECT name, ''AUTO_SHRINK is ON'' FROM sys.databases WHERE is_auto_shrink_on = 1
    UNION ALL SELECT name, ''PAGE_VERIFY is '' + page_verify_option_desc FROM sys.databases WHERE page_verify_option_desc <> N''CHECKSUM'' AND database_id <> 2
    UNION ALL SELECT name, ''AUTO_UPDATE_STATISTICS is OFF'' FROM sys.databases WHERE is_auto_update_stats_on = 0
    UNION ALL SELECT name, ''AUTO_CREATE_STATISTICS is OFF'' FROM sys.databases WHERE is_auto_create_stats_on = 0
    UNION ALL SELECT name, ''Owner is NULL / orphaned SID'' FROM sys.databases WHERE SUSER_SNAME(owner_sid) IS NULL
    UNION ALL SELECT name, ''Compat level '' + CAST(compatibility_level AS varchar(5)) + '' is below 130''
              FROM sys.databases WHERE compatibility_level < 130 AND database_id > 4
    UNION ALL SELECT name, ''Target recovery time is 0 (legacy checkpoints)'' FROM sys.databases WHERE target_recovery_time_in_seconds = 0 AND database_id > 4
    UNION ALL SELECT name, ''Query Store is OFF'' FROM sys.databases WHERE is_query_store_on = 0 AND database_id > 4
) AS x
ORDER BY name, finding;
';
GO

/* 15.6  ERROR LOG - SEARCH   (15_database_health_errorlog.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_errorlog_search', @section = N'15.6', @source_file = N'15_database_health_errorlog.sql',
    @title = N'ERROR LOG - SEARCH', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_errorlog_search @log_number = 0, @search_text = N''error'', @search_text2 = N'''';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_errorlog_search
    @log_number int = 0,
    @search_text nvarchar(200) = N''error'',
    @search_text2 nvarchar(200) = N''''
AS
-- Toolkit 15_database_health_errorlog.sql section 15.6: ERROR LOG - SEARCH
SET NOCOUNT ON;
EXEC sys.xp_readerrorlog @log_number, 1, @search_text, @search_text2;
',
    @fallback_definition = NULL;
GO

/* 15.7  ERROR LOG FILE LIST (sizes / dates)   (15_database_health_errorlog.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_errorlog_files', @section = N'15.7', @source_file = N'15_database_health_errorlog.sql',
    @title = N'ERROR LOG FILE LIST (sizes / dates)', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_errorlog_files;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_errorlog_files
AS
-- Toolkit 15_database_health_errorlog.sql section 15.7: ERROR LOG FILE LIST (sizes / dates)
SET NOCOUNT ON;
EXEC sys.sp_enumerrorlogs;
',
    @fallback_definition = NULL;
GO

/* 15.8  HIGH SEVERITY ERRORS FROM system_health (XE)   (15_database_health_errorlog.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_high_severity_errors', @section = N'15.8', @source_file = N'15_database_health_errorlog.sql',
    @title = N'HIGH SEVERITY ERRORS FROM system_health (XE)', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_high_severity_errors;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_high_severity_errors
AS
-- Toolkit 15_database_health_errorlog.sql section 15.8: HIGH SEVERITY ERRORS FROM system_health (XE)
SET NOCOUNT ON;
SELECT
    x.ev.value(''(event/@timestamp)[1]'', ''datetime2'')                     AS event_time_utc,
    x.ev.value(''(event/data[@name="error_number"]/value)[1]'', ''int'')     AS error_number,
    x.ev.value(''(event/data[@name="severity"]/value)[1]'', ''int'')         AS severity,
    x.ev.value(''(event/data[@name="message"]/value)[1]'', ''nvarchar(max)'') AS message
FROM sys.fn_xe_file_target_read_file(N''system_health*.xel'', NULL, NULL, NULL) AS f
CROSS APPLY (SELECT CAST(f.event_data AS xml)) AS x(ev)
WHERE f.object_name = N''error_reported''
ORDER BY event_time_utc DESC;
',
    @fallback_definition = NULL;
GO

/* 16.1  SERVICE TIER / SIZE / LIMITS (user DB)   (16_azure_sql_database.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_sqldb_tier', @section = N'16.1', @source_file = N'16_azure_sql_database.sql',
    @title = N'SERVICE TIER / SIZE / LIMITS (user DB)', @tags = N'SQLDB',
    @usage = N'EXEC dbo.HC_sqldb_tier @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_sqldb_tier
    @database_name sysname = NULL
AS
-- Toolkit 16_azure_sql_database.sql section 16.1: SERVICE TIER / SIZE / LIMITS (user DB)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT DB_NAME() AS database_name,
       DATABASEPROPERTYEX(DB_NAME(), ''''Edition'''')          AS edition,
       DATABASEPROPERTYEX(DB_NAME(), ''''ServiceObjective'''') AS service_objective,
       CAST(DATABASEPROPERTYEX(DB_NAME(), ''''MaxSizeInBytes'''') AS bigint) / 1073741824 AS max_size_gb,
       DATABASEPROPERTYEX(DB_NAME(), ''''Updateability'''')    AS updateability;

SELECT * FROM sys.database_service_objectives;

SELECT * FROM sys.dm_user_db_resource_governance;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 16.2  RESOURCE USAGE - LAST HOUR (15-second samples) (user DB)   (16_azure_sql_database.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_sqldb_resource_1h', @section = N'16.2', @source_file = N'16_azure_sql_database.sql',
    @title = N'RESOURCE USAGE - LAST HOUR (15-second samples) (user DB)', @tags = N'SQLDB',
    @usage = N'EXEC dbo.HC_sqldb_resource_1h @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_sqldb_resource_1h
    @database_name sysname = NULL
AS
-- Toolkit 16_azure_sql_database.sql section 16.2: RESOURCE USAGE - LAST HOUR (15-second samples) (user DB)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT end_time,
       avg_cpu_percent, avg_data_io_percent, avg_log_write_percent,
       avg_memory_usage_percent, max_worker_percent, max_session_percent,
       xtp_storage_percent, avg_instance_cpu_percent, avg_instance_memory_percent
FROM sys.dm_db_resource_stats
ORDER BY end_time DESC;

SELECT MAX(avg_cpu_percent)        AS max_cpu,  AVG(avg_cpu_percent)        AS avg_cpu,
       MAX(avg_data_io_percent)    AS max_io,   AVG(avg_data_io_percent)    AS avg_io,
       MAX(avg_log_write_percent)  AS max_log,  AVG(avg_log_write_percent)  AS avg_log,
       MAX(avg_memory_usage_percent) AS max_mem,
       MAX(max_worker_percent)     AS max_workers,
       MAX(max_session_percent)    AS max_sessions
FROM sys.dm_db_resource_stats;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 16.5  WAIT STATS - THIS DATABASE (user DB)   (16_azure_sql_database.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_sqldb_waits', @section = N'16.5', @source_file = N'16_azure_sql_database.sql',
    @title = N'WAIT STATS - THIS DATABASE (user DB)', @tags = N'SQLDB',
    @usage = N'EXEC dbo.HC_sqldb_waits @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_sqldb_waits
    @database_name sysname = NULL
AS
-- Toolkit 16_azure_sql_database.sql section 16.5: WAIT STATS - THIS DATABASE (user DB)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT TOP (20) wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms,
       CAST(wait_time_ms * 1.0 / NULLIF(waiting_tasks_count, 0) AS decimal(10,2)) AS avg_wait_ms
FROM sys.dm_db_wait_stats
WHERE wait_type NOT LIKE N''''%SLEEP%'''' AND wait_type NOT LIKE N''''%IDLE%'''' AND wait_type NOT LIKE N''''%QUEUE%''''
  AND wait_type NOT IN (N''''XE_TIMER_EVENT'''', N''''WAITFOR'''', N''''BROKER_TASK_STOP'''', N''''CXCONSUMER'''')
ORDER BY wait_time_ms DESC;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 16.6  SPACE USED vs ALLOCATED vs MAX (user DB)   (16_azure_sql_database.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_sqldb_space', @section = N'16.6', @source_file = N'16_azure_sql_database.sql',
    @title = N'SPACE USED vs ALLOCATED vs MAX (user DB)', @tags = N'SQLDB',
    @usage = N'EXEC dbo.HC_sqldb_space @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_sqldb_space
    @database_name sysname = NULL
AS
-- Toolkit 16_azure_sql_database.sql section 16.6: SPACE USED vs ALLOCATED vs MAX (user DB)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT file_id, name, type_desc,
       CAST(size / 128.0 AS decimal(18,2))                            AS allocated_mb,
       CAST(FILEPROPERTY(name, ''''SpaceUsed'''') / 128.0 AS decimal(18,2)) AS used_mb,
       CAST(max_size / 128.0 AS decimal(18,2))                        AS max_mb
FROM sys.database_files;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 16.7  GEO-REPLICATION / FAILOVER GROUP LINK STATUS (user DB)   (16_azure_sql_database.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_sqldb_geo_repl', @section = N'16.7', @source_file = N'16_azure_sql_database.sql',
    @title = N'GEO-REPLICATION / FAILOVER GROUP LINK STATUS (user DB)', @tags = N'SQLDB',
    @usage = N'EXEC dbo.HC_sqldb_geo_repl @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_sqldb_geo_repl
    @database_name sysname = NULL
AS
-- Toolkit 16_azure_sql_database.sql section 16.7: GEO-REPLICATION / FAILOVER GROUP LINK STATUS (user DB)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT link_guid, partner_server, partner_database, replication_state_desc,
       role_desc, secondary_allow_connections_desc, last_replication, replication_lag_sec
FROM sys.dm_geo_replication_link_status;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 16.9  AUTOMATIC TUNING (user DB)   (16_azure_sql_database.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_sqldb_auto_tuning', @section = N'16.9', @source_file = N'16_azure_sql_database.sql',
    @title = N'AUTOMATIC TUNING (user DB)', @tags = N'MI,SQLDB',
    @usage = N'EXEC dbo.HC_sqldb_auto_tuning @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_sqldb_auto_tuning
    @database_name sysname = NULL
AS
-- Toolkit 16_azure_sql_database.sql section 16.9: AUTOMATIC TUNING (user DB)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT name, desired_state_desc, actual_state_desc, reason_desc
FROM sys.database_automatic_tuning_options;

SELECT name, type, reason, valid_since, last_refresh,
       JSON_VALUE(state, ''''$.currentValue'''')                        AS current_state,
       JSON_VALUE(details, ''''$.implementationDetails.script'''')      AS fix_script,
       score
FROM sys.dm_db_tuning_recommendations
ORDER BY score DESC;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 16.10  ACTIVE CONNECTIONS vs LIMIT (user DB)   (16_azure_sql_database.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_sqldb_connections', @section = N'16.10', @source_file = N'16_azure_sql_database.sql',
    @title = N'ACTIVE CONNECTIONS vs LIMIT (user DB)', @tags = N'SQLDB',
    @usage = N'EXEC dbo.HC_sqldb_connections @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_sqldb_connections
    @database_name sysname = NULL
AS
-- Toolkit 16_azure_sql_database.sql section 16.10: ACTIVE CONNECTIONS vs LIMIT (user DB)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT COUNT(*) AS sessions,
       SUM(CASE WHEN status = ''''running'''' THEN 1 ELSE 0 END) AS running,
       (SELECT MAX(max_session_percent) FROM sys.dm_db_resource_stats) AS max_session_pct_last_hour
FROM sys.dm_exec_sessions
WHERE is_user_process = 1;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 16.11  PERSISTENT VERSION STORE (ADR is always on in Azure SQL DB) (user DB)   (16_azure_sql_database.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_sqldb_pvs', @section = N'16.11', @source_file = N'16_azure_sql_database.sql',
    @title = N'PERSISTENT VERSION STORE (ADR is always on in Azure SQL DB) (user DB)', @tags = N'SQLDB',
    @usage = N'EXEC dbo.HC_sqldb_pvs @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_sqldb_pvs
    @database_name sysname = NULL
AS
-- Toolkit 16_azure_sql_database.sql section 16.11: PERSISTENT VERSION STORE (ADR is always on in Azure SQL DB) (user DB)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT DB_NAME(database_id) AS database_name,
       persistent_version_store_size_kb / 1024 AS pvs_mb,
       online_index_version_store_size_kb / 1024 AS online_index_vs_mb,
       current_aborted_transaction_count,
       oldest_active_transaction_id, oldest_aborted_transaction_id,
       pvs_off_row_page_skipped_oldest_active_xdesid
FROM sys.dm_tran_persistent_version_store_stats
WHERE database_id = DB_ID();'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 17.1  AM I ON A MANAGED INSTANCE?   (17_azure_managed_instance.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_mi_check', @section = N'17.1', @source_file = N'17_azure_managed_instance.sql',
    @title = N'AM I ON A MANAGED INSTANCE?', @tags = N'MI',
    @usage = N'SELECT * FROM dbo.HC_mi_check;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_mi_check
AS
-- Toolkit 17_azure_managed_instance.sql section 17.1: AM I ON A MANAGED INSTANCE?
SELECT SERVERPROPERTY(''EngineEdition'') AS engine_edition,
       SERVERPROPERTY(''ServerName'')    AS server_name,
       @@VERSION                       AS version;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_mi_check
AS
-- Toolkit 17_azure_managed_instance.sql section 17.1: AM I ON A MANAGED INSTANCE?
SET NOCOUNT ON;
SELECT SERVERPROPERTY(''EngineEdition'') AS engine_edition,
       SERVERPROPERTY(''ServerName'')    AS server_name,
       @@VERSION                       AS version;
';
GO

/* 17.2  INSTANCE RESOURCE HISTORY - CPU / STORAGE / IO (master)   (17_azure_managed_instance.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_mi_resource_history', @section = N'17.2', @source_file = N'17_azure_managed_instance.sql',
    @title = N'INSTANCE RESOURCE HISTORY - CPU / STORAGE / IO (master)', @tags = N'MI',
    @usage = N'EXEC dbo.HC_mi_resource_history;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_mi_resource_history
AS
-- Toolkit 17_azure_managed_instance.sql section 17.2: INSTANCE RESOURCE HISTORY - CPU / STORAGE / IO (master)
SET NOCOUNT ON;
SELECT TOP (300)
    start_time, end_time, resource_name, sku, hardware_generation,
    virtual_core_count, avg_cpu_percent,
    reserved_storage_mb, storage_space_used_mb,
    CAST(100.0 * storage_space_used_mb / NULLIF(reserved_storage_mb, 0) AS decimal(5,2)) AS storage_used_pct,
    io_requests, io_bytes_read, io_bytes_written
FROM master.sys.server_resource_stats
ORDER BY start_time DESC;

SELECT CAST(start_time AS date) AS day, MAX(avg_cpu_percent) AS peak_cpu, AVG(avg_cpu_percent) AS avg_cpu
FROM master.sys.server_resource_stats
GROUP BY CAST(start_time AS date)
ORDER BY day DESC;
',
    @fallback_definition = NULL;
GO

/* 17.3  INSTANCE GOVERNANCE LIMITS (log rate, IOPS, memory)   (17_azure_managed_instance.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_mi_governance', @section = N'17.3', @source_file = N'17_azure_managed_instance.sql',
    @title = N'INSTANCE GOVERNANCE LIMITS (log rate, IOPS, memory)', @tags = N'MI',
    @usage = N'SELECT * FROM dbo.HC_mi_governance;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_mi_governance
AS
-- Toolkit 17_azure_managed_instance.sql section 17.3: INSTANCE GOVERNANCE LIMITS (log rate, IOPS, memory)
SELECT * FROM sys.dm_instance_resource_governance;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_mi_governance
AS
-- Toolkit 17_azure_managed_instance.sql section 17.3: INSTANCE GOVERNANCE LIMITS (log rate, IOPS, memory)
SET NOCOUNT ON;
SELECT * FROM sys.dm_instance_resource_governance;
';
GO

/* 17.4  STORAGE: INSTANCE TOTAL vs RESERVED   (17_azure_managed_instance.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_mi_storage', @section = N'17.4', @source_file = N'17_azure_managed_instance.sql',
    @title = N'STORAGE: INSTANCE TOTAL vs RESERVED', @tags = N'MI',
    @usage = N'EXEC dbo.HC_mi_storage;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_mi_storage
AS
-- Toolkit 17_azure_managed_instance.sql section 17.4: STORAGE: INSTANCE TOTAL vs RESERVED
SET NOCOUNT ON;
SELECT TOP (1) reserved_storage_mb, storage_space_used_mb,
       reserved_storage_mb - storage_space_used_mb AS free_mb
FROM master.sys.server_resource_stats
ORDER BY start_time DESC;

SELECT DB_NAME(database_id) AS database_name, type_desc,
       CAST(SUM(CAST(size AS bigint)) * 8 / 1024.0 / 1024 AS decimal(18,2)) AS size_gb
FROM sys.master_files
GROUP BY database_id, type_desc
ORDER BY size_gb DESC;
',
    @fallback_definition = NULL;
GO

/* 17.5  GENERAL PURPOSE: FILE SIZE vs REMOTE STORAGE PERFORMANCE   (17_azure_managed_instance.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_mi_gp_file_perf', @section = N'17.5', @source_file = N'17_azure_managed_instance.sql',
    @title = N'GENERAL PURPOSE: FILE SIZE vs REMOTE STORAGE PERFORMANCE', @tags = N'MI',
    @usage = N'SELECT * FROM dbo.HC_mi_gp_file_perf ORDER BY total_io DESC;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY total_io DESC',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_mi_gp_file_perf
AS
-- Toolkit 17_azure_managed_instance.sql section 17.5: GENERAL PURPOSE: FILE SIZE vs REMOTE STORAGE PERFORMANCE
SELECT DB_NAME(mf.database_id) AS database_name, mf.name, mf.type_desc,
       CAST(CAST(mf.size AS bigint) * 8 / 1024.0 / 1024 AS decimal(18,2)) AS size_gb,
       CAST(vfs.io_stall_read_ms  * 1.0 / NULLIF(vfs.num_of_reads, 0)  AS decimal(10,2)) AS avg_read_ms,
       CAST(vfs.io_stall_write_ms * 1.0 / NULLIF(vfs.num_of_writes, 0) AS decimal(10,2)) AS avg_write_ms,
       vfs.num_of_reads + vfs.num_of_writes AS total_io
FROM sys.master_files AS mf
JOIN sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs ON vfs.database_id = mf.database_id AND vfs.file_id = mf.file_id;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_mi_gp_file_perf
AS
-- Toolkit 17_azure_managed_instance.sql section 17.5: GENERAL PURPOSE: FILE SIZE vs REMOTE STORAGE PERFORMANCE
SET NOCOUNT ON;
SELECT DB_NAME(mf.database_id) AS database_name, mf.name, mf.type_desc,
       CAST(CAST(mf.size AS bigint) * 8 / 1024.0 / 1024 AS decimal(18,2)) AS size_gb,
       CAST(vfs.io_stall_read_ms  * 1.0 / NULLIF(vfs.num_of_reads, 0)  AS decimal(10,2)) AS avg_read_ms,
       CAST(vfs.io_stall_write_ms * 1.0 / NULLIF(vfs.num_of_writes, 0) AS decimal(10,2)) AS avg_write_ms,
       vfs.num_of_reads + vfs.num_of_writes AS total_io
FROM sys.master_files AS mf
JOIN sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs ON vfs.database_id = mf.database_id AND vfs.file_id = mf.file_id
ORDER BY total_io DESC;
';
GO

/* 17.6  LOG RATE GOVERNANCE WAITS   (17_azure_managed_instance.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_mi_log_rate_waits', @section = N'17.6', @source_file = N'17_azure_managed_instance.sql',
    @title = N'LOG RATE GOVERNANCE WAITS', @tags = N'MI',
    @usage = N'SELECT * FROM dbo.HC_mi_log_rate_waits ORDER BY wait_time_ms DESC;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY wait_time_ms DESC',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_mi_log_rate_waits
AS
-- Toolkit 17_azure_managed_instance.sql section 17.6: LOG RATE GOVERNANCE WAITS
SELECT wait_type, waiting_tasks_count, wait_time_ms
FROM sys.dm_os_wait_stats
WHERE wait_type IN (N''INSTANCE_LOG_RATE_GOVERNOR'', N''LOG_RATE_GOVERNOR'', N''POOL_LOG_RATE_GOVERNOR'',
                    N''HADR_THROTTLE_LOG_RATE_GOVERNOR'', N''HADR_THROTTLE_LOG_RATE_SEND_RECV_QUEUE_SIZE'',
                    N''WRITELOG'', N''IO_QUEUE_LIMIT'');
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_mi_log_rate_waits
AS
-- Toolkit 17_azure_managed_instance.sql section 17.6: LOG RATE GOVERNANCE WAITS
SET NOCOUNT ON;
SELECT wait_type, waiting_tasks_count, wait_time_ms
FROM sys.dm_os_wait_stats
WHERE wait_type IN (N''INSTANCE_LOG_RATE_GOVERNOR'', N''LOG_RATE_GOVERNOR'', N''POOL_LOG_RATE_GOVERNOR'',
                    N''HADR_THROTTLE_LOG_RATE_GOVERNOR'', N''HADR_THROTTLE_LOG_RATE_SEND_RECV_QUEUE_SIZE'',
                    N''WRITELOG'', N''IO_QUEUE_LIMIT'')
ORDER BY wait_time_ms DESC;
';
GO

/* 17.7  BUSINESS CRITICAL / FAILOVER GROUP REPLICA STATE   (17_azure_managed_instance.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_mi_replica_state', @section = N'17.7', @source_file = N'17_azure_managed_instance.sql',
    @title = N'BUSINESS CRITICAL / FAILOVER GROUP REPLICA STATE', @tags = N'MI',
    @usage = N'SELECT * FROM dbo.HC_mi_replica_state ORDER BY database_name, is_primary_replica DESC;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY database_name, is_primary_replica DESC',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_mi_replica_state
AS
-- Toolkit 17_azure_managed_instance.sql section 17.7: BUSINESS CRITICAL / FAILOVER GROUP REPLICA STATE
SELECT DB_NAME(database_id) AS database_name, is_local, is_primary_replica,
       synchronization_state_desc, synchronization_health_desc,
       log_send_queue_size, redo_queue_size, secondary_lag_seconds, last_commit_time
FROM sys.dm_hadr_database_replica_states;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_mi_replica_state
AS
-- Toolkit 17_azure_managed_instance.sql section 17.7: BUSINESS CRITICAL / FAILOVER GROUP REPLICA STATE
SET NOCOUNT ON;
SELECT DB_NAME(database_id) AS database_name, is_local, is_primary_replica,
       synchronization_state_desc, synchronization_health_desc,
       log_send_queue_size, redo_queue_size, secondary_lag_seconds, last_commit_time
FROM sys.dm_hadr_database_replica_states
ORDER BY database_name, is_primary_replica DESC;
';
GO

/* 17.8  BACKUP HISTORY ON MI   (17_azure_managed_instance.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_mi_backup_history', @section = N'17.8', @source_file = N'17_azure_managed_instance.sql',
    @title = N'BACKUP HISTORY ON MI', @tags = N'MI',
    @usage = N'SELECT * FROM dbo.HC_mi_backup_history ORDER BY backup_start_date DESC;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_mi_backup_history
AS
-- Toolkit 17_azure_managed_instance.sql section 17.8: BACKUP HISTORY ON MI
SELECT TOP (50) database_name, type, backup_start_date, backup_finish_date,
       is_copy_only, backup_size / 1048576 AS size_mb
FROM msdb.dbo.backupset
ORDER BY backup_start_date DESC;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_mi_backup_history
AS
-- Toolkit 17_azure_managed_instance.sql section 17.8: BACKUP HISTORY ON MI
SET NOCOUNT ON;
SELECT TOP (50) database_name, type, backup_start_date, backup_finish_date,
       is_copy_only, backup_size / 1048576 AS size_mb
FROM msdb.dbo.backupset
ORDER BY backup_start_date DESC;
';
GO

/* 18.1  RUNNING XE SESSIONS & TARGETS   (18_extended_events.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_xe_sessions', @section = N'18.1', @source_file = N'18_extended_events.sql',
    @title = N'RUNNING XE SESSIONS & TARGETS', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_xe_sessions;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_xe_sessions
AS
-- Toolkit 18_extended_events.sql section 18.1: RUNNING XE SESSIONS & TARGETS
SET NOCOUNT ON;
SELECT s.name AS session_name, s.create_time, t.target_name,
       CAST(t.target_data AS xml).value(''(EventFileTarget/File/@name)[1]'', ''nvarchar(260)'') AS current_file
FROM sys.dm_xe_sessions AS s
JOIN sys.dm_xe_session_targets AS t ON t.event_session_address = s.address
ORDER BY s.name;
',
    @fallback_definition = NULL;
GO

/* 18.2  BLOCKED PROCESS REPORT (who blocked whom, > N seconds)   (18_extended_events.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_xe_blocked_process', @section = N'18.2', @source_file = N'18_extended_events.sql',
    @title = N'BLOCKED PROCESS REPORT (who blocked whom, > N seconds)', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_xe_blocked_process;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_xe_blocked_process
AS
-- Toolkit 18_extended_events.sql section 18.2: BLOCKED PROCESS REPORT (who blocked whom, > N seconds)
SET NOCOUNT ON;
SELECT
    x.ev.value(''(event/@timestamp)[1]'', ''datetime2'')                     AS event_time_utc,
    x.ev.value(''(event/data[@name="database_name"]/value)[1]'', ''sysname'') AS database_name,
    x.ev.value(''(event/data[@name="duration"]/value)[1]'', ''bigint'') / 1000000 AS blocked_seconds,
    x.ev.query(''(event/data[@name="blocked_process"]/value/blocked-process-report)[1]'') AS report
FROM sys.fn_xe_file_target_read_file(N''D:\XE\DBA_BlockedProcess*.xel'', NULL, NULL, NULL) AS f
CROSS APPLY (SELECT CAST(f.event_data AS xml)) AS x(ev)
ORDER BY event_time_utc DESC;
',
    @fallback_definition = NULL;
GO

/* 18.3  LONG-RUNNING QUERIES (> 5 seconds)   (18_extended_events.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_xe_long_queries', @section = N'18.3', @source_file = N'18_extended_events.sql',
    @title = N'LONG-RUNNING QUERIES (> 5 seconds)', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_xe_long_queries;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_xe_long_queries
AS
-- Toolkit 18_extended_events.sql section 18.3: LONG-RUNNING QUERIES (> 5 seconds)
SET NOCOUNT ON;
SELECT
    x.ev.value(''(event/@timestamp)[1]'', ''datetime2'')                                    AS event_time_utc,
    x.ev.value(''(event/@name)[1]'', ''nvarchar(60)'')                                      AS event_name,
    x.ev.value(''(event/action[@name="database_name"]/value)[1]'', ''sysname'')             AS database_name,
    x.ev.value(''(event/data[@name="duration"]/value)[1]'', ''bigint'') / 1000              AS duration_ms,
    x.ev.value(''(event/data[@name="cpu_time"]/value)[1]'', ''bigint'') / 1000              AS cpu_ms,
    x.ev.value(''(event/data[@name="logical_reads"]/value)[1]'', ''bigint'')                AS logical_reads,
    x.ev.value(''(event/action[@name="client_app_name"]/value)[1]'', ''nvarchar(256)'')     AS app,
    x.ev.value(''(event/action[@name="username"]/value)[1]'', ''nvarchar(256)'')            AS username,
    x.ev.value(''(event/action[@name="sql_text"]/value)[1]'', ''nvarchar(max)'')            AS sql_text
FROM sys.fn_xe_file_target_read_file(N''D:\XE\DBA_LongQueries*.xel'', NULL, NULL, NULL) AS f
CROSS APPLY (SELECT CAST(f.event_data AS xml)) AS x(ev)
ORDER BY duration_ms DESC;
',
    @fallback_definition = NULL;
GO

/* 19.1  GENERATE INDEX REORG / REBUILD - CURRENT DB   (19_maintenance_helpers.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_generate_index_maint', @section = N'19.1', @source_file = N'19_maintenance_helpers.sql',
    @title = N'GENERATE INDEX REORG / REBUILD - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_generate_index_maint @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_generate_index_maint
    @database_name sysname = NULL
AS
-- Toolkit 19_maintenance_helpers.sql section 19.1: GENERATE INDEX REORG / REBUILD - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''DECLARE @online bit = CASE WHEN SERVERPROPERTY(''''EngineEdition'''') IN (3, 5, 8) THEN 1 ELSE 0 END;

SELECT
    OBJECT_SCHEMA_NAME(ips.object_id) + N''''.'''' + OBJECT_NAME(ips.object_id) AS table_name,
    i.name AS index_name, ips.partition_number,
    CAST(ips.avg_fragmentation_in_percent AS decimal(5,2)) AS frag_pct, ips.page_count,
    N''''ALTER INDEX '''' + QUOTENAME(i.name) + N'''' ON ''''
      + QUOTENAME(OBJECT_SCHEMA_NAME(ips.object_id)) + N''''.'''' + QUOTENAME(OBJECT_NAME(ips.object_id))
      + CASE WHEN ips.avg_fragmentation_in_percent >= 30
             THEN N'''' REBUILD'''' + CASE WHEN p.partitions > 1 THEN N'''' PARTITION = '''' + CAST(ips.partition_number AS nvarchar(10)) ELSE N'''''''' END
                  + N'''' WITH (SORT_IN_TEMPDB = ON'''' + CASE WHEN @online = 1 THEN N'''', ONLINE = ON'''' ELSE N'''''''' END + N'''')''''
             ELSE N'''' REORGANIZE'''' + CASE WHEN p.partitions > 1 THEN N'''' PARTITION = '''' + CAST(ips.partition_number AS nvarchar(10)) ELSE N'''''''' END
        END + N'''';'''' AS maintenance_cmd
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, ''''LIMITED'''') AS ips
JOIN sys.indexes AS i ON i.object_id = ips.object_id AND i.index_id = ips.index_id
CROSS APPLY (SELECT COUNT(*) AS partitions FROM sys.partitions AS pp
             WHERE pp.object_id = i.object_id AND pp.index_id = i.index_id) AS p
WHERE ips.avg_fragmentation_in_percent >= 5
  AND ips.page_count >= 1000
  AND ips.index_id > 0
  AND i.is_disabled = 0
  AND ips.alloc_unit_type_desc = ''''IN_ROW_DATA''''
ORDER BY ips.page_count DESC;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 19.2  GENERATE UPDATE STATISTICS FOR STALE STATS - CURRENT DB   (19_maintenance_helpers.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_generate_stats_update', @section = N'19.2', @source_file = N'19_maintenance_helpers.sql',
    @title = N'GENERATE UPDATE STATISTICS FOR STALE STATS - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_generate_stats_update @database_name = N''YourDB'', @min_mod_pct = 10.0;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_generate_stats_update
    @database_name sysname = NULL,
    @min_mod_pct decimal(5,2) = 10.0
AS
-- Toolkit 19_maintenance_helpers.sql section 19.2: GENERATE UPDATE STATISTICS FOR STALE STATS - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT
    OBJECT_SCHEMA_NAME(s.object_id) + N''''.'''' + OBJECT_NAME(s.object_id) AS table_name,
    s.name AS stats_name, sp.rows, sp.modification_counter, sp.last_updated,
    N''''UPDATE STATISTICS '''' + QUOTENAME(OBJECT_SCHEMA_NAME(s.object_id)) + N''''.'''' + QUOTENAME(OBJECT_NAME(s.object_id))
      + N'''' '''' + QUOTENAME(s.name) + N'''' WITH FULLSCAN;'''' AS update_cmd
FROM sys.stats AS s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
WHERE OBJECTPROPERTY(s.object_id, ''''IsUserTable'''') = 1
  AND sp.rows > 0
  AND 100.0 * sp.modification_counter / sp.rows >= @min_mod_pct
ORDER BY sp.modification_counter DESC;'';
EXEC @hc_exec @hc_sql, N''@min_mod_pct decimal(5,2)'', @min_mod_pct = @min_mod_pct;
',
    @fallback_definition = NULL;
GO

/* 19.4  FIND AN OBJECT BY NAME ACROSS ALL DATABASES   (19_maintenance_helpers.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_find_object', @section = N'19.4', @source_file = N'19_maintenance_helpers.sql',
    @title = N'FIND AN OBJECT BY NAME ACROSS ALL DATABASES', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_find_object @object_name = N''%Customer%'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_find_object
    @object_name nvarchar(128) = N''%Customer%''
AS
-- Toolkit 19_maintenance_helpers.sql section 19.4: FIND AN OBJECT BY NAME ACROSS ALL DATABASES
SET NOCOUNT ON;
IF OBJECT_ID(''tempdb..#found'') IS NOT NULL DROP TABLE #found;
CREATE TABLE #found (database_name sysname, schema_name sysname, object_name sysname, type_desc nvarchar(60), modify_date datetime);
DECLARE @sql nvarchar(max) = N'''';
SELECT @sql += N''USE '' + QUOTENAME(name) + N'';
INSERT #found SELECT DB_NAME(), SCHEMA_NAME(schema_id), name, type_desc, modify_date FROM sys.objects WHERE name LIKE @p;
''
FROM sys.databases WHERE state_desc = N''ONLINE'' AND HAS_DBACCESS(name) = 1;
EXEC sys.sp_executesql @sql, N''@p nvarchar(128)'', @p = @object_name;
SELECT * FROM #found ORDER BY database_name, object_name;
',
    @fallback_definition = NULL;
GO

/* 19.5  FIND A COLUMN BY NAME - CURRENT DB   (19_maintenance_helpers.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_find_column', @section = N'19.5', @source_file = N'19_maintenance_helpers.sql',
    @title = N'FIND A COLUMN BY NAME - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_find_column @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_find_column
    @database_name sysname = NULL
AS
-- Toolkit 19_maintenance_helpers.sql section 19.5: FIND A COLUMN BY NAME - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT OBJECT_SCHEMA_NAME(c.object_id) + N''''.'''' + OBJECT_NAME(c.object_id) AS table_name,
       c.name AS column_name, TYPE_NAME(c.user_type_id) AS data_type, c.max_length, c.is_nullable
FROM sys.columns AS c
JOIN sys.objects AS o ON o.object_id = c.object_id AND o.type IN (''''U'''', ''''V'''')
WHERE c.name LIKE N''''%Email%''''
ORDER BY table_name;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 19.6  SEARCH CODE (procs, views, functions, triggers) - CURRENT DB   (19_maintenance_helpers.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_search_code', @section = N'19.6', @source_file = N'19_maintenance_helpers.sql',
    @title = N'SEARCH CODE (procs, views, functions, triggers) - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_search_code @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_search_code
    @database_name sysname = NULL
AS
-- Toolkit 19_maintenance_helpers.sql section 19.6: SEARCH CODE (procs, views, functions, triggers) - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT OBJECT_SCHEMA_NAME(m.object_id) + N''''.'''' + OBJECT_NAME(m.object_id) AS object_name,
       o.type_desc, o.modify_date
FROM sys.sql_modules AS m
JOIN sys.objects AS o ON o.object_id = m.object_id
WHERE m.definition LIKE N''''%YourSearchText%''''
ORDER BY object_name;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 19.7  FAST ROW COUNTS - CURRENT DB (no table scans)   (19_maintenance_helpers.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_row_counts', @section = N'19.7', @source_file = N'19_maintenance_helpers.sql',
    @title = N'FAST ROW COUNTS - CURRENT DB (no table scans)', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_row_counts @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_row_counts
    @database_name sysname = NULL
AS
-- Toolkit 19_maintenance_helpers.sql section 19.7: FAST ROW COUNTS - CURRENT DB (no table scans)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT OBJECT_SCHEMA_NAME(object_id) + N''''.'''' + OBJECT_NAME(object_id) AS table_name,
       SUM(row_count) AS row_count
FROM sys.dm_db_partition_stats
WHERE index_id IN (0, 1) AND OBJECTPROPERTY(object_id, ''''IsUserTable'''') = 1
GROUP BY object_id
ORDER BY row_count DESC;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 19.8  RECENTLY MODIFIED OBJECTS (what changed?) - CURRENT DB   (19_maintenance_helpers.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_recently_modified', @section = N'19.8', @source_file = N'19_maintenance_helpers.sql',
    @title = N'RECENTLY MODIFIED OBJECTS (what changed?) - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_recently_modified @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_recently_modified
    @database_name sysname = NULL
AS
-- Toolkit 19_maintenance_helpers.sql section 19.8: RECENTLY MODIFIED OBJECTS (what changed?) - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT TOP (50) SCHEMA_NAME(schema_id) + N''''.'''' + name AS object_name, type_desc, create_date, modify_date
FROM sys.objects
WHERE is_ms_shipped = 0
ORDER BY modify_date DESC;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 20.1  2017+ : HOST INFO, AUTOMATIC TUNING, RESUMABLE INDEX   (20_version_specific_features.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_v2017_features', @section = N'20.1', @source_file = N'20_version_specific_features.sql',
    @title = N'2017+ : HOST INFO, AUTOMATIC TUNING, RESUMABLE INDEX', @tags = N'',
    @usage = N'EXEC dbo.HC_v2017_features @database_name = N''YourDB'';',
    @min_version = 14,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_v2017_features
    @database_name sysname = NULL
AS
-- Toolkit 20_version_specific_features.sql section 20.1: 2017+ : HOST INFO, AUTOMATIC TUNING, RESUMABLE INDEX
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT * FROM sys.dm_os_host_info;
SELECT * FROM sys.dm_db_tuning_recommendations;
SELECT * FROM sys.index_resumable_operations;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 20.2  2019+ : ACCELERATED DATABASE RECOVERY (ADR)   (20_version_specific_features.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_adr_status', @section = N'20.2', @source_file = N'20_version_specific_features.sql',
    @title = N'2019+ : ACCELERATED DATABASE RECOVERY (ADR)', @tags = N'',
    @usage = N'EXEC dbo.HC_adr_status @database_name = N''YourDB'';',
    @min_version = 15,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_adr_status
    @database_name sysname = NULL
AS
-- Toolkit 20_version_specific_features.sql section 20.2: 2019+ : ACCELERATED DATABASE RECOVERY (ADR)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT name, is_accelerated_database_recovery_on FROM sys.databases ORDER BY name;

SELECT DB_NAME(database_id) AS database_name,
       persistent_version_store_size_kb / 1024 AS pvs_mb,
       current_aborted_transaction_count, oldest_active_transaction_id
FROM sys.dm_tran_persistent_version_store_stats;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 20.3  2019+ : DECODE A wait_resource PAGE (PAGELATCH / PAGEIOLATCH)   (20_version_specific_features.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_decode_page', @section = N'20.3', @source_file = N'20_version_specific_features.sql',
    @title = N'2019+ : DECODE A wait_resource PAGE (PAGELATCH / PAGEIOLATCH)', @tags = N'',
    @usage = N'SELECT * FROM dbo.HC_decode_page;',
    @min_version = 15,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_decode_page
AS
-- Toolkit 20_version_specific_features.sql section 20.3: 2019+ : DECODE A wait_resource PAGE (PAGELATCH / PAGEIOLATCH)
SELECT r.session_id, r.wait_type, r.wait_resource,
       OBJECT_SCHEMA_NAME(pi.object_id, pi.database_id) + N''.'' + OBJECT_NAME(pi.object_id, pi.database_id) AS object_name,
       pi.index_id, pi.page_type_desc
FROM sys.dm_exec_requests AS r
CROSS APPLY sys.fn_PageResCracker(r.page_resource) AS prc
CROSS APPLY sys.dm_db_page_info(prc.db_id, prc.file_id, prc.page_id, ''LIMITED'') AS pi
WHERE r.page_resource IS NOT NULL;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_decode_page
AS
-- Toolkit 20_version_specific_features.sql section 20.3: 2019+ : DECODE A wait_resource PAGE (PAGELATCH / PAGEIOLATCH)
SET NOCOUNT ON;
SELECT r.session_id, r.wait_type, r.wait_resource,
       OBJECT_SCHEMA_NAME(pi.object_id, pi.database_id) + N''.'' + OBJECT_NAME(pi.object_id, pi.database_id) AS object_name,
       pi.index_id, pi.page_type_desc
FROM sys.dm_exec_requests AS r
CROSS APPLY sys.fn_PageResCracker(r.page_resource) AS prc
CROSS APPLY sys.dm_db_page_info(prc.db_id, prc.file_id, prc.page_id, ''LIMITED'') AS pi
WHERE r.page_resource IS NOT NULL;
';
GO

/* 20.4  2019+ : LAST ACTUAL EXECUTION PLAN FROM CACHE   (20_version_specific_features.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_last_actual_plan', @section = N'20.4', @source_file = N'20_version_specific_features.sql',
    @title = N'2019+ : LAST ACTUAL EXECUTION PLAN FROM CACHE', @tags = N'',
    @usage = N'SELECT * FROM dbo.HC_last_actual_plan;',
    @min_version = 15,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_last_actual_plan
AS
-- Toolkit 20_version_specific_features.sql section 20.4: 2019+ : LAST ACTUAL EXECUTION PLAN FROM CACHE
SELECT TOP (10) DB_NAME(t.dbid) AS database_name, qs.execution_count, t.text, qps.query_plan AS last_actual_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
CROSS APPLY sys.dm_exec_query_plan_stats(qs.plan_handle) AS qps
ORDER BY qs.total_worker_time DESC;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_last_actual_plan
AS
-- Toolkit 20_version_specific_features.sql section 20.4: 2019+ : LAST ACTUAL EXECUTION PLAN FROM CACHE
SET NOCOUNT ON;
SELECT TOP (10) DB_NAME(t.dbid) AS database_name, qs.execution_count, t.text, qps.query_plan AS last_actual_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
CROSS APPLY sys.dm_exec_query_plan_stats(qs.plan_handle) AS qps
ORDER BY qs.total_worker_time DESC;
';
GO

/* 20.5  2019+ : MISSING INDEX -> WHICH QUERY ASKED FOR IT   (20_version_specific_features.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_missing_index_queries', @section = N'20.5', @source_file = N'20_version_specific_features.sql',
    @title = N'2019+ : MISSING INDEX -> WHICH QUERY ASKED FOR IT', @tags = N'',
    @usage = N'SELECT * FROM dbo.HC_missing_index_queries;',
    @min_version = 15,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_missing_index_queries
AS
-- Toolkit 20_version_specific_features.sql section 20.5: 2019+ : MISSING INDEX -> WHICH QUERY ASKED FOR IT
SELECT TOP (20) mid.statement AS table_name, mid.equality_columns, mid.inequality_columns, mid.included_columns,
       migsq.user_seeks, migsq.avg_user_impact, migsq.avg_total_user_cost,
       SUBSTRING(t.text, migsq.last_statement_start_offset / 2 + 1,
           (CASE migsq.last_statement_end_offset WHEN -1 THEN DATALENGTH(t.text)
            ELSE migsq.last_statement_end_offset END - migsq.last_statement_start_offset) / 2 + 1) AS query_text
FROM sys.dm_db_missing_index_group_stats_query AS migsq
JOIN sys.dm_db_missing_index_groups  AS mig ON mig.index_group_handle = migsq.group_handle
JOIN sys.dm_db_missing_index_details AS mid ON mid.index_handle = mig.index_handle
CROSS APPLY sys.dm_exec_sql_text(migsq.last_sql_handle) AS t
ORDER BY migsq.avg_total_user_cost * migsq.avg_user_impact * migsq.user_seeks DESC;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_missing_index_queries
AS
-- Toolkit 20_version_specific_features.sql section 20.5: 2019+ : MISSING INDEX -> WHICH QUERY ASKED FOR IT
SET NOCOUNT ON;
SELECT TOP (20) mid.statement AS table_name, mid.equality_columns, mid.inequality_columns, mid.included_columns,
       migsq.user_seeks, migsq.avg_user_impact, migsq.avg_total_user_cost,
       SUBSTRING(t.text, migsq.last_statement_start_offset / 2 + 1,
           (CASE migsq.last_statement_end_offset WHEN -1 THEN DATALENGTH(t.text)
            ELSE migsq.last_statement_end_offset END - migsq.last_statement_start_offset) / 2 + 1) AS query_text
FROM sys.dm_db_missing_index_group_stats_query AS migsq
JOIN sys.dm_db_missing_index_groups  AS mig ON mig.index_group_handle = migsq.group_handle
JOIN sys.dm_db_missing_index_details AS mid ON mid.index_handle = mig.index_handle
CROSS APPLY sys.dm_exec_sql_text(migsq.last_sql_handle) AS t
ORDER BY migsq.avg_total_user_cost * migsq.avg_user_impact * migsq.user_seeks DESC;
';
GO

/* 20.6  2019+ : INTELLIGENT QUERY PROCESSING SETTINGS (current DB)   (20_version_specific_features.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_iqp_settings', @section = N'20.6', @source_file = N'20_version_specific_features.sql',
    @title = N'2019+ : INTELLIGENT QUERY PROCESSING SETTINGS (current DB)', @tags = N'',
    @usage = N'EXEC dbo.HC_iqp_settings @database_name = N''YourDB'';',
    @min_version = 15,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_iqp_settings
    @database_name sysname = NULL
AS
-- Toolkit 20_version_specific_features.sql section 20.6: 2019+ : INTELLIGENT QUERY PROCESSING SETTINGS (current DB)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT name, value, is_value_default
FROM sys.database_scoped_configurations
WHERE name IN (N''''BATCH_MODE_ON_ROWSTORE'''', N''''BATCH_MODE_MEMORY_GRANT_FEEDBACK'''',
               N''''ROW_MODE_MEMORY_GRANT_FEEDBACK'''', N''''INTERLEAVED_EXECUTION_TVF'''',
               N''''TSQL_SCALAR_UDF_INLINING'''', N''''DEFERRED_COMPILATION_TV'''',
               N''''PARAMETER_SENSITIVE_PLAN_OPTIMIZATION'''', N''''DOP_FEEDBACK'''', N''''CE_FEEDBACK'''',
               N''''MEMORY_GRANT_FEEDBACK_PERCENTILE_GRANT'''', N''''MEMORY_GRANT_FEEDBACK_PERSISTENCE'''',
               N''''OPTIMIZED_PLAN_FORCING'''', N''''LAST_QUERY_PLAN_STATS'''', N''''LIGHTWEIGHT_QUERY_PROFILING'''')
ORDER BY name;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 20.7  2022+ : CONTAINED AVAILABILITY GROUPS   (20_version_specific_features.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_contained_ags', @section = N'20.7', @source_file = N'20_version_specific_features.sql',
    @title = N'2022+ : CONTAINED AVAILABILITY GROUPS', @tags = N'',
    @usage = N'SELECT * FROM dbo.HC_contained_ags;',
    @min_version = 16,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_contained_ags
AS
-- Toolkit 20_version_specific_features.sql section 20.7: 2022+ : CONTAINED AVAILABILITY GROUPS
SELECT name, is_contained, cluster_type_desc FROM sys.availability_groups;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_contained_ags
AS
-- Toolkit 20_version_specific_features.sql section 20.7: 2022+ : CONTAINED AVAILABILITY GROUPS
SET NOCOUNT ON;
SELECT name, is_contained, cluster_type_desc FROM sys.availability_groups;
';
GO

/* 20.8  2022+ : PARAMETER SENSITIVE PLAN (PSP) VARIANTS IN QUERY STORE   (20_version_specific_features.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_psp_variants', @section = N'20.8', @source_file = N'20_version_specific_features.sql',
    @title = N'2022+ : PARAMETER SENSITIVE PLAN (PSP) VARIANTS IN QUERY STORE', @tags = N'',
    @usage = N'EXEC dbo.HC_psp_variants @database_name = N''YourDB'';',
    @min_version = 16,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_psp_variants
    @database_name sysname = NULL
AS
-- Toolkit 20_version_specific_features.sql section 20.8: 2022+ : PARAMETER SENSITIVE PLAN (PSP) VARIANTS IN QUERY STORE
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT qv.query_variant_query_id, qv.parent_query_id, qv.dispatcher_plan_id, qt.query_sql_text
FROM sys.query_store_query_variant AS qv
JOIN sys.query_store_query AS q ON q.query_id = qv.parent_query_id
JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 20.9  2022+ : LEDGER TABLES   (20_version_specific_features.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_ledger_tables', @section = N'20.9', @source_file = N'20_version_specific_features.sql',
    @title = N'2022+ : LEDGER TABLES', @tags = N'',
    @usage = N'EXEC dbo.HC_ledger_tables @database_name = N''YourDB'';',
    @min_version = 16,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_ledger_tables
    @database_name sysname = NULL
AS
-- Toolkit 20_version_specific_features.sql section 20.9: 2022+ : LEDGER TABLES
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT OBJECT_SCHEMA_NAME(object_id) + N''''.'''' + name AS table_name, ledger_type_desc, is_dropped_ledger_table
FROM sys.tables
WHERE ledger_type <> 0;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 20.10  2022+ : OUT-OF-MEMORY EVENTS   (20_version_specific_features.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_oom_events_2022', @section = N'20.10', @source_file = N'20_version_specific_features.sql',
    @title = N'2022+ : OUT-OF-MEMORY EVENTS', @tags = N'',
    @usage = N'SELECT * FROM dbo.HC_oom_events_2022;',
    @min_version = 16,
    @sort_hint = N'ORDER BY event_time DESC',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_oom_events_2022
AS
-- Toolkit 20_version_specific_features.sql section 20.10: 2022+ : OUT-OF-MEMORY EVENTS
SELECT * FROM sys.dm_os_out_of_memory_events;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_oom_events_2022
AS
-- Toolkit 20_version_specific_features.sql section 20.10: 2022+ : OUT-OF-MEMORY EVENTS
SET NOCOUNT ON;
SELECT * FROM sys.dm_os_out_of_memory_events ORDER BY event_time DESC;
';
GO

/* 20.11  2025 (and Azure SQL DB) : OPTIMIZED LOCKING   (20_version_specific_features.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_optimized_locking', @section = N'20.11', @source_file = N'20_version_specific_features.sql',
    @title = N'2025 (and Azure SQL DB) : OPTIMIZED LOCKING', @tags = N'',
    @usage = N'SELECT * FROM dbo.HC_optimized_locking ORDER BY name;',
    @min_version = 17,
    @sort_hint = N'ORDER BY name',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_optimized_locking
AS
-- Toolkit 20_version_specific_features.sql section 20.11: 2025 (and Azure SQL DB) : OPTIMIZED LOCKING
SELECT name,
       is_accelerated_database_recovery_on,
       is_read_committed_snapshot_on,
       DATABASEPROPERTYEX(name, ''IsOptimizedLockingOn'') AS is_optimized_locking_on
FROM sys.databases
WHERE database_id > 4;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_optimized_locking
AS
-- Toolkit 20_version_specific_features.sql section 20.11: 2025 (and Azure SQL DB) : OPTIMIZED LOCKING
SET NOCOUNT ON;
SELECT name,
       is_accelerated_database_recovery_on,
       is_read_committed_snapshot_on,
       DATABASEPROPERTYEX(name, ''IsOptimizedLockingOn'') AS is_optimized_locking_on
FROM sys.databases
WHERE database_id > 4
ORDER BY name;
';
GO

/* 20.12  QUICK "WHAT VERSION AM I ON" DECODER   (20_version_specific_features.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_version_decoder', @section = N'20.12', @source_file = N'20_version_specific_features.sql',
    @title = N'QUICK "WHAT VERSION AM I ON" DECODER', @tags = N'',
    @usage = N'EXEC dbo.HC_version_decoder;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_version_decoder
AS
-- Toolkit 20_version_specific_features.sql section 20.12: QUICK "WHAT VERSION AM I ON" DECODER
SET NOCOUNT ON;
SELECT CASE PARSENAME(CAST(SERVERPROPERTY(''ProductVersion'') AS varchar(20)), 4)
           WHEN ''13'' THEN ''SQL Server 2016''
           WHEN ''14'' THEN ''SQL Server 2017''
           WHEN ''15'' THEN ''SQL Server 2019''
           WHEN ''16'' THEN ''SQL Server 2022''
           WHEN ''17'' THEN ''SQL Server 2025''
           WHEN ''12'' THEN CASE WHEN SERVERPROPERTY(''EngineEdition'') = 5 THEN ''Azure SQL Database''
                               WHEN SERVERPROPERTY(''EngineEdition'') = 8 THEN ''Azure SQL Managed Instance''
                               ELSE ''SQL Server 2014'' END
           ELSE ''Other / unknown'' END AS sql_version,
       SERVERPROPERTY(''ProductVersion'') AS build,
       SERVERPROPERTY(''ProductUpdateLevel'') AS cu,
       SERVERPROPERTY(''EngineEdition'') AS engine_edition;
',
    @fallback_definition = NULL;
GO

/* 21.1  DATABASES WITH CDC / CHANGE TRACKING ENABLED   (21_cdc_change_tracking.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_cdc_ct_databases', @section = N'21.1', @source_file = N'21_cdc_change_tracking.sql',
    @title = N'DATABASES WITH CDC / CHANGE TRACKING ENABLED', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_cdc_ct_databases;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_cdc_ct_databases
AS
-- Toolkit 21_cdc_change_tracking.sql section 21.1: DATABASES WITH CDC / CHANGE TRACKING ENABLED
SET NOCOUNT ON;
SELECT d.name, d.is_cdc_enabled,
       CASE WHEN ct.database_id IS NOT NULL THEN 1 ELSE 0 END AS is_change_tracking_enabled,
       ct.retention_period, ct.retention_period_units_desc, ct.is_auto_cleanup_on,
       d.log_reuse_wait_desc
FROM sys.databases AS d
LEFT JOIN sys.change_tracking_databases AS ct ON ct.database_id = d.database_id
WHERE d.is_cdc_enabled = 1 OR ct.database_id IS NOT NULL
ORDER BY d.name;
',
    @fallback_definition = NULL;
GO

/* 21.2  CDC TRACKED TABLES & CAPTURE INSTANCES - CURRENT DB   (21_cdc_change_tracking.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_cdc_tables', @section = N'21.2', @source_file = N'21_cdc_change_tracking.sql',
    @title = N'CDC TRACKED TABLES & CAPTURE INSTANCES - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_cdc_tables @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_cdc_tables
    @database_name sysname = NULL
AS
-- Toolkit 21_cdc_change_tracking.sql section 21.2: CDC TRACKED TABLES & CAPTURE INSTANCES - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT OBJECT_SCHEMA_NAME(ct.source_object_id) + N''''.'''' + OBJECT_NAME(ct.source_object_id) AS source_table,
       ct.capture_instance, ct.supports_net_changes, ct.role_name AS gating_role,
       ct.index_name AS unique_index_for_net_changes, ct.filegroup_name,
       ct.create_date, ct.start_lsn,
       sys.fn_cdc_map_lsn_to_time(ct.start_lsn)          AS capture_start_time,
       sys.fn_cdc_get_min_lsn(ct.capture_instance)        AS min_lsn_available,
       sys.fn_cdc_map_lsn_to_time(sys.fn_cdc_get_min_lsn(ct.capture_instance)) AS oldest_change_time,
       OBJECT_NAME(ct.object_id)                          AS change_table_name
FROM cdc.change_tables AS ct
ORDER BY source_table;

SELECT sys.fn_cdc_get_max_lsn() AS max_lsn,
       sys.fn_cdc_map_lsn_to_time(sys.fn_cdc_get_max_lsn()) AS last_captured_change_time;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 21.3  CAPTURED COLUMNS PER CAPTURE INSTANCE - CURRENT DB   (21_cdc_change_tracking.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_cdc_columns', @section = N'21.3', @source_file = N'21_cdc_change_tracking.sql',
    @title = N'CAPTURED COLUMNS PER CAPTURE INSTANCE - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_cdc_columns @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_cdc_columns
    @database_name sysname = NULL
AS
-- Toolkit 21_cdc_change_tracking.sql section 21.3: CAPTURED COLUMNS PER CAPTURE INSTANCE - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT ct.capture_instance, cc.column_ordinal, cc.column_name, cc.column_type, cc.is_computed
FROM cdc.captured_columns AS cc
JOIN cdc.change_tables AS ct ON ct.object_id = cc.object_id
ORDER BY ct.capture_instance, cc.column_ordinal;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 21.4  SOURCE TABLE COLUMNS NOT CAPTURED (schema drift after enabling CDC)   (21_cdc_change_tracking.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_cdc_schema_drift', @section = N'21.4', @source_file = N'21_cdc_change_tracking.sql',
    @title = N'SOURCE TABLE COLUMNS NOT CAPTURED (schema drift after enabling CDC)', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_cdc_schema_drift @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_cdc_schema_drift
    @database_name sysname = NULL
AS
-- Toolkit 21_cdc_change_tracking.sql section 21.4: SOURCE TABLE COLUMNS NOT CAPTURED (schema drift after enabling CDC)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT ct.capture_instance,
       OBJECT_SCHEMA_NAME(c.object_id) + N''''.'''' + OBJECT_NAME(c.object_id) AS source_table,
       c.name AS column_not_captured
FROM cdc.change_tables AS ct
JOIN sys.columns AS c ON c.object_id = ct.source_object_id
WHERE NOT EXISTS (SELECT 1 FROM cdc.captured_columns AS cc
                  WHERE cc.object_id = ct.object_id AND cc.column_name = c.name)
ORDER BY source_table, c.column_id;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 21.5  CDC CAPTURE LATENCY & THROUGHPUT (log scan sessions)   (21_cdc_change_tracking.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_cdc_latency', @section = N'21.5', @source_file = N'21_cdc_change_tracking.sql',
    @title = N'CDC CAPTURE LATENCY & THROUGHPUT (log scan sessions)', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_cdc_latency @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_cdc_latency
    @database_name sysname = NULL
AS
-- Toolkit 21_cdc_change_tracking.sql section 21.5: CDC CAPTURE LATENCY & THROUGHPUT (log scan sessions)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT TOP (50) session_id, start_time, end_time, duration, scan_phase,
       error_count, tran_count, command_count, empty_scan_count,
       latency, last_commit_time, log_record_count, schema_change_count, failed_sessions_count
FROM sys.dm_cdc_log_scan_sessions
ORDER BY session_id DESC;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 21.6  CDC ERRORS   (21_cdc_change_tracking.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_cdc_errors', @section = N'21.6', @source_file = N'21_cdc_change_tracking.sql',
    @title = N'CDC ERRORS', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_cdc_errors @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_cdc_errors
    @database_name sysname = NULL
AS
-- Toolkit 21_cdc_change_tracking.sql section 21.6: CDC ERRORS
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT session_id, phase_number, entry_time, error_number, error_severity, error_state, error_message
FROM sys.dm_cdc_errors
ORDER BY entry_time DESC;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 21.7  CDC AGENT JOBS & SETTINGS (retention, polling)   (21_cdc_change_tracking.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_cdc_jobs', @section = N'21.7', @source_file = N'21_cdc_change_tracking.sql',
    @title = N'CDC AGENT JOBS & SETTINGS (retention, polling)', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_cdc_jobs;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_cdc_jobs
AS
-- Toolkit 21_cdc_change_tracking.sql section 21.7: CDC AGENT JOBS & SETTINGS (retention, polling)
SET NOCOUNT ON;
SELECT DB_NAME(cj.database_id) AS database_name, cj.job_type, j.name AS job_name, j.enabled,
       cj.maxtrans, cj.maxscans, cj.continuous, cj.pollinginterval,
       cj.retention AS retention_minutes, cj.retention / 1440.0 AS retention_days, cj.threshold
FROM msdb.dbo.cdc_jobs AS cj
LEFT JOIN msdb.dbo.sysjobs AS j ON j.job_id = cj.job_id
ORDER BY database_name, cj.job_type;

SELECT j.name, ja.start_execution_date, ja.stop_execution_date
FROM msdb.dbo.sysjobactivity AS ja
JOIN msdb.dbo.sysjobs AS j ON j.job_id = ja.job_id
WHERE j.name LIKE N''cdc.%capture''
  AND ja.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions);
',
    @fallback_definition = NULL;
GO

/* 21.8  CDC IS HOLDING THE LOG? (log_reuse_wait = REPLICATION)   (21_cdc_change_tracking.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_cdc_log_hold', @section = N'21.8', @source_file = N'21_cdc_change_tracking.sql',
    @title = N'CDC IS HOLDING THE LOG? (log_reuse_wait = REPLICATION)', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_cdc_log_hold;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_cdc_log_hold
AS
-- Toolkit 21_cdc_change_tracking.sql section 21.8: CDC IS HOLDING THE LOG? (log_reuse_wait = REPLICATION)
SELECT name, is_cdc_enabled, is_published, log_reuse_wait_desc
FROM sys.databases
WHERE log_reuse_wait_desc = N''REPLICATION'';
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_cdc_log_hold
AS
-- Toolkit 21_cdc_change_tracking.sql section 21.8: CDC IS HOLDING THE LOG? (log_reuse_wait = REPLICATION)
SET NOCOUNT ON;
SELECT name, is_cdc_enabled, is_published, log_reuse_wait_desc
FROM sys.databases
WHERE log_reuse_wait_desc = N''REPLICATION'';
';
GO

/* 21.9  CHANGE TABLE SIZES - CURRENT DB   (21_cdc_change_tracking.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_cdc_table_sizes', @section = N'21.9', @source_file = N'21_cdc_change_tracking.sql',
    @title = N'CHANGE TABLE SIZES - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_cdc_table_sizes @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_cdc_table_sizes
    @database_name sysname = NULL
AS
-- Toolkit 21_cdc_change_tracking.sql section 21.9: CHANGE TABLE SIZES - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT ct.capture_instance,
       SUM(CASE WHEN ps.index_id < 2 THEN ps.row_count ELSE 0 END)     AS change_rows,
       CAST(SUM(ps.reserved_page_count) * 8 / 1024.0 AS decimal(18,2)) AS reserved_mb
FROM cdc.change_tables AS ct
JOIN sys.dm_db_partition_stats AS ps ON ps.object_id = ct.object_id
GROUP BY ct.capture_instance
ORDER BY reserved_mb DESC;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 21.13  CHANGE TRACKING - TABLES & VERSIONS - CURRENT DB   (21_cdc_change_tracking.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_ct_tables', @section = N'21.13', @source_file = N'21_cdc_change_tracking.sql',
    @title = N'CHANGE TRACKING - TABLES & VERSIONS - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_ct_tables @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_ct_tables
    @database_name sysname = NULL
AS
-- Toolkit 21_cdc_change_tracking.sql section 21.13: CHANGE TRACKING - TABLES & VERSIONS - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT OBJECT_SCHEMA_NAME(ctt.object_id) + N''''.'''' + OBJECT_NAME(ctt.object_id) AS table_name,
       ctt.is_track_columns_updated_on,
       ctt.min_valid_version,
       ctt.begin_version, ctt.cleanup_version,
       CHANGE_TRACKING_CURRENT_VERSION() AS current_version
FROM sys.change_tracking_tables AS ctt
ORDER BY table_name;

SELECT OBJECT_NAME(it.parent_id) AS tracked_table, it.name AS internal_table, it.internal_type_desc,
       SUM(ps.row_count) AS rows,
       CAST(SUM(ps.reserved_page_count) * 8 / 1024.0 AS decimal(18,2)) AS reserved_mb
FROM sys.internal_tables AS it
JOIN sys.dm_db_partition_stats AS ps ON ps.object_id = it.object_id AND ps.index_id IN (0, 1)
WHERE it.internal_type_desc IN (N''''CHANGE_TRACKING'''', N''''TRACKED_COMMITTED_TRANSACTIONS'''')
GROUP BY it.parent_id, it.name, it.internal_type_desc
ORDER BY reserved_mb DESC;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 22.1  TDE STATUS PER DATABASE + PROTECTING CERTIFICATE   (22_tde_encryption.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_tde_status', @section = N'22.1', @source_file = N'22_tde_encryption.sql',
    @title = N'TDE STATUS PER DATABASE + PROTECTING CERTIFICATE', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_tde_status;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_tde_status
AS
-- Toolkit 22_tde_encryption.sql section 22.1: TDE STATUS PER DATABASE + PROTECTING CERTIFICATE
SET NOCOUNT ON;
SELECT DB_NAME(dek.database_id) AS database_name,
       dek.encryption_state,
       CASE dek.encryption_state WHEN 0 THEN ''No key'' WHEN 1 THEN ''Unencrypted''
            WHEN 2 THEN ''Encryption in progress'' WHEN 3 THEN ''ENCRYPTED''
            WHEN 4 THEN ''Key change in progress'' WHEN 5 THEN ''Decryption in progress''
            WHEN 6 THEN ''Protection change in progress'' END AS encryption_state_desc,
       dek.percent_complete,

       dek.key_algorithm, dek.key_length,
       dek.encryptor_type,
       c.name AS certificate_name, c.expiry_date AS cert_expiry, c.pvt_key_last_backup_date,
       dek.create_date, dek.regenerate_date, dek.set_date
FROM sys.dm_database_encryption_keys AS dek
LEFT JOIN master.sys.certificates AS c ON c.thumbprint = dek.encryptor_thumbprint
ORDER BY database_name;
',
    @fallback_definition = NULL;
GO

/* 22.2  USER DATABASES NOT ENCRYPTED   (22_tde_encryption.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_dbs_not_encrypted', @section = N'22.2', @source_file = N'22_tde_encryption.sql',
    @title = N'USER DATABASES NOT ENCRYPTED', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_dbs_not_encrypted ORDER BY name;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY d.name',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_dbs_not_encrypted
AS
-- Toolkit 22_tde_encryption.sql section 22.2: USER DATABASES NOT ENCRYPTED
SELECT d.name, d.is_encrypted, d.state_desc
FROM sys.databases AS d
LEFT JOIN sys.dm_database_encryption_keys AS dek ON dek.database_id = d.database_id
WHERE d.database_id > 4
  AND ISNULL(dek.encryption_state, 1) <> 3;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_dbs_not_encrypted
AS
-- Toolkit 22_tde_encryption.sql section 22.2: USER DATABASES NOT ENCRYPTED
SET NOCOUNT ON;
SELECT d.name, d.is_encrypted, d.state_desc
FROM sys.databases AS d
LEFT JOIN sys.dm_database_encryption_keys AS dek ON dek.database_id = d.database_id
WHERE d.database_id > 4
  AND ISNULL(dek.encryption_state, 1) <> 3
ORDER BY d.name;
';
GO

/* 22.3  CERTIFICATES IN MASTER - EXPIRY & PRIVATE KEY BACKUP   (22_tde_encryption.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_certificates', @section = N'22.3', @source_file = N'22_tde_encryption.sql',
    @title = N'CERTIFICATES IN MASTER - EXPIRY & PRIVATE KEY BACKUP', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_certificates;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_certificates
AS
-- Toolkit 22_tde_encryption.sql section 22.3: CERTIFICATES IN MASTER - EXPIRY & PRIVATE KEY BACKUP
SET NOCOUNT ON;
SELECT c.name, c.subject, c.start_date, c.expiry_date,
       DATEDIFF(DAY, GETDATE(), c.expiry_date) AS days_to_expiry,
       c.pvt_key_encryption_type_desc, c.pvt_key_last_backup_date,
       c.thumbprint,
       CASE WHEN EXISTS (SELECT 1 FROM sys.dm_database_encryption_keys AS d WHERE d.encryptor_thumbprint = c.thumbprint)
            THEN ''Used by TDE'' ELSE '''' END AS tde_usage,
       CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.backupset AS b WHERE b.encryptor_thumbprint = c.thumbprint)
            THEN ''Used for backup encryption'' ELSE '''' END AS backup_usage
FROM master.sys.certificates AS c
WHERE c.name NOT LIKE N''##%''
ORDER BY c.expiry_date;
',
    @fallback_definition = NULL;
GO

/* 22.4  DATABASE MASTER KEY (master DB) & SERVICE MASTER KEY   (22_tde_encryption.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_master_keys', @section = N'22.4', @source_file = N'22_tde_encryption.sql',
    @title = N'DATABASE MASTER KEY (master DB) & SERVICE MASTER KEY', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_master_keys;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_master_keys
AS
-- Toolkit 22_tde_encryption.sql section 22.4: DATABASE MASTER KEY (master DB) & SERVICE MASTER KEY
SET NOCOUNT ON;
SELECT name, is_master_key_encrypted_by_server, is_encrypted, is_trustworthy_on
FROM sys.databases
WHERE name = N''master'';

SELECT name, algorithm_desc, key_length, create_date, modify_date
FROM master.sys.symmetric_keys
WHERE name IN (N''##MS_DatabaseMasterKey##'', N''##MS_ServiceMasterKey##'');
',
    @fallback_definition = NULL;
GO

/* 22.5  TDE PROGRESS (encryption / decryption scan)   (22_tde_encryption.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_tde_progress', @section = N'22.5', @source_file = N'22_tde_encryption.sql',
    @title = N'TDE PROGRESS (encryption / decryption scan)', @tags = N'BOX,MI,SQLDB',
    @usage = N'SELECT * FROM dbo.HC_tde_progress;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_tde_progress
AS
-- Toolkit 22_tde_encryption.sql section 22.5: TDE PROGRESS (encryption / decryption scan)
SELECT DB_NAME(database_id) AS database_name, encryption_state, percent_complete

FROM sys.dm_database_encryption_keys
WHERE encryption_state IN (2, 4, 5, 6);
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_tde_progress
AS
-- Toolkit 22_tde_encryption.sql section 22.5: TDE PROGRESS (encryption / decryption scan)
SET NOCOUNT ON;
SELECT DB_NAME(database_id) AS database_name, encryption_state, percent_complete

FROM sys.dm_database_encryption_keys
WHERE encryption_state IN (2, 4, 5, 6);
';
GO

/* 22.6  ENCRYPTED BACKUPS - WHICH CERT / ALGORITHM   (22_tde_encryption.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_encrypted_backups', @section = N'22.6', @source_file = N'22_tde_encryption.sql',
    @title = N'ENCRYPTED BACKUPS - WHICH CERT / ALGORITHM', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_encrypted_backups;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_encrypted_backups
AS
-- Toolkit 22_tde_encryption.sql section 22.6: ENCRYPTED BACKUPS - WHICH CERT / ALGORITHM
SET NOCOUNT ON;
SELECT TOP (50) bs.database_name, bs.type, bs.backup_finish_date,
       bs.key_algorithm, bs.encryptor_type, bs.encryptor_thumbprint,
       c.name AS certificate_name,
       CASE WHEN dek.database_id IS NOT NULL THEN ''TDE'' ELSE '''' END AS db_is_tde
FROM msdb.dbo.backupset AS bs
LEFT JOIN master.sys.certificates AS c ON c.thumbprint = bs.encryptor_thumbprint
LEFT JOIN sys.dm_database_encryption_keys AS dek ON dek.database_id = DB_ID(bs.database_name) AND dek.encryption_state = 3
ORDER BY bs.backup_finish_date DESC;
',
    @fallback_definition = NULL;
GO

/* 22.7  ALWAYS ON + TDE: CERT THUMBPRINTS TO COMPARE ACROSS REPLICAS   (22_tde_encryption.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_tde_cert_thumbprints', @section = N'22.7', @source_file = N'22_tde_encryption.sql',
    @title = N'ALWAYS ON + TDE: CERT THUMBPRINTS TO COMPARE ACROSS REPLICAS', @tags = N'BOX',
    @usage = N'EXEC dbo.HC_tde_cert_thumbprints;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_tde_cert_thumbprints
AS
-- Toolkit 22_tde_encryption.sql section 22.7: ALWAYS ON + TDE: CERT THUMBPRINTS TO COMPARE ACROSS REPLICAS
SET NOCOUNT ON;
SELECT @@SERVERNAME AS replica, DB_NAME(dek.database_id) AS database_name,
       dek.encryptor_thumbprint,
       c.name AS cert_on_this_replica,
       CASE WHEN c.thumbprint IS NULL THEN ''MISSING ON THIS REPLICA'' ELSE ''OK'' END AS status
FROM sys.dm_database_encryption_keys AS dek
LEFT JOIN master.sys.certificates AS c ON c.thumbprint = dek.encryptor_thumbprint
WHERE dek.database_id > 4;
',
    @fallback_definition = NULL;
GO

/* 22.8  EKM / AZURE KEY VAULT (customer-managed keys)   (22_tde_encryption.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_ekm_akv', @section = N'22.8', @source_file = N'22_tde_encryption.sql',
    @title = N'EKM / AZURE KEY VAULT (customer-managed keys)', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_ekm_akv;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_ekm_akv
AS
-- Toolkit 22_tde_encryption.sql section 22.8: EKM / AZURE KEY VAULT (customer-managed keys)
SET NOCOUNT ON;
SELECT * FROM sys.cryptographic_providers;
SELECT name, algorithm_desc, key_length, provider_type, thumbprint, cryptographic_provider_guid
FROM master.sys.asymmetric_keys;
SELECT name, credential_identity, target_type FROM sys.credentials;
',
    @fallback_definition = NULL;
GO

/* 22.9  ALWAYS ENCRYPTED INVENTORY - CURRENT DB   (22_tde_encryption.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_always_encrypted', @section = N'22.9', @source_file = N'22_tde_encryption.sql',
    @title = N'ALWAYS ENCRYPTED INVENTORY - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_always_encrypted @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_always_encrypted
    @database_name sysname = NULL
AS
-- Toolkit 22_tde_encryption.sql section 22.9: ALWAYS ENCRYPTED INVENTORY - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT OBJECT_SCHEMA_NAME(c.object_id) + N''''.'''' + OBJECT_NAME(c.object_id) AS table_name,
       c.name AS column_name, c.encryption_type_desc, c.encryption_algorithm_name,
       cek.name AS column_encryption_key
FROM sys.columns AS c
JOIN sys.column_encryption_keys AS cek ON cek.column_encryption_key_id = c.column_encryption_key_id
ORDER BY table_name, column_name;

SELECT cmk.name AS column_master_key, cmk.key_store_provider_name, cmk.key_path,
       cmk.allow_enclave_computations,
       cek.name AS column_encryption_key
FROM sys.column_master_keys AS cmk
LEFT JOIN sys.column_encryption_key_values AS v ON v.column_master_key_id = cmk.column_master_key_id
LEFT JOIN sys.column_encryption_keys AS cek ON cek.column_encryption_key_id = v.column_encryption_key_id;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 23.1  MASKED COLUMNS   (23_data_masking_rls_classification.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_masked_columns', @section = N'23.1', @source_file = N'23_data_masking_rls_classification.sql',
    @title = N'MASKED COLUMNS', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_masked_columns @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_masked_columns
    @database_name sysname = NULL
AS
-- Toolkit 23_data_masking_rls_classification.sql section 23.1: MASKED COLUMNS
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT OBJECT_SCHEMA_NAME(mc.object_id) + N''''.'''' + OBJECT_NAME(mc.object_id) AS table_name,
       mc.name AS column_name, TYPE_NAME(mc.user_type_id) AS data_type, mc.max_length,
       mc.masking_function
FROM sys.masked_columns AS mc
WHERE mc.is_masked = 1
ORDER BY table_name, column_name;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 23.2  WHO CAN SEE UNMASKED DATA   (23_data_masking_rls_classification.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_unmask_permissions', @section = N'23.2', @source_file = N'23_data_masking_rls_classification.sql',
    @title = N'WHO CAN SEE UNMASKED DATA', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_unmask_permissions @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_unmask_permissions
    @database_name sysname = NULL
AS
-- Toolkit 23_data_masking_rls_classification.sql section 23.2: WHO CAN SEE UNMASKED DATA
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT pr.name AS principal_name, pr.type_desc, pe.state_desc, pe.permission_name, pe.class_desc,
       CASE pe.class WHEN 0 THEN N''''DATABASE''''
                     WHEN 1 THEN OBJECT_SCHEMA_NAME(pe.major_id) + N''''.'''' + OBJECT_NAME(pe.major_id)
                                 + ISNULL(N''''.'''' + COL_NAME(pe.major_id, NULLIF(pe.minor_id, 0)), N'''''''')
                     WHEN 3 THEN N''''SCHEMA::'''' + SCHEMA_NAME(pe.major_id) END AS scope
FROM sys.database_permissions AS pe
JOIN sys.database_principals  AS pr ON pr.principal_id = pe.grantee_principal_id
WHERE pe.permission_name IN (N''''UNMASK'''', N''''CONTROL'''')
ORDER BY principal_name;

SELECT m.name AS db_owner_member, m.type_desc
FROM sys.database_role_members AS drm
JOIN sys.database_principals AS r ON r.principal_id = drm.role_principal_id AND r.name = N''''db_owner''''
JOIN sys.database_principals AS m ON m.principal_id = drm.member_principal_id;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 23.4  POSSIBLY SENSITIVE COLUMNS NOT MASKED (name-based finder)   (23_data_masking_rls_classification.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_unmasked_sensitive_cols', @section = N'23.4', @source_file = N'23_data_masking_rls_classification.sql',
    @title = N'POSSIBLY SENSITIVE COLUMNS NOT MASKED (name-based finder)', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_unmasked_sensitive_cols @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_unmasked_sensitive_cols
    @database_name sysname = NULL
AS
-- Toolkit 23_data_masking_rls_classification.sql section 23.4: POSSIBLY SENSITIVE COLUMNS NOT MASKED (name-based finder)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT OBJECT_SCHEMA_NAME(c.object_id) + N''''.'''' + OBJECT_NAME(c.object_id) AS table_name,
       c.name AS column_name, TYPE_NAME(c.user_type_id) AS data_type,
       CASE WHEN mc.is_masked = 1 THEN ''''MASKED'''' ELSE ''''not masked'''' END AS mask_status,
       CASE WHEN c.encryption_type IS NOT NULL THEN ''''ALWAYS ENCRYPTED'''' ELSE '''''''' END AS ae_status
FROM sys.columns AS c
JOIN sys.tables AS t ON t.object_id = c.object_id AND t.is_ms_shipped = 0
LEFT JOIN sys.masked_columns AS mc ON mc.object_id = c.object_id AND mc.column_id = c.column_id
WHERE c.name LIKE N''''%email%''''  OR c.name LIKE N''''%phone%''''   OR c.name LIKE N''''%mobile%''''
   OR c.name LIKE N''''%ssn%''''    OR c.name LIKE N''''%pan%''''     OR c.name LIKE N''''%aadhaar%''''
   OR c.name LIKE N''''%passport%'''' OR c.name LIKE N''''%card%''''  OR c.name LIKE N''''%account%''''
   OR c.name LIKE N''''%iban%''''   OR c.name LIKE N''''%salary%''''  OR c.name LIKE N''''%dob%''''
   OR c.name LIKE N''''%birth%''''  OR c.name LIKE N''''%address%'''' OR c.name LIKE N''''%password%''''
   OR c.name LIKE N''''%tax%''''    OR c.name LIKE N''''%national%''''
ORDER BY mask_status DESC, table_name, column_name;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 23.6  ROW-LEVEL SECURITY POLICIES & PREDICATES   (23_data_masking_rls_classification.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_rls_policies', @section = N'23.6', @source_file = N'23_data_masking_rls_classification.sql',
    @title = N'ROW-LEVEL SECURITY POLICIES & PREDICATES', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_rls_policies @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_rls_policies
    @database_name sysname = NULL
AS
-- Toolkit 23_data_masking_rls_classification.sql section 23.6: ROW-LEVEL SECURITY POLICIES & PREDICATES
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT sp.name AS policy_name, sp.is_enabled, sp.is_schema_bound,
       OBJECT_SCHEMA_NAME(pr.target_object_id) + N''''.'''' + OBJECT_NAME(pr.target_object_id) AS target_table,
       pr.predicate_type_desc, pr.operation_desc, pr.predicate_definition
FROM sys.security_policies AS sp
JOIN sys.security_predicates AS pr ON pr.object_id = sp.object_id
ORDER BY policy_name, target_table;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 23.7  DATA CLASSIFICATION / SENSITIVITY LABELS (2019+, Azure)   (23_data_masking_rls_classification.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_data_classification', @section = N'23.7', @source_file = N'23_data_masking_rls_classification.sql',
    @title = N'DATA CLASSIFICATION / SENSITIVITY LABELS (2019+, Azure)', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_data_classification @database_name = N''YourDB'';',
    @min_version = 15,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_data_classification
    @database_name sysname = NULL
AS
-- Toolkit 23_data_masking_rls_classification.sql section 23.7: DATA CLASSIFICATION / SENSITIVITY LABELS (2019+, Azure)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT OBJECT_SCHEMA_NAME(sc.major_id) + N''''.'''' + OBJECT_NAME(sc.major_id) AS table_name,
       COL_NAME(sc.major_id, sc.minor_id) AS column_name,
       sc.label, sc.information_type, sc.rank_desc
FROM sys.sensitivity_classifications AS sc
ORDER BY sc.rank DESC, table_name;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 23.8  PROTECTION SUMMARY PER TABLE   (23_data_masking_rls_classification.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_protection_summary', @section = N'23.8', @source_file = N'23_data_masking_rls_classification.sql',
    @title = N'PROTECTION SUMMARY PER TABLE', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_protection_summary @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_protection_summary
    @database_name sysname = NULL
AS
-- Toolkit 23_data_masking_rls_classification.sql section 23.8: PROTECTION SUMMARY PER TABLE
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT OBJECT_SCHEMA_NAME(t.object_id) + N''''.'''' + t.name AS table_name,
       (SELECT COUNT(*) FROM sys.masked_columns mc WHERE mc.object_id = t.object_id AND mc.is_masked = 1)   AS masked_cols,
       (SELECT COUNT(*) FROM sys.columns c WHERE c.object_id = t.object_id AND c.encryption_type IS NOT NULL) AS always_encrypted_cols,
       (SELECT COUNT(*) FROM sys.sensitivity_classifications s WHERE s.major_id = t.object_id)             AS classified_cols,
       CASE WHEN EXISTS (SELECT 1 FROM sys.security_predicates p WHERE p.target_object_id = t.object_id)
            THEN ''''Yes'''' ELSE ''''No'''' END AS has_rls
FROM sys.tables AS t
WHERE t.is_ms_shipped = 0
ORDER BY masked_cols + always_encrypted_cols + classified_cols DESC, table_name;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 24.1  MISSING INDEXES CONSOLIDATED PER TABLE - CURRENT DB   (24_index_tuning.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_missing_indexes_per_table', @section = N'24.1', @source_file = N'24_index_tuning.sql',
    @title = N'MISSING INDEXES CONSOLIDATED PER TABLE - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_missing_indexes_per_table @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_missing_indexes_per_table
    @database_name sysname = NULL
AS
-- Toolkit 24_index_tuning.sql section 24.1: MISSING INDEXES CONSOLIDATED PER TABLE - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT
    mid.statement AS table_name,
    COUNT(*) OVER (PARTITION BY mid.object_id)                                 AS suggestions_on_table,
    mid.equality_columns, mid.inequality_columns, mid.included_columns,
    migs.user_seeks + migs.user_scans                                          AS uses,
    CAST(migs.avg_user_impact AS decimal(5,1))                                 AS avg_impact_pct,
    CAST(migs.avg_total_user_cost * migs.avg_user_impact / 100.0
         * (migs.user_seeks + migs.user_scans) AS decimal(18,0))               AS score,
    (SELECT COUNT(*) FROM sys.indexes i WHERE i.object_id = mid.object_id AND i.index_id > 0) AS existing_indexes
FROM sys.dm_db_missing_index_details     AS mid
JOIN sys.dm_db_missing_index_groups      AS mig  ON mig.index_handle = mid.index_handle
JOIN sys.dm_db_missing_index_group_stats AS migs ON migs.group_handle = mig.index_group_handle
WHERE mid.database_id = DB_ID()
ORDER BY SUM(migs.avg_total_user_cost * migs.avg_user_impact * (migs.user_seeks + migs.user_scans))
             OVER (PARTITION BY mid.object_id) DESC,
         mid.statement, mid.equality_columns;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 24.2  EXISTING INDEX COLUMN MAP FOR A TABLE (compare with 24.1)   (24_index_tuning.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_index_column_map', @section = N'24.2', @source_file = N'24_index_tuning.sql',
    @title = N'EXISTING INDEX COLUMN MAP FOR A TABLE (compare with 24.1)', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_index_column_map @database_name = N''YourDB'', @table = N''dbo.YourTable'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_index_column_map
    @database_name sysname = NULL,
    @table sysname = N''dbo.YourTable''
AS
-- Toolkit 24_index_tuning.sql section 24.2: EXISTING INDEX COLUMN MAP FOR A TABLE (compare with 24.1)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT i.name AS index_name, i.type_desc, ic.key_ordinal, c.name AS column_name,
       CASE WHEN ic.is_included_column = 1 THEN ''''INCLUDE'''' ELSE ''''KEY'''' END AS role,
       ic.is_descending_key, TYPE_NAME(c.user_type_id) AS data_type, c.max_length
FROM sys.indexes AS i
JOIN sys.index_columns AS ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.object_id = OBJECT_ID(@table)
ORDER BY i.index_id, ic.is_included_column, ic.key_ordinal, c.name;'';
EXEC @hc_exec @hc_sql, N''@table sysname'', @table = @table;
',
    @fallback_definition = NULL;
GO

/* 24.3  KEY / RID LOOKUPS IN CACHED PLANS (covering index candidates)   (24_index_tuning.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_key_lookups', @section = N'24.3', @source_file = N'24_index_tuning.sql',
    @title = N'KEY / RID LOOKUPS IN CACHED PLANS (covering index candidates)', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_key_lookups;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_key_lookups
AS
-- Toolkit 24_index_tuning.sql section 24.3: KEY / RID LOOKUPS IN CACHED PLANS (covering index candidates)
SET NOCOUNT ON;
WITH XMLNAMESPACES (DEFAULT ''http://schemas.microsoft.com/sqlserver/2004/07/showplan''),
lookups AS (
    SELECT TOP (500) qs.plan_handle, qs.execution_count, qs.total_logical_reads, qs.total_worker_time,
           qp.query_plan, t.text
    FROM sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
    WHERE qp.query_plan.exist(''//IndexScan[@Lookup="1"]'') = 1
    ORDER BY qs.total_logical_reads DESC
)
SELECT TOP (50)
    l.execution_count, l.total_logical_reads, l.total_worker_time / 1000 AS total_cpu_ms,
    n.op.value(''(IndexScan/Object/@Database)[1]'', ''sysname'') + N''.''
      + n.op.value(''(IndexScan/Object/@Schema)[1]'', ''sysname'') + N''.''
      + n.op.value(''(IndexScan/Object/@Table)[1]'', ''sysname'')       AS lookup_table,
    n.op.value(''(IndexScan/Object/@Index)[1]'', ''sysname'')           AS via_index,
    n.op.query(''for $c in OutputList/ColumnReference return string($c/@Column)'').value(''.'', ''nvarchar(max)'') AS columns_fetched_by_lookup,
    n.op.value(''@EstimateRows'', ''float'') * n.op.value(''@EstimateRebinds'', ''float'') AS est_lookup_rows,
    l.text
FROM lookups AS l
CROSS APPLY l.query_plan.nodes(''//RelOp[IndexScan[@Lookup="1"]]'') AS n(op)
ORDER BY l.total_logical_reads DESC;
',
    @fallback_definition = NULL;
GO

/* 24.4  TABLE / CLUSTERED INDEX SCANS IN CACHED PLANS   (24_index_tuning.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_scans_in_cache', @section = N'24.4', @source_file = N'24_index_tuning.sql',
    @title = N'TABLE / CLUSTERED INDEX SCANS IN CACHED PLANS', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_scans_in_cache;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_scans_in_cache
AS
-- Toolkit 24_index_tuning.sql section 24.4: TABLE / CLUSTERED INDEX SCANS IN CACHED PLANS
SET NOCOUNT ON;
WITH XMLNAMESPACES (DEFAULT ''http://schemas.microsoft.com/sqlserver/2004/07/showplan'')
SELECT TOP (50)
    qs.execution_count, qs.total_logical_reads / qs.execution_count AS avg_reads,
    n.op.value(''@PhysicalOp'', ''nvarchar(60)'')                           AS operator,
    n.op.value(''(.//Object/@Table)[1]'', ''sysname'')                      AS table_name,
    n.op.value(''(.//Object/@Index)[1]'', ''sysname'')                      AS index_name,
    n.op.value(''@EstimatedRowsRead'', ''float'')                           AS est_rows_read,
    n.op.value(''@EstimateRows'', ''float'')                                AS est_rows_out,
    n.op.exist(''.//Predicate'')                                          AS has_residual_predicate,
    t.text
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
CROSS APPLY qp.query_plan.nodes(''//RelOp[@PhysicalOp="Table Scan" or @PhysicalOp="Clustered Index Scan" or @PhysicalOp="Index Scan"]'') AS n(op)
WHERE qs.total_logical_reads / qs.execution_count > 10000
ORDER BY qs.total_logical_reads DESC;
',
    @fallback_definition = NULL;
GO

/* 24.5  FOREIGN KEYS WITHOUT A SUPPORTING INDEX - CURRENT DB   (24_index_tuning.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_fk_without_index', @section = N'24.5', @source_file = N'24_index_tuning.sql',
    @title = N'FOREIGN KEYS WITHOUT A SUPPORTING INDEX - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_fk_without_index @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_fk_without_index
    @database_name sysname = NULL
AS
-- Toolkit 24_index_tuning.sql section 24.5: FOREIGN KEYS WITHOUT A SUPPORTING INDEX - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''WITH fk_cols AS (
    SELECT fk.object_id AS fk_id, fk.name AS fk_name, fk.parent_object_id,
           cols = STUFF((SELECT N'''','''' + QUOTENAME(c.name)
                         FROM sys.foreign_key_columns AS fkc
                         JOIN sys.columns AS c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
                         WHERE fkc.constraint_object_id = fk.object_id
                         ORDER BY fkc.constraint_column_id
                         FOR XML PATH(''''''''), TYPE).value(''''.'''', ''''nvarchar(max)''''), 1, 1, N'''''''')
    FROM sys.foreign_keys AS fk
), idx_cols AS (
    SELECT i.object_id, i.index_id,
           cols = STUFF((SELECT N'''','''' + QUOTENAME(c.name)
                         FROM sys.index_columns AS ic
                         JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                         WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
                         ORDER BY ic.key_ordinal
                         FOR XML PATH(''''''''), TYPE).value(''''.'''', ''''nvarchar(max)''''), 1, 1, N'''''''')
    FROM sys.indexes AS i
    WHERE i.index_id > 0 AND i.is_disabled = 0
)
SELECT OBJECT_SCHEMA_NAME(f.parent_object_id) + N''''.'''' + OBJECT_NAME(f.parent_object_id) AS child_table,
       f.fk_name, f.cols AS fk_columns,
       N''''CREATE INDEX '''' + QUOTENAME(N''''IX_'''' + OBJECT_NAME(f.parent_object_id) + N''''_'''' + REPLACE(REPLACE(REPLACE(f.cols, N''''['''', N''''''''), N'''']'''', N''''''''), N'''','''', N''''_''''))
         + N'''' ON '''' + QUOTENAME(OBJECT_SCHEMA_NAME(f.parent_object_id)) + N''''.'''' + QUOTENAME(OBJECT_NAME(f.parent_object_id))
         + N'''' ('''' + f.cols + N'''');'''' AS suggested_index
FROM fk_cols AS f
WHERE NOT EXISTS (SELECT 1 FROM idx_cols AS ix
                  WHERE ix.object_id = f.parent_object_id
                    AND (ix.cols = f.cols OR ix.cols LIKE f.cols + N'''',%''''))
ORDER BY child_table;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 24.6  CLUSTERED INDEX KEY REVIEW - CURRENT DB   (24_index_tuning.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_clustered_key_review', @section = N'24.6', @source_file = N'24_index_tuning.sql',
    @title = N'CLUSTERED INDEX KEY REVIEW - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_clustered_key_review @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_clustered_key_review
    @database_name sysname = NULL
AS
-- Toolkit 24_index_tuning.sql section 24.6: CLUSTERED INDEX KEY REVIEW - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT OBJECT_SCHEMA_NAME(i.object_id) + N''''.'''' + OBJECT_NAME(i.object_id) AS table_name,
       i.name AS clustered_index, i.is_unique,
       COUNT(*)                         AS key_columns,
       SUM(c.max_length)                AS key_bytes,
       MAX(CASE WHEN TYPE_NAME(c.user_type_id) = N''''uniqueidentifier'''' THEN 1 ELSE 0 END) AS has_guid_key,
       MAX(CAST(c.is_nullable AS int))  AS has_nullable_key,
       CASE WHEN SUM(c.max_length) > 16 THEN ''''WIDE KEY; '''' ELSE '''''''' END
     + CASE WHEN MAX(CASE WHEN TYPE_NAME(c.user_type_id) = N''''uniqueidentifier'''' THEN 1 ELSE 0 END) = 1 THEN ''''GUID KEY (use NEWSEQUENTIALID or other key); '''' ELSE '''''''' END
     + CASE WHEN i.is_unique = 0 THEN ''''NOT UNIQUE; '''' ELSE '''''''' END AS findings
FROM sys.indexes AS i
JOIN sys.index_columns AS ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.type = 1 AND OBJECTPROPERTY(i.object_id, ''''IsUserTable'''') = 1
GROUP BY i.object_id, i.name, i.is_unique
HAVING SUM(c.max_length) > 16 OR i.is_unique = 0
    OR MAX(CASE WHEN TYPE_NAME(c.user_type_id) = N''''uniqueidentifier'''' THEN 1 ELSE 0 END) = 1
ORDER BY key_bytes DESC;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 24.7  OVER-INDEXED & WIDE INDEXES - CURRENT DB   (24_index_tuning.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_over_indexed_tables', @section = N'24.7', @source_file = N'24_index_tuning.sql',
    @title = N'OVER-INDEXED & WIDE INDEXES - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_over_indexed_tables @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_over_indexed_tables
    @database_name sysname = NULL
AS
-- Toolkit 24_index_tuning.sql section 24.7: OVER-INDEXED & WIDE INDEXES - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT OBJECT_SCHEMA_NAME(i.object_id) + N''''.'''' + OBJECT_NAME(i.object_id) AS table_name,
       COUNT(*) AS nc_index_count,
       SUM(ISNULL(us.user_updates, 0)) AS total_index_writes,
       SUM(ISNULL(us.user_seeks + us.user_scans + us.user_lookups, 0)) AS total_index_reads
FROM sys.indexes AS i
LEFT JOIN sys.dm_db_index_usage_stats AS us ON us.object_id = i.object_id AND us.index_id = i.index_id AND us.database_id = DB_ID()
WHERE i.type = 2 AND OBJECTPROPERTY(i.object_id, ''''IsUserTable'''') = 1
GROUP BY i.object_id
HAVING COUNT(*) >= 8
ORDER BY nc_index_count DESC;

SELECT OBJECT_SCHEMA_NAME(i.object_id) + N''''.'''' + OBJECT_NAME(i.object_id) AS table_name, i.name AS index_name,
       SUM(CASE WHEN ic.is_included_column = 0 THEN 1 ELSE 0 END) AS key_cols,
       SUM(CASE WHEN ic.is_included_column = 1 THEN 1 ELSE 0 END) AS included_cols,
       SUM(CASE WHEN ic.is_included_column = 0 THEN c.max_length ELSE 0 END) AS key_bytes
FROM sys.indexes AS i
JOIN sys.index_columns AS ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.type = 2 AND OBJECTPROPERTY(i.object_id, ''''IsUserTable'''') = 1
GROUP BY i.object_id, i.name
HAVING SUM(CASE WHEN ic.is_included_column = 0 THEN 1 ELSE 0 END) > 5
    OR SUM(CASE WHEN ic.is_included_column = 1 THEN 1 ELSE 0 END) > 10
ORDER BY key_cols + included_cols DESC;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 24.8  PAGE SPLITS (instance counter + per-index "bad" splits)   (24_index_tuning.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_page_splits', @section = N'24.8', @source_file = N'24_index_tuning.sql',
    @title = N'PAGE SPLITS (instance counter + per-index "bad" splits)', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_page_splits @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_page_splits
    @database_name sysname = NULL
AS
-- Toolkit 24_index_tuning.sql section 24.8: PAGE SPLITS (instance counter + per-index "bad" splits)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT RTRIM(counter_name) AS counter_name, cntr_value
FROM sys.dm_os_performance_counters
WHERE counter_name IN (N''''Page Splits/sec'''', N''''Batch Requests/sec'''');

SELECT TOP (25)
    OBJECT_SCHEMA_NAME(os.object_id) + N''''.'''' + OBJECT_NAME(os.object_id) AS table_name,
    i.name AS index_name, i.fill_factor,
    os.leaf_allocation_count AS leaf_page_allocations,
    os.nonleaf_allocation_count,
    os.leaf_insert_count,
    CAST(100.0 * os.leaf_allocation_count / NULLIF(os.leaf_insert_count, 0) AS decimal(10,2)) AS alloc_per_100_inserts
FROM sys.dm_db_index_operational_stats(DB_ID(), NULL, NULL, NULL) AS os
JOIN sys.indexes AS i ON i.object_id = os.object_id AND i.index_id = os.index_id
WHERE OBJECTPROPERTY(os.object_id, ''''IsUserTable'''') = 1 AND os.leaf_allocation_count > 0
ORDER BY os.leaf_allocation_count DESC;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 24.9  NON-DEFAULT FILL FACTORS - CURRENT DB   (24_index_tuning.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_fill_factors', @section = N'24.9', @source_file = N'24_index_tuning.sql',
    @title = N'NON-DEFAULT FILL FACTORS - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_fill_factors @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_fill_factors
    @database_name sysname = NULL
AS
-- Toolkit 24_index_tuning.sql section 24.9: NON-DEFAULT FILL FACTORS - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT OBJECT_SCHEMA_NAME(object_id) + N''''.'''' + OBJECT_NAME(object_id) AS table_name,
       name AS index_name, type_desc, fill_factor, is_padded
FROM sys.indexes
WHERE fill_factor NOT IN (0, 100) AND OBJECTPROPERTY(object_id, ''''IsUserTable'''') = 1
ORDER BY fill_factor;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 24.10  COMPRESSION CANDIDATES - LARGE UNCOMPRESSED INDEXES   (24_index_tuning.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_compression_candidates', @section = N'24.10', @source_file = N'24_index_tuning.sql',
    @title = N'COMPRESSION CANDIDATES - LARGE UNCOMPRESSED INDEXES', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_compression_candidates @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_compression_candidates
    @database_name sysname = NULL
AS
-- Toolkit 24_index_tuning.sql section 24.10: COMPRESSION CANDIDATES - LARGE UNCOMPRESSED INDEXES
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT TOP (25)
    OBJECT_SCHEMA_NAME(p.object_id) + N''''.'''' + OBJECT_NAME(p.object_id) AS table_name,
    i.name AS index_name, i.index_id, p.data_compression_desc,
    SUM(p.rows) AS rows,
    CAST(SUM(ps.used_page_count) * 8 / 1024.0 AS decimal(18,2)) AS used_mb,
    N''''EXEC sys.sp_estimate_data_compression_savings @schema_name = N'''''''''''' + OBJECT_SCHEMA_NAME(p.object_id)
      + N'''''''''''', @object_name = N'''''''''''' + OBJECT_NAME(p.object_id) + N'''''''''''', @index_id = ''''
      + CAST(i.index_id AS nvarchar(10)) + N'''', @partition_number = NULL, @data_compression = N''''''''PAGE'''''''';'''' AS estimate_cmd
FROM sys.partitions AS p
JOIN sys.indexes AS i ON i.object_id = p.object_id AND i.index_id = p.index_id
JOIN sys.dm_db_partition_stats AS ps ON ps.partition_id = p.partition_id
WHERE p.data_compression = 0 AND OBJECTPROPERTY(p.object_id, ''''IsUserTable'''') = 1
GROUP BY p.object_id, i.name, i.index_id, p.data_compression_desc
ORDER BY used_mb DESC;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 24.11  PARTITIONED TABLES - BOUNDARIES & ROWS PER PARTITION   (24_index_tuning.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_partitions', @section = N'24.11', @source_file = N'24_index_tuning.sql',
    @title = N'PARTITIONED TABLES - BOUNDARIES & ROWS PER PARTITION', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_partitions @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_partitions
    @database_name sysname = NULL
AS
-- Toolkit 24_index_tuning.sql section 24.11: PARTITIONED TABLES - BOUNDARIES & ROWS PER PARTITION
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT OBJECT_SCHEMA_NAME(p.object_id) + N''''.'''' + OBJECT_NAME(p.object_id) AS table_name,
       i.name AS index_name, ps.name AS partition_scheme, pf.name AS partition_function,
       p.partition_number, prv.value AS boundary_value, pf.boundary_value_on_right,
       fg.name AS filegroup, p.rows, p.data_compression_desc
FROM sys.partitions AS p
JOIN sys.indexes AS i ON i.object_id = p.object_id AND i.index_id = p.index_id
JOIN sys.partition_schemes AS ps ON ps.data_space_id = i.data_space_id
JOIN sys.partition_functions AS pf ON pf.function_id = ps.function_id
LEFT JOIN sys.partition_range_values AS prv ON prv.function_id = pf.function_id
      AND prv.boundary_id = p.partition_number - CASE WHEN pf.boundary_value_on_right = 1 THEN 1 ELSE 0 END
JOIN sys.destination_data_spaces AS dds ON dds.partition_scheme_id = ps.data_space_id AND dds.destination_id = p.partition_number
JOIN sys.filegroups AS fg ON fg.data_space_id = dds.data_space_id
WHERE i.index_id IN (0, 1)
ORDER BY table_name, p.partition_number;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 24.12  DISABLED & HYPOTHETICAL (leftover DTA) INDEXES   (24_index_tuning.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_disabled_hypothetical_indexes', @section = N'24.12', @source_file = N'24_index_tuning.sql',
    @title = N'DISABLED & HYPOTHETICAL (leftover DTA) INDEXES', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_disabled_hypothetical_indexes @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_disabled_hypothetical_indexes
    @database_name sysname = NULL
AS
-- Toolkit 24_index_tuning.sql section 24.12: DISABLED & HYPOTHETICAL (leftover DTA) INDEXES
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT OBJECT_SCHEMA_NAME(object_id) + N''''.'''' + OBJECT_NAME(object_id) AS table_name, name AS index_name,
       is_disabled, is_hypothetical,
       CASE WHEN is_hypothetical = 1 THEN N''''DROP INDEX '''' + QUOTENAME(name) + N'''' ON ''''
              + QUOTENAME(OBJECT_SCHEMA_NAME(object_id)) + N''''.'''' + QUOTENAME(OBJECT_NAME(object_id)) + N'''';''''
            ELSE N''''ALTER INDEX '''' + QUOTENAME(name) + N'''' ON ''''
              + QUOTENAME(OBJECT_SCHEMA_NAME(object_id)) + N''''.'''' + QUOTENAME(OBJECT_NAME(object_id)) + N'''' REBUILD;  -- or DROP'''' END AS action
FROM sys.indexes
WHERE (is_disabled = 1 OR is_hypothetical = 1) AND OBJECTPROPERTY(object_id, ''''IsMSShipped'''') = 0;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 25.1  SINGLE ALERT QUERY - RETURNS ROWS ONLY WHEN SOMETHING IS WRONG   (25_alwayson_advanced.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_ag_alert', @section = N'25.1', @source_file = N'25_alwayson_advanced.sql',
    @title = N'SINGLE ALERT QUERY - RETURNS ROWS ONLY WHEN SOMETHING IS WRONG', @tags = N'BOX',
    @usage = N'EXEC dbo.HC_ag_alert @max_send_queue_kb = 1048576, @max_redo_queue_kb = 1048576, @max_lag_s = 300;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_ag_alert
    @max_send_queue_kb bigint = 1048576,
    @max_redo_queue_kb bigint = 1048576,
    @max_lag_s int = 300
AS
-- Toolkit 25_alwayson_advanced.sql section 25.1: SINGLE ALERT QUERY - RETURNS ROWS ONLY WHEN SOMETHING IS WRONG
SET NOCOUNT ON;
SELECT ''AG'' AS level, ag.name AS ag_name, NULL AS replica, NULL AS database_name,
       ''AG health: '' + ags.synchronization_health_desc AS issue
FROM sys.dm_hadr_availability_group_states AS ags
JOIN sys.availability_groups AS ag ON ag.group_id = ags.group_id
WHERE ags.synchronization_health_desc <> ''HEALTHY''
UNION ALL
SELECT ''REPLICA'', ag.name, ar.replica_server_name, NULL,
       ''Replica '' + ISNULL(ars.connected_state_desc, ''UNKNOWN'') + '' / '' + ISNULL(ars.synchronization_health_desc, ''UNKNOWN'')
       + ISNULL('' / last error: '' + ars.last_connect_error_description, '''')
FROM sys.availability_replicas AS ar
JOIN sys.availability_groups AS ag ON ag.group_id = ar.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states AS ars ON ars.replica_id = ar.replica_id
WHERE ars.connected_state_desc <> ''CONNECTED'' OR ars.synchronization_health_desc <> ''HEALTHY''
UNION ALL
SELECT ''DATABASE'', ag.name, ar.replica_server_name, DB_NAME(drs.database_id),
       CASE WHEN drs.is_suspended = 1 THEN ''SUSPENDED ('' + drs.suspend_reason_desc + '')''
            WHEN drs.synchronization_health_desc <> ''HEALTHY'' THEN ''Health: '' + drs.synchronization_health_desc + '' / '' + drs.synchronization_state_desc
            WHEN drs.log_send_queue_size > @max_send_queue_kb THEN ''Log send queue '' + CAST(drs.log_send_queue_size / 1024 AS varchar(20)) + '' MB''
            WHEN drs.redo_queue_size > @max_redo_queue_kb THEN ''Redo queue '' + CAST(drs.redo_queue_size / 1024 AS varchar(20)) + '' MB''
            ELSE ''Secondary lag '' + CAST(drs.secondary_lag_seconds AS varchar(20)) + '' s'' END
FROM sys.dm_hadr_database_replica_states AS drs
JOIN sys.availability_replicas AS ar ON ar.replica_id = drs.replica_id
JOIN sys.availability_groups AS ag ON ag.group_id = drs.group_id
WHERE drs.is_suspended = 1
   OR drs.synchronization_health_desc <> ''HEALTHY''
   OR drs.log_send_queue_size > @max_send_queue_kb
   OR drs.redo_queue_size > @max_redo_queue_kb
   OR drs.secondary_lag_seconds > @max_lag_s;
',
    @fallback_definition = NULL;
GO

/* 25.2  "NOT SYNCHRONIZING" TROUBLESHOOTING CHECKLIST   (25_alwayson_advanced.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_ag_not_syncing_checklist', @section = N'25.2', @source_file = N'25_alwayson_advanced.sql',
    @title = N'"NOT SYNCHRONIZING" TROUBLESHOOTING CHECKLIST', @tags = N'BOX',
    @usage = N'EXEC dbo.HC_ag_not_syncing_checklist;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_ag_not_syncing_checklist
AS
-- Toolkit 25_alwayson_advanced.sql section 25.2: "NOT SYNCHRONIZING" TROUBLESHOOTING CHECKLIST
SET NOCOUNT ON;
SELECT DB_NAME(database_id) AS database_name, synchronization_state_desc, is_suspended,
       suspend_reason_desc, database_state_desc, last_received_time, last_redone_time
FROM sys.dm_hadr_database_replica_states
WHERE is_local = 1;

SELECT name, state_desc FROM sys.database_mirroring_endpoints;

SELECT ar.replica_server_name, ars.connected_state_desc,
       ars.last_connect_error_number, ars.last_connect_error_description, ars.last_connect_error_timestamp
FROM sys.dm_hadr_availability_replica_states AS ars
JOIN sys.availability_replicas AS ar ON ar.replica_id = ars.replica_id;

EXEC sys.xp_readerrorlog 0, 1, N''Always On'';
',
    @fallback_definition = NULL;
GO

/* 25.3  READABLE SECONDARY: REDO BLOCKED BY REPORTING QUERIES   (25_alwayson_advanced.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_ag_redo_blocked', @section = N'25.3', @source_file = N'25_alwayson_advanced.sql',
    @title = N'READABLE SECONDARY: REDO BLOCKED BY REPORTING QUERIES', @tags = N'BOX',
    @usage = N'EXEC dbo.HC_ag_redo_blocked;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_ag_redo_blocked
AS
-- Toolkit 25_alwayson_advanced.sql section 25.3: READABLE SECONDARY: REDO BLOCKED BY REPORTING QUERIES
SET NOCOUNT ON;
SELECT r.session_id, r.command, DB_NAME(r.database_id) AS database_name,
       r.wait_type, r.wait_time, r.blocking_session_id,
       bs.login_name AS blocker_login, bs.program_name AS blocker_program,
       bib.event_info AS blocker_sql
FROM sys.dm_exec_requests AS r
LEFT JOIN sys.dm_exec_sessions AS bs ON bs.session_id = r.blocking_session_id
OUTER APPLY sys.dm_exec_input_buffer(r.blocking_session_id, NULL) AS bib
WHERE r.command IN (N''DB STARTUP'', N''PARALLEL REDO TASK'', N''PARALLEL REDO HELP TASK'')
ORDER BY r.wait_time DESC;

SELECT RTRIM(instance_name) AS database_name, cntr_value AS redo_blocked
FROM sys.dm_os_performance_counters
WHERE object_name LIKE N''%Database Replica%'' AND counter_name = N''Redo blocked/sec'' AND cntr_value > 0;
',
    @fallback_definition = NULL;
GO

/* 25.4  READABLE SECONDARY: VERSION STORE / GHOST CLEANUP IMPACT   (25_alwayson_advanced.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_ag_secondary_version_store', @section = N'25.4', @source_file = N'25_alwayson_advanced.sql',
    @title = N'READABLE SECONDARY: VERSION STORE / GHOST CLEANUP IMPACT', @tags = N'BOX',
    @usage = N'EXEC dbo.HC_ag_secondary_version_store;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_ag_secondary_version_store
AS
-- Toolkit 25_alwayson_advanced.sql section 25.4: READABLE SECONDARY: VERSION STORE / GHOST CLEANUP IMPACT
SET NOCOUNT ON;
SELECT TOP (10) ast.session_id, ast.elapsed_time_seconds, s.login_name, s.program_name,
       ib.event_info AS sql_text
FROM sys.dm_tran_active_snapshot_database_transactions AS ast
JOIN sys.dm_exec_sessions AS s ON s.session_id = ast.session_id
OUTER APPLY sys.dm_exec_input_buffer(ast.session_id, NULL) AS ib
ORDER BY ast.elapsed_time_seconds DESC;

SELECT DB_NAME(database_id) AS database_name, reserved_page_count * 8 / 1024 AS version_store_mb
FROM sys.dm_tran_version_store_space_usage
ORDER BY reserved_page_count DESC;
',
    @fallback_definition = NULL;
GO

/* 25.5  COMMIT LATENCY ON THE PRIMARY (sync replicas)   (25_alwayson_advanced.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_ag_commit_latency', @section = N'25.5', @source_file = N'25_alwayson_advanced.sql',
    @title = N'COMMIT LATENCY ON THE PRIMARY (sync replicas)', @tags = N'BOX',
    @usage = N'SELECT * FROM dbo.HC_ag_commit_latency;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_ag_commit_latency
AS
-- Toolkit 25_alwayson_advanced.sql section 25.5: COMMIT LATENCY ON THE PRIMARY (sync replicas)
SELECT RTRIM(instance_name) AS database_name,
       MAX(CASE WHEN counter_name = N''Transaction Delay'' THEN cntr_value END)                AS transaction_delay_ms_total,
       MAX(CASE WHEN counter_name = N''Mirrored Write Transactions/sec'' THEN cntr_value END)  AS mirrored_write_tx_total
FROM sys.dm_os_performance_counters
WHERE object_name LIKE N''%Database Replica%''
  AND counter_name IN (N''Transaction Delay'', N''Mirrored Write Transactions/sec'')
GROUP BY instance_name;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_ag_commit_latency
AS
-- Toolkit 25_alwayson_advanced.sql section 25.5: COMMIT LATENCY ON THE PRIMARY (sync replicas)
SET NOCOUNT ON;
SELECT RTRIM(instance_name) AS database_name,
       MAX(CASE WHEN counter_name = N''Transaction Delay'' THEN cntr_value END)                AS transaction_delay_ms_total,
       MAX(CASE WHEN counter_name = N''Mirrored Write Transactions/sec'' THEN cntr_value END)  AS mirrored_write_tx_total
FROM sys.dm_os_performance_counters
WHERE object_name LIKE N''%Database Replica%''
  AND counter_name IN (N''Transaction Delay'', N''Mirrored Write Transactions/sec'')
GROUP BY instance_name;
';
GO

/* 25.6  DISTRIBUTED AVAILABILITY GROUPS   (25_alwayson_advanced.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_distributed_ags', @section = N'25.6', @source_file = N'25_alwayson_advanced.sql',
    @title = N'DISTRIBUTED AVAILABILITY GROUPS', @tags = N'BOX',
    @usage = N'EXEC dbo.HC_distributed_ags;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_distributed_ags
AS
-- Toolkit 25_alwayson_advanced.sql section 25.6: DISTRIBUTED AVAILABILITY GROUPS
SET NOCOUNT ON;
SELECT ag.name AS distributed_ag, ar.replica_server_name AS member_ag,
       ar.endpoint_url AS listener_url, ar.availability_mode_desc, ar.failover_mode_desc,
       ar.seeding_mode_desc, ars.role_desc, ars.connected_state_desc, ars.synchronization_health_desc
FROM sys.availability_groups AS ag
JOIN sys.availability_replicas AS ar ON ar.group_id = ag.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states AS ars ON ars.replica_id = ar.replica_id
WHERE ag.is_distributed = 1;

SELECT ag.name AS distributed_ag, DB_NAME(drs.database_id) AS database_name,
       drs.synchronization_state_desc, drs.log_send_queue_size, drs.redo_queue_size,
       drs.last_hardened_lsn, drs.last_commit_time
FROM sys.dm_hadr_database_replica_states AS drs
JOIN sys.availability_groups AS ag ON ag.group_id = drs.group_id
WHERE ag.is_distributed = 1;
',
    @fallback_definition = NULL;
GO

/* 25.7  CONTAINED AVAILABILITY GROUPS (2022+)   (25_alwayson_advanced.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_contained_ags_detail', @section = N'25.7', @source_file = N'25_alwayson_advanced.sql',
    @title = N'CONTAINED AVAILABILITY GROUPS (2022+)', @tags = N'BOX',
    @usage = N'SELECT * FROM dbo.HC_contained_ags_detail;',
    @min_version = 16,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_contained_ags_detail
AS
-- Toolkit 25_alwayson_advanced.sql section 25.7: CONTAINED AVAILABILITY GROUPS (2022+)
SELECT name, is_contained, cluster_type_desc FROM sys.availability_groups WHERE is_contained = 1;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_contained_ags_detail
AS
-- Toolkit 25_alwayson_advanced.sql section 25.7: CONTAINED AVAILABILITY GROUPS (2022+)
SET NOCOUNT ON;
SELECT name, is_contained, cluster_type_desc FROM sys.availability_groups WHERE is_contained = 1;
';
GO

/* 25.8  LOGIN DRIFT BETWEEN REPLICAS   (25_alwayson_advanced.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_ag_login_drift', @section = N'25.8', @source_file = N'25_alwayson_advanced.sql',
    @title = N'LOGIN DRIFT BETWEEN REPLICAS', @tags = N'BOX',
    @usage = N'SELECT * FROM dbo.HC_ag_login_drift ORDER BY name;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY name',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_ag_login_drift
AS
-- Toolkit 25_alwayson_advanced.sql section 25.8: LOGIN DRIFT BETWEEN REPLICAS
SELECT @@SERVERNAME AS replica, name, type_desc, sid, is_disabled, default_database_name,
       CONVERT(varchar(100), LOGINPROPERTY(name, ''PasswordHash''), 1) AS password_hash
FROM sys.server_principals
WHERE type IN (''S'', ''U'', ''G'') AND name NOT LIKE N''##%'' AND name NOT LIKE N''NT %'';
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_ag_login_drift
AS
-- Toolkit 25_alwayson_advanced.sql section 25.8: LOGIN DRIFT BETWEEN REPLICAS
SET NOCOUNT ON;
SELECT @@SERVERNAME AS replica, name, type_desc, sid, is_disabled, default_database_name,
       CONVERT(varchar(100), LOGINPROPERTY(name, ''PasswordHash''), 1) AS password_hash
FROM sys.server_principals
WHERE type IN (''S'', ''U'', ''G'') AND name NOT LIKE N''##%'' AND name NOT LIKE N''NT %''
ORDER BY name;
';
GO

/* 25.9  JOB DRIFT BETWEEN REPLICAS + "AM I PRIMARY" JOB GUARD   (25_alwayson_advanced.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_ag_job_drift', @section = N'25.9', @source_file = N'25_alwayson_advanced.sql',
    @title = N'JOB DRIFT BETWEEN REPLICAS + "AM I PRIMARY" JOB GUARD', @tags = N'BOX',
    @usage = N'SELECT * FROM dbo.HC_ag_job_drift ORDER BY name;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY j.name',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_ag_job_drift
AS
-- Toolkit 25_alwayson_advanced.sql section 25.9: JOB DRIFT BETWEEN REPLICAS + "AM I PRIMARY" JOB GUARD
SELECT @@SERVERNAME AS replica, j.name, j.enabled, j.date_modified
FROM msdb.dbo.sysjobs AS j;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_ag_job_drift
AS
-- Toolkit 25_alwayson_advanced.sql section 25.9: JOB DRIFT BETWEEN REPLICAS + "AM I PRIMARY" JOB GUARD
SET NOCOUNT ON;
SELECT @@SERVERNAME AS replica, j.name, j.enabled, j.date_modified
FROM msdb.dbo.sysjobs AS j
ORDER BY j.name;
';
GO

/* 25.10  BACKUP PREFERENCE CHECK PER DATABASE (run on each replica)   (25_alwayson_advanced.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_ag_backup_preference', @section = N'25.10', @source_file = N'25_alwayson_advanced.sql',
    @title = N'BACKUP PREFERENCE CHECK PER DATABASE (run on each replica)', @tags = N'BOX',
    @usage = N'SELECT * FROM dbo.HC_ag_backup_preference;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_ag_backup_preference
AS
-- Toolkit 25_alwayson_advanced.sql section 25.10: BACKUP PREFERENCE CHECK PER DATABASE (run on each replica)
SELECT ag.name AS ag_name, ag.automated_backup_preference_desc, ar.replica_server_name, ar.backup_priority,
       adc.database_name,
       sys.fn_hadr_backup_is_preferred_replica(adc.database_name) AS backup_here
FROM sys.availability_groups AS ag
JOIN sys.availability_replicas AS ar ON ar.group_id = ag.group_id AND ar.replica_server_name = @@SERVERNAME
JOIN sys.availability_databases_cluster AS adc ON adc.group_id = ag.group_id;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_ag_backup_preference
AS
-- Toolkit 25_alwayson_advanced.sql section 25.10: BACKUP PREFERENCE CHECK PER DATABASE (run on each replica)
SET NOCOUNT ON;
SELECT ag.name AS ag_name, ag.automated_backup_preference_desc, ar.replica_server_name, ar.backup_priority,
       adc.database_name,
       sys.fn_hadr_backup_is_preferred_replica(adc.database_name) AS backup_here
FROM sys.availability_groups AS ag
JOIN sys.availability_replicas AS ar ON ar.group_id = ag.group_id AND ar.replica_server_name = @@SERVERNAME
JOIN sys.availability_databases_cluster AS adc ON adc.group_id = ag.group_id;
';
GO

/* 26.1  INSTANCE FILESTREAM CONFIGURATION   (26_filestream_filetable.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_filestream_config', @section = N'26.1', @source_file = N'26_filestream_filetable.sql',
    @title = N'INSTANCE FILESTREAM CONFIGURATION', @tags = N'BOX',
    @usage = N'EXEC dbo.HC_filestream_config;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_filestream_config
AS
-- Toolkit 26_filestream_filetable.sql section 26.1: INSTANCE FILESTREAM CONFIGURATION
SET NOCOUNT ON;
SELECT SERVERPROPERTY(''FilestreamConfiguredLevel'') AS configured_level,
       SERVERPROPERTY(''FilestreamEffectiveLevel'')  AS effective_level,
       SERVERPROPERTY(''FilestreamShareName'')       AS windows_share_name;

SELECT name, value, value_in_use FROM sys.configurations WHERE name = N''filestream access level'';
',
    @fallback_definition = NULL;
GO

/* 26.2  DATABASES USING FILESTREAM + NON-TRANSACTED ACCESS (FileTable)   (26_filestream_filetable.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_filestream_dbs', @section = N'26.2', @source_file = N'26_filestream_filetable.sql',
    @title = N'DATABASES USING FILESTREAM + NON-TRANSACTED ACCESS (FileTable)', @tags = N'BOX',
    @usage = N'EXEC dbo.HC_filestream_dbs;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_filestream_dbs
AS
-- Toolkit 26_filestream_filetable.sql section 26.2: DATABASES USING FILESTREAM + NON-TRANSACTED ACCESS (FileTable)
SET NOCOUNT ON;
SELECT DB_NAME(fo.database_id) AS database_name,
       fo.non_transacted_access_desc,
       fo.directory_name
FROM sys.database_filestream_options AS fo
WHERE fo.non_transacted_access <> 0 OR fo.directory_name IS NOT NULL;

SELECT DB_NAME(mf.database_id) AS database_name, mf.name AS container_name, mf.physical_name, mf.state_desc
FROM sys.master_files AS mf
WHERE mf.type_desc = N''FILESTREAM''
ORDER BY database_name;
',
    @fallback_definition = NULL;
GO

/* 26.3  FILESTREAM FILEGROUPS & CONTAINERS - CURRENT DB   (26_filestream_filetable.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_filestream_containers', @section = N'26.3', @source_file = N'26_filestream_filetable.sql',
    @title = N'FILESTREAM FILEGROUPS & CONTAINERS - CURRENT DB', @tags = N'BOX',
    @usage = N'EXEC dbo.HC_filestream_containers @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_filestream_containers
    @database_name sysname = NULL
AS
-- Toolkit 26_filestream_filetable.sql section 26.3: FILESTREAM FILEGROUPS & CONTAINERS - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT fg.name AS filegroup_name, fg.type_desc, fg.is_default,
       df.name AS container_name, df.physical_name, df.state_desc,
       CAST(CAST(df.size AS bigint) * 8 / 1024.0 AS decimal(18,2)) AS size_mb,
       CASE df.max_size WHEN -1 THEN ''''Unlimited'''' ELSE CAST(CAST(df.max_size AS bigint) * 8 / 1024 AS varchar(20)) + '''' MB'''' END AS max_size
FROM sys.filegroups AS fg
JOIN sys.database_files AS df ON df.data_space_id = fg.data_space_id
WHERE fg.type = ''''FD''''
ORDER BY fg.name, df.name;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 26.4  TABLES / COLUMNS STORING FILESTREAM DATA - CURRENT DB   (26_filestream_filetable.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_filestream_columns', @section = N'26.4', @source_file = N'26_filestream_filetable.sql',
    @title = N'TABLES / COLUMNS STORING FILESTREAM DATA - CURRENT DB', @tags = N'BOX',
    @usage = N'EXEC dbo.HC_filestream_columns @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_filestream_columns
    @database_name sysname = NULL
AS
-- Toolkit 26_filestream_filetable.sql section 26.4: TABLES / COLUMNS STORING FILESTREAM DATA - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT OBJECT_SCHEMA_NAME(c.object_id) + N''''.'''' + OBJECT_NAME(c.object_id) AS table_name,
       c.name AS filestream_column, ds.name AS filestream_filegroup,
       (SELECT SUM(p.rows) FROM sys.partitions p WHERE p.object_id = c.object_id AND p.index_id IN (0, 1)) AS row_count
FROM sys.columns AS c
JOIN sys.tables AS t ON t.object_id = c.object_id
LEFT JOIN sys.data_spaces AS ds ON ds.data_space_id = t.filestream_data_space_id
WHERE c.is_filestream = 1
ORDER BY table_name;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 26.5  FILETABLES - CURRENT DB   (26_filestream_filetable.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_filetables', @section = N'26.5', @source_file = N'26_filestream_filetable.sql',
    @title = N'FILETABLES - CURRENT DB', @tags = N'BOX',
    @usage = N'EXEC dbo.HC_filetables @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_filetables
    @database_name sysname = NULL
AS
-- Toolkit 26_filestream_filetable.sql section 26.5: FILETABLES - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT OBJECT_SCHEMA_NAME(ft.object_id) + N''''.'''' + OBJECT_NAME(ft.object_id) AS filetable_name,
       ft.directory_name, ft.is_enabled, ft.filename_collation_name,
       FileTableRootPath(OBJECT_SCHEMA_NAME(ft.object_id) + N''''.'''' + OBJECT_NAME(ft.object_id)) AS unc_root_path
FROM sys.filetables AS ft;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 26.6  OPEN NON-TRANSACTED HANDLES (who has FileTable files open)   (26_filestream_filetable.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_filetable_handles', @section = N'26.6', @source_file = N'26_filestream_filetable.sql',
    @title = N'OPEN NON-TRANSACTED HANDLES (who has FileTable files open)', @tags = N'BOX',
    @usage = N'SELECT * FROM dbo.HC_filetable_handles ORDER BY open_time;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY open_time',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_filetable_handles
AS
-- Toolkit 26_filestream_filetable.sql section 26.6: OPEN NON-TRANSACTED HANDLES (who has FileTable files open)
SELECT DB_NAME(database_id) AS database_name, OBJECT_NAME(object_id, database_id) AS filetable_name,
       handle_id, opened_file_name, login_name, open_time, read_access, write_access, share_read, share_write
FROM sys.dm_filestream_non_transacted_handles;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_filetable_handles
AS
-- Toolkit 26_filestream_filetable.sql section 26.6: OPEN NON-TRANSACTED HANDLES (who has FileTable files open)
SET NOCOUNT ON;
SELECT DB_NAME(database_id) AS database_name, OBJECT_NAME(object_id, database_id) AS filetable_name,
       handle_id, opened_file_name, login_name, open_time, read_access, write_access, share_read, share_write
FROM sys.dm_filestream_non_transacted_handles
ORDER BY open_time;
';
GO

/* 26.8  FILESTREAM-RELATED WAITS   (26_filestream_filetable.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_filestream_waits', @section = N'26.8', @source_file = N'26_filestream_filetable.sql',
    @title = N'FILESTREAM-RELATED WAITS', @tags = N'BOX',
    @usage = N'SELECT * FROM dbo.HC_filestream_waits ORDER BY wait_time_ms DESC;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY wait_time_ms DESC',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_filestream_waits
AS
-- Toolkit 26_filestream_filetable.sql section 26.8: FILESTREAM-RELATED WAITS
SELECT wait_type, waiting_tasks_count, wait_time_ms,
       CAST(wait_time_ms * 1.0 / NULLIF(waiting_tasks_count, 0) AS decimal(10,2)) AS avg_wait_ms
FROM sys.dm_os_wait_stats
WHERE (wait_type LIKE N''FS%'' OR wait_type LIKE N''FILESTREAM%'' OR wait_type LIKE N''%FSAGENT%'' OR wait_type LIKE N''FFT%'')
  AND waiting_tasks_count > 0;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_filestream_waits
AS
-- Toolkit 26_filestream_filetable.sql section 26.8: FILESTREAM-RELATED WAITS
SET NOCOUNT ON;
SELECT wait_type, waiting_tasks_count, wait_time_ms,
       CAST(wait_time_ms * 1.0 / NULLIF(waiting_tasks_count, 0) AS decimal(10,2)) AS avg_wait_ms
FROM sys.dm_os_wait_stats
WHERE (wait_type LIKE N''FS%'' OR wait_type LIKE N''FILESTREAM%'' OR wait_type LIKE N''%FSAGENT%'' OR wait_type LIKE N''FFT%'')
  AND waiting_tasks_count > 0
ORDER BY wait_time_ms DESC;
';
GO

/* 31.1  SCHEMA FINGERPRINT - CURRENT DB (run on both envs, compare)   (31_schema_validation.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_schema_fingerprint', @section = N'31.1', @source_file = N'31_schema_validation.sql',
    @title = N'SCHEMA FINGERPRINT - CURRENT DB (run on both envs, compare)', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_schema_fingerprint @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_schema_fingerprint
    @database_name sysname = NULL
AS
-- Toolkit 31_schema_validation.sql section 31.1: SCHEMA FINGERPRINT - CURRENT DB (run on both envs, compare)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''WITH cols AS (
    SELECT c.object_id,
           sig = (SELECT c2.name, TYPE_NAME(c2.user_type_id) AS t, c2.max_length AS l, c2.precision AS p, c2.scale AS s,
                         c2.is_nullable AS n, c2.is_identity AS i, c2.collation_name AS co,
                         OBJECT_DEFINITION(c2.default_object_id) AS d
                  FROM sys.columns AS c2 WHERE c2.object_id = c.object_id ORDER BY c2.name FOR XML RAW, TYPE)
    FROM sys.columns AS c GROUP BY c.object_id
)
SELECT SCHEMA_NAME(o.schema_id) + N''''.'''' + o.name AS object_name, o.type_desc,
       CONVERT(varchar(66), HASHBYTES(''''SHA2_256'''',
            CASE WHEN m.object_id IS NOT NULL
                 THEN REPLACE(REPLACE(REPLACE(m.definition, NCHAR(13), N''''''''), NCHAR(10), N''''''''), N'''' '''', N'''''''')
                 ELSE CAST(cols.sig AS nvarchar(max)) END), 1) AS object_hash
FROM sys.objects AS o
LEFT JOIN sys.sql_modules AS m ON m.object_id = o.object_id
LEFT JOIN cols ON cols.object_id = o.object_id
WHERE o.is_ms_shipped = 0
  AND o.type IN (''''U'''', ''''V'''', ''''P'''', ''''FN'''', ''''IF'''', ''''TF'''', ''''TR'''', ''''SN'''', ''''SO'''')
ORDER BY o.type_desc, object_name;

SELECT OBJECT_SCHEMA_NAME(i.object_id) + N''''.'''' + OBJECT_NAME(i.object_id) + N''''.'''' + ISNULL(i.name, N''''HEAP'''') AS index_name,
       i.type_desc,
       CONVERT(varchar(66), HASHBYTES(''''SHA2_256'''', CAST((
            SELECT i.is_unique AS u, i.is_primary_key AS pk, i.filter_definition AS f, i.fill_factor AS ff,
                   (SELECT c.name, ic.key_ordinal AS k, ic.is_descending_key AS d, ic.is_included_column AS inc
                    FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                    WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id
                    ORDER BY ic.is_included_column, ic.key_ordinal, c.name FOR XML RAW, TYPE)
            FOR XML RAW, TYPE) AS nvarchar(max))), 1) AS index_hash
FROM sys.indexes AS i
WHERE OBJECTPROPERTY(i.object_id, ''''IsUserTable'''') = 1
ORDER BY index_name;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 31.2  COMPARE TWO DATABASES ON THE SAME INSTANCE - OBJECTS   (31_schema_validation.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_compare_db_objects', @section = N'31.2', @source_file = N'31_schema_validation.sql',
    @title = N'COMPARE TWO DATABASES ON THE SAME INSTANCE - OBJECTS', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_compare_db_objects @source_db = N''App_PROD_Copy'', @target_db = N''App_UAT'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_compare_db_objects
    @source_db sysname = N''App_PROD_Copy'',
    @target_db sysname = N''App_UAT''
AS
-- Toolkit 31_schema_validation.sql section 31.2: COMPARE TWO DATABASES ON THE SAME INSTANCE - OBJECTS
SET NOCOUNT ON;
DECLARE @sql nvarchar(max) = N''
SELECT COALESCE(s.obj, t.obj) AS object_name, COALESCE(s.type_desc, t.type_desc) AS type_desc,
       CASE WHEN t.obj IS NULL THEN ''''ONLY IN SOURCE''''
            WHEN s.obj IS NULL THEN ''''ONLY IN TARGET''''
            ELSE ''''DEFINITION DIFFERS'''' END AS difference
FROM (SELECT sc.name + N''''.'''' + o.name AS obj, o.type_desc, HASHBYTES(''''SHA2_256'''', m.definition) AS h
      FROM '' + QUOTENAME(@source_db) + N''.sys.objects o
      JOIN '' + QUOTENAME(@source_db) + N''.sys.schemas sc ON sc.schema_id = o.schema_id
      LEFT JOIN '' + QUOTENAME(@source_db) + N''.sys.sql_modules m ON m.object_id = o.object_id
      WHERE o.is_ms_shipped = 0 AND o.type IN (''''U'''',''''V'''',''''P'''',''''FN'''',''''IF'''',''''TF'''',''''TR'''',''''SN'''')) AS s
FULL JOIN
     (SELECT sc.name + N''''.'''' + o.name AS obj, o.type_desc, HASHBYTES(''''SHA2_256'''', m.definition) AS h
      FROM '' + QUOTENAME(@target_db) + N''.sys.objects o
      JOIN '' + QUOTENAME(@target_db) + N''.sys.schemas sc ON sc.schema_id = o.schema_id
      LEFT JOIN '' + QUOTENAME(@target_db) + N''.sys.sql_modules m ON m.object_id = o.object_id
      WHERE o.is_ms_shipped = 0 AND o.type IN (''''U'''',''''V'''',''''P'''',''''FN'''',''''IF'''',''''TF'''',''''TR'''',''''SN'''')) AS t
  ON t.obj = s.obj AND t.type_desc = s.type_desc
WHERE s.obj IS NULL OR t.obj IS NULL OR ISNULL(s.h, 0x0) <> ISNULL(t.h, 0x0)
ORDER BY difference, object_name;'';
EXEC sys.sp_executesql @sql;
',
    @fallback_definition = NULL;
GO

/* 31.3  COMPARE TWO DATABASES - COLUMNS   (31_schema_validation.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_compare_db_columns', @section = N'31.3', @source_file = N'31_schema_validation.sql',
    @title = N'COMPARE TWO DATABASES - COLUMNS', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_compare_db_columns;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_compare_db_columns
AS
-- Toolkit 31_schema_validation.sql section 31.3: COMPARE TWO DATABASES - COLUMNS
SET NOCOUNT ON;
SET @sql = N''
WITH s AS (SELECT sc.name + N''''.'''' + t.name AS tbl, c.name AS col, ty.name AS data_type, c.max_length, c.precision, c.scale, c.is_nullable, c.collation_name
           FROM '' + QUOTENAME(@src) + N''.sys.columns c JOIN '' + QUOTENAME(@src) + N''.sys.tables t ON t.object_id = c.object_id
           JOIN '' + QUOTENAME(@src) + N''.sys.schemas sc ON sc.schema_id = t.schema_id
           JOIN '' + QUOTENAME(@src) + N''.sys.types ty ON ty.user_type_id = c.user_type_id WHERE t.is_ms_shipped = 0),
     t AS (SELECT sc.name + N''''.'''' + t.name AS tbl, c.name AS col, ty.name AS data_type, c.max_length, c.precision, c.scale, c.is_nullable, c.collation_name
           FROM '' + QUOTENAME(@tgt) + N''.sys.columns c JOIN '' + QUOTENAME(@tgt) + N''.sys.tables t ON t.object_id = c.object_id
           JOIN '' + QUOTENAME(@tgt) + N''.sys.schemas sc ON sc.schema_id = t.schema_id
           JOIN '' + QUOTENAME(@tgt) + N''.sys.types ty ON ty.user_type_id = c.user_type_id WHERE t.is_ms_shipped = 0)
SELECT COALESCE(s.tbl, t.tbl) AS table_name, COALESCE(s.col, t.col) AS column_name,
       s.data_type + ''''('''' + CAST(s.max_length AS varchar(10)) + '''')'''' + CASE s.is_nullable WHEN 1 THEN '''' NULL'''' ELSE '''' NOT NULL'''' END AS source_def,
       t.data_type + ''''('''' + CAST(t.max_length AS varchar(10)) + '''')'''' + CASE t.is_nullable WHEN 1 THEN '''' NULL'''' ELSE '''' NOT NULL'''' END AS target_def,
       CASE WHEN t.col IS NULL THEN ''''ONLY IN SOURCE'''' WHEN s.col IS NULL THEN ''''ONLY IN TARGET'''' ELSE ''''DIFFERS'''' END AS difference
FROM s FULL JOIN t ON t.tbl = s.tbl AND t.col = s.col
WHERE s.col IS NULL OR t.col IS NULL
   OR s.data_type <> t.data_type OR s.max_length <> t.max_length OR s.precision <> t.precision
   OR s.scale <> t.scale OR s.is_nullable <> t.is_nullable OR ISNULL(s.collation_name, '''''''') <> ISNULL(t.collation_name, '''''''')
ORDER BY table_name, column_name;'';
EXEC sys.sp_executesql @sql;
',
    @fallback_definition = NULL;
GO

/* 31.4  BROKEN OBJECTS - CURRENT DB   (31_schema_validation.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_broken_objects', @section = N'31.4', @source_file = N'31_schema_validation.sql',
    @title = N'BROKEN OBJECTS - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_broken_objects @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_broken_objects
    @database_name sysname = NULL
AS
-- Toolkit 31_schema_validation.sql section 31.4: BROKEN OBJECTS - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT OBJECT_SCHEMA_NAME(d.referencing_id) + N''''.'''' + OBJECT_NAME(d.referencing_id) AS referencing_object,
       ISNULL(d.referenced_schema_name + N''''.'''', N'''''''') + d.referenced_entity_name AS missing_reference
FROM sys.sql_expression_dependencies AS d
WHERE d.referenced_id IS NULL
  AND d.is_ambiguous = 0
  AND d.referenced_database_name IS NULL AND d.referenced_server_name IS NULL
  AND OBJECT_ID(ISNULL(d.referenced_schema_name + N''''.'''', N''''dbo.'''') + d.referenced_entity_name) IS NULL
  AND NOT EXISTS (SELECT 1 FROM sys.types t WHERE t.name = d.referenced_entity_name)
ORDER BY referencing_object;

IF OBJECT_ID(''''tempdb..#broken'''') IS NOT NULL DROP TABLE #broken;
CREATE TABLE #broken (object_name nvarchar(300), error_message nvarchar(4000));
DECLARE @obj nvarchar(300);
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT QUOTENAME(OBJECT_SCHEMA_NAME(m.object_id)) + N''''.'''' + QUOTENAME(OBJECT_NAME(m.object_id))
    FROM sys.sql_modules AS m JOIN sys.objects AS o ON o.object_id = m.object_id
    WHERE m.is_schema_bound = 0 AND o.is_ms_shipped = 0 AND o.type IN (''''P'''', ''''V'''', ''''FN'''', ''''IF'''', ''''TF'''');
OPEN cur; FETCH NEXT FROM cur INTO @obj;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        BEGIN TRAN;
        EXEC sys.sp_refreshsqlmodule @name = @obj;
        ROLLBACK;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        INSERT #broken VALUES (@obj, ERROR_MESSAGE());
    END CATCH;
    FETCH NEXT FROM cur INTO @obj;
END
CLOSE cur; DEALLOCATE cur;
SELECT * FROM #broken ORDER BY object_name;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 31.5  CONSTRAINT & TRIGGER INTEGRITY - CURRENT DB   (31_schema_validation.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_constraint_integrity', @section = N'31.5', @source_file = N'31_schema_validation.sql',
    @title = N'CONSTRAINT & TRIGGER INTEGRITY - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_constraint_integrity @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_constraint_integrity
    @database_name sysname = NULL
AS
-- Toolkit 31_schema_validation.sql section 31.5: CONSTRAINT & TRIGGER INTEGRITY - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT ''''FOREIGN KEY'''' AS constraint_type, OBJECT_SCHEMA_NAME(parent_object_id) + N''''.'''' + OBJECT_NAME(parent_object_id) AS table_name,
       name, is_disabled, is_not_trusted,
       N''''ALTER TABLE '''' + QUOTENAME(OBJECT_SCHEMA_NAME(parent_object_id)) + N''''.'''' + QUOTENAME(OBJECT_NAME(parent_object_id))
         + N'''' WITH CHECK CHECK CONSTRAINT '''' + QUOTENAME(name) + N'''';'''' AS fix_cmd
FROM sys.foreign_keys WHERE is_not_trusted = 1 OR is_disabled = 1
UNION ALL
SELECT ''''CHECK'''', OBJECT_SCHEMA_NAME(parent_object_id) + N''''.'''' + OBJECT_NAME(parent_object_id), name, is_disabled, is_not_trusted,
       N''''ALTER TABLE '''' + QUOTENAME(OBJECT_SCHEMA_NAME(parent_object_id)) + N''''.'''' + QUOTENAME(OBJECT_NAME(parent_object_id))
         + N'''' WITH CHECK CHECK CONSTRAINT '''' + QUOTENAME(name) + N'''';''''
FROM sys.check_constraints WHERE is_not_trusted = 1 OR is_disabled = 1
ORDER BY table_name;

SELECT OBJECT_SCHEMA_NAME(parent_id) + N''''.'''' + OBJECT_NAME(parent_id) AS table_name, name AS trigger_name, is_disabled
FROM sys.triggers WHERE parent_class = 1 AND is_disabled = 1;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 31.6  ROW COUNTS - CURRENT DB (run on source & target, compare)   (31_schema_validation.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_exact_row_counts', @section = N'31.6', @source_file = N'31_schema_validation.sql',
    @title = N'ROW COUNTS - CURRENT DB (run on source & target, compare)', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_exact_row_counts @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_exact_row_counts
    @database_name sysname = NULL
AS
-- Toolkit 31_schema_validation.sql section 31.6: ROW COUNTS - CURRENT DB (run on source & target, compare)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT OBJECT_SCHEMA_NAME(object_id) + N''''.'''' + OBJECT_NAME(object_id) AS table_name,
       SUM(row_count) AS row_count
FROM sys.dm_db_partition_stats
WHERE index_id IN (0, 1) AND OBJECTPROPERTY(object_id, ''''IsUserTable'''') = 1
GROUP BY object_id
ORDER BY table_name;

SET @sql = N''''
SELECT COALESCE(s.tbl, t.tbl) AS table_name, s.rows AS source_rows, t.rows AS target_rows, ISNULL(s.rows,0) - ISNULL(t.rows,0) AS diff
FROM (SELECT sc.name + N''''''''.'''''''' + tb.name AS tbl, SUM(p.rows) AS rows FROM '''' + QUOTENAME(@src) + N''''.sys.partitions p
      JOIN '''' + QUOTENAME(@src) + N''''.sys.tables tb ON tb.object_id = p.object_id JOIN '''' + QUOTENAME(@src) + N''''.sys.schemas sc ON sc.schema_id = tb.schema_id
      WHERE p.index_id IN (0,1) GROUP BY sc.name, tb.name) s
FULL JOIN
     (SELECT sc.name + N''''''''.'''''''' + tb.name AS tbl, SUM(p.rows) AS rows FROM '''' + QUOTENAME(@tgt) + N''''.sys.partitions p
      JOIN '''' + QUOTENAME(@tgt) + N''''.sys.tables tb ON tb.object_id = p.object_id JOIN '''' + QUOTENAME(@tgt) + N''''.sys.schemas sc ON sc.schema_id = tb.schema_id
      WHERE p.index_id IN (0,1) GROUP BY sc.name, tb.name) t ON t.tbl = s.tbl
WHERE ISNULL(s.rows, -1) <> ISNULL(t.rows, -1)
ORDER BY ABS(ISNULL(s.rows,0) - ISNULL(t.rows,0)) DESC;'''';
EXEC sys.sp_executesql @sql;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 31.7  COLLATION MISMATCHES (column vs database) - CURRENT DB   (31_schema_validation.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_collation_mismatches', @section = N'31.7', @source_file = N'31_schema_validation.sql',
    @title = N'COLLATION MISMATCHES (column vs database) - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_collation_mismatches @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_collation_mismatches
    @database_name sysname = NULL
AS
-- Toolkit 31_schema_validation.sql section 31.7: COLLATION MISMATCHES (column vs database) - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT OBJECT_SCHEMA_NAME(c.object_id) + N''''.'''' + OBJECT_NAME(c.object_id) AS table_name,
       c.name AS column_name, c.collation_name,
       CAST(DATABASEPROPERTYEX(DB_NAME(), ''''Collation'''') AS sysname) AS database_collation
FROM sys.columns AS c
JOIN sys.tables AS t ON t.object_id = c.object_id AND t.is_ms_shipped = 0
WHERE c.collation_name IS NOT NULL
  AND c.collation_name <> CAST(DATABASEPROPERTYEX(DB_NAME(), ''''Collation'''') AS sysname)
ORDER BY table_name, column_name;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 31.8  SAME COLUMN NAME, DIFFERENT DATA TYPES - CURRENT DB   (31_schema_validation.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_column_type_mismatches', @section = N'31.8', @source_file = N'31_schema_validation.sql',
    @title = N'SAME COLUMN NAME, DIFFERENT DATA TYPES - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_column_type_mismatches @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_column_type_mismatches
    @database_name sysname = NULL
AS
-- Toolkit 31_schema_validation.sql section 31.8: SAME COLUMN NAME, DIFFERENT DATA TYPES - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''WITH c AS (
    SELECT c.name AS column_name, TYPE_NAME(c.user_type_id) + ''''('''' + CAST(c.max_length AS varchar(10)) + '''')'''' AS type_def,
           OBJECT_SCHEMA_NAME(c.object_id) + N''''.'''' + OBJECT_NAME(c.object_id) AS table_name
    FROM sys.columns AS c JOIN sys.tables AS t ON t.object_id = c.object_id AND t.is_ms_shipped = 0
)
SELECT column_name, type_def, COUNT(*) AS tables_using, MIN(table_name) AS example_table
FROM c
WHERE column_name IN (SELECT column_name FROM c GROUP BY column_name HAVING COUNT(DISTINCT type_def) > 1)
GROUP BY column_name, type_def
ORDER BY column_name, tables_using DESC;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 31.9  IDENTITY COLUMNS CLOSE TO THEIR MAXIMUM - CURRENT DB   (31_schema_validation.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_identity_near_max', @section = N'31.9', @source_file = N'31_schema_validation.sql',
    @title = N'IDENTITY COLUMNS CLOSE TO THEIR MAXIMUM - CURRENT DB', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_identity_near_max @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_identity_near_max
    @database_name sysname = NULL
AS
-- Toolkit 31_schema_validation.sql section 31.9: IDENTITY COLUMNS CLOSE TO THEIR MAXIMUM - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT OBJECT_SCHEMA_NAME(ic.object_id) + N''''.'''' + OBJECT_NAME(ic.object_id) AS table_name,
       ic.name AS column_name, TYPE_NAME(ic.user_type_id) AS data_type,
       CAST(ic.last_value AS bigint) AS last_value,
       CASE TYPE_NAME(ic.user_type_id) WHEN ''''tinyint'''' THEN 255 WHEN ''''smallint'''' THEN 32767
            WHEN ''''int'''' THEN 2147483647 WHEN ''''bigint'''' THEN 9223372036854775807 END AS max_value,
       CAST(100.0 * CAST(ic.last_value AS bigint) /
            CASE TYPE_NAME(ic.user_type_id) WHEN ''''tinyint'''' THEN 255 WHEN ''''smallint'''' THEN 32767
                 WHEN ''''int'''' THEN 2147483647 WHEN ''''bigint'''' THEN 9223372036854775807 END AS decimal(6,2)) AS pct_used
FROM sys.identity_columns AS ic
WHERE ic.last_value IS NOT NULL
  AND TYPE_NAME(ic.user_type_id) IN (''''tinyint'''', ''''smallint'''', ''''int'''', ''''bigint'''')
ORDER BY pct_used DESC;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 31.10  OBJECT COUNTS BY TYPE (quick env-to-env sanity check)   (31_schema_validation.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_object_counts', @section = N'31.10', @source_file = N'31_schema_validation.sql',
    @title = N'OBJECT COUNTS BY TYPE (quick env-to-env sanity check)', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_object_counts @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_object_counts
    @database_name sysname = NULL
AS
-- Toolkit 31_schema_validation.sql section 31.10: OBJECT COUNTS BY TYPE (quick env-to-env sanity check)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT type_desc, COUNT(*) AS object_count
FROM sys.objects WHERE is_ms_shipped = 0
GROUP BY type_desc
UNION ALL SELECT ''''INDEX'''', COUNT(*) FROM sys.indexes i WHERE i.index_id > 0 AND OBJECTPROPERTY(i.object_id, ''''IsUserTable'''') = 1
UNION ALL SELECT ''''STATISTICS (user)'''', COUNT(*) FROM sys.stats s WHERE s.user_created = 1
UNION ALL SELECT ''''USER'''', COUNT(*) FROM sys.database_principals WHERE type IN (''''S'''',''''U'''',''''G'''',''''E'''',''''X'''') AND principal_id > 4
UNION ALL SELECT ''''ROLE (custom)'''', COUNT(*) FROM sys.database_principals WHERE type = ''''R'''' AND is_fixed_role = 0 AND principal_id > 0 AND name <> N''''public''''
ORDER BY type_desc;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 36.1  FAILED LOGINS DECODED (error 18456 state -> reason)   (36_connectivity_service_troubleshooting.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_failed_logins_decoded', @section = N'36.1', @source_file = N'36_connectivity_service_troubleshooting.sql',
    @title = N'FAILED LOGINS DECODED (error 18456 state -> reason)', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_failed_logins_decoded;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_failed_logins_decoded
AS
-- Toolkit 36_connectivity_service_troubleshooting.sql section 36.1: FAILED LOGINS DECODED (error 18456 state -> reason)
SET NOCOUNT ON;
IF OBJECT_ID(''tempdb..#el'') IS NOT NULL DROP TABLE #el;
CREATE TABLE #el (LogDate datetime, ProcessInfo nvarchar(50), [Text] nvarchar(max));
INSERT #el EXEC sys.xp_readerrorlog 0, 1, N''Login failed'';
INSERT #el EXEC sys.xp_readerrorlog 0, 1, N''Error: 18456'';

WITH states AS (
    SELECT * FROM (VALUES
        (2,  ''Login does not exist (invalid user ID)''),
        (5,  ''Login does not exist (invalid user ID)''),
        (6,  ''Windows login name used with SQL authentication''),
        (7,  ''Login disabled AND wrong password''),
        (8,  ''Wrong password''),
        (9,  ''Invalid password (policy)''),
        (11, ''Valid login, no server access (e.g. CONNECT SQL denied / UAC / group removed)''),
        (12, ''Valid login, no server access''),
        (13, ''SQL Server service paused''),
        (18, ''Password must be changed''),
        (23, ''Server shutting down''),
        (38, ''Cannot open the database requested in the connection string''),
        (40, ''Cannot open the login''''s DEFAULT database''),
        (58, ''SQL login used but server is Windows-authentication only'')
    ) AS v(state, reason)
),
errs AS (
    SELECT LogDate, ProcessInfo,
           TRY_CAST(REPLACE(SUBSTRING([Text], CHARINDEX(''State:'', [Text]) + 7, 5), ''.'', '''') AS int) AS state
    FROM #el WHERE [Text] LIKE N''Error: 18456%''
)
SELECT l.LogDate, e.state, ISNULL(s.reason, ''see docs: MSSQLSERVER_18456'') AS reason, l.[Text] AS message
FROM #el AS l
LEFT JOIN errs AS e ON e.LogDate = l.LogDate AND e.ProcessInfo = l.ProcessInfo
LEFT JOIN states AS s ON s.state = e.state
WHERE l.[Text] LIKE N''Login failed%''
ORDER BY l.LogDate DESC;
',
    @fallback_definition = NULL;
GO

/* 36.2  CONNECTIVITY RING BUFFER (closed connections, login timeouts)   (36_connectivity_service_troubleshooting.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_connectivity_ring_buffer', @section = N'36.2', @source_file = N'36_connectivity_service_troubleshooting.sql',
    @title = N'CONNECTIVITY RING BUFFER (closed connections, login timeouts)', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_connectivity_ring_buffer;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_connectivity_ring_buffer
AS
-- Toolkit 36_connectivity_service_troubleshooting.sql section 36.2: CONNECTIVITY RING BUFFER (closed connections, login timeouts)
SET NOCOUNT ON;
DECLARE @ms_now bigint = (SELECT ms_ticks FROM sys.dm_os_sys_info);
SELECT TOP (100)
    DATEADD(MILLISECOND, -1 * (@ms_now - rb.[timestamp]), SYSDATETIME())                             AS event_time,
    x.r.value(''(Record/ConnectivityTraceRecord/RecordType)[1]'', ''varchar(50)'')                      AS record_type,
    x.r.value(''(Record/ConnectivityTraceRecord/RecordSource)[1]'', ''varchar(50)'')                    AS record_source,
    x.r.value(''(Record/ConnectivityTraceRecord/Spid)[1]'', ''int'')                                    AS spid,
    x.r.value(''(Record/ConnectivityTraceRecord/RemoteHost)[1]'', ''varchar(50)'')                      AS remote_host,
    x.r.value(''(Record/ConnectivityTraceRecord/RemotePort)[1]'', ''int'')                              AS remote_port,
    x.r.value(''(Record/ConnectivityTraceRecord/LocalPort)[1]'', ''int'')                               AS local_port,
    x.r.value(''(Record/ConnectivityTraceRecord/SniConsumerError)[1]'', ''int'')                        AS sni_error,
    x.r.value(''(Record/ConnectivityTraceRecord/State)[1]'', ''int'')                                   AS state,
    x.r.value(''(Record/ConnectivityTraceRecord/OSError)[1]'', ''int'')                                 AS os_error,
    x.r                                                                                              AS full_record
FROM sys.dm_os_ring_buffers AS rb
CROSS APPLY (SELECT CAST(rb.record AS xml)) AS x(r)
WHERE rb.ring_buffer_type = N''RING_BUFFER_CONNECTIVITY''
ORDER BY rb.[timestamp] DESC;

SELECT TOP (50)
    DATEADD(MILLISECOND, -1 * (@ms_now - rb.[timestamp]), SYSDATETIME()) AS event_time,
    x.r.value(''(Record/Error/ErrorCode)[1]'', ''varchar(20)'')               AS error_code,
    x.r.value(''(Record/Error/CallingAPIName)[1]'', ''varchar(100)'')         AS calling_api,
    x.r.value(''(Record/Error/APIName)[1]'', ''varchar(100)'')                AS api_name,
    x.r.value(''(Record/Error/SPID)[1]'', ''int'')                            AS spid
FROM sys.dm_os_ring_buffers AS rb
CROSS APPLY (SELECT CAST(rb.record AS xml)) AS x(r)
WHERE rb.ring_buffer_type = N''RING_BUFFER_SECURITY_ERROR''
ORDER BY rb.[timestamp] DESC;
',
    @fallback_definition = NULL;
GO

/* 36.3  KERBEROS OR NTLM? + SPN CHECKS   (36_connectivity_service_troubleshooting.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_auth_scheme_spn', @section = N'36.3', @source_file = N'36_connectivity_service_troubleshooting.sql',
    @title = N'KERBEROS OR NTLM? + SPN CHECKS', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_auth_scheme_spn;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_auth_scheme_spn
AS
-- Toolkit 36_connectivity_service_troubleshooting.sql section 36.3: KERBEROS OR NTLM? + SPN CHECKS
SET NOCOUNT ON;
SELECT c.auth_scheme, c.net_transport, COUNT(*) AS connections,
       SUM(CASE WHEN c.client_net_address NOT IN (''<local machine>'', ''127.0.0.1'', ''::1'') THEN 1 ELSE 0 END) AS remote_connections
FROM sys.dm_exec_connections AS c
GROUP BY c.auth_scheme, c.net_transport;

SELECT auth_scheme FROM sys.dm_exec_connections WHERE session_id = @@SPID;
',
    @fallback_definition = NULL;
GO

/* 36.4  WHAT IS SQL LISTENING ON? (ports, protocols, TLS)   (36_connectivity_service_troubleshooting.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_listening_ports', @section = N'36.4', @source_file = N'36_connectivity_service_troubleshooting.sql',
    @title = N'WHAT IS SQL LISTENING ON? (ports, protocols, TLS)', @tags = N'BOX',
    @usage = N'EXEC dbo.HC_listening_ports;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_listening_ports
AS
-- Toolkit 36_connectivity_service_troubleshooting.sql section 36.4: WHAT IS SQL LISTENING ON? (ports, protocols, TLS)
SET NOCOUNT ON;
SELECT listener_id, ip_address, is_ipv4, port, type_desc, state_desc, start_time
FROM sys.dm_tcp_listener_states;

SELECT DISTINCT local_net_address, local_tcp_port, net_transport, protocol_type, encrypt_option
FROM sys.dm_exec_connections WHERE local_tcp_port IS NOT NULL;

SELECT registry_key, value_name, value_data
FROM sys.dm_server_registry
WHERE value_name IN (N''TcpPort'', N''TcpDynamicPorts'', N''ForceEncryption'', N''Certificate'', N''Enabled'', N''ListenOnAllIPs'')
ORDER BY registry_key, value_name;
',
    @fallback_definition = NULL;
GO

/* 36.5  CONNECTION STORMS / POOL LEAKS   (36_connectivity_service_troubleshooting.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_connection_storms', @section = N'36.5', @source_file = N'36_connectivity_service_troubleshooting.sql',
    @title = N'CONNECTION STORMS / POOL LEAKS', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_connection_storms;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_connection_storms
AS
-- Toolkit 36_connectivity_service_troubleshooting.sql section 36.5: CONNECTION STORMS / POOL LEAKS
SET NOCOUNT ON;
SELECT s.host_name, s.program_name, s.login_name, COUNT(*) AS sessions,
       SUM(CASE WHEN s.status = ''sleeping'' THEN 1 ELSE 0 END) AS sleeping,
       MAX(DATEDIFF(MINUTE, s.last_request_end_time, SYSDATETIME())) AS max_idle_min,
       SUM(CASE WHEN s.open_transaction_count > 0 THEN 1 ELSE 0 END) AS with_open_tran
FROM sys.dm_exec_sessions AS s
WHERE s.is_user_process = 1
GROUP BY s.host_name, s.program_name, s.login_name
ORDER BY sessions DESC;

SELECT RTRIM(counter_name) AS counter_name, cntr_value
FROM sys.dm_os_performance_counters
WHERE counter_name IN (N''Logins/sec'', N''Logouts/sec'', N''User Connections'', N''Connection Reset/sec'');
',
    @fallback_definition = NULL;
GO

/* 36.6  LINKED SERVER TROUBLESHOOTING   (36_connectivity_service_troubleshooting.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_linked_server_check', @section = N'36.6', @source_file = N'36_connectivity_service_troubleshooting.sql',
    @title = N'LINKED SERVER TROUBLESHOOTING', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_linked_server_check;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_linked_server_check
AS
-- Toolkit 36_connectivity_service_troubleshooting.sql section 36.6: LINKED SERVER TROUBLESHOOTING
SELECT r.session_id, r.wait_type, r.wait_time, s.login_name, t.text
FROM sys.dm_exec_requests r
JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.wait_type IN (N''OLEDB'', N''PREEMPTIVE_OLEDBOPS'', N''PREEMPTIVE_OS_AUTHENTICATIONOPS'', N''MSQL_DQ'');
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_linked_server_check
AS
-- Toolkit 36_connectivity_service_troubleshooting.sql section 36.6: LINKED SERVER TROUBLESHOOTING
SET NOCOUNT ON;
SELECT r.session_id, r.wait_type, r.wait_time, s.login_name, t.text
FROM sys.dm_exec_requests r
JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.wait_type IN (N''OLEDB'', N''PREEMPTIVE_OLEDBOPS'', N''PREEMPTIVE_OS_AUTHENTICATIONOPS'', N''MSQL_DQ'');
';
GO

/* 36.7  DISTRIBUTED TRANSACTIONS (DTC) & ORPHANED SPID -2   (36_connectivity_service_troubleshooting.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_dtc_orphans', @section = N'36.7', @source_file = N'36_connectivity_service_troubleshooting.sql',
    @title = N'DISTRIBUTED TRANSACTIONS (DTC) & ORPHANED SPID -2', @tags = N'BOX',
    @usage = N'EXEC dbo.HC_dtc_orphans;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_dtc_orphans
AS
-- Toolkit 36_connectivity_service_troubleshooting.sql section 36.7: DISTRIBUTED TRANSACTIONS (DTC) & ORPHANED SPID -2
SET NOCOUNT ON;
SELECT at.transaction_id, at.name, at.transaction_begin_time, at.transaction_type,
       at.dtc_state, at.transaction_uow
FROM sys.dm_tran_active_transactions AS at
WHERE at.transaction_type = 4
ORDER BY at.transaction_begin_time;

SELECT DISTINCT tl.request_owner_guid AS uow,
       N''KILL '''''' + CAST(tl.request_owner_guid AS nvarchar(40)) + N'''''';'' AS kill_cmd
FROM sys.dm_tran_locks AS tl
WHERE tl.request_session_id = -2;
',
    @fallback_definition = NULL;
GO

/* 36.8  SERVICE BROKER HEALTH - CURRENT DB   (36_connectivity_service_troubleshooting.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_service_broker', @section = N'36.8', @source_file = N'36_connectivity_service_troubleshooting.sql',
    @title = N'SERVICE BROKER HEALTH - CURRENT DB', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_service_broker @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_service_broker
    @database_name sysname = NULL
AS
-- Toolkit 36_connectivity_service_troubleshooting.sql section 36.8: SERVICE BROKER HEALTH - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT name, is_broker_enabled, service_broker_guid FROM sys.databases WHERE database_id = DB_ID();

SELECT q.name, q.is_receive_enabled, q.is_enqueue_enabled, q.is_activation_enabled,
       q.activation_procedure, q.max_readers, q.is_poison_message_handling_enabled,
       (SELECT SUM(p.rows) FROM sys.partitions p JOIN sys.internal_tables it ON it.object_id = p.object_id
        WHERE it.parent_object_id = q.object_id AND p.index_id = 1) AS messages_in_queue
FROM sys.service_queues AS q
WHERE q.is_ms_shipped = 0;

SELECT TOP (50) to_service_name, enqueue_time, transmission_status, message_type_name
FROM sys.transmission_queue ORDER BY enqueue_time;

SELECT state_desc, COUNT(*) AS conversations FROM sys.conversation_endpoints GROUP BY state_desc ORDER BY conversations DESC;

SELECT DB_NAME(database_id) AS database_name, queue_id, procedure_name, execute_as, spid FROM sys.dm_broker_activated_tasks;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 36.9  HANGS, STACK DUMPS, NON-YIELDING SCHEDULERS   (36_connectivity_service_troubleshooting.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_stack_dumps_nonyield', @section = N'36.9', @source_file = N'36_connectivity_service_troubleshooting.sql',
    @title = N'HANGS, STACK DUMPS, NON-YIELDING SCHEDULERS', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_stack_dumps_nonyield;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_stack_dumps_nonyield
AS
-- Toolkit 36_connectivity_service_troubleshooting.sql section 36.9: HANGS, STACK DUMPS, NON-YIELDING SCHEDULERS
SET NOCOUNT ON;
SELECT filename, creation_time, size_in_bytes / 1048576 AS size_mb
FROM sys.dm_server_memory_dumps
ORDER BY creation_time DESC;

EXEC sys.xp_readerrorlog 0, 1, N''non-yielding'';
EXEC sys.xp_readerrorlog 0, 1, N''Stack Signature'';
EXEC sys.xp_readerrorlog 0, 1, N''deadlocked schedulers'';

SELECT x.ev.value(''(event/@timestamp)[1]'', ''datetime2'') AS event_time_utc,
       x.ev.value(''(event/@name)[1]'', ''nvarchar(100)'')  AS event_name,
       x.ev.value(''(event/data[@name="component"]/text)[1]'', ''nvarchar(100)'')  AS component,
       x.ev.value(''(event/data[@name="state"]/text)[1]'', ''nvarchar(50)'')       AS state
FROM sys.fn_xe_file_target_read_file(N''system_health*.xel'', NULL, NULL, NULL) AS f
CROSS APPLY (SELECT CAST(f.event_data AS xml)) AS x(ev)
WHERE f.object_name IN (N''scheduler_monitor_non_yielding_ring_buffer_recorded'', N''scheduler_monitor_deadlock_ring_buffer_recorded'',
                        N''sp_server_diagnostics_component_result'')
  AND (f.object_name <> N''sp_server_diagnostics_component_result''
       OR x.ev.value(''(event/data[@name="state"]/text)[1]'', ''nvarchar(50)'') <> N''CLEAN'')
ORDER BY event_time_utc DESC;
',
    @fallback_definition = NULL;
GO

/* 39.1  STATISTICS ON A TABLE + HISTOGRAM (2016 SP1 CU2+)   (39_advanced_tuning.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_stats_histogram', @section = N'39.1', @source_file = N'39_advanced_tuning.sql',
    @title = N'STATISTICS ON A TABLE + HISTOGRAM (2016 SP1 CU2+)', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_stats_histogram @database_name = N''YourDB'', @table = N''dbo.Orders'', @stats_id = 1;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_stats_histogram
    @database_name sysname = NULL,
    @table sysname = N''dbo.Orders'',
    @stats_id int = 1
AS
-- Toolkit 39_advanced_tuning.sql section 39.1: STATISTICS ON A TABLE + HISTOGRAM (2016 SP1 CU2+)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT s.stats_id, s.name AS stats_name, s.auto_created, s.has_filter, s.filter_definition,
       STUFF((SELECT N'''', '''' + c.name FROM sys.stats_columns sc JOIN sys.columns c ON c.object_id = sc.object_id AND c.column_id = sc.column_id
              WHERE sc.object_id = s.object_id AND sc.stats_id = s.stats_id ORDER BY sc.stats_column_id
              FOR XML PATH(''''''''), TYPE).value(''''.'''', ''''nvarchar(max)''''), 1, 2, N'''''''') AS columns,
       sp.last_updated, sp.rows, sp.rows_sampled, sp.steps, sp.modification_counter, sp.persisted_sample_percent
FROM sys.stats AS s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
WHERE s.object_id = OBJECT_ID(@table)
ORDER BY s.stats_id;


SELECT step_number, range_high_key, range_rows, equal_rows, distinct_range_rows, average_range_rows
FROM sys.dm_db_stats_histogram(OBJECT_ID(@table), @stats_id)
ORDER BY step_number;'';
EXEC @hc_exec @hc_sql, N''@table sysname, @stats_id int'', @table = @table, @stats_id = @stats_id;
',
    @fallback_definition = NULL;
GO

/* 39.2  ASCENDING KEY PROBLEM (new rows beyond the last histogram step)   (39_advanced_tuning.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_ascending_key', @section = N'39.2', @source_file = N'39_advanced_tuning.sql',
    @title = N'ASCENDING KEY PROBLEM (new rows beyond the last histogram step)', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_ascending_key @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_ascending_key
    @database_name sysname = NULL
AS
-- Toolkit 39_advanced_tuning.sql section 39.2: ASCENDING KEY PROBLEM (new rows beyond the last histogram step)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT TOP (3) step_number, range_high_key, equal_rows, range_rows
FROM sys.dm_db_stats_histogram(OBJECT_ID(@tbl), @stats_id)
ORDER BY step_number DESC;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 39.3  STATS PAST THE AUTO-UPDATE THRESHOLD BUT NOT YET UPDATED   (39_advanced_tuning.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_stats_past_threshold', @section = N'39.3', @source_file = N'39_advanced_tuning.sql',
    @title = N'STATS PAST THE AUTO-UPDATE THRESHOLD BUT NOT YET UPDATED', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_stats_past_threshold @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_stats_past_threshold
    @database_name sysname = NULL
AS
-- Toolkit 39_advanced_tuning.sql section 39.3: STATS PAST THE AUTO-UPDATE THRESHOLD BUT NOT YET UPDATED
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT OBJECT_SCHEMA_NAME(s.object_id) + N''''.'''' + OBJECT_NAME(s.object_id) AS table_name, s.name AS stats_name,
       sp.rows, sp.modification_counter, sp.last_updated,
       CAST(CASE WHEN sp.rows <= 500 THEN 500
                 WHEN 500 + 0.2 * sp.rows < SQRT(1000.0 * sp.rows) THEN 500 + 0.2 * sp.rows
                 ELSE SQRT(1000.0 * sp.rows) END AS bigint) AS threshold
FROM sys.stats AS s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
WHERE OBJECTPROPERTY(s.object_id, ''''IsUserTable'''') = 1
  AND sp.modification_counter > CASE WHEN sp.rows <= 500 THEN 500
                                     WHEN 500 + 0.2 * sp.rows < SQRT(1000.0 * sp.rows) THEN 500 + 0.2 * sp.rows
                                     ELSE SQRT(1000.0 * sp.rows) END
ORDER BY sp.modification_counter DESC;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 39.4  ESTIMATED vs ACTUAL ROWS FOR A RUNNING QUERY (cardinality problems)   (39_advanced_tuning.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_est_vs_actual_rows', @section = N'39.4', @source_file = N'39_advanced_tuning.sql',
    @title = N'ESTIMATED vs ACTUAL ROWS FOR A RUNNING QUERY (cardinality problems)', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_est_vs_actual_rows @database_name = N''YourDB'', @spid = 55;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_est_vs_actual_rows
    @database_name sysname = NULL,
    @spid int = 55
AS
-- Toolkit 39_advanced_tuning.sql section 39.4: ESTIMATED vs ACTUAL ROWS FOR A RUNNING QUERY (cardinality problems)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT node_id, physical_operator_name, OBJECT_NAME(object_id) AS object_name, index_id,
       estimate_row_count, row_count,
       CAST(row_count * 1.0 / NULLIF(estimate_row_count, 0) AS decimal(18,2)) AS actual_vs_estimate,
       elapsed_time_ms, cpu_time_ms, logical_read_count
FROM sys.dm_exec_query_profiles
WHERE session_id = @spid
ORDER BY ABS(row_count - estimate_row_count) DESC;'';
EXEC @hc_exec @hc_sql, N''@spid int'', @spid = @spid;
',
    @fallback_definition = NULL;
GO

/* 39.5  PARALLELISM: WHO GOES PARALLEL, AND SKEW   (39_advanced_tuning.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_parallelism', @section = N'39.5', @source_file = N'39_advanced_tuning.sql',
    @title = N'PARALLELISM: WHO GOES PARALLEL, AND SKEW', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_parallelism;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_parallelism
AS
-- Toolkit 39_advanced_tuning.sql section 39.5: PARALLELISM: WHO GOES PARALLEL, AND SKEW
SET NOCOUNT ON;
SELECT TOP (25) qs.execution_count, qs.last_dop, qs.min_dop, qs.max_dop,
       qs.total_worker_time / qs.execution_count / 1000   AS avg_cpu_ms,
       qs.total_elapsed_time / qs.execution_count / 1000  AS avg_duration_ms,
       CAST(1.0 * qs.total_worker_time / NULLIF(qs.total_elapsed_time, 0) AS decimal(10,2)) AS cpu_to_duration,
       SUBSTRING(t.text, qs.statement_start_offset / 2 + 1, 200) AS statement_start
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
WHERE qs.max_dop > 1
ORDER BY qs.total_worker_time DESC;

SELECT t.session_id, COUNT(*) AS tasks, MAX(t.exec_context_id) AS max_context,
       SUM(CASE WHEN t.task_state = ''RUNNING''   THEN 1 ELSE 0 END) AS running,
       SUM(CASE WHEN t.task_state = ''SUSPENDED'' THEN 1 ELSE 0 END) AS suspended,
       SUM(CASE WHEN t.task_state = ''RUNNABLE''  THEN 1 ELSE 0 END) AS runnable
FROM sys.dm_os_tasks AS t
WHERE t.session_id > 50
GROUP BY t.session_id
HAVING COUNT(*) > 1
ORDER BY tasks DESC;

SELECT wt.session_id, wt.exec_context_id, wt.wait_type, wt.wait_duration_ms, wt.resource_description
FROM sys.dm_os_waiting_tasks AS wt
WHERE wt.wait_type IN (N''CXPACKET'', N''CXCONSUMER'', N''CXSYNC_PORT'', N''CXSYNC_CONSUMER'')
ORDER BY wt.session_id, wt.exec_context_id;
',
    @fallback_definition = NULL;
GO

/* 39.6  COMPILE COST & OPTIMIZER TIMEOUTS   (39_advanced_tuning.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_compile_cost', @section = N'39.6', @source_file = N'39_advanced_tuning.sql',
    @title = N'COMPILE COST & OPTIMIZER TIMEOUTS', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_compile_cost @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_compile_cost
    @database_name sysname = NULL
AS
-- Toolkit 39_advanced_tuning.sql section 39.6: COMPILE COST & OPTIMIZER TIMEOUTS
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT counter, occurrence, value
FROM sys.dm_exec_query_optimizer_info
WHERE counter IN (N''''optimizations'''', N''''elapsed time'''', N''''trivial plan'''', N''''search 0'''', N''''search 1'''', N''''search 2'''',
                  N''''timeout'''', N''''memory limit exceeded'''', N''''tables'''', N''''hints'''');

SELECT TOP (25) q.query_id, q.count_compiles,
       q.avg_compile_duration / 1000.0 AS avg_compile_ms, q.last_compile_duration / 1000.0 AS last_compile_ms,
       q.avg_compile_memory_kb, q.max_compile_memory_kb,
       LEFT(qt.query_sql_text, 200) AS query_start
FROM sys.query_store_query AS q
JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
ORDER BY q.avg_compile_duration * q.count_compiles DESC;

WITH XMLNAMESPACES (DEFAULT ''''http://schemas.microsoft.com/sqlserver/2004/07/showplan'''')
SELECT TOP (25) qs.execution_count, qs.total_worker_time / 1000 AS total_cpu_ms, t.text, qp.query_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
WHERE qp.query_plan.exist(''''//StmtSimple[@StatementOptmEarlyAbortReason="TimeOut"]'''') = 1
ORDER BY qs.total_worker_time DESC;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 39.7  PLAN GUIDES - CURRENT DB (forgotten ones cause odd plans)   (39_advanced_tuning.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_plan_guides', @section = N'39.7', @source_file = N'39_advanced_tuning.sql',
    @title = N'PLAN GUIDES - CURRENT DB (forgotten ones cause odd plans)', @tags = N'BOX,MI,SQLDB',
    @usage = N'EXEC dbo.HC_plan_guides @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_plan_guides
    @database_name sysname = NULL
AS
-- Toolkit 39_advanced_tuning.sql section 39.7: PLAN GUIDES - CURRENT DB (forgotten ones cause odd plans)
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT pg.plan_guide_id, pg.name, pg.is_disabled, pg.scope_type_desc,
       OBJECT_NAME(pg.scope_object_id) AS scope_object, pg.hints, LEFT(pg.query_text, 200) AS query_text,
       v.msgnum AS validation_error, v.message AS validation_message
FROM sys.plan_guides AS pg
OUTER APPLY sys.fn_validate_plan_guide(pg.plan_guide_id) AS v;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 39.8  RESOURCE GOVERNOR   (39_advanced_tuning.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_resource_governor', @section = N'39.8', @source_file = N'39_advanced_tuning.sql',
    @title = N'RESOURCE GOVERNOR', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_resource_governor;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_resource_governor
AS
-- Toolkit 39_advanced_tuning.sql section 39.8: RESOURCE GOVERNOR
SET NOCOUNT ON;
SELECT c.is_enabled, OBJECT_SCHEMA_NAME(c.classifier_function_id, 1) + N''.'' + OBJECT_NAME(c.classifier_function_id, 1) AS classifier_function,
       dc.is_reconfiguration_pending
FROM sys.resource_governor_configuration AS c
CROSS JOIN sys.dm_resource_governor_configuration AS dc;

SELECT p.name AS pool, p.min_cpu_percent, p.max_cpu_percent, p.cap_cpu_percent,
       p.min_memory_percent, p.max_memory_percent,
       p.total_cpu_usage_ms, p.used_memory_kb / 1024 AS used_mb, p.target_memory_kb / 1024 AS target_mb,
       p.active_memgrant_count, p.memgrant_waiter_count
FROM sys.dm_resource_governor_resource_pools AS p;

SELECT g.name AS workload_group, p.name AS pool, g.total_request_count, g.active_request_count,
       g.queued_request_count, g.total_queued_request_count, g.total_cpu_usage_ms, g.max_request_cpu_time_ms,
       g.total_cpu_limit_violation_count, g.blocked_task_count,
       g.request_max_memory_grant_percent, g.max_dop, g.group_max_requests
FROM sys.dm_resource_governor_workload_groups AS g
JOIN sys.dm_resource_governor_resource_pools AS p ON p.pool_id = g.pool_id;

SELECT s.session_id, s.login_name, s.program_name, g.name AS workload_group
FROM sys.dm_exec_sessions AS s
JOIN sys.dm_resource_governor_workload_groups AS g ON g.group_id = s.group_id
WHERE s.is_user_process = 1;
',
    @fallback_definition = NULL;
GO

/* 39.9  IN-MEMORY OLTP (memory-optimized tables) - CURRENT DB   (39_advanced_tuning.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_inmemory_oltp', @section = N'39.9', @source_file = N'39_advanced_tuning.sql',
    @title = N'IN-MEMORY OLTP (memory-optimized tables) - CURRENT DB', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_inmemory_oltp @database_name = N''YourDB'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_inmemory_oltp
    @database_name sysname = NULL
AS
-- Toolkit 39_advanced_tuning.sql section 39.9: IN-MEMORY OLTP (memory-optimized tables) - CURRENT DB
SET NOCOUNT ON;
IF @database_name IS NULL AND CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 5 SET @database_name = DB_NAME();
IF DB_ID(@database_name) IS NULL
BEGIN RAISERROR(N''Pass @database_name = N''''YourDB'''' (an online database on this instance).'', 16, 1); RETURN; END;
DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N''.sys.sp_executesql'';
DECLARE @hc_sql nvarchar(max) = N''SELECT OBJECT_SCHEMA_NAME(t.object_id) + N''''.'''' + OBJECT_NAME(t.object_id) AS table_name, t.durability_desc,
       ms.memory_allocated_for_table_kb / 1024 AS table_alloc_mb, ms.memory_used_by_table_kb / 1024 AS table_used_mb,
       ms.memory_allocated_for_indexes_kb / 1024 AS index_alloc_mb, ms.memory_used_by_indexes_kb / 1024 AS index_used_mb
FROM sys.tables AS t
JOIN sys.dm_db_xtp_table_memory_stats AS ms ON ms.object_id = t.object_id
WHERE t.is_memory_optimized = 1
ORDER BY ms.memory_allocated_for_table_kb DESC;

SELECT OBJECT_NAME(h.object_id) AS table_name, i.name AS index_name, h.total_bucket_count, h.empty_bucket_count,
       CAST(100.0 * h.empty_bucket_count / h.total_bucket_count AS decimal(5,2)) AS empty_bucket_pct,
       h.avg_chain_length, h.max_chain_length
FROM sys.dm_db_xtp_hash_index_stats AS h
JOIN sys.indexes AS i ON i.object_id = h.object_id AND i.index_id = h.index_id
ORDER BY h.avg_chain_length DESC;

SELECT SUM(pages_kb) / 1024 AS xtp_memory_mb FROM sys.dm_os_memory_clerks WHERE type = N''''MEMORYCLERK_XTP'''';
SELECT d.name, p.name AS bound_resource_pool
FROM sys.databases d LEFT JOIN sys.dm_resource_governor_resource_pools p ON p.pool_id = d.resource_pool_id
WHERE d.database_id > 4;'';
EXEC @hc_exec @hc_sql;
',
    @fallback_definition = NULL;
GO

/* 39.10  SPINLOCK CONTENTION (advanced - high CPU with low waits)   (39_advanced_tuning.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_spinlocks', @section = N'39.10', @source_file = N'39_advanced_tuning.sql',
    @title = N'SPINLOCK CONTENTION (advanced - high CPU with low waits)', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_spinlocks ORDER BY spins DESC;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER VIEW dbo.HC_spinlocks
AS
-- Toolkit 39_advanced_tuning.sql section 39.10: SPINLOCK CONTENTION (advanced - high CPU with low waits)
SELECT TOP (20) name, collisions, spins, spins_per_collision, sleep_time, backoffs
FROM sys.dm_os_spinlock_stats
ORDER BY spins DESC;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_spinlocks
AS
-- Toolkit 39_advanced_tuning.sql section 39.10: SPINLOCK CONTENTION (advanced - high CPU with low waits)
SET NOCOUNT ON;
SELECT TOP (20) name, collisions, spins, spins_per_collision, sleep_time, backoffs
FROM sys.dm_os_spinlock_stats
ORDER BY spins DESC;
';
GO

/* 40.1  RPO / RTO SCORECARD vs SLA - ONE RESULT SET   (40_rpo_rto_compliance.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_rpo_rto_scorecard', @section = N'40.1', @source_file = N'40_rpo_rto_compliance.sql',
    @title = N'RPO / RTO SCORECARD vs SLA - ONE RESULT SET', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_rpo_rto_scorecard @default_rpo_min = 15, @default_rto_min = 60, @restore_factor = 1.30, @zero_mb_per_s = 300, @days = 7, @ifi = ''Y'';',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_rpo_rto_scorecard
    @default_rpo_min int = 15,
    @default_rto_min int = 60,
    @restore_factor decimal(5,2) = 1.30,
    @zero_mb_per_s int = 300,
    @days int = 7,
    @ifi char(1) = ''Y''
AS
-- Toolkit 40_rpo_rto_compliance.sql section 40.1: RPO / RTO SCORECARD vs SLA - ONE RESULT SET
SET NOCOUNT ON;
IF CAST(SERVERPROPERTY(''EngineEdition'') AS int) NOT IN (5, 8)
    EXEC sys.sp_executesql
         N''SELECT TOP (1) @i = instant_file_initialization_enabled FROM sys.dm_server_services WHERE servicename LIKE N''''SQL Server (%'''''',
         N''@i char(1) OUTPUT'', @i = @ifi OUTPUT;

IF OBJECT_ID(''tempdb..#sla'') IS NOT NULL DROP TABLE #sla;
CREATE TABLE #sla (database_name sysname COLLATE DATABASE_DEFAULT PRIMARY KEY, tier varchar(20), rpo_minutes int, rto_minutes int);
IF OBJECT_ID(N''DBAdmin.dbo.DatabaseSLA'') IS NOT NULL
    EXEC (N''INSERT #sla (database_name, tier, rpo_minutes, rto_minutes) SELECT database_name, tier, rpo_minutes, rto_minutes FROM DBAdmin.dbo.DatabaseSLA;'');
INSERT #sla (database_name, tier, rpo_minutes, rto_minutes)
SELECT d.name, ''default'', @default_rpo_min, @default_rto_min
FROM sys.databases AS d
WHERE d.database_id > 4 AND NOT EXISTS (SELECT 1 FROM #sla AS s WHERE s.database_name = d.name);

WITH bk AS (
    SELECT d.name, d.recovery_model_desc, d.state_desc, d.replica_id,
           f.backup_finish_date AS last_full, f.backup_size AS full_bytes, f.dur_s AS full_dur_s,
           df.backup_finish_date AS last_diff, df.backup_size AS diff_bytes,
           lg.log_count, lg.log_bytes,
           (SELECT MAX(b.backup_finish_date) FROM msdb.dbo.backupset AS b WHERE b.database_name = d.name AND b.type = ''L'') AS last_log,
           (SELECT SUM(CAST(mf.size AS bigint)) * 8 / 1024 FROM sys.master_files AS mf WHERE mf.database_id = d.database_id AND mf.type = 0) AS data_mb,
           (SELECT SUM(CAST(mf.size AS bigint)) * 8 / 1024 FROM sys.master_files AS mf WHERE mf.database_id = d.database_id AND mf.type = 1) AS log_mb
    FROM sys.databases AS d
    OUTER APPLY (SELECT TOP (1) b.backup_finish_date, b.backup_size, b.checkpoint_lsn,
                        NULLIF(DATEDIFF(SECOND, b.backup_start_date, b.backup_finish_date), 0) AS dur_s
                 FROM msdb.dbo.backupset AS b
                 WHERE b.database_name = d.name AND b.type = ''D'' AND b.is_copy_only = 0
                 ORDER BY b.backup_finish_date DESC) AS f
    OUTER APPLY (SELECT TOP (1) b.backup_finish_date, b.backup_size
                 FROM msdb.dbo.backupset AS b
                 WHERE b.database_name = d.name AND b.type = ''I'' AND b.differential_base_lsn = f.checkpoint_lsn
                 ORDER BY b.backup_finish_date DESC) AS df
    OUTER APPLY (SELECT COUNT(*) AS log_count, SUM(b.backup_size) AS log_bytes
                 FROM msdb.dbo.backupset AS b
                 WHERE b.database_name = d.name AND b.type = ''L''
                   AND b.backup_finish_date > COALESCE(df.backup_finish_date, f.backup_finish_date)) AS lg
    WHERE d.database_id > 4 AND d.source_database_id IS NULL
),
gaps AS (
    SELECT database_name, MAX(gap_min) AS worst_gap_min
    FROM (SELECT database_name,
                 DATEDIFF(MINUTE, LAG(backup_finish_date) OVER (PARTITION BY database_name ORDER BY backup_finish_date), backup_finish_date) AS gap_min
          FROM msdb.dbo.backupset
          WHERE type = ''L'' AND backup_finish_date >= DATEADD(DAY, -@days, GETDATE())) AS x
    GROUP BY database_name
),
sc AS (
SELECT
    bk.name AS database_name, s.tier, bk.recovery_model_desc, bk.state_desc,
    CASE WHEN bk.replica_id IS NULL THEN '''' WHEN sys.fn_hadr_backup_is_preferred_replica(bk.name) = 1
         THEN ''AG - backups here'' ELSE ''AG - backups on other replica'' END AS ag_backup_role,
    bk.last_full, bk.last_diff, bk.last_log,
    s.rpo_minutes AS rpo_sla_min,
    DATEDIFF(MINUTE, lp.latest, GETDATE())                     AS rpo_now_min,
    CASE WHEN bk.recovery_model_desc = ''SIMPLE'' THEN NULL ELSE g.worst_gap_min END AS worst_gap_min,
    s.rto_minutes AS rto_sla_min,
    CAST(rt.est_s / 60.0 AS decimal(10,1))                     AS est_restore_min,
    bk.log_count AS logs_to_restore,
    CAST(bk.full_bytes / 1048576.0 / ISNULL(bk.full_dur_s, 1) AS decimal(10,1)) AS backup_mb_per_s,
    @ifi AS ifi_enabled,
    CASE
        WHEN bk.replica_id IS NOT NULL AND sys.fn_hadr_backup_is_preferred_replica(bk.name) = 0
             AND (lp.latest IS NULL OR DATEDIFF(MINUTE, lp.latest, GETDATE()) > s.rpo_minutes) THEN ''CHECK PREFERRED REPLICA''
        WHEN bk.last_full IS NULL                                                         THEN ''RPO BREACH - no full backup''
        WHEN bk.recovery_model_desc = ''SIMPLE'' AND s.rpo_minutes < 1440                   THEN ''RPO BREACH - SIMPLE recovery cannot meet SLA''
        WHEN DATEDIFF(MINUTE, lp.latest, GETDATE()) > s.rpo_minutes                       THEN ''RPO BREACH - now''
        WHEN bk.recovery_model_desc <> ''SIMPLE'' AND g.worst_gap_min > s.rpo_minutes       THEN ''RPO BREACHED in last '' + CAST(@days AS varchar(3)) + '' days''
        WHEN rt.est_s / 60.0 > s.rto_minutes                                              THEN ''RTO RISK - restore too slow (add diffs / faster storage / HA)''
        ELSE ''OK'' END AS status
FROM bk
JOIN #sla AS s ON s.database_name = bk.name
LEFT JOIN gaps AS g ON g.database_name = bk.name
CROSS APPLY (SELECT MAX(v) AS latest
             FROM (VALUES (bk.last_full), (bk.last_diff),
                          (CASE WHEN bk.recovery_model_desc <> ''SIMPLE'' THEN bk.last_log END)) AS x(v)) AS lp
CROSS APPLY (SELECT (ISNULL(bk.full_bytes, 0) + ISNULL(bk.diff_bytes, 0) + ISNULL(bk.log_bytes, 0)) / 1048576.0
                    / NULLIF(bk.full_bytes / 1048576.0 / ISNULL(bk.full_dur_s, 1), 0) * @restore_factor
                  + CASE WHEN @ifi = ''N'' THEN ISNULL(bk.data_mb, 0) * 1.0 / @zero_mb_per_s ELSE 0 END
                  + ISNULL(bk.log_mb, 0) * 1.0 / @zero_mb_per_s AS est_s) AS rt
)
SELECT * FROM sc
ORDER BY CASE WHEN status = ''OK'' THEN 1 ELSE 0 END, database_name
OPTION (RECOMPILE);
',
    @fallback_definition = NULL;
GO

/* 40.2  WORST-CASE RPO DETAIL - WHEN DID THE BIG GAPS HAPPEN?   (40_rpo_rto_compliance.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_rpo_gaps', @section = N'40.2', @source_file = N'40_rpo_rto_compliance.sql',
    @title = N'WORST-CASE RPO DETAIL - WHEN DID THE BIG GAPS HAPPEN?', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_rpo_gaps(DEFAULT, DEFAULT);  -- @gap_days = 7, @gap_threshold_min = 15',
    @min_version = NULL,
    @sort_hint = N'ORDER BY gap_min DESC',
    @definition = N'CREATE OR ALTER FUNCTION dbo.HC_rpo_gaps
(
    @gap_days int = 7,
    @gap_threshold_min int = 15
)
RETURNS TABLE
AS
-- Toolkit 40_rpo_rto_compliance.sql section 40.2: WORST-CASE RPO DETAIL - WHEN DID THE BIG GAPS HAPPEN?
RETURN
(
WITH l AS (
    SELECT database_name, backup_finish_date,
           LAG(backup_finish_date) OVER (PARTITION BY database_name ORDER BY backup_finish_date) AS prev_finish
    FROM msdb.dbo.backupset
    WHERE type = ''L'' AND backup_finish_date >= DATEADD(DAY, -@gap_days, GETDATE())
)
SELECT database_name, prev_finish AS gap_from, backup_finish_date AS gap_to,
       DATEDIFF(MINUTE, prev_finish, backup_finish_date) AS gap_min
FROM l
WHERE DATEDIFF(MINUTE, prev_finish, backup_finish_date) > @gap_threshold_min
UNION ALL
SELECT database_name, MAX(backup_finish_date), GETDATE(), DATEDIFF(MINUTE, MAX(backup_finish_date), GETDATE())
FROM msdb.dbo.backupset WHERE type = ''L''
GROUP BY database_name
HAVING DATEDIFF(MINUTE, MAX(backup_finish_date), GETDATE()) > @gap_threshold_min
);
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_rpo_gaps
    @gap_days int = 7,
    @gap_threshold_min int = 15
AS
-- Toolkit 40_rpo_rto_compliance.sql section 40.2: WORST-CASE RPO DETAIL - WHEN DID THE BIG GAPS HAPPEN?
SET NOCOUNT ON;
WITH l AS (
    SELECT database_name, backup_finish_date,
           LAG(backup_finish_date) OVER (PARTITION BY database_name ORDER BY backup_finish_date) AS prev_finish
    FROM msdb.dbo.backupset
    WHERE type = ''L'' AND backup_finish_date >= DATEADD(DAY, -@gap_days, GETDATE())
)
SELECT database_name, prev_finish AS gap_from, backup_finish_date AS gap_to,
       DATEDIFF(MINUTE, prev_finish, backup_finish_date) AS gap_min
FROM l
WHERE DATEDIFF(MINUTE, prev_finish, backup_finish_date) > @gap_threshold_min
UNION ALL
SELECT database_name, MAX(backup_finish_date), GETDATE(), DATEDIFF(MINUTE, MAX(backup_finish_date), GETDATE())
FROM msdb.dbo.backupset WHERE type = ''L''
GROUP BY database_name
HAVING DATEDIFF(MINUTE, MAX(backup_finish_date), GETDATE()) > @gap_threshold_min
ORDER BY gap_min DESC;
';
GO

/* 40.3  BROKEN LOG CHAINS (an unrestorable point in time)   (40_rpo_rto_compliance.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_broken_log_chains', @section = N'40.3', @source_file = N'40_rpo_rto_compliance.sql',
    @title = N'BROKEN LOG CHAINS (an unrestorable point in time)', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_broken_log_chains ORDER BY log_backup_after_gap DESC;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY backup_start_date DESC',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_broken_log_chains
AS
-- Toolkit 40_rpo_rto_compliance.sql section 40.3: BROKEN LOG CHAINS (an unrestorable point in time)
WITH l AS (
    SELECT database_name, database_guid, backup_start_date, first_lsn, last_lsn, server_name,
           LAG(last_lsn)          OVER (PARTITION BY database_name, database_guid ORDER BY first_lsn) AS prev_last_lsn,
           LAG(backup_start_date) OVER (PARTITION BY database_name, database_guid ORDER BY first_lsn) AS prev_start
    FROM msdb.dbo.backupset
    WHERE type = ''L'' AND is_copy_only = 0 AND backup_start_date >= DATEADD(DAY, -14, GETDATE())
)
SELECT database_name, prev_start AS previous_log_backup, backup_start_date AS log_backup_after_gap,
       prev_last_lsn, first_lsn, server_name,
       ''CHAIN BROKEN - point-in-time restore impossible between these backups'' AS finding
FROM l
WHERE prev_last_lsn IS NOT NULL AND first_lsn > prev_last_lsn;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_broken_log_chains
AS
-- Toolkit 40_rpo_rto_compliance.sql section 40.3: BROKEN LOG CHAINS (an unrestorable point in time)
SET NOCOUNT ON;
WITH l AS (
    SELECT database_name, database_guid, backup_start_date, first_lsn, last_lsn, server_name,
           LAG(last_lsn)          OVER (PARTITION BY database_name, database_guid ORDER BY first_lsn) AS prev_last_lsn,
           LAG(backup_start_date) OVER (PARTITION BY database_name, database_guid ORDER BY first_lsn) AS prev_start
    FROM msdb.dbo.backupset
    WHERE type = ''L'' AND is_copy_only = 0 AND backup_start_date >= DATEADD(DAY, -14, GETDATE())
)
SELECT database_name, prev_start AS previous_log_backup, backup_start_date AS log_backup_after_gap,
       prev_last_lsn, first_lsn, server_name,
       ''CHAIN BROKEN - point-in-time restore impossible between these backups'' AS finding
FROM l
WHERE prev_last_lsn IS NOT NULL AND first_lsn > prev_last_lsn
ORDER BY backup_start_date DESC;
';
GO

/* 40.4  CHAIN-BREAKING / ROGUE BACKUPS   (40_rpo_rto_compliance.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_rogue_backups', @section = N'40.4', @source_file = N'40_rpo_rto_compliance.sql',
    @title = N'CHAIN-BREAKING / ROGUE BACKUPS', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_rogue_backups;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_rogue_backups
AS
-- Toolkit 40_rpo_rto_compliance.sql section 40.4: CHAIN-BREAKING / ROGUE BACKUPS
SET NOCOUNT ON;
SELECT bs.database_name, bs.type, bs.backup_start_date, bs.user_name, bs.server_name,
       bs.is_copy_only, bs.is_snapshot, bmf.device_type, bmf.physical_device_name,
       CASE WHEN bmf.physical_device_name = N''NUL'' THEN ''BACKUP TO NUL - chain broken''
            WHEN bmf.device_type = 7 AND bs.is_copy_only = 0 THEN ''Virtual device (VSS / VM snapshot / 3rd-party) - not COPY_ONLY''
            WHEN bs.is_snapshot = 1 AND bs.is_copy_only = 0 THEN ''Snapshot backup - not COPY_ONLY''
            ELSE ''Full by a different user/tool than usual - review'' END AS finding
FROM msdb.dbo.backupset AS bs
JOIN msdb.dbo.backupmediafamily AS bmf ON bmf.media_set_id = bs.media_set_id
WHERE bs.backup_start_date >= DATEADD(DAY, -30, GETDATE())
  AND (   bmf.physical_device_name = N''NUL''
       OR (bmf.device_type = 7 AND bs.is_copy_only = 0)
       OR (bs.is_snapshot = 1 AND bs.is_copy_only = 0)
       OR (bs.type = ''D'' AND bs.is_copy_only = 0
           AND bs.user_name NOT IN (SELECT TOP (1) WITH TIES b2.user_name
                                    FROM msdb.dbo.backupset AS b2
                                    WHERE b2.database_name = bs.database_name AND b2.type = ''D''
                                    GROUP BY b2.user_name ORDER BY COUNT(*) DESC)))
ORDER BY bs.backup_start_date DESC;

WITH r AS (
    SELECT database_name, backup_start_date, recovery_model,
           LAG(recovery_model) OVER (PARTITION BY database_name ORDER BY backup_start_date) AS prev_model
    FROM msdb.dbo.backupset WHERE backup_start_date >= DATEADD(DAY, -30, GETDATE())
)
SELECT database_name, backup_start_date, prev_model, recovery_model
FROM r WHERE prev_model IS NOT NULL AND prev_model <> recovery_model;

EXEC sys.xp_readerrorlog 0, 1, N''Setting database option RECOVERY'';
',
    @fallback_definition = NULL;
GO

/* 40.5  BACKUP QUALITY (last 7 days)   (40_rpo_rto_compliance.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_backup_quality', @section = N'40.5', @source_file = N'40_rpo_rto_compliance.sql',
    @title = N'BACKUP QUALITY (last 7 days)', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_backup_quality;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_backup_quality
AS
-- Toolkit 40_rpo_rto_compliance.sql section 40.5: BACKUP QUALITY (last 7 days)
SET NOCOUNT ON;
SELECT bs.database_name, bs.type, bs.backup_finish_date,
       bs.has_backup_checksums, bs.is_damaged, bs.has_incomplete_metadata,
       CASE WHEN bs.compressed_backup_size < bs.backup_size THEN 1 ELSE 0 END AS is_compressed,
       bs.key_algorithm AS encryption,
       bmf.physical_device_name
FROM msdb.dbo.backupset AS bs
JOIN msdb.dbo.backupmediafamily AS bmf ON bmf.media_set_id = bs.media_set_id
WHERE bs.backup_finish_date >= DATEADD(DAY, -7, GETDATE())
  AND (bs.has_backup_checksums = 0 OR bs.is_damaged = 1 OR bs.has_incomplete_metadata = 1)
ORDER BY bs.backup_finish_date DESC;
',
    @fallback_definition = NULL;
GO

/* 40.6  DO THE FILES NEEDED FOR A RESTORE STILL EXIST?   (40_rpo_rto_compliance.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_backup_files_exist', @section = N'40.6', @source_file = N'40_rpo_rto_compliance.sql',
    @title = N'DO THE FILES NEEDED FOR A RESTORE STILL EXIST?', @tags = N'BOX',
    @usage = N'EXEC dbo.HC_backup_files_exist;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_backup_files_exist
AS
-- Toolkit 40_rpo_rto_compliance.sql section 40.6: DO THE FILES NEEDED FOR A RESTORE STILL EXIST?
SET NOCOUNT ON;
IF OBJECT_ID(''tempdb..#files'') IS NOT NULL DROP TABLE #files;
CREATE TABLE #files (database_name sysname, type char(1), backup_finish_date datetime, path nvarchar(260), file_exists bit NULL);

INSERT #files (database_name, type, backup_finish_date, path)
SELECT bs.database_name, bs.type, bs.backup_finish_date, bmf.physical_device_name
FROM msdb.dbo.backupset AS bs
JOIN msdb.dbo.backupmediafamily AS bmf ON bmf.media_set_id = bs.media_set_id
WHERE bmf.device_type = 2
  AND bs.backup_finish_date >= (SELECT MAX(f.backup_finish_date) FROM msdb.dbo.backupset AS f
                                WHERE f.database_name = bs.database_name AND f.type = ''D'' AND f.is_copy_only = 0);

DECLARE @path nvarchar(260), @exists int;
DECLARE fc CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT path FROM #files;
OPEN fc; FETCH NEXT FROM fc INTO @path;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC master.dbo.xp_fileexist @path, @exists OUTPUT;
    UPDATE #files SET file_exists = @exists WHERE path = @path;
    FETCH NEXT FROM fc INTO @path;
END
CLOSE fc; DEALLOCATE fc;

SELECT database_name, type, backup_finish_date, path, file_exists
FROM #files
WHERE file_exists = 0
ORDER BY database_name, backup_finish_date;
',
    @fallback_definition = NULL;
GO

/* 40.7  RESTORE CHAIN LENGTH (long chains = long RTO, more ways to fail)   (40_rpo_rto_compliance.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_restore_chain_length', @section = N'40.7', @source_file = N'40_rpo_rto_compliance.sql',
    @title = N'RESTORE CHAIN LENGTH (long chains = long RTO, more ways to fail)', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_restore_chain_length;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_restore_chain_length
AS
-- Toolkit 40_rpo_rto_compliance.sql section 40.7: RESTORE CHAIN LENGTH (long chains = long RTO, more ways to fail)
SET NOCOUNT ON;
SELECT d.name, d.recovery_model_desc,
       f.backup_finish_date AS last_full,
       df.backup_finish_date AS last_diff,
       (SELECT COUNT(*) FROM msdb.dbo.backupset AS b
        WHERE b.database_name = d.name AND b.type = ''L''
          AND b.backup_finish_date > COALESCE(df.backup_finish_date, f.backup_finish_date)) AS logs_to_restore,
       CASE WHEN df.backup_finish_date IS NULL AND DATEDIFF(DAY, f.backup_finish_date, GETDATE()) >= 2
            THEN ''Add DIFF backups to shorten the chain'' ELSE '''' END AS advice
FROM sys.databases AS d
OUTER APPLY (SELECT TOP (1) backup_finish_date, checkpoint_lsn FROM msdb.dbo.backupset
             WHERE database_name = d.name AND type = ''D'' AND is_copy_only = 0 ORDER BY backup_finish_date DESC) AS f
OUTER APPLY (SELECT TOP (1) backup_finish_date FROM msdb.dbo.backupset
             WHERE database_name = d.name AND type = ''I'' AND differential_base_lsn = f.checkpoint_lsn ORDER BY backup_finish_date DESC) AS df
WHERE d.database_id > 4 AND d.recovery_model_desc <> ''SIMPLE''
ORDER BY logs_to_restore DESC;
',
    @fallback_definition = NULL;
GO

/* 40.8  CRASH-RECOVERY RTO (how long a restart / failover takes)   (40_rpo_rto_compliance.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_crash_recovery_rto', @section = N'40.8', @source_file = N'40_rpo_rto_compliance.sql',
    @title = N'CRASH-RECOVERY RTO (how long a restart / failover takes)', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_crash_recovery_rto;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_crash_recovery_rto
AS
-- Toolkit 40_rpo_rto_compliance.sql section 40.8: CRASH-RECOVERY RTO (how long a restart / failover takes)
SET NOCOUNT ON;
SELECT d.name, d.target_recovery_time_in_seconds,
       ls.log_recovery_size_mb, ls.log_since_last_checkpoint_mb,
       ls.total_vlf_count, ls.active_vlf_count, ls.total_log_size_mb,
       CASE WHEN d.target_recovery_time_in_seconds = 0 THEN ''Set TARGET_RECOVERY_TIME = 60 SECONDS; '' ELSE '''' END
     + CASE WHEN ls.total_vlf_count > 1000 THEN ''Too many VLFs (19.3); '' ELSE '''' END
     + CASE WHEN ls.log_recovery_size_mb > 10240 THEN ''Large recovery size - long txn open? (02 2.5); '' ELSE '''' END AS advice
FROM sys.databases AS d
CROSS APPLY sys.dm_db_log_stats(d.database_id) AS ls
WHERE d.state_desc = N''ONLINE'' AND d.database_id <> 2
ORDER BY ls.log_recovery_size_mb DESC;
',
    @fallback_definition = NULL;
GO

/* 40.9  RESTORE TESTS - EVIDENCE THAT BACKUPS ACTUALLY WORK   (40_rpo_rto_compliance.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_restore_tests', @section = N'40.9', @source_file = N'40_rpo_rto_compliance.sql',
    @title = N'RESTORE TESTS - EVIDENCE THAT BACKUPS ACTUALLY WORK', @tags = N'BOX,MI',
    @usage = N'SELECT * FROM dbo.HC_restore_tests ORDER BY days_ago DESC;',
    @min_version = NULL,
    @sort_hint = N'ORDER BY days_ago DESC',
    @definition = N'CREATE OR ALTER VIEW dbo.HC_restore_tests
AS
-- Toolkit 40_rpo_rto_compliance.sql section 40.9: RESTORE TESTS - EVIDENCE THAT BACKUPS ACTUALLY WORK
SELECT bs.database_name AS source_db, bs.server_name AS source_server,
       MAX(rh.restore_date) AS last_test_restore,
       DATEDIFF(DAY, MAX(rh.restore_date), GETDATE()) AS days_ago
FROM msdb.dbo.restorehistory AS rh
JOIN msdb.dbo.backupset AS bs ON bs.backup_set_id = rh.backup_set_id
GROUP BY bs.database_name, bs.server_name;
',
    @fallback_definition = N'CREATE OR ALTER PROCEDURE dbo.HC_restore_tests
AS
-- Toolkit 40_rpo_rto_compliance.sql section 40.9: RESTORE TESTS - EVIDENCE THAT BACKUPS ACTUALLY WORK
SET NOCOUNT ON;
SELECT bs.database_name AS source_db, bs.server_name AS source_server,
       MAX(rh.restore_date) AS last_test_restore,
       DATEDIFF(DAY, MAX(rh.restore_date), GETDATE()) AS days_ago
FROM msdb.dbo.restorehistory AS rh
JOIN msdb.dbo.backupset AS bs ON bs.backup_set_id = rh.backup_set_id
GROUP BY bs.database_name, bs.server_name
ORDER BY days_ago DESC;
';
GO

/* 40.10  HA / DR COVERAGE PER DATABASE   (40_rpo_rto_compliance.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_ha_dr_coverage', @section = N'40.10', @source_file = N'40_rpo_rto_compliance.sql',
    @title = N'HA / DR COVERAGE PER DATABASE', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_ha_dr_coverage;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_ha_dr_coverage
AS
-- Toolkit 40_rpo_rto_compliance.sql section 40.10: HA / DR COVERAGE PER DATABASE
SET NOCOUNT ON;
SELECT d.name, d.recovery_model_desc,
       ag.name AS availability_group,
       agx.replicas, agx.sync_replicas, agx.auto_failover_replicas, agx.has_listener,
       CASE WHEN lsp.primary_database IS NOT NULL THEN 1 ELSE 0 END AS log_shipping,
       CASE WHEN dm.mirroring_guid IS NOT NULL THEN 1 ELSE 0 END AS mirroring,
       CASE
           WHEN ag.name IS NOT NULL AND agx.auto_failover_replicas >= 2 THEN ''HA: AG sync + automatic failover''
           WHEN ag.name IS NOT NULL AND agx.sync_replicas >= 2         THEN ''HA: AG sync, MANUAL failover (someone must act)''
           WHEN ag.name IS NOT NULL                                    THEN ''DR: AG async only (data loss possible)''
           WHEN dm.mirroring_guid IS NOT NULL                          THEN ''Mirroring (deprecated)''
           WHEN lsp.primary_database IS NOT NULL                       THEN ''DR: log shipping (manual, RPO = LS interval)''
           ELSE ''BACKUPS ONLY - RTO = full restore time (40.1)'' END AS protection
FROM sys.databases AS d
LEFT JOIN sys.availability_databases_cluster AS adc ON adc.database_name = d.name
LEFT JOIN sys.availability_groups AS ag ON ag.group_id = adc.group_id
OUTER APPLY (SELECT COUNT(*) AS replicas,
                    SUM(CASE WHEN ar.availability_mode = 1 THEN 1 ELSE 0 END) AS sync_replicas,
                    SUM(CASE WHEN ar.failover_mode = 0 AND ar.availability_mode = 1 THEN 1 ELSE 0 END) AS auto_failover_replicas,
                    (SELECT COUNT(*) FROM sys.availability_group_listeners AS agl WHERE agl.group_id = ag.group_id) AS has_listener
             FROM sys.availability_replicas AS ar WHERE ar.group_id = ag.group_id) AS agx
LEFT JOIN msdb.dbo.log_shipping_primary_databases AS lsp ON lsp.primary_database = d.name
LEFT JOIN sys.database_mirroring AS dm ON dm.database_id = d.database_id AND dm.mirroring_guid IS NOT NULL
WHERE d.database_id > 4
ORDER BY protection DESC, d.name;
',
    @fallback_definition = NULL;
GO

/* 40.11  AG: CAN WE FAIL OVER WITHIN RTO / WITHOUT DATA LOSS RIGHT NOW?   (40_rpo_rto_compliance.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_ag_failover_rto', @section = N'40.11', @source_file = N'40_rpo_rto_compliance.sql',
    @title = N'AG: CAN WE FAIL OVER WITHIN RTO / WITHOUT DATA LOSS RIGHT NOW?', @tags = N'BOX',
    @usage = N'EXEC dbo.HC_ag_failover_rto;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_ag_failover_rto
AS
-- Toolkit 40_rpo_rto_compliance.sql section 40.11: AG: CAN WE FAIL OVER WITHIN RTO / WITHOUT DATA LOSS RIGHT NOW?
SET NOCOUNT ON;
SELECT ag.name AS ag_name, DB_NAME(drs.database_id) AS database_name, ar.replica_server_name AS secondary,
       ar.availability_mode_desc, ar.failover_mode_desc,
       drs.synchronization_state_desc, dcs.is_failover_ready,
       CAST(drs.redo_queue_size * 1.0 / NULLIF(drs.redo_rate, 0) AS decimal(18,1)) AS est_failover_redo_s,
       drs.log_send_queue_size AS unsent_log_kb,
       DATEDIFF(SECOND, drs.last_commit_time, p.last_commit_time) AS data_loss_s_if_forced,
       CASE WHEN ar.availability_mode = 1 AND dcs.is_failover_ready = 1 THEN ''Planned failover OK - no data loss''
            WHEN ar.availability_mode = 1 THEN ''SYNC but NOT failover ready - fix first (25.2)''
            ELSE ''ASYNC - only FORCE_FAILOVER_ALLOW_DATA_LOSS (or switch to SYNC and wait)'' END AS verdict
FROM sys.dm_hadr_database_replica_states AS drs
JOIN sys.availability_replicas AS ar ON ar.replica_id = drs.replica_id
JOIN sys.availability_groups AS ag ON ag.group_id = drs.group_id
JOIN sys.dm_hadr_database_replica_cluster_states AS dcs ON dcs.replica_id = drs.replica_id AND dcs.group_database_id = drs.group_database_id
JOIN sys.dm_hadr_database_replica_states AS p ON p.group_database_id = drs.group_database_id AND p.is_primary_replica = 1
WHERE drs.is_primary_replica = 0
ORDER BY ag.name, database_name, ar.replica_server_name;
',
    @fallback_definition = NULL;
GO

/* 41.1  PROBLEMS-ONLY HEALTH CHECK (0 rows = all good)   (41_proactive_monitoring_alerts.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_problems', @section = N'41.1', @source_file = N'41_proactive_monitoring_alerts.sql',
    @title = N'PROBLEMS-ONLY HEALTH CHECK (0 rows = all good)', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_problems @log_rpo_min = 30, @full_max_days = 7, @checkdb_days = 7, @disk_free_pct = 15, @log_used_pct = 80, @tempdb_free_pct = 20, @blocking_min = 5, @open_tran_min = 30, @cert_days = 30, @vlf_max = 1000;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_problems
    @log_rpo_min int = 30,
    @full_max_days int = 7,
    @checkdb_days int = 7,
    @disk_free_pct int = 15,
    @log_used_pct int = 80,
    @tempdb_free_pct int = 20,
    @blocking_min int = 5,
    @open_tran_min int = 30,
    @cert_days int = 30,
    @vlf_max int = 1000
AS
-- Toolkit 41_proactive_monitoring_alerts.sql section 41.1: PROBLEMS-ONLY HEALTH CHECK (0 rows = all good)
SET NOCOUNT ON;
DECLARE @issues TABLE (severity varchar(10), area varchar(30), item nvarchar(256), detail nvarchar(4000));
DECLARE @is_mi bit = CASE WHEN CAST(SERVERPROPERTY(''EngineEdition'') AS int) = 8 THEN 1 ELSE 0 END;

INSERT @issues SELECT ''CRITICAL'', ''Database'', name, ''State: '' + state_desc + '' / '' + user_access_desc
FROM sys.databases WHERE state_desc NOT IN (N''ONLINE'', N''RESTORING'') OR user_access_desc <> N''MULTI_USER'';

INSERT @issues SELECT ''WARNING'', ''Instance'', ''Restarted recently'', ''Up since '' + CONVERT(varchar(20), sqlserver_start_time, 120)
FROM sys.dm_os_sys_info WHERE sqlserver_start_time > DATEADD(HOUR, -24, GETDATE());

INSERT @issues
SELECT ''CRITICAL'', ''Backup'', d.name,
       CASE WHEN f.last_full IS NULL THEN ''No full backup ever''
            WHEN d.recovery_model_desc <> ''SIMPLE'' AND (l.last_log IS NULL OR l.last_log < DATEADD(MINUTE, -@log_rpo_min, GETDATE()))
                 THEN ''Last log backup: '' + ISNULL(CONVERT(varchar(20), l.last_log, 120), ''never'') + '' (RPO '' + CAST(@log_rpo_min AS varchar(5)) + '' min)''
            ELSE ''Last full '' + CONVERT(varchar(20), f.last_full, 120) + '', no recent diff'' END
FROM sys.databases AS d
OUTER APPLY (SELECT MAX(backup_finish_date) AS last_full FROM msdb.dbo.backupset WHERE database_name = d.name AND type = ''D'') AS f
OUTER APPLY (SELECT MAX(backup_finish_date) AS last_diff FROM msdb.dbo.backupset WHERE database_name = d.name AND type = ''I'') AS i
OUTER APPLY (SELECT MAX(backup_finish_date) AS last_log  FROM msdb.dbo.backupset WHERE database_name = d.name AND type = ''L'') AS l
WHERE d.database_id <> 2 AND d.state_desc = N''ONLINE'' AND d.source_database_id IS NULL AND d.is_in_standby = 0
  AND (d.replica_id IS NULL OR sys.fn_hadr_backup_is_preferred_replica(d.name) = 1)
  AND (   f.last_full IS NULL
       OR (f.last_full < DATEADD(DAY, -@full_max_days, GETDATE()) AND ISNULL(i.last_diff, ''19000101'') < DATEADD(DAY, -1, GETDATE()))
       OR (d.recovery_model_desc <> ''SIMPLE'' AND d.database_id > 4
           AND (l.last_log IS NULL OR l.last_log < DATEADD(MINUTE, -@log_rpo_min, GETDATE()))));

INSERT @issues SELECT ''WARNING'', ''Integrity'', name,
       ''Last good CHECKDB: '' + ISNULL(CONVERT(varchar(20), CAST(DATABASEPROPERTYEX(name, ''LastGoodCheckDbTime'') AS datetime), 120), ''never'')
FROM sys.databases
WHERE database_id <> 2 AND state_desc = N''ONLINE''
  AND ISNULL(CAST(DATABASEPROPERTYEX(name, ''LastGoodCheckDbTime'') AS datetime), ''19000101'') < DATEADD(DAY, -@checkdb_days, GETDATE());

INSERT @issues SELECT ''CRITICAL'', ''Integrity'', DB_NAME(database_id), ''Suspect page '' + CAST(file_id AS varchar(5)) + '':'' + CAST(page_id AS varchar(20))
       + '' event_type '' + CAST(event_type AS varchar(3)) + '' at '' + CONVERT(varchar(20), last_update_date, 120)
FROM msdb.dbo.suspect_pages WHERE last_update_date > DATEADD(DAY, -30, GETDATE());

INSERT @issues SELECT ''CRITICAL'', ''AlwaysOn'', ag.name + '' / '' + ar.replica_server_name,
       ISNULL(ars.connected_state_desc, ''?'') + '' / '' + ISNULL(ars.synchronization_health_desc, ''?'') + ISNULL('' / '' + ars.last_connect_error_description, '''')
FROM sys.availability_replicas ar
JOIN sys.availability_groups ag ON ag.group_id = ar.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id
WHERE ars.connected_state_desc <> ''CONNECTED'' OR ars.synchronization_health_desc <> ''HEALTHY'';

INSERT @issues SELECT ''CRITICAL'', ''AlwaysOn'', DB_NAME(drs.database_id) + '' on '' + ar.replica_server_name,
       drs.synchronization_state_desc + CASE WHEN drs.is_suspended = 1 THEN '' SUSPENDED ('' + drs.suspend_reason_desc + '')'' ELSE '''' END
     + '' send_queue_kb='' + CAST(ISNULL(drs.log_send_queue_size, 0) AS varchar(20)) + '' redo_queue_kb='' + CAST(ISNULL(drs.redo_queue_size, 0) AS varchar(20))
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
WHERE drs.synchronization_health_desc <> ''HEALTHY'' OR drs.is_suspended = 1;

INSERT @issues SELECT ''WARNING'', ''Agent job'', j.name, ''Failed at '' + CONVERT(varchar(20), msdb.dbo.agent_datetime(h.run_date, h.run_time), 120) + '': '' + LEFT(h.message, 300)
FROM msdb.dbo.sysjobhistory h JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
WHERE h.step_id = 0 AND h.run_status = 0
  AND msdb.dbo.agent_datetime(h.run_date, h.run_time) > DATEADD(HOUR, -24, GETDATE());

IF @is_mi = 0
BEGIN
    INSERT @issues EXEC (N''SELECT ''''CRITICAL'''', ''''Service'''', servicename, status_desc FROM sys.dm_server_services
                           WHERE servicename LIKE N''''SQL Server Agent%'''' AND status_desc <> N''''Running'''''');
    DECLARE @disk_sql nvarchar(max) = N''SELECT CASE WHEN pct < 10 THEN ''''CRITICAL'''' ELSE ''''WARNING'''' END, ''''Disk'''', volume_mount_point,
                                  CAST(free_gb AS varchar(20)) + '''' GB free ('''' + CAST(pct AS varchar(10)) + ''''%)''''
                           FROM (SELECT DISTINCT vs.volume_mount_point,
                                        CAST(vs.available_bytes / 1073741824.0 AS decimal(18,1)) AS free_gb,
                                        CAST(100.0 * vs.available_bytes / vs.total_bytes AS decimal(5,1)) AS pct
                                 FROM sys.master_files mf CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs) v
                           WHERE pct < '' + CAST(@disk_free_pct AS nvarchar(5)) + N'';'';
    INSERT @issues EXEC (@disk_sql);
END;

INSERT @issues SELECT CASE WHEN ls.active_log_size_mb * 100.0 / NULLIF(ls.total_log_size_mb, 0) > 90 THEN ''CRITICAL'' ELSE ''WARNING'' END,
       ''Log space'', d.name,
       CAST(CAST(ls.active_log_size_mb * 100.0 / NULLIF(ls.total_log_size_mb, 0) AS decimal(5,1)) AS varchar(10)) + ''% used, reuse wait: '' + d.log_reuse_wait_desc
FROM sys.databases d CROSS APPLY sys.dm_db_log_stats(d.database_id) ls
WHERE d.state_desc = N''ONLINE'' AND ls.active_log_size_mb * 100.0 / NULLIF(ls.total_log_size_mb, 0) > @log_used_pct;

INSERT @issues SELECT ''WARNING'', ''Log VLFs'', d.name, CAST(ls.total_vlf_count AS varchar(10)) + '' VLFs (slow recovery / failover)''
FROM sys.databases d CROSS APPLY sys.dm_db_log_stats(d.database_id) ls
WHERE d.state_desc = N''ONLINE'' AND ls.total_vlf_count > @vlf_max;

INSERT @issues SELECT ''WARNING'', ''File growth'', DB_NAME(database_id) + ''.'' + name,
       CASE WHEN growth = 0 THEN ''Autogrowth disabled'' ELSE ''At '' + CAST(CAST(100.0 * size / max_size AS decimal(5,1)) AS varchar(10)) + ''% of max_size'' END
FROM sys.master_files
WHERE database_id <> 2 AND (growth = 0 OR (max_size > 0 AND size >= 0.9 * max_size));

INSERT @issues SELECT ''WARNING'', ''tempdb'', ''Free space'',
       CAST(CAST(100.0 * SUM(unallocated_extent_page_count) / SUM(total_page_count) AS decimal(5,1)) AS varchar(10)) + ''% free''
FROM tempdb.sys.dm_db_file_space_usage
HAVING 100.0 * SUM(unallocated_extent_page_count) / SUM(total_page_count) < @tempdb_free_pct;

INSERT @issues SELECT ''CRITICAL'', ''Blocking'', ''Session '' + CAST(r.session_id AS varchar(10)) + '' blocked by '' + CAST(r.blocking_session_id AS varchar(10)),
       CAST(r.wait_time / 60000 AS varchar(10)) + '' min, '' + ISNULL(r.wait_type, '''') + '' on '' + ISNULL(DB_NAME(r.database_id), '''')
FROM sys.dm_exec_requests r WHERE r.blocking_session_id > 0 AND r.wait_time > @blocking_min * 60000;

INSERT @issues SELECT ''WARNING'', ''Open transaction'', ''Session '' + CAST(st.session_id AS varchar(10)) + '' ('' + s.login_name + '')'',
       ''Open since '' + CONVERT(varchar(20), at.transaction_begin_time, 120) + '' from '' + ISNULL(s.host_name, '''') + '' / '' + ISNULL(s.program_name, '''')
FROM sys.dm_tran_active_transactions at
JOIN sys.dm_tran_session_transactions st ON st.transaction_id = at.transaction_id
JOIN sys.dm_exec_sessions s ON s.session_id = st.session_id
WHERE at.transaction_begin_time < DATEADD(MINUTE, -@open_tran_min, GETDATE()) AND s.is_user_process = 1;

INSERT @issues SELECT ''WARNING'', ''Memory'', ''Memory Grants Pending'', CAST(cntr_value AS varchar(10)) + '' queries waiting for memory''
FROM sys.dm_os_performance_counters WHERE counter_name = N''Memory Grants Pending'' AND cntr_value > 0;

INSERT @issues SELECT ''WARNING'', ''Certificate'', c.name,
       ''Expires '' + CONVERT(varchar(10), c.expiry_date, 120)
     + CASE WHEN c.pvt_key_last_backup_date IS NULL AND EXISTS (SELECT 1 FROM sys.dm_database_encryption_keys k WHERE k.encryptor_thumbprint = c.thumbprint)
            THEN '' | TDE cert PRIVATE KEY NEVER BACKED UP'' ELSE '''' END
FROM master.sys.certificates c
WHERE c.name NOT LIKE N''##%''
  AND (c.expiry_date < DATEADD(DAY, @cert_days, GETDATE())
       OR (c.pvt_key_last_backup_date IS NULL AND EXISTS (SELECT 1 FROM sys.dm_database_encryption_keys k WHERE k.encryptor_thumbprint = c.thumbprint)));

IF OBJECT_ID(''tempdb..#sev'') IS NOT NULL DROP TABLE #sev;
CREATE TABLE #sev (LogDate datetime, ProcessInfo nvarchar(50), [Text] nvarchar(max));
INSERT #sev EXEC sys.xp_readerrorlog 0, 1, N''Severity:'';
INSERT @issues SELECT ''CRITICAL'', ''Error log'', ''Severity '' + CAST(sev AS varchar(3)) + '' errors (24h)'',
       CAST(COUNT(*) AS varchar(10)) + ''x, last '' + CONVERT(varchar(20), MAX(LogDate), 120) + '': '' + MAX(LEFT([Text], 200))
FROM (SELECT LogDate, [Text], TRY_CAST(SUBSTRING([Text], CHARINDEX(''Severity:'', [Text]) + 10, 2) AS int) AS sev FROM #sev) x
WHERE sev >= 17 AND LogDate > DATEADD(HOUR, -24, GETDATE())
GROUP BY sev;

INSERT @issues SELECT ''WARNING'', ''Database Mail'', ''Failed mails (24h)'', CAST(COUNT(*) AS varchar(10)) + '' not sent - alerts may not be reaching you''
FROM msdb.dbo.sysmail_allitems WHERE sent_status = ''failed'' AND send_request_date > DATEADD(HOUR, -24, GETDATE())
HAVING COUNT(*) > 0;

SELECT severity, area, item, detail FROM @issues
ORDER BY CASE severity WHEN ''CRITICAL'' THEN 0 ELSE 1 END, area, item;
',
    @fallback_definition = NULL;
GO

/* 41.2  GROWTH FORECAST - DAYS UNTIL DISK FULL   (41_proactive_monitoring_alerts.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_growth_forecast', @section = N'41.2', @source_file = N'41_proactive_monitoring_alerts.sql',
    @title = N'GROWTH FORECAST - DAYS UNTIL DISK FULL', @tags = N'BOX',
    @usage = N'EXEC dbo.HC_growth_forecast;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_growth_forecast
AS
-- Toolkit 41_proactive_monitoring_alerts.sql section 41.2: GROWTH FORECAST - DAYS UNTIL DISK FULL
SET NOCOUNT ON;
WITH fb AS (
    SELECT database_name, backup_finish_date, backup_size,
           ROW_NUMBER() OVER (PARTITION BY database_name ORDER BY backup_finish_date)      AS rn_first,
           ROW_NUMBER() OVER (PARTITION BY database_name ORDER BY backup_finish_date DESC) AS rn_last
    FROM msdb.dbo.backupset
    WHERE type = ''D'' AND is_copy_only = 0 AND backup_finish_date >= DATEADD(DAY, -30, GETDATE())
),
gr AS (
    SELECT f.database_name,
           (l.backup_size - f.backup_size) / 1048576.0 / NULLIF(DATEDIFF(DAY, f.backup_finish_date, l.backup_finish_date), 0) AS mb_per_day
    FROM fb f JOIN fb l ON l.database_name = f.database_name AND l.rn_last = 1
    WHERE f.rn_first = 1
),
dv AS (
    SELECT DISTINCT mf.database_id, vs.volume_mount_point
    FROM sys.master_files mf CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs
    WHERE mf.type = 0
),
dvc AS (SELECT database_id, volume_mount_point, COUNT(*) OVER (PARTITION BY database_id) AS nvol FROM dv),
vol AS (
    SELECT DISTINCT vs.volume_mount_point, vs.available_bytes / 1048576 AS free_mb, vs.total_bytes / 1048576 AS total_mb
    FROM sys.master_files mf CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs
)
SELECT v.volume_mount_point, v.total_mb / 1024 AS total_gb, v.free_mb / 1024 AS free_gb,
       CAST(SUM(gr.mb_per_day / dvc.nvol) AS decimal(18,1)) AS growth_mb_per_day,
       CAST(v.free_mb / NULLIF(SUM(gr.mb_per_day / dvc.nvol), 0) AS decimal(18,0)) AS days_until_full
FROM vol v
LEFT JOIN dvc ON dvc.volume_mount_point = v.volume_mount_point
LEFT JOIN gr ON gr.database_name = DB_NAME(dvc.database_id) AND gr.mb_per_day > 0
GROUP BY v.volume_mount_point, v.total_mb, v.free_mb
ORDER BY days_until_full;

WITH fb AS (
    SELECT database_name, backup_finish_date, backup_size,
           ROW_NUMBER() OVER (PARTITION BY database_name ORDER BY backup_finish_date)      AS rn_first,
           ROW_NUMBER() OVER (PARTITION BY database_name ORDER BY backup_finish_date DESC) AS rn_last
    FROM msdb.dbo.backupset
    WHERE type = ''D'' AND is_copy_only = 0 AND backup_finish_date >= DATEADD(DAY, -30, GETDATE())
)
SELECT f.database_name,
       CAST(l.backup_size / 1073741824.0 AS decimal(18,2)) AS current_used_gb,
       CAST((l.backup_size - f.backup_size) / 1048576.0 / NULLIF(DATEDIFF(DAY, f.backup_finish_date, l.backup_finish_date), 0) AS decimal(18,1)) AS mb_per_day,
       CAST((l.backup_size - f.backup_size) / 1048576.0 / NULLIF(DATEDIFF(DAY, f.backup_finish_date, l.backup_finish_date), 0) * 30 / 1024 AS decimal(18,2)) AS gb_per_month
FROM fb f JOIN fb l ON l.database_name = f.database_name AND l.rn_last = 1
WHERE f.rn_first = 1
ORDER BY mb_per_day DESC;
',
    @fallback_definition = NULL;
GO

/* 41.3  FILES THAT WILL FAIL THEIR NEXT AUTOGROWTH   (41_proactive_monitoring_alerts.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_autogrowth_will_fail', @section = N'41.3', @source_file = N'41_proactive_monitoring_alerts.sql',
    @title = N'FILES THAT WILL FAIL THEIR NEXT AUTOGROWTH', @tags = N'BOX',
    @usage = N'EXEC dbo.HC_autogrowth_will_fail;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_autogrowth_will_fail
AS
-- Toolkit 41_proactive_monitoring_alerts.sql section 41.3: FILES THAT WILL FAIL THEIR NEXT AUTOGROWTH
SET NOCOUNT ON;
SELECT DB_NAME(mf.database_id) AS database_name, mf.name AS logical_name, mf.type_desc, vs.volume_mount_point,
       CAST(mf.size AS bigint) * 8 / 1024 AS size_mb,
       CASE WHEN mf.is_percent_growth = 1 THEN CAST(mf.size AS bigint) * 8 / 1024 * mf.growth / 100
            ELSE CAST(mf.growth AS bigint) * 8 / 1024 END AS next_growth_mb,
       vs.available_bytes / 1048576 AS disk_free_mb,
       CASE WHEN mf.max_size = -1 THEN ''unlimited'' ELSE CAST(CAST(mf.max_size AS bigint) * 8 / 1024 AS varchar(20)) + '' MB'' END AS max_size,
       CASE WHEN mf.growth = 0 THEN ''Autogrowth OFF''
            WHEN mf.max_size > 0 AND mf.size >= mf.max_size THEN ''AT MAX SIZE''
            ELSE ''NOT ENOUGH DISK FOR NEXT GROWTH'' END AS finding
FROM sys.master_files AS mf
CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs
WHERE mf.growth = 0
   OR (mf.max_size > 0 AND mf.size >= mf.max_size)
   OR vs.available_bytes / 1048576 < CASE WHEN mf.is_percent_growth = 1 THEN CAST(mf.size AS bigint) * 8 / 1024 * mf.growth / 100
                                          ELSE CAST(mf.growth AS bigint) * 8 / 1024 END
ORDER BY finding, database_name;
',
    @fallback_definition = NULL;
GO

/* 41.5  VERIFY ALERTS ACTUALLY NOTIFY SOMEONE   (41_proactive_monitoring_alerts.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_alerts_notify', @section = N'41.5', @source_file = N'41_proactive_monitoring_alerts.sql',
    @title = N'VERIFY ALERTS ACTUALLY NOTIFY SOMEONE', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_alerts_notify;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_alerts_notify
AS
-- Toolkit 41_proactive_monitoring_alerts.sql section 41.5: VERIFY ALERTS ACTUALLY NOTIFY SOMEONE
SET NOCOUNT ON;
SELECT a.name AS alert_name, a.enabled, a.severity, a.message_id, a.occurrence_count,
       CASE WHEN a.last_occurrence_date > 0 THEN msdb.dbo.agent_datetime(a.last_occurrence_date, a.last_occurrence_time) END AS last_fired,
       o.name AS operator, o.email_address, o.enabled AS operator_enabled,
       CASE WHEN n.alert_id IS NULL THEN ''NO NOTIFICATION - nobody will know'' ELSE '''' END AS finding
FROM msdb.dbo.sysalerts AS a
LEFT JOIN msdb.dbo.sysnotifications AS n ON n.alert_id = a.id
LEFT JOIN msdb.dbo.sysoperators AS o ON o.id = n.operator_id
ORDER BY finding DESC, a.name;

SELECT j.name, j.enabled, j.notify_level_email, o.name AS operator
FROM msdb.dbo.sysjobs j LEFT JOIN msdb.dbo.sysoperators o ON o.id = j.notify_email_operator_id
WHERE j.enabled = 1 AND (j.notify_level_email NOT IN (2, 3) OR o.id IS NULL);
',
    @fallback_definition = NULL;
GO

/* 41.6  RESTART / SHUTDOWN HISTORY (from all error logs)   (41_proactive_monitoring_alerts.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_restart_history', @section = N'41.6', @source_file = N'41_proactive_monitoring_alerts.sql',
    @title = N'RESTART / SHUTDOWN HISTORY (from all error logs)', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_restart_history;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_restart_history
AS
-- Toolkit 41_proactive_monitoring_alerts.sql section 41.6: RESTART / SHUTDOWN HISTORY (from all error logs)
SET NOCOUNT ON;
IF OBJECT_ID(''tempdb..#logs'') IS NOT NULL DROP TABLE #logs;
IF OBJECT_ID(''tempdb..#ev'') IS NOT NULL DROP TABLE #ev;
CREATE TABLE #logs (ArchiveNo int, LogDate datetime, LogSize bigint);
CREATE TABLE #ev (LogDate datetime, ProcessInfo nvarchar(50), [Text] nvarchar(max));
INSERT #logs EXEC sys.sp_enumerrorlogs;

DECLARE @n int = 0, @max int = (SELECT MAX(ArchiveNo) FROM #logs);
WHILE @n <= @max
BEGIN
    INSERT #ev EXEC sys.xp_readerrorlog @n, 1, N''Server process ID is'';
    INSERT #ev EXEC sys.xp_readerrorlog @n, 1, N''SQL Server is terminating'';
    INSERT #ev EXEC sys.xp_readerrorlog @n, 1, N''SQL Server is now ready for client connections'';
    SET @n += 1;
END;
SELECT DISTINCT LogDate,
       CASE WHEN [Text] LIKE N''Server process ID%'' THEN ''START''
            WHEN [Text] LIKE N''SQL Server is now ready%'' THEN ''READY''
            ELSE ''SHUTDOWN'' END AS event, [Text]
FROM #ev ORDER BY LogDate DESC;
',
    @fallback_definition = NULL;
GO

/* 41.7  CONFIGURATION CHANGES (who changed what, when)   (41_proactive_monitoring_alerts.sql) */
EXEC dbo.HC_usp_deploy
    @name = N'HC_config_changes', @section = N'41.7', @source_file = N'41_proactive_monitoring_alerts.sql',
    @title = N'CONFIGURATION CHANGES (who changed what, when)', @tags = N'BOX,MI',
    @usage = N'EXEC dbo.HC_config_changes;',
    @min_version = NULL,
    @sort_hint = NULL,
    @definition = N'CREATE OR ALTER PROCEDURE dbo.HC_config_changes
AS
-- Toolkit 41_proactive_monitoring_alerts.sql section 41.7: CONFIGURATION CHANGES (who changed what, when)
SET NOCOUNT ON;
TRUNCATE TABLE #ev;
SET @n = 0;
WHILE @n <= @max
BEGIN
    INSERT #ev EXEC sys.xp_readerrorlog @n, 1, N''Configuration option'';
    INSERT #ev EXEC sys.xp_readerrorlog @n, 1, N''Setting database option'';
    INSERT #ev EXEC sys.xp_readerrorlog @n, 1, N''DBCC TRACEON'';
    SET @n += 1;
END;
SELECT DISTINCT LogDate, ProcessInfo, [Text] FROM #ev ORDER BY LogDate DESC;
',
    @fallback_definition = NULL;
GO

/*============================================================================
  CATALOG: what is installed and how to call it
     SELECT * FROM dbo.HC_catalog;                               -- everything
     SELECT * FROM dbo.HC_catalog WHERE title LIKE N'%block%';   -- find one
============================================================================*/
CREATE OR ALTER VIEW dbo.HC_catalog
AS
SELECT
    r.name,
    r.section                     AS toolkit_section,
    r.title,
    CASE o.type WHEN 'V'  THEN 'view'
                WHEN 'IF' THEN 'function'
                WHEN 'P'  THEN 'procedure'
                ELSE 'not installed' END AS object_type,
    CASE WHEN o.type = 'P' AND r.usage LIKE N'SELECT%'      -- view/function that had to become a procedure
         THEN N'EXEC dbo.' + r.name + N';'
         ELSE r.usage END         AS how_to_run,
    r.sort_hint                   AS suggested_order_by,
    r.tags                        AS runs_on,
    r.status,
    r.message,
    r.source_file,
    r.deployed_at
FROM dbo.HC_objects AS r
LEFT JOIN sys.objects AS o ON o.object_id = OBJECT_ID(N'dbo.' + QUOTENAME(r.name));
GO

/*----------------------------------------------------------------------------
  Deployment summary
----------------------------------------------------------------------------*/
SELECT status, COUNT(*) AS objects
FROM dbo.HC_objects
GROUP BY status
ORDER BY status;

SELECT toolkit_section, name, status, message
FROM dbo.HC_catalog
WHERE status NOT IN ('OK', 'NOT APPLICABLE', 'NOT ON THIS VERSION')
ORDER BY TRY_CAST(PARSENAME(toolkit_section, 2) AS int), TRY_CAST(PARSENAME(toolkit_section, 1) AS int);
GO

SET NOEXEC OFF;
GO

/*----------------------------------------------------------------------------
  OPTIONAL: let a team group use the objects (run once, adjust names)
----------------------------------------------------------------------------
USE DBAdmin;
CREATE ROLE HC_users;
GRANT SELECT, EXECUTE ON SCHEMA::dbo TO HC_users;
CREATE USER [DOMAIN\DBA-Team] FOR LOGIN [DOMAIN\DBA-Team];
ALTER ROLE HC_users ADD MEMBER [DOMAIN\DBA-Team];
USE master;
GRANT VIEW SERVER STATE TO [DOMAIN\DBA-Team];      -- 2022+: VIEW SERVER PERFORMANCE STATE + VIEW SERVER SECURITY STATE
GRANT VIEW ANY DEFINITION TO [DOMAIN\DBA-Team];
----------------------------------------------------------------------------*/
