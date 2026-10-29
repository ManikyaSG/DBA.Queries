/*******************************************************************************
 File    : 30_patching.sql
 Purpose : Cumulative Update / GDR / security patching: where am I, pre-patch
           checks, job pause/resume, Always On rolling patch, FCI notes,
           post-patch validation.
 Tags    : [BOX] SQL Server on-prem / Azure VM
           MI & Azure SQL DB are patched by Microsoft (see 30.9).
 Tip     : Latest CU per version is listed on Microsoft's "Latest updates and
           version history for SQL Server" page (and sqlserverbuilds.blogspot.com).
*******************************************************************************/

/*=============================================================================
  30.1 CURRENT BUILD / CU / LAST PATCH DATE                            [BOX]
  ResourceLastUpdateDateTime ~= when the last CU/GDR was applied.
=============================================================================*/
SELECT SERVERPROPERTY('MachineName')                 AS machine,
       SERVERPROPERTY('ServerName')                  AS instance,
       SERVERPROPERTY('ProductMajorVersion')         AS major_version,
       SERVERPROPERTY('ProductVersion')              AS build,
       SERVERPROPERTY('ProductLevel')                AS sp_level,
       SERVERPROPERTY('ProductUpdateLevel')          AS cu,
       SERVERPROPERTY('ProductUpdateReference')      AS kb,
       SERVERPROPERTY('ResourceVersion')             AS resource_db_version,
       SERVERPROPERTY('ResourceLastUpdateDateTime')  AS last_patched,
       DATEDIFF(DAY, CAST(SERVERPROPERTY('ResourceLastUpdateDateTime') AS datetime), GETDATE()) AS days_since_patch,
       SERVERPROPERTY('Edition')                     AS edition,
       SERVERPROPERTY('IsClustered')                 AS is_fci,
       SERVERPROPERTY('IsHadrEnabled')               AS is_hadr;


/*=============================================================================
  30.2 PRE-PATCH HEALTH CHECK - ONE RESULT SET                          [BOX]
  Anything returned here should be fixed / understood before patching.
  FULL SNAPSHOT: EXEC DBAdmin.dbo.usp_DBA_ChangeSnapshot @Label = 'PRE' (43.3) -> after: 'POST' + 43.4 / 43.5

=============================================================================*/
SELECT 'DB not online' AS check_item, name AS detail FROM sys.databases WHERE state_desc <> N'ONLINE'
UNION ALL
SELECT 'No full backup in 24h', d.name FROM sys.databases d
WHERE d.database_id <> 2 AND NOT EXISTS (SELECT 1 FROM msdb.dbo.backupset b WHERE b.database_name = d.name AND b.type = 'D'
                                         AND b.backup_finish_date > DATEADD(HOUR, -24, GETDATE()))
UNION ALL
SELECT 'AG not healthy', ag.name + ' ' + ags.synchronization_health_desc
FROM sys.dm_hadr_availability_group_states ags JOIN sys.availability_groups ag ON ag.group_id = ags.group_id
WHERE ags.synchronization_health_desc <> 'HEALTHY'
UNION ALL
SELECT 'Open transaction > 5 min', CAST(st.session_id AS varchar(10)) + ' since ' + CONVERT(varchar(20), at.transaction_begin_time, 120)
FROM sys.dm_tran_active_transactions at JOIN sys.dm_tran_session_transactions st ON st.transaction_id = at.transaction_id
WHERE at.transaction_begin_time < DATEADD(MINUTE, -5, GETDATE())
UNION ALL
SELECT 'Agent job running', j.name FROM msdb.dbo.sysjobactivity ja JOIN msdb.dbo.sysjobs j ON j.job_id = ja.job_id
WHERE ja.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions) AND ja.start_execution_date IS NOT NULL AND ja.stop_execution_date IS NULL
UNION ALL
SELECT 'Low disk (< 10% free)', vs.volume_mount_point
FROM (SELECT DISTINCT vs.volume_mount_point, vs.available_bytes, vs.total_bytes
      FROM sys.master_files mf CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs) vs
WHERE vs.available_bytes * 100.0 / vs.total_bytes < 10
UNION ALL
SELECT 'Backup/restore/DBCC in progress', command FROM sys.dm_exec_requests
WHERE command LIKE N'BACKUP%' OR command LIKE N'RESTORE%' OR command LIKE N'DBCC%';


/*=============================================================================
  30.3 SYSTEM DB BACKUPS BEFORE PATCHING (generator)                   [BOX]
=============================================================================*/
DECLARE @path nvarchar(260) = N'X:\PrePatch\';   -- <== change
SELECT N'BACKUP DATABASE ' + QUOTENAME(name) + N' TO DISK = N''' + @path + name + N'_PrePatch_'
       + CONVERT(nvarchar(8), GETDATE(), 112) + N'.bak'' WITH COPY_ONLY, COMPRESSION, CHECKSUM;' AS cmd
FROM sys.databases WHERE name IN (N'master', N'model', N'msdb')
UNION ALL SELECT N'-- also: SSISDB (+ export its master key), ReportServer, distribution if present';


/*=============================================================================
  30.4 PAUSE / RESUME AGENT JOBS AROUND THE PATCH                      [BOX]
  Save the "enable" list first - re-enable ONLY what was enabled before.
=============================================================================*/
SELECT j.name,
       N'EXEC msdb.dbo.sp_update_job @job_name = N''' + REPLACE(j.name, '''', '''''') + N''', @enabled = 0;' AS disable_cmd,
       N'EXEC msdb.dbo.sp_update_job @job_name = N''' + REPLACE(j.name, '''', '''''') + N''', @enabled = 1;' AS enable_cmd
FROM msdb.dbo.sysjobs AS j
WHERE j.enabled = 1
ORDER BY j.name;


/*=============================================================================
  30.5 ALWAYS ON ROLLING PATCH - CHECKS BETWEEN EACH STEP              [BOX]
=============================================================================*/
-- Run between every step: role, sync state, versions per replica
SELECT ar.replica_server_name, ars.role_desc, ar.availability_mode_desc, ar.failover_mode_desc,
       ars.connected_state_desc, ars.synchronization_health_desc
FROM sys.availability_replicas ar
LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id
ORDER BY ars.role_desc;

SELECT DB_NAME(database_id) AS database_name, is_local, synchronization_state_desc,
       log_send_queue_size, redo_queue_size
FROM sys.dm_hadr_database_replica_states
ORDER BY database_name, is_local DESC;

/*
 ROLLING PATCH ORDER (2+ replicas):
 1. ALTER AVAILABILITY GROUP [AG1] MODIFY REPLICA ON N'<each replica>' WITH (FAILOVER_MODE = MANUAL);
 2. Patch ASYNC / DR secondaries, then SYNC secondaries one at a time (reboot if required).
    After each: wait until synchronization_state = SYNCHRONIZED (or SYNCHRONIZING for async).
 3. Fail over to a patched SYNC secondary (run on it):  ALTER AVAILABILITY GROUP [AG1] FAILOVER;
 4. Patch the old primary (now secondary). Wait for SYNCHRONIZED.
 5. Optionally fail back. Restore FAILOVER_MODE = AUTOMATIC where it was before.
 Mixed CU levels between replicas are fine temporarily; don't run that way for long.
 Each AG with its own primary on the box needs to be failed over before patching that node.
*/


/*=============================================================================
  30.6 FAILOVER CLUSTER INSTANCE (FCI) NOTES                           [BOX]
=============================================================================*/
/*
 1. Patch passive node(s) first (setup applies to the local node only).
 2. Move the SQL role to a patched node (Failover Cluster Manager / Move-ClusterGroup).
    -> database upgrade scripts run when the instance starts on the patched node.
 3. Patch the previously active node.
 4. Check possible owners / preferred owners were not changed.
*/
SELECT NodeName, status_description, is_current_owner FROM sys.dm_os_cluster_nodes;


/*=============================================================================
  30.7 POST-PATCH VALIDATION                                           [BOX]
=============================================================================*/
-- a) New build is live (compare with 30.1 output)
SELECT SERVERPROPERTY('ProductVersion') AS build, SERVERPROPERTY('ProductUpdateLevel') AS cu,
       SERVERPROPERTY('ResourceLastUpdateDateTime') AS last_patched;

-- b) All databases online & no recovery pending
SELECT name, state_desc FROM sys.databases WHERE state_desc <> N'ONLINE';

-- c) Upgrade script / startup errors
EXEC sys.xp_readerrorlog 0, 1, N'Script level upgrade';
EXEC sys.xp_readerrorlog 0, 1, N'Error:';

-- d) Services running (Engine, Agent, Full-text, Launchpad)
SELECT servicename, status_desc, startup_type_desc FROM sys.dm_server_services;

-- e) AG back to healthy -> 25_alwayson_advanced.sql 25.1 should return 0 rows
-- f) Re-enable jobs from 30.4, run a test backup job, check 14.1 for failures.


/*=============================================================================
  30.8 AZURE VM PATCHING OPTIONS
=============================================================================*/
/*
 - SQL IaaS Agent extension: register VM -> "Automated patching" (Windows + SQL important updates
   in a maintenance window) - it is NOT AG-aware, avoid it for AG nodes; patch AGs manually (30.5).
 - Azure Update Manager can install SQL CUs (Microsoft Update must be enabled for "other Microsoft products").
 - Snapshot the OS + data disks (or keep 30.3 backups) before applying CUs.
*/


/*=============================================================================
  30.9 MANAGED INSTANCE / AZURE SQL DB                            [MI][SQLDB]
=============================================================================*/
-- Patched by Microsoft. You control WHEN via a maintenance window (portal / PowerShell).
-- Version check only:
SELECT @@VERSION AS version, SERVERPROPERTY('ProductVersion') AS build, SERVERPROPERTY('EngineEdition') AS engine_edition;
-- MI: update policy ("SQL Server 2022" / "Always-up-to-date" / newer) decides feature level & restore compatibility to boxed SQL.
