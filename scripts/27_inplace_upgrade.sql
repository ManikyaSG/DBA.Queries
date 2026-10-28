/*******************************************************************************
 File    : 27_inplace_upgrade.sql
 Purpose : In-place version upgrade (e.g. 2016/2017/2019 -> 2022/2025):
           pre-upgrade readiness checks, blockers, backups, post-upgrade
           validation and a safe compatibility-level upgrade path.
 Tags    : [BOX] SQL Server on-prem / Azure VM  (MI & Azure SQL DB are
           upgraded by Microsoft - only the compat-level section applies there)
 Note    : Always confirm the supported upgrade path, edition path and OS
           support in the "Supported version and edition upgrades" doc for
           your TARGET version before starting. In-place has no rollback
           except restore - side-by-side / AG rolling upgrade is safer.
*******************************************************************************/

/*=============================================================================
  27.1 WHAT ARE WE UPGRADING FROM?                                     [BOX]
=============================================================================*/
SELECT SERVERPROPERTY('ProductVersion')     AS build,
       SERVERPROPERTY('ProductLevel')       AS sp_level,
       SERVERPROPERTY('ProductUpdateLevel') AS cu,
       SERVERPROPERTY('Edition')            AS edition,
       SERVERPROPERTY('IsClustered')        AS is_fci,
       SERVERPROPERTY('IsHadrEnabled')      AS is_hadr,
       SERVERPROPERTY('Collation')          AS server_collation,
       @@VERSION                            AS full_version;

SELECT host_platform, host_distribution, host_release FROM sys.dm_os_host_info;   -- target version must support this OS


/*=============================================================================
  27.2 DEPRECATED FEATURES ACTUALLY USED SINCE LAST RESTART            [BOX]
  Anything here may be removed in a future version - review before upgrading.
=============================================================================*/
SELECT RTRIM(instance_name) AS deprecated_feature, cntr_value AS times_used
FROM sys.dm_os_performance_counters
WHERE object_name LIKE N'%Deprecated Features%' AND cntr_value > 0
ORDER BY cntr_value DESC;


/*=============================================================================
  27.3 COMPATIBILITY LEVELS (target must support each DB's level)      [BOX]
  110=2012 120=2014 130=2016 140=2017 150=2019 160=2022 170=2025
=============================================================================*/
SELECT name, compatibility_level, state_desc, recovery_model_desc
FROM sys.databases
ORDER BY compatibility_level, name;


/*=============================================================================
  27.4 POTENTIAL BLOCKERS / RISK ITEMS                                 [BOX]
=============================================================================*/
-- a) CLR assemblies (2017+ 'clr strict security' blocks unsigned SAFE/EXTERNAL assemblies)
SELECT DB_NAME() AS database_name, a.name, a.permission_set_desc, a.clr_name, a.create_date
FROM sys.assemblies AS a
WHERE a.is_user_defined = 1;            -- run per DB (or via 29.2 loop)

-- b) Startup procedures
SELECT name FROM master.sys.procedures WHERE OBJECTPROPERTY(object_id, 'ExecIsStartup') = 1;

-- c) Server-level DDL / logon triggers (a bad logon trigger can lock you out after restart)
SELECT name, type_desc, is_disabled, create_date FROM sys.server_triggers;

-- d) Global trace flags (verify each is still valid/needed on the target)
DBCC TRACESTATUS(-1);

-- e) Components that have their own upgrade step
SELECT name FROM sys.databases WHERE name IN (N'SSISDB', N'ReportServer', N'ReportServerTempDB', N'distribution', N'DQS_MAIN', N'MDS');

-- f) Database mirroring (deprecated) / log shipping / replication in use
SELECT DB_NAME(database_id) AS database_name, mirroring_role_desc, mirroring_state_desc
FROM sys.database_mirroring WHERE mirroring_guid IS NOT NULL;
SELECT name, is_published, is_subscribed, is_merge_published, is_distributor FROM sys.databases
WHERE is_published = 1 OR is_subscribed = 1 OR is_merge_published = 1 OR is_distributor = 1;
SELECT primary_database, backup_directory FROM msdb.dbo.log_shipping_primary_databases;

-- g) Legacy data types still in use (text/ntext/image) - per DB
SELECT OBJECT_SCHEMA_NAME(c.object_id) + N'.' + OBJECT_NAME(c.object_id) AS table_name, c.name, TYPE_NAME(c.user_type_id) AS data_type
FROM sys.columns AS c
JOIN sys.tables AS t ON t.object_id = c.object_id
WHERE TYPE_NAME(c.user_type_id) IN (N'text', N'ntext', N'image');

-- h) Full-text catalogs (rebuilt / re-populated depending on upgrade option)
SELECT name, is_default, is_accent_sensitivity_on FROM sys.fulltext_catalogs;


/*=============================================================================
  27.5 PRE-UPGRADE SAFETY NET                                          [BOX]
=============================================================================*/
-- Last CHECKDB + last full backup per DB (both should be recent)
SELECT d.name,
       DATABASEPROPERTYEX(d.name, 'LastGoodCheckDbTime') AS last_good_checkdb,
       (SELECT MAX(backup_finish_date) FROM msdb.dbo.backupset b WHERE b.database_name = d.name AND b.type = 'D') AS last_full_backup
FROM sys.databases AS d
WHERE d.database_id <> 2
ORDER BY d.name;

-- Generate full COPY_ONLY backups of ALL databases incl. system DBs
DECLARE @path nvarchar(260) = N'X:\PreUpgrade\';   -- <== change
SELECT N'BACKUP DATABASE ' + QUOTENAME(name) + N' TO DISK = N''' + @path + name + N'_PreUpgrade_'
       + CONVERT(nvarchar(8), GETDATE(), 112) + N'.bak'' WITH COPY_ONLY, COMPRESSION, CHECKSUM, STATS = 10;' AS backup_cmd
FROM sys.databases
WHERE name <> N'tempdb' AND state_desc = N'ONLINE'
ORDER BY CASE WHEN database_id <= 4 THEN 0 ELSE 1 END, name;

-- Save instance config to compare after upgrade
IF OBJECT_ID('tempdb..#pre_config') IS NOT NULL DROP TABLE #pre_config;
SELECT name, value_in_use INTO #pre_config FROM sys.configurations;   -- temp table dies with the restart: also save the result to a file / DBA table
-- Also script: logins (sp_help_revlogin / dbatools), jobs, linked servers, credentials, certificates.

-- System DB free space (upgrade scripts grow master/msdb)
SELECT DB_NAME(database_id) AS database_name, name, CAST(size AS bigint) * 8 / 1024 AS size_mb, physical_name
FROM sys.master_files WHERE database_id IN (1, 3, 4);


/*=============================================================================
  27.6 POST-UPGRADE VALIDATION                                         [BOX]
=============================================================================*/
-- a) New version is live, all DBs online
SELECT SERVERPROPERTY('ProductVersion') AS build, SERVERPROPERTY('ProductUpdateLevel') AS cu;
SELECT name, state_desc, compatibility_level FROM sys.databases WHERE state_desc <> N'ONLINE';

-- b) Upgrade script errors in the error log
EXEC sys.xp_readerrorlog 0, 1, N'Script level upgrade';
EXEC sys.xp_readerrorlog 0, 1, N'error';

-- c) Services, Agent, IFI
SELECT servicename, status_desc, service_account, instant_file_initialization_enabled FROM sys.dm_server_services;

-- d) Config drift vs pre-upgrade snapshot (if #pre_config still exists / reloaded)
-- SELECT c.name, p.value_in_use AS before, c.value_in_use AS after
-- FROM sys.configurations c JOIN #pre_config p ON p.name = c.name WHERE p.value_in_use <> c.value_in_use;

-- e) Recommended per user DB after upgrade (generator)
SELECT N'USE ' + QUOTENAME(name) + N'; DBCC CHECKDB WITH DATA_PURITY, NO_INFOMSGS; EXEC sp_updatestats;' AS post_upgrade_cmd
FROM sys.databases WHERE database_id > 4 AND state_desc = N'ONLINE';
-- (DATA_PURITY only matters for DBs that originated on 2000 or earlier; harmless otherwise)


/*=============================================================================
  27.7 SAFE COMPATIBILITY LEVEL UPGRADE (Query Store guided)   [BOX][MI][SQLDB]
  Keep the OLD compat level right after the engine upgrade, capture a
  baseline, then raise it and fix regressions with plan forcing / hints.
=============================================================================*/
/*
-- Step 1: keep old compat, make sure Query Store is collecting
ALTER DATABASE [YourDB] SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE);
-- ... run a full business cycle (days / month-end) ...

-- Step 2: raise compat level
ALTER DATABASE [YourDB] SET COMPATIBILITY_LEVEL = 160;   -- 2022 (170 = 2025)

-- Step 3: find regressions -> 04_query_store.sql 4.4 / 4.5, force last good plan:
EXEC sys.sp_query_store_force_plan @query_id = 123, @plan_id = 456;
-- or enable automatic correction:
ALTER DATABASE [YourDB] SET AUTOMATIC_TUNING (FORCE_LAST_GOOD_PLAN = ON);

-- Fallbacks without dropping compat level:
ALTER DATABASE SCOPED CONFIGURATION SET LEGACY_CARDINALITY_ESTIMATION = ON;
-- or per query: OPTION (USE HINT ('QUERY_OPTIMIZER_COMPATIBILITY_LEVEL_150'))
*/


/*=============================================================================
  27.8 ALWAYS ON ROLLING UPGRADE (minimal downtime) - ORDER OF STEPS   [BOX]
=============================================================================*/
/*
 1. Check health (11 / 25.1). Remove automatic failover:  ALTER AG ... MODIFY REPLICA ... FAILOVER_MODE = MANUAL
 2. Upgrade remote ASYNC secondaries first, then local SYNC secondaries (one at a time).
    Secondaries on the higher version keep receiving log but can't be readable until primary upgrades.
 3. Manual failover to an upgraded SYNC secondary (ALTER AVAILABILITY GROUP [AG1] FAILOVER;)
    -> database upgrade scripts run on the new primary here.
 4. Upgrade the old primary, it rejoins as secondary.
 5. Restore FAILOVER_MODE = AUTOMATIC, optionally fail back, re-check 11.3.
 NOTE: once the primary runs the new version you CANNOT fail back to an old-version replica.
*/
