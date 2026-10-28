/*******************************************************************************
 File    : 29_migration.sql
 Purpose : Server / database migration (new server, new version, Azure VM,
           Managed Instance, Azure SQL DB): pre-migration inventory,
           dependency & cloud-blocker checks, cutover monitoring,
           post-migration validation.
 Tags    : [BOX] source/target on-prem / Azure VM   [MI] target   [SQLDB] target
 Methods : backup/restore (+ log/diff for cutover), log shipping, AG / distributed
           AG, MI link, Log Replay Service (MI), Azure DMS, bacpac / sqlpackage,
           dbatools Start-DbaMigration (instance-level objects).
*******************************************************************************/

/*=============================================================================
  29.1 SOURCE INVENTORY - DATABASES                                    [BOX][MI]
=============================================================================*/
SELECT d.name, d.compatibility_level, d.recovery_model_desc, d.collation_name, d.state_desc,
       SUSER_SNAME(d.owner_sid) AS owner_name, d.is_encrypted, d.is_cdc_enabled, d.is_published,
       d.is_broker_enabled, d.is_trustworthy_on, d.containment_desc,
       CAST(SUM(CAST(mf.size AS bigint)) * 8 / 1024.0 / 1024 AS decimal(18,2)) AS size_gb,
       SUM(CASE WHEN mf.type_desc = N'FILESTREAM' THEN 1 ELSE 0 END) AS filestream_files,
       SUM(CASE WHEN mf.type_desc = N'FULLTEXT' THEN 1 ELSE 0 END)   AS fulltext_files
FROM sys.databases AS d
JOIN sys.master_files AS mf ON mf.database_id = d.database_id
WHERE d.database_id > 4
GROUP BY d.name, d.compatibility_level, d.recovery_model_desc, d.collation_name, d.state_desc, d.owner_sid,
         d.is_encrypted, d.is_cdc_enabled, d.is_published, d.is_broker_enabled, d.is_trustworthy_on, d.containment_desc
ORDER BY size_gb DESC;


/*=============================================================================
  29.2 SOURCE INVENTORY - INSTANCE-LEVEL OBJECTS TO CARRY OVER          [BOX][MI]
  (These live in master/msdb and are NOT in a user-DB backup.)
=============================================================================*/
SELECT 'Logins'            AS item, COUNT(*) AS cnt FROM sys.server_principals WHERE type IN ('S','U','G') AND name NOT LIKE N'##%' AND name NOT LIKE N'NT %'
UNION ALL SELECT 'Server roles (custom)',   COUNT(*) FROM sys.server_principals WHERE type = 'R' AND is_fixed_role = 0 AND principal_id > 10
UNION ALL SELECT 'Linked servers',          COUNT(*) FROM sys.servers WHERE is_linked = 1
UNION ALL SELECT 'Credentials',             COUNT(*) FROM sys.credentials
UNION ALL SELECT 'Agent jobs',              COUNT(*) FROM msdb.dbo.sysjobs
UNION ALL SELECT 'Agent proxies',           COUNT(*) FROM msdb.dbo.sysproxies
UNION ALL SELECT 'Operators',               COUNT(*) FROM msdb.dbo.sysoperators
UNION ALL SELECT 'Alerts',                  COUNT(*) FROM msdb.dbo.sysalerts
UNION ALL SELECT 'DB Mail profiles',        COUNT(*) FROM msdb.dbo.sysmail_profile
UNION ALL SELECT 'SSIS pkgs in msdb (incl. maint plans)', COUNT(*) FROM msdb.dbo.sysssispackages
UNION ALL SELECT 'SSISDB catalog present',  COUNT(*) FROM sys.databases WHERE name = N'SSISDB'
UNION ALL SELECT 'Server triggers',         COUNT(*) FROM sys.server_triggers
UNION ALL SELECT 'Custom error messages',   COUNT(*) FROM sys.messages WHERE message_id > 50000
UNION ALL SELECT 'Certificates (master)',   COUNT(*) FROM master.sys.certificates WHERE name NOT LIKE N'##%'
UNION ALL SELECT 'Endpoints (user)',        COUNT(*) FROM sys.endpoints WHERE endpoint_id > 5
UNION ALL SELECT 'Backup devices',          COUNT(*) FROM sys.backup_devices
UNION ALL SELECT 'Startup procs',           COUNT(*) FROM master.sys.procedures WHERE OBJECTPROPERTY(object_id, 'ExecIsStartup') = 1
UNION ALL SELECT 'Audits',                  COUNT(*) FROM sys.server_audits
UNION ALL SELECT 'XE sessions (user)',      COUNT(*) FROM sys.server_event_sessions WHERE name NOT IN (N'system_health', N'AlwaysOn_health', N'telemetry_xevents', N'hkenginexesession', N'sp_server_diagnostics session');

-- Details you'll want handy
SELECT name, product, provider, data_source FROM sys.servers WHERE is_linked = 1;
SELECT name, credential_identity FROM sys.credentials;
SELECT message_id, language_id, severity, text FROM sys.messages WHERE message_id > 50000 AND language_id = 1033;
SELECT name, value_in_use FROM sys.configurations ORDER BY name;          -- replicate non-defaults on target
DBCC TRACESTATUS(-1);


/*=============================================================================
  29.3 CROSS-DATABASE & CROSS-SERVER DEPENDENCIES - CURRENT DB [BOX][MI][SQLDB]
  3/4-part names break when DBs move apart (and are blocked in Azure SQL DB).
=============================================================================*/
SELECT OBJECT_SCHEMA_NAME(sed.referencing_id) + N'.' + OBJECT_NAME(sed.referencing_id) AS referencing_object,
       sed.referenced_server_name, sed.referenced_database_name,
       sed.referenced_schema_name, sed.referenced_entity_name
FROM sys.sql_expression_dependencies AS sed
WHERE sed.referenced_database_name IS NOT NULL OR sed.referenced_server_name IS NOT NULL
ORDER BY sed.referenced_server_name, sed.referenced_database_name, referencing_object;

-- Synonyms pointing elsewhere
SELECT name, base_object_name FROM sys.synonyms;

-- Hard-coded server names / features in code
SELECT OBJECT_SCHEMA_NAME(m.object_id) + N'.' + OBJECT_NAME(m.object_id) AS object_name,
       CASE WHEN m.definition LIKE N'%xp_cmdshell%'   THEN 'xp_cmdshell ' ELSE '' END
     + CASE WHEN m.definition LIKE N'%OPENROWSET%' OR m.definition LIKE N'%OPENDATASOURCE%' THEN 'OPENROWSET/OPENDATASOURCE ' ELSE '' END
     + CASE WHEN m.definition LIKE N'%OPENQUERY%'     THEN 'OPENQUERY ' ELSE '' END
     + CASE WHEN m.definition LIKE N'%sp_OA%'         THEN 'OLE Automation ' ELSE '' END
     + CASE WHEN m.definition LIKE N'%msdb%'          THEN 'msdb reference ' ELSE '' END
     + CASE WHEN m.definition LIKE N'%' + @@SERVERNAME + N'%' THEN 'hard-coded server name ' ELSE '' END AS findings
FROM sys.sql_modules AS m
WHERE m.definition LIKE N'%xp_cmdshell%' OR m.definition LIKE N'%OPENROWSET%' OR m.definition LIKE N'%OPENDATASOURCE%'
   OR m.definition LIKE N'%OPENQUERY%' OR m.definition LIKE N'%sp_OA%' OR m.definition LIKE N'%msdb%'
   OR m.definition LIKE N'%' + @@SERVERNAME + N'%';


/*=============================================================================
  29.4 AZURE SQL DATABASE BLOCKER CHECK - CURRENT DB                   [BOX]
  (Run on source. Azure Migrate / DMA / the "Azure SQL Migration" extension
  in ADS give the official assessment - this is a quick DBA pre-check.)
=============================================================================*/
SELECT 'Cross-DB / linked server refs' AS check_item, COUNT(*) AS hits
FROM sys.sql_expression_dependencies WHERE referenced_database_name IS NOT NULL OR referenced_server_name IS NOT NULL
UNION ALL SELECT 'CLR assemblies (user)', COUNT(*) FROM sys.assemblies WHERE is_user_defined = 1
UNION ALL SELECT 'FILESTREAM / FileTable columns', COUNT(*) FROM sys.columns WHERE is_filestream = 1
UNION ALL SELECT 'Windows users/groups (need Entra ID)', COUNT(*) FROM sys.database_principals WHERE type IN ('U','G')
UNION ALL SELECT 'Service Broker queues (user)', COUNT(*) FROM sys.service_queues WHERE is_ms_shipped = 0
UNION ALL SELECT 'Modules using xp_cmdshell / sp_OA / OPENROWSET', COUNT(*) FROM sys.sql_modules
          WHERE definition LIKE N'%xp_cmdshell%' OR definition LIKE N'%sp_OA%' OR definition LIKE N'%OPENROWSET%'
UNION ALL SELECT 'Modules referencing msdb (Agent/DBMail)', COUNT(*) FROM sys.sql_modules WHERE definition LIKE N'%msdb%'
UNION ALL SELECT 'Database-level DDL triggers', COUNT(*) FROM sys.triggers WHERE parent_class = 0
UNION ALL SELECT 'Multiple data files / filegroups', COUNT(*) - 1 FROM sys.filegroups;
-- Managed Instance supports most of these (cross-DB, CLR, Agent, Broker) - main MI blockers:
-- FILESTREAM/FileTable, Windows auth (use Entra/Kerberos), some xp_ procs, OS file paths.


/*=============================================================================
  29.5 GENERATE BACKUP / RESTORE COMMANDS FOR CUTOVER                   [BOX][MI]
=============================================================================*/
DECLARE @share nvarchar(260) = N'\\fileshare\migration\';   -- <== change (or https://<acct>.blob.core.windows.net/<container>/)
SELECT name,
       N'BACKUP DATABASE ' + QUOTENAME(name) + N' TO DISK = N''' + @share + name + N'_FULL.bak'' WITH COPY_ONLY, COMPRESSION, CHECKSUM, STATS = 10;' AS full_backup,
       N'BACKUP LOG '      + QUOTENAME(name) + N' TO DISK = N''' + @share + name + N'_TAIL.trn'' WITH NORECOVERY, COMPRESSION, CHECKSUM;  -- final tail, puts source in RESTORING' AS tail_log_backup,
       N'RESTORE DATABASE ' + QUOTENAME(name) + N' FROM DISK = N''' + @share + name + N'_FULL.bak'' WITH NORECOVERY, STATS = 10;  -- add MOVE' AS target_restore_full,
       N'RESTORE LOG '      + QUOTENAME(name) + N' FROM DISK = N''' + @share + name + N'_TAIL.trn'' WITH RECOVERY;' AS target_restore_tail
FROM sys.databases WHERE database_id > 4 AND state_desc = N'ONLINE'
ORDER BY name;


/*=============================================================================
  29.6 LOG SHIPPING STATUS DURING MIGRATION                            [BOX]
=============================================================================*/
-- On primary:
SELECT primary_server, primary_database, last_backup_file, last_backup_date, backup_threshold
FROM msdb.dbo.log_shipping_monitor_primary;
-- On secondary:
SELECT secondary_server, secondary_database, last_copied_file, last_copied_date,
       last_restored_file, last_restored_date, last_restored_latency,
       DATEDIFF(MINUTE, last_restored_date, GETDATE()) AS minutes_since_restore
FROM msdb.dbo.log_shipping_monitor_secondary;
-- EXEC sp_help_log_shipping_monitor;   -- combined view


/*=============================================================================
  29.7 POST-MIGRATION VALIDATION (run on TARGET)               [BOX][MI][SQLDB]
=============================================================================*/
-- a) DBs online, owner, compat, recovery, TRUSTWORTHY carried over?
SELECT name, state_desc, SUSER_SNAME(owner_sid) AS owner_name, compatibility_level, recovery_model_desc,
       is_trustworthy_on, is_broker_enabled, is_read_committed_snapshot_on, is_query_store_on
FROM sys.databases WHERE database_id > 4;

-- b) Orphaned users -> 13_security.sql 13.5 ; fix with ALTER USER ... WITH LOGIN = ...
-- c) Row counts vs source -> 31_schema_validation.sql 31.6 (run on both, compare)
-- d) Schema identical -> 31_schema_validation.sql 31.1 hashes on both sides
-- e) Refresh stats + module metadata after version change:
SELECT N'USE ' + QUOTENAME(name) + N'; EXEC sp_updatestats;' AS cmd FROM sys.databases WHERE database_id > 4 AND state_desc = N'ONLINE';
-- f) Jobs present, enabled and pointing to new paths/servers -> 14_agent_jobs_dbmail.sql 14.3 / 14.5
-- g) Linked servers test:   EXEC sp_testlinkedserver N'LinkedServerName';
-- h) App connection strings / DNS alias switched; old source set READ_ONLY or OFFLINE:
--    ALTER DATABASE [YourDB] SET READ_ONLY WITH ROLLBACK IMMEDIATE;


/*=============================================================================
  29.8 CUTOVER CHECKLIST
=============================================================================*/
/*
 T-7d   Inventory (29.1/29.2), blockers (29.3/29.4), target build & config, logins/jobs copied
 T-1d   Full restore on target WITH NORECOVERY, then diffs/logs (or log shipping / AG / MI link / LRS)
 T-0    Stop apps -> disable source jobs -> tail-log backup (29.5) -> restore tail WITH RECOVERY
        -> 29.7 validation -> switch connection strings / DNS / listener -> smoke test
 Rollback plan: source DB still intact (tail-log left it RESTORING: RESTORE DATABASE x WITH RECOVERY)
 T+1d   Query Store regressions (04), waits (01), errors (15), backups on target (10)
*/
