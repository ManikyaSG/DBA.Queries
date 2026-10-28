/*******************************************************************************
 File    : 15_database_health_errorlog.sql
 Purpose : Daily health check - DB state, CHECKDB, corruption, config
           anti-patterns, error log search.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] Managed Instance   [SQLDB] Azure SQL DB
*******************************************************************************/

/*=============================================================================
  15.1 DATABASES NOT ONLINE / NOT MULTI_USER                          [BOX][MI]
=============================================================================*/
SELECT name, state_desc, user_access_desc, is_read_only, is_in_standby
FROM sys.databases
WHERE state_desc <> N'ONLINE' OR user_access_desc <> N'MULTI_USER';


/*=============================================================================
  15.2 LAST KNOWN GOOD CHECKDB (2016 SP2+)                            [BOX][MI]
=============================================================================*/
SELECT name,
       DATABASEPROPERTYEX(name, 'LastGoodCheckDbTime') AS last_good_checkdb,
       DATEDIFF(DAY, CAST(DATABASEPROPERTYEX(name, 'LastGoodCheckDbTime') AS datetime), GETDATE()) AS days_ago
FROM sys.databases
WHERE database_id <> 2 AND state_desc = N'ONLINE'
ORDER BY days_ago DESC;


/*=============================================================================
  15.3 SUSPECT PAGES (823/824 errors recorded in msdb)                [BOX][MI]
=============================================================================*/
SELECT DB_NAME(database_id) AS database_name, file_id, page_id,
       CASE event_type WHEN 1 THEN '823/824 error' WHEN 2 THEN 'Bad checksum' WHEN 3 THEN 'Torn page'
            WHEN 4 THEN 'Restored' WHEN 5 THEN 'Repaired' WHEN 7 THEN 'Deallocated by DBCC' END AS event_desc,
       error_count, last_update_date
FROM msdb.dbo.suspect_pages
ORDER BY last_update_date DESC;


/*=============================================================================
  15.4 AG AUTOMATIC PAGE REPAIR HISTORY                               [BOX]
=============================================================================*/
SELECT DB_NAME(database_id) AS database_name, file_id, page_id, error_type, page_status, modification_time
FROM sys.dm_hadr_auto_page_repair
ORDER BY modification_time DESC;


/*=============================================================================
  15.5 CONFIGURATION ANTI-PATTERNS                             [BOX][MI][SQLDB]
=============================================================================*/
SELECT name, finding FROM (
    SELECT name, 'AUTO_CLOSE is ON' AS finding FROM sys.databases WHERE is_auto_close_on = 1
    UNION ALL SELECT name, 'AUTO_SHRINK is ON' FROM sys.databases WHERE is_auto_shrink_on = 1
    UNION ALL SELECT name, 'PAGE_VERIFY is ' + page_verify_option_desc FROM sys.databases WHERE page_verify_option_desc <> N'CHECKSUM' AND database_id <> 2
    UNION ALL SELECT name, 'AUTO_UPDATE_STATISTICS is OFF' FROM sys.databases WHERE is_auto_update_stats_on = 0
    UNION ALL SELECT name, 'AUTO_CREATE_STATISTICS is OFF' FROM sys.databases WHERE is_auto_create_stats_on = 0
    UNION ALL SELECT name, 'Owner is NULL / orphaned SID' FROM sys.databases WHERE SUSER_SNAME(owner_sid) IS NULL
    UNION ALL SELECT name, 'Compat level ' + CAST(compatibility_level AS varchar(5)) + ' is below 130'
              FROM sys.databases WHERE compatibility_level < 130 AND database_id > 4
    UNION ALL SELECT name, 'Target recovery time is 0 (legacy checkpoints)' FROM sys.databases WHERE target_recovery_time_in_seconds = 0 AND database_id > 4
    UNION ALL SELECT name, 'Query Store is OFF' FROM sys.databases WHERE is_query_store_on = 0 AND database_id > 4
) AS x
ORDER BY name, finding;


/*=============================================================================
  15.6 ERROR LOG - SEARCH                                             [BOX][MI]
  xp_readerrorlog <log#: 0=current>, <1=SQL 2=Agent>, N'search1', N'search2'
=============================================================================*/
EXEC sys.xp_readerrorlog 0, 1, N'error';
-- EXEC sys.xp_readerrorlog 0, 1, N'I/O requests taking longer than 15 seconds';   -- storage stalls
-- EXEC sys.xp_readerrorlog 0, 1, N'stack dump';
-- EXEC sys.xp_readerrorlog 0, 1, N'Severity: 2';            -- severity 20-25
-- EXEC sys.xp_readerrorlog 0, 1, N'memory';                  -- paging / low memory
-- EXEC sys.xp_readerrorlog 0, 1, N'Recovery of database';    -- startup recovery progress
-- EXEC sys.xp_readerrorlog 0, 1, N'Always On', N'role';      -- AG role changes
-- EXEC sys.xp_readerrorlog 0, 2;                              -- Agent log


/*=============================================================================
  15.7 ERROR LOG FILE LIST (sizes / dates)                            [BOX][MI]
=============================================================================*/
EXEC sys.sp_enumerrorlogs;
-- EXEC sys.sp_cycle_errorlog;   -- start a new log (schedule weekly)


/*=============================================================================
  15.8 HIGH SEVERITY ERRORS FROM system_health (XE)                   [BOX][MI]
=============================================================================*/
SELECT
    x.ev.value('(event/@timestamp)[1]', 'datetime2')                     AS event_time_utc,
    x.ev.value('(event/data[@name="error_number"]/value)[1]', 'int')     AS error_number,
    x.ev.value('(event/data[@name="severity"]/value)[1]', 'int')         AS severity,
    x.ev.value('(event/data[@name="message"]/value)[1]', 'nvarchar(max)') AS message
FROM sys.fn_xe_file_target_read_file(N'system_health*.xel', NULL, NULL, NULL) AS f
CROSS APPLY (SELECT CAST(f.event_data AS xml)) AS x(ev)
WHERE f.object_name = N'error_reported'
ORDER BY event_time_utc DESC;


/*=============================================================================
  15.9 sp_server_diagnostics SNAPSHOT (what WSFC/AG health check sees) [BOX][MI]
=============================================================================*/
-- EXEC sys.sp_server_diagnostics;   -- returns system, resource, query_processing, io_subsystem, events


/*=============================================================================
  15.10 RUN CHECKDB (templates)                                [BOX][MI][SQLDB]
=============================================================================*/
/*
DBCC CHECKDB (N'YourDB') WITH NO_INFOMSGS, ALL_ERRORMSGS;
DBCC CHECKDB (N'YourDB') WITH PHYSICAL_ONLY, NO_INFOMSGS;   -- faster, for large DBs
-- On AG: offload to a secondary is OK, but corruption on the primary is only
-- detected by running it on the primary (or restoring its backups and checking).
*/
