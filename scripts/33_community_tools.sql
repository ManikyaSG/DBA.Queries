/*******************************************************************************
 File    : 33_community_tools.sql
 Purpose : Ready-to-run calls for the community tools the toolkit relies on:
             sp_WhoIsActive (Adam Machanic)
             First Responder Kit (Brent Ozar) - sp_Blitz, sp_BlitzFirst,
               sp_BlitzCache, sp_BlitzIndex, sp_BlitzLock, sp_BlitzWho
             Ola Hallengren Maintenance Solution - DatabaseBackup,
               DatabaseIntegrityCheck, IndexOptimize, CommandLog
             Glenn Berry's Diagnostic Information Queries
 Install : community-tools/Install-CommunityTools.ps1 (dbatools) - installs
           into a DBA database (default DBAdmin). Run `USE DBAdmin;` first or
           prefix calls with DBAdmin.dbo.
 Tags    : [BOX] [MI] everywhere; [SQLDB] noted per tool.
 Note    : Parameter names below are the commonly used ones - each proc
           documents itself: EXEC sp_Blitz @Help = 1; / sp_WhoIsActive @help = 1;
*******************************************************************************/

/*=============================================================================
  33.1 WHAT'S INSTALLED, WHERE, WHICH VERSION                         [BOX][MI]
=============================================================================*/
IF OBJECT_ID('tempdb..#tools') IS NOT NULL DROP TABLE #tools;
CREATE TABLE #tools (database_name sysname, proc_name sysname, modify_date datetime);
DECLARE @sql nvarchar(max) = N'';
SELECT @sql += N'USE ' + QUOTENAME(name) + N';
INSERT #tools SELECT DB_NAME(), name, modify_date FROM sys.procedures
WHERE name IN (''sp_WhoIsActive'',''sp_Blitz'',''sp_BlitzFirst'',''sp_BlitzCache'',''sp_BlitzIndex'',''sp_BlitzLock'',''sp_BlitzWho'',
               ''DatabaseBackup'',''DatabaseIntegrityCheck'',''IndexOptimize'',''CommandExecute'');
'
FROM sys.databases WHERE state_desc = N'ONLINE' AND HAS_DBACCESS(name) = 1;
EXEC sys.sp_executesql @sql;
SELECT * FROM #tools ORDER BY proc_name, database_name;
-- Version of a FRK proc:  DECLARE @v varchar(30), @d datetime; EXEC sp_Blitz @VersionCheckMode = 1, @Version = @v OUTPUT, @VersionDate = @d OUTPUT; SELECT @v, @d;


/*=============================================================================
  33.2 sp_WhoIsActive - LIVE ACTIVITY                          [BOX][MI][SQLDB]
=============================================================================*/
-- Everyday view
EXEC sp_WhoIsActive;

-- Blocking: who's at the head of the chain, sorted by how many they block
EXEC sp_WhoIsActive @find_block_leaders = 1, @sort_order = '[blocked_session_count] DESC', @get_locks = 1;

-- Full detail for troubleshooting a slow query
EXEC sp_WhoIsActive @get_plans = 1, @get_outer_command = 1, @get_transaction_info = 1,
                    @get_task_info = 2, @get_additional_info = 1;

-- What's consuming RIGHT NOW (5-second delta of CPU/reads/writes)
EXEC sp_WhoIsActive @delta_interval = 5, @sort_order = '[CPU_delta] DESC';

-- Include sleeping sessions with open transactions (forgotten COMMIT)
EXEC sp_WhoIsActive @show_sleeping_spids = 1, @get_transaction_info = 1;

-- Filter to one database / login / host / program
EXEC sp_WhoIsActive @filter_type = 'database', @filter = 'YourDB';
EXEC sp_WhoIsActive @filter_type = 'login',    @filter = 'DOMAIN\appuser';

-- Log to a table every N minutes (Agent job) for "what happened at 3am?"
/*
DECLARE @schema nvarchar(max);
EXEC sp_WhoIsActive @get_plans = 1, @get_transaction_info = 1, @find_block_leaders = 1,
                    @return_schema = 1, @schema = @schema OUTPUT;
SET @schema = REPLACE(@schema, '<table_name>', 'DBAdmin.dbo.WhoIsActiveLog');
EXEC (@schema);                                        -- create table once
-- Job step (every 1-5 min):
EXEC sp_WhoIsActive @get_plans = 1, @get_transaction_info = 1, @find_block_leaders = 1,
                    @destination_table = 'DBAdmin.dbo.WhoIsActiveLog';
-- Purge: DELETE DBAdmin.dbo.WhoIsActiveLog WHERE collection_time < DATEADD(DAY, -7, GETDATE());
*/
-- Query the log:
-- SELECT collection_time, session_id, blocking_session_id, [dd hh:mm:ss.mss], database_name, login_name, sql_text, wait_info
-- FROM DBAdmin.dbo.WhoIsActiveLog WHERE collection_time BETWEEN '2026-10-28 02:55' AND '2026-10-28 03:15' ORDER BY collection_time;


/*=============================================================================
  33.3 sp_Blitz - OVERALL HEALTH CHECK (prioritised findings)  [BOX][MI][SQLDB*]
=============================================================================*/
EXEC sp_Blitz;                                             -- priority 1-50 = fix soon
EXEC sp_Blitz @CheckServerInfo = 1;                        -- + server info section
EXEC sp_Blitz @CheckUserDatabaseObjects = 1, @CheckServerInfo = 1;   -- deeper, slower
-- EXEC sp_Blitz @IgnorePrioritiesAbove = 50;              -- only important stuff
-- EXEC sp_Blitz @OutputType = 'MARKDOWN';                 -- paste into a ticket / git issue
-- *Azure SQL DB: several FRK procs work; sp_Blitz is box/MI focused.


/*=============================================================================
  33.4 sp_BlitzFirst - "WHY IS IT SLOW RIGHT NOW?"              [BOX][MI][SQLDB]
=============================================================================*/
EXEC sp_BlitzFirst;                                        -- 5-second sample with findings
EXEC sp_BlitzFirst @Seconds = 30, @ExpertMode = 1;         -- longer sample + waits/file stats/perfmon
EXEC sp_BlitzFirst @SinceStartup = 1;                      -- waits, file stats since restart

-- Log every 15 min to tables (great baseline; feeds the Power BI dashboard from the FRK repo)
/*
EXEC sp_BlitzFirst @OutputDatabaseName = 'DBAdmin', @OutputSchemaName = 'dbo',
     @OutputTableName              = 'BlitzFirst',
     @OutputTableNameFileStats     = 'BlitzFirst_FileStats',
     @OutputTableNamePerfmonStats  = 'BlitzFirst_PerfmonStats',
     @OutputTableNameWaitStats     = 'BlitzFirst_WaitStats',
     @OutputTableNameBlitzCache    = 'BlitzCache',
     @OutputTableNameBlitzWho      = 'BlitzWho';
*/


/*=============================================================================
  33.5 sp_BlitzCache - WORST QUERIES IN THE PLAN CACHE          [BOX][MI][SQLDB]
  @SortOrder: 'cpu' 'reads' 'writes' 'duration' 'executions' 'memory grant'
              'spills' 'avg cpu' 'avg reads' 'avg duration' 'xpm' (execs/min)
=============================================================================*/
EXEC sp_BlitzCache @SortOrder = 'cpu', @Top = 10;
EXEC sp_BlitzCache @SortOrder = 'reads', @Top = 10;
EXEC sp_BlitzCache @SortOrder = 'memory grant', @Top = 10;
EXEC sp_BlitzCache @SortOrder = 'cpu', @DatabaseName = 'YourDB', @Top = 10;
EXEC sp_BlitzCache @StoredProcName = 'usp_YourProc';       -- one proc
-- EXEC sp_BlitzCache @ExpertMode = 1, @SortOrder = 'duration';
-- Query Store version of this view: 04_query_store.sql


/*=============================================================================
  33.6 sp_BlitzIndex - INDEX DESIGN REVIEW                      [BOX][MI][SQLDB]
  @Mode 0 = diagnose (default), 1 = summary, 2 = inventory of all indexes,
        3 = missing indexes, 4 = in-depth diagnose
=============================================================================*/
EXEC sp_BlitzIndex @DatabaseName = 'YourDB';                                  -- prioritised findings
EXEC sp_BlitzIndex @DatabaseName = 'YourDB', @SchemaName = 'dbo', @TableName = 'Orders';   -- one table, full detail
EXEC sp_BlitzIndex @DatabaseName = 'YourDB', @Mode = 3;                       -- missing indexes
EXEC sp_BlitzIndex @DatabaseName = 'YourDB', @Mode = 2;                       -- inventory (export to Excel)
-- EXEC sp_BlitzIndex @GetAllDatabases = 1;                                    -- whole instance (can be slow)
-- Raw DMV equivalents: 05_indexes_statistics.sql, 24_index_tuning.sql


/*=============================================================================
  33.7 sp_BlitzLock - DEADLOCK ANALYSIS                         [BOX][MI][SQLDB]
=============================================================================*/
EXEC sp_BlitzLock;                                                 -- from system_health
EXEC sp_BlitzLock @StartDate = '2026-10-27', @EndDate = '2026-10-28';
EXEC sp_BlitzLock @DatabaseName = 'YourDB';
-- Raw XE equivalents: 12_locking_deadlocks.sql 12.5 / 12.6


/*=============================================================================
  33.8 sp_BlitzWho - LIGHTWEIGHT "WHO'S RUNNING" (FRK)          [BOX][MI][SQLDB]
=============================================================================*/
EXEC sp_BlitzWho;
EXEC sp_BlitzWho @ExpertMode = 1;


/*=============================================================================
  33.9 OLA HALLENGREN - BACKUPS                                       [BOX][MI]
  Always On aware: honours backup preference (sys.fn_hadr_backup_is_preferred_replica)
  - deploy the same job on every replica.
=============================================================================*/
/*
-- Full, all user DBs, verify + checksum + compression, delete files older than 7 days
EXECUTE dbo.DatabaseBackup
    @Databases   = 'USER_DATABASES',
    @Directory   = N'\\backupshare\SQL',
    @BackupType  = 'FULL',
    @Verify      = 'Y',
    @Compress    = 'Y',
    @CheckSum    = 'Y',
    @CleanupTime = 168,           -- hours
    @LogToTable  = 'Y';

-- Differential / log
EXECUTE dbo.DatabaseBackup @Databases = 'USER_DATABASES', @Directory = N'\\backupshare\SQL', @BackupType = 'DIFF', @CheckSum = 'Y', @Compress = 'Y', @LogToTable = 'Y';
EXECUTE dbo.DatabaseBackup @Databases = 'USER_DATABASES', @Directory = N'\\backupshare\SQL', @BackupType = 'LOG',  @CheckSum = 'Y', @Compress = 'Y', @CleanupTime = 72, @LogToTable = 'Y';

-- Only AG databases / exclude some
EXECUTE dbo.DatabaseBackup @Databases = 'AVAILABILITY_GROUP_DATABASES', @Directory = N'\\backupshare\SQL', @BackupType = 'LOG', @LogToTable = 'Y';
EXECUTE dbo.DatabaseBackup @Databases = 'USER_DATABASES, -BigArchiveDB', @Directory = N'\\backupshare\SQL', @BackupType = 'FULL', @LogToTable = 'Y';

-- Backup to Azure Blob (SAS credential named after the container URL)
EXECUTE dbo.DatabaseBackup @Databases = 'USER_DATABASES', @URL = N'https://<acct>.blob.core.windows.net/<container>',
        @BackupType = 'FULL', @Compress = 'Y', @CheckSum = 'Y', @LogToTable = 'Y';
-- Managed Instance: only COPY_ONLY to URL ->  add @CopyOnly = 'Y'
*/


/*=============================================================================
  33.10 OLA HALLENGREN - INTEGRITY CHECK                              [BOX][MI]
=============================================================================*/
/*
EXECUTE dbo.DatabaseIntegrityCheck @Databases = 'ALL_DATABASES', @CheckCommands = 'CHECKDB', @LogToTable = 'Y';
-- Big DBs: physical only on weekdays, full at the weekend; or spread with time limit
EXECUTE dbo.DatabaseIntegrityCheck @Databases = 'USER_DATABASES', @CheckCommands = 'CHECKDB', @PhysicalOnly = 'Y', @LogToTable = 'Y';
EXECUTE dbo.DatabaseIntegrityCheck @Databases = 'USER_DATABASES', @CheckCommands = 'CHECKDB', @TimeLimit = 14400, @LogToTable = 'Y';
*/


/*=============================================================================
  33.11 OLA HALLENGREN - INDEX & STATISTICS MAINTENANCE        [BOX][MI][SQLDB*]
=============================================================================*/
/*
EXECUTE dbo.IndexOptimize
    @Databases              = 'USER_DATABASES',
    @FragmentationLow       = NULL,
    @FragmentationMedium    = 'INDEX_REORGANIZE,INDEX_REBUILD_ONLINE,INDEX_REBUILD_OFFLINE',
    @FragmentationHigh      = 'INDEX_REBUILD_ONLINE,INDEX_REBUILD_OFFLINE',
    @FragmentationLevel1    = 5,
    @FragmentationLevel2    = 30,
    @MinNumberOfPages       = 1000,
    @UpdateStatistics       = 'ALL',
    @OnlyModifiedStatistics = 'Y',
    @LogToTable             = 'Y';

-- Statistics only (often the bigger win on SSD/SAN):
EXECUTE dbo.IndexOptimize @Databases = 'USER_DATABASES',
        @FragmentationLow = NULL, @FragmentationMedium = NULL, @FragmentationHigh = NULL,
        @UpdateStatistics = 'ALL', @OnlyModifiedStatistics = 'Y', @LogToTable = 'Y';
-- *Azure SQL DB: install the scripts in the user DB and schedule with Elastic Jobs / Azure Automation.
*/


/*=============================================================================
  33.12 OLA HALLENGREN - WHAT DID LAST NIGHT'S MAINTENANCE DO? (CommandLog)
                                                                      [BOX][MI]
=============================================================================*/
-- Failures in the last 24 hours
SELECT StartTime, EndTime, DatabaseName, CommandType, ObjectName, IndexName, ErrorNumber, ErrorMessage, Command
FROM dbo.CommandLog
WHERE ErrorNumber <> 0 AND StartTime >= DATEADD(DAY, -1, GETDATE())
ORDER BY StartTime DESC;

-- Duration per command type per night
SELECT CAST(StartTime AS date) AS run_date, CommandType, COUNT(*) AS commands,
       SUM(DATEDIFF(SECOND, StartTime, EndTime)) / 60 AS total_minutes,
       SUM(CASE WHEN ErrorNumber <> 0 THEN 1 ELSE 0 END) AS errors
FROM dbo.CommandLog
WHERE StartTime >= DATEADD(DAY, -14, GETDATE())
GROUP BY CAST(StartTime AS date), CommandType
ORDER BY run_date DESC, total_minutes DESC;

-- Slowest index operations (candidates for different strategy)
SELECT TOP (20) DatabaseName, SchemaName + '.' + ObjectName AS table_name, IndexName, CommandType,
       DATEDIFF(SECOND, StartTime, EndTime) AS seconds,
       ExtendedInfo.value('(ExtendedInfo/Fragmentation)[1]', 'decimal(5,2)') AS frag_before,
       ExtendedInfo.value('(ExtendedInfo/PageCount)[1]', 'bigint')           AS page_count
FROM dbo.CommandLog
WHERE CommandType IN ('ALTER_INDEX', 'UPDATE_STATISTICS') AND StartTime >= DATEADD(DAY, -7, GETDATE())
ORDER BY seconds DESC;

-- Ola's job list & last outcome (job names start with the proc name)
SELECT j.name, j.enabled, js.last_run_outcome,
       CASE WHEN js.last_run_date > 0 THEN msdb.dbo.agent_datetime(js.last_run_date, js.last_run_time) END AS last_run
FROM msdb.dbo.sysjobs j LEFT JOIN msdb.dbo.sysjobservers js ON js.job_id = j.job_id
WHERE j.name LIKE N'DatabaseBackup%' OR j.name LIKE N'DatabaseIntegrityCheck%' OR j.name LIKE N'IndexOptimize%'
   OR j.name IN (N'CommandLog Cleanup', N'Output File Cleanup', N'sp_delete_backuphistory', N'sp_purge_jobhistory')
ORDER BY j.name;

-- Keep CommandLog small
-- DELETE dbo.CommandLog WHERE StartTime < DATEADD(DAY, -30, GETDATE());


/*=============================================================================
  33.13 GLENN BERRY'S DIAGNOSTIC INFORMATION QUERIES
=============================================================================*/
/*
 - Version-specific scripts (one per SQL version + Azure SQL DB + MI) with ~70-80 numbered
   queries each, updated monthly. Pick the file matching your version (27.1 / 20.12).
 - Get the latest:      Save-DbaDiagnosticQueryScript -Path C:\DBA\GlennBerry          (dbatools)
   or run them all and export to Excel / CSV in one go:
       Invoke-DbaDiagnosticQuery -SqlInstance SQLVM1 | Export-DbaDiagnosticQuery -Path C:\DBA\Reports
       Invoke-DbaDiagnosticQuery -SqlInstance SQLVM1 -QueryName 'Top Waits','Memory Clerk Usage'
       Invoke-DbaDiagnosticQuery -SqlInstance SQLVM1 -DatabaseSpecific -DatabaseName YourDB
 - Good practice: run instance-level queries top to bottom once per new server you take over,
   and keep the exported results as a baseline in your DBA share.
*/
