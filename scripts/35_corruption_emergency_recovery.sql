/*******************************************************************************
 File    : 35_corruption_emergency_recovery.sql
 Purpose : Physical recovery runbook: corruption triage & repair, SUSPECT /
           RECOVERY_PENDING databases, lost log file, long crash recovery,
           system database recovery (master/msdb/model/tempdb), lost
           sysadmin access, moving files, DAC, AG loss of quorum.
 Tags    : [BOX] SQL Server on-prem / Azure VM  (MI / Azure SQL DB: platform
           handles corruption & system DBs - open a support case)
 GOLDEN  : Restore from backup beats repair. REPAIR_ALLOW_DATA_LOSS deletes
 RULE      data. Copy the damaged files somewhere safe BEFORE trying anything.
*******************************************************************************/

/*=============================================================================
  35.1 TRIAGE: WHAT IS BROKEN?                                         [BOX]
=============================================================================*/
-- DB state
SELECT name, state_desc, user_access_desc, is_read_only, page_verify_option_desc,
       DATABASEPROPERTYEX(name, 'LastGoodCheckDbTime') AS last_good_checkdb
FROM sys.databases
WHERE state_desc <> N'ONLINE' OR name = DB_NAME();

-- Recorded bad pages (823/824/checksum)
SELECT DB_NAME(database_id) AS database_name, file_id, page_id, event_type, error_count, last_update_date
FROM msdb.dbo.suspect_pages ORDER BY last_update_date DESC;

-- What the error log says (823 = OS I/O error, 824 = logical consistency, 825 = read retry = disk dying)
EXEC sys.xp_readerrorlog 0, 1, N'823';
EXEC sys.xp_readerrorlog 0, 1, N'824';
EXEC sys.xp_readerrorlog 0, 1, N'825';
EXEC sys.xp_readerrorlog 0, 1, N'suspect';


/*=============================================================================
  35.2 RUN CHECKDB FOR FULL PICTURE                                    [BOX]
  The LAST lines of output state "repair_allow_data_loss is the minimum
  repair level" etc. Read them before deciding anything.
=============================================================================*/
/*
DBCC CHECKDB (N'YourDB') WITH NO_INFOMSGS, ALL_ERRORMSGS;
DBCC CHECKDB (N'YourDB') WITH NO_INFOMSGS, ALL_ERRORMSGS, TABLERESULTS;   -- grid output, easier to filter
-- Narrower / faster:
DBCC CHECKTABLE (N'dbo.Orders') WITH NO_INFOMSGS, ALL_ERRORMSGS;
DBCC CHECKALLOC (N'YourDB') WITH NO_INFOMSGS;
DBCC CHECKCATALOG (N'YourDB');
*/


/*=============================================================================
  35.3 WHICH OBJECT / INDEX OWNS A BAD PAGE?                           [BOX]
  index_id 0/1 = heap/clustered = DATA (restore or repair)
  index_id >1  = nonclustered = rebuild the index, NO data loss  (35.4)
=============================================================================*/
DECLARE @dbid int = DB_ID(N'YourDB'), @file int = 1, @page int = 57;   -- <== from CHECKDB / 35.1

-- 2019+:
SELECT DB_NAME(database_id) AS database_name, OBJECT_SCHEMA_NAME(object_id, database_id) + N'.' + OBJECT_NAME(object_id, database_id) AS object_name,
       index_id, partition_id, page_type_desc, allocation_unit_type_desc, is_iam_page, is_mixed_page_allocation
FROM sys.dm_db_page_info(@dbid, @file, @page, 'DETAILED');

/* 2016/2017 (undocumented DBCC PAGE):
DBCC TRACEON (3604);
DBCC PAGE (N'YourDB', 1, 57, 0);      -- read "Metadata: ObjectId" and "Metadata: IndexId" in the header
DBCC TRACEOFF (3604);
*/


/*=============================================================================
  35.4 FIX BY CORRUPTION TYPE (decision guide)                          [BOX]
=============================================================================*/
/*
 A) Only NONCLUSTERED indexes (index_id > 1) are corrupt:
      ALTER INDEX [IX_name] ON dbo.T DISABLE;  ALTER INDEX [IX_name] ON dbo.T REBUILD;
      (or DROP + CREATE from script). Rebuild reads the base table -> no data loss.
      Do NOT use ONLINE rebuild here - it can read the corrupt index.

 B) Heap / clustered (data) pages, few pages, have backups:
      -> Page restore: 34_point_in_time_recovery.sql 34.10
 C) Lots of damage, have backups:
      -> Tail-log (34.11) + full restore chain (10.5 generator) to a new name, validate, swap.
 D) AG database: restore the secondary copy? -> fail over to the healthy replica
      (corruption is usually NOT copied by log shipping/AG - pages are written independently).
 E) No usable backup (last resort):
      ALTER DATABASE [YourDB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
      BEGIN TRAN;                                                   -- optional: inspect before commit
      DBCC CHECKDB (N'YourDB', REPAIR_ALLOW_DATA_LOSS) WITH NO_INFOMSGS, ALL_ERRORMSGS;
      -- review output: which rows / pages were deallocated
      COMMIT;                                                      -- or ROLLBACK
      ALTER DATABASE [YourDB] SET MULTI_USER;
      DBCC CHECKCONSTRAINTS WITH ALL_CONSTRAINTS;                  -- repair ignores FK/CHECK logic
      -- REPAIR_REBUILD only fixes things that lose no data (rarely enough on its own).
 After ANY corruption: check storage (825s, disk/SAN/VM host logs), run CHECKDB again,
 take a full backup, schedule CHECKDB more often.
*/


/*=============================================================================
  35.5 DATABASE IN SUSPECT / RECOVERY_PENDING                          [BOX]
=============================================================================*/
-- 1) Read WHY in the error log (missing file? full disk? permission? corruption during recovery?)
EXEC sys.xp_readerrorlog 0, 1, N'YourDB';             -- <== change

-- 2) Simple causes - fix and bring online:
--    missing drive / permissions / disk full -> fix it, then:
-- ALTER DATABASE [YourDB] SET ONLINE;

/* 3) Damaged log / recovery can't complete, no good backup -> EMERGENCY mode repair:
ALTER DATABASE [YourDB] SET EMERGENCY;                       -- read-only access for sysadmins
-- Now you can SELECT data out first if you want (bcp / SSIS / INSERT INTO other DB)!
ALTER DATABASE [YourDB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DBCC CHECKDB (N'YourDB', REPAIR_ALLOW_DATA_LOSS) WITH NO_INFOMSGS, ALL_ERRORMSGS;   -- also rebuilds the log
ALTER DATABASE [YourDB] SET MULTI_USER;
-- Transactional consistency is LOST (half-finished transactions remain). Validate data with the app owners.
*/


/*=============================================================================
  35.6 LOG FILE LOST / DELETED                                          [BOX]
=============================================================================*/
/*
-- a) DB was shut down CLEANLY (e.g. detached / service stopped normally): attach and rebuild log
CREATE DATABASE [YourDB] ON (FILENAME = N'D:\Data\YourDB.mdf') FOR ATTACH_REBUILD_LOG;
-- b) Not clean (crash / log disappeared while online): restore from backup, or 35.5 step 3 (EMERGENCY repair).
-- After either: the log chain is broken -> take a FULL backup immediately.
*/


/*=============================================================================
  35.7 LONG CRASH RECOVERY - HOW FAR ALONG?                            [BOX]
  Phases: 1 analysis, 2 redo, 3 undo. Many VLFs / huge open transaction = slow.
=============================================================================*/
EXEC sys.xp_readerrorlog 0, 1, N'Recovery of database';   -- "...is 43% complete (approximately 512 seconds remain). Phase 2 of 3."
EXEC sys.xp_readerrorlog 0, 1, N'Recovery completed';

SELECT session_id, command, DB_NAME(database_id) AS database_name, percent_complete,
       estimated_completion_time / 1000 AS est_seconds_left, wait_type
FROM sys.dm_exec_requests
WHERE command IN (N'DB STARTUP', N'DB RECOVERY', N'ROLLBACK TRANSACTION', N'KILLED/ROLLBACK');
-- Don't restart the service to "speed it up" - recovery starts again from scratch.
-- 2019+: ADR (20.2) makes recovery/rollback near-instant - enable it for big OLTP DBs.


/*=============================================================================
  35.8 SYSTEM DATABASE RECOVERY                                         [BOX]
=============================================================================*/
/*
 ---- msdb (jobs, backup history) - instance can run without it ----
   Stop SQL Agent, then:  RESTORE DATABASE msdb FROM DISK = N'...\msdb.bak' WITH REPLACE;   Start Agent.

 ---- model ----
   RESTORE DATABASE model FROM DISK = N'...\model.bak' WITH REPLACE;
   (If model is corrupt the instance won't start -> start with trace flag 3608, restore model, restart.)

 ---- master: instance starts, master usable, want an older copy ----
   1. Stop SQL + Agent. Start single-user, only SQLCMD may connect:
        net start MSSQLSERVER /m"SQLCMD"                (named instance: MSSQL$INST1)
   2. sqlcmd -S . -E -Q "RESTORE DATABASE master FROM DISK = N'X:\bak\master.bak' WITH REPLACE"
      -> instance stops itself after master is restored.
   3. net start MSSQLSERVER ; check logins, linked servers, endpoints, DB list (DBs created after the
      backup must be re-attached: CREATE DATABASE ... FOR ATTACH).

 ---- master: instance will NOT start (master damaged) -> REBUILD system DBs ----
   setup.exe /QUIET /ACTION=REBUILDDATABASE /INSTANCENAME=MSSQLSERVER
             /SQLSYSADMINACCOUNTS="DOMAIN\DBA-Group" [/SAPWD="..."] [/SQLCOLLATION=...]
   (rebuilds master, model, msdb to fresh RTM state - patch level stays; resources in Setup Bootstrap folder)
   then restore master (steps above), then msdb, then model.

 ---- tempdb path missing / bad (instance won't start) ----
   net start MSSQLSERVER /f /m"SQLCMD"                  -- minimal config, tempdb created in default location
   sqlcmd -S . -E -Q "ALTER DATABASE tempdb MODIFY FILE (NAME = tempdev, FILENAME = N'T:\TempDB\tempdb.mdf'); ALTER DATABASE tempdb MODIFY FILE (NAME = templog, FILENAME = N'T:\TempDB\templog.ldf')"
   net stop MSSQLSERVER & net start MSSQLSERVER
   Azure VM tip: tempdb on D: (temporary disk) -> folder must exist at boot (SQL IaaS extension handles it,
   or a startup scheduled task creating D:\TempDB before the SQL service starts).

 Keep regular backups of master/msdb/model (Ola: @Databases = 'SYSTEM_DATABASES') and note
 the service startup parameters (00 0.7) + file locations (below).
*/
SELECT DB_NAME(database_id) AS database_name, name, physical_name
FROM sys.master_files WHERE database_id <= 4 ORDER BY database_id, file_id;

SELECT value_name, value_data FROM sys.dm_server_registry WHERE value_name LIKE N'SQLArg%';


/*=============================================================================
  35.9 LOCKED OUT: NO SYSADMIN LOGIN WORKS                              [BOX]
  Needs local Windows admin on the server. (Legitimate break-glass procedure.)
=============================================================================*/
/*
 1. net stop MSSQLSERVER  (and stop Agent / anything that grabs the single connection)
 2. net start MSSQLSERVER /m"SQLCMD"
 3. sqlcmd -S . -E        (connect as the local admin)
      CREATE LOGIN [DOMAIN\DBA-Group] FROM WINDOWS;
      ALTER SERVER ROLE sysadmin ADD MEMBER [DOMAIN\DBA-Group];
      GO
 4. net stop MSSQLSERVER & net start MSSQLSERVER & net start SQLSERVERAGENT
 (dbatools alternative: Reset-DbaAdmin -SqlInstance SQLVM1 -Login DOMAIN\DBA-Group)
*/


/*=============================================================================
  35.10 DEDICATED ADMIN CONNECTION (DAC) - WHEN NOTHING ELSE CONNECTS   [BOX][MI]
  Server hung (THREADPOOL, runaway queries): DAC has its own scheduler.
=============================================================================*/
SELECT name, value_in_use FROM sys.configurations WHERE name = N'remote admin connections';   -- 1 = DAC allowed remotely
-- EXEC sp_configure 'remote admin connections', 1; RECONFIGURE;    -- set this BEFORE you need it
-- Connect:  sqlcmd -S ADMIN:SQLVM1 -E      or SSMS "Database Engine Query" with server name ADMIN:SQLVM1
-- Is someone already on the DAC? (only one allowed)
SELECT s.session_id, s.login_name, s.host_name
FROM sys.dm_exec_sessions s JOIN sys.endpoints e ON e.endpoint_id = s.endpoint_id
WHERE e.name = N'Dedicated Admin Connection';


/*=============================================================================
  35.11 MOVE DATABASE FILES (disk full / new drive)                     [BOX]
=============================================================================*/
DECLARE @mvdb sysname = N'YourDB', @newdata nvarchar(260) = N'E:\Data\', @newlog nvarchar(260) = N'F:\Log\';   -- <== change
SELECT N'ALTER DATABASE ' + QUOTENAME(@mvdb) + N' MODIFY FILE (NAME = ' + QUOTENAME(name) + N', FILENAME = N'''
       + CASE type WHEN 1 THEN @newlog ELSE @newdata END
       + RIGHT(physical_name, CHARINDEX(N'\', REVERSE(physical_name)) - 1) + N''');' AS modify_cmd,
       physical_name AS current_path
FROM sys.master_files WHERE database_id = DB_ID(@mvdb);
/*
 Then: ALTER DATABASE [YourDB] SET OFFLINE WITH ROLLBACK IMMEDIATE;
       move the files (copy, keep NTFS permissions for the SQL service account)
       ALTER DATABASE [YourDB] SET ONLINE;
 AG database: can't go OFFLINE - remove from AG on that replica, or move on secondaries
 first with SQL stopped, then fail over.
 System DBs: msdb/model/tempdb same MODIFY FILE + restart; master = change -d/-l startup params.
*/


/*=============================================================================
  35.12 ALWAYS ON: CLUSTER LOST QUORUM / PRIMARY SITE DOWN               [BOX]
=============================================================================*/
/*
 1. On a surviving DR node, force the cluster up (PowerShell, as admin):
      Start-ClusterNode -Name SQLVM3 -FixQuorum          (or: net start clussvc /forcequorum)
      (Get-ClusterNode -Name SQLVM3).NodeWeight = 1      # adjust votes so the surviving set has quorum
 2. On that replica (AG is RESOLVING):
      ALTER AVAILABILITY GROUP [AG1] FORCE_FAILOVER_ALLOW_DATA_LOSS;
 3. Point apps at it (listener follows if its IP is valid in this subnet / DNN).
 4. When old replicas come back they are SUSPENDED (data-loss protection):
      - compare what's missing if needed (old primary had un-sent log),
      - ALTER DATABASE [YourDB] SET HADR RESUME;  on each secondary DB  (discards their extra changes)
      - If you need those extra changes: create a DB snapshot on the old primary BEFORE resuming
        and copy the rows from it.
 5. Restore normal quorum votes, re-enable automatic failover, take full backups.
 Check before step 2 how much you lose: 11_alwayson_ag.sql 11.4 (last_commit_time) if still readable.
*/
SELECT ag.name, ags.primary_replica, ags.primary_recovery_health_desc, ags.synchronization_health_desc
FROM sys.dm_hadr_availability_group_states ags JOIN sys.availability_groups ag ON ag.group_id = ags.group_id;
SELECT cluster_name, quorum_type_desc, quorum_state_desc FROM sys.dm_hadr_cluster;


/*=============================================================================
  35.13 AG SECONDARY DATABASE STUCK (NOT SYNCHRONIZING / RECOVERY PENDING) [BOX]
  When resume doesn't work (log chain gap, corruption on secondary): re-seed.
=============================================================================*/
/*
 Re-seed ONE secondary manually (other replicas untouched):
   SECONDARY: ALTER DATABASE [YourDB] SET HADR OFF;            -- leaves the AG locally, DB goes RESTORING
   PRIMARY:   BACKUP DATABASE [YourDB] ... ;  BACKUP LOG [YourDB] ... ;   (pause log backup jobs meanwhile)
   SECONDARY: RESTORE DATABASE [YourDB] FROM ... WITH NORECOVERY, REPLACE;
              RESTORE LOG [YourDB] FROM ... WITH NORECOVERY;  -- every log since that full
              ALTER DATABASE [YourDB] SET HADR AVAILABILITY GROUP = [AG1];
 Re-seed with AUTOMATIC seeding (affects ALL secondaries of this DB):
   PRIMARY:   ALTER AVAILABILITY GROUP [AG1] REMOVE DATABASE [YourDB];
   EACH SECONDARY: DROP DATABASE [YourDB];                      -- it's now a RESTORING leftover
   PRIMARY:   ALTER AVAILABILITY GROUP [AG1] ADD DATABASE [YourDB];
 Watch: 11_alwayson_ag.sql 11.11 (seeding) and 11.3 (sync).
*/
