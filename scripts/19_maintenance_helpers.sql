/*******************************************************************************
 File    : 19_maintenance_helpers.sql
 Purpose : Script generators and one-off helpers: index/stats maintenance,
           log shrink, object search, row counts, owners.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] Managed Instance   [SQLDB] Azure SQL DB
 Note    : Generators only OUTPUT statements - review before executing.
           For scheduled maintenance, Ola Hallengren's Maintenance Solution
           (IndexOptimize / DatabaseIntegrityCheck / DatabaseBackup) is the
           de-facto standard.
*******************************************************************************/

/*=============================================================================
  19.1 GENERATE INDEX REORG / REBUILD - CURRENT DB             [BOX][MI][SQLDB]
=============================================================================*/
DECLARE @online bit = CASE WHEN SERVERPROPERTY('EngineEdition') IN (3, 5, 8) THEN 1 ELSE 0 END;  -- Ent / Azure

SELECT
    OBJECT_SCHEMA_NAME(ips.object_id) + N'.' + OBJECT_NAME(ips.object_id) AS table_name,
    i.name AS index_name, ips.partition_number,
    CAST(ips.avg_fragmentation_in_percent AS decimal(5,2)) AS frag_pct, ips.page_count,
    N'ALTER INDEX ' + QUOTENAME(i.name) + N' ON '
      + QUOTENAME(OBJECT_SCHEMA_NAME(ips.object_id)) + N'.' + QUOTENAME(OBJECT_NAME(ips.object_id))
      + CASE WHEN ips.avg_fragmentation_in_percent >= 30
             THEN N' REBUILD' + CASE WHEN p.partitions > 1 THEN N' PARTITION = ' + CAST(ips.partition_number AS nvarchar(10)) ELSE N'' END
                  + N' WITH (SORT_IN_TEMPDB = ON' + CASE WHEN @online = 1 THEN N', ONLINE = ON' ELSE N'' END + N')'
             ELSE N' REORGANIZE' + CASE WHEN p.partitions > 1 THEN N' PARTITION = ' + CAST(ips.partition_number AS nvarchar(10)) ELSE N'' END
        END + N';' AS maintenance_cmd
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') AS ips
JOIN sys.indexes AS i ON i.object_id = ips.object_id AND i.index_id = ips.index_id
CROSS APPLY (SELECT COUNT(*) AS partitions FROM sys.partitions AS pp
             WHERE pp.object_id = i.object_id AND pp.index_id = i.index_id) AS p
WHERE ips.avg_fragmentation_in_percent >= 5
  AND ips.page_count >= 1000
  AND ips.index_id > 0
  AND i.is_disabled = 0
  AND ips.alloc_unit_type_desc = 'IN_ROW_DATA'
ORDER BY ips.page_count DESC;


/*=============================================================================
  19.2 GENERATE UPDATE STATISTICS FOR STALE STATS - CURRENT DB [BOX][MI][SQLDB]
=============================================================================*/
DECLARE @min_mod_pct decimal(5,2) = 10.0;
SELECT
    OBJECT_SCHEMA_NAME(s.object_id) + N'.' + OBJECT_NAME(s.object_id) AS table_name,
    s.name AS stats_name, sp.rows, sp.modification_counter, sp.last_updated,
    N'UPDATE STATISTICS ' + QUOTENAME(OBJECT_SCHEMA_NAME(s.object_id)) + N'.' + QUOTENAME(OBJECT_NAME(s.object_id))
      + N' ' + QUOTENAME(s.name) + N' WITH FULLSCAN;' AS update_cmd
FROM sys.stats AS s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
WHERE OBJECTPROPERTY(s.object_id, 'IsUserTable') = 1
  AND sp.rows > 0
  AND 100.0 * sp.modification_counter / sp.rows >= @min_mod_pct
ORDER BY sp.modification_counter DESC;
-- Whole DB, sampled:  EXEC sp_updatestats;


/*=============================================================================
  19.3 SHRINK / RESIZE TRANSACTION LOG SAFELY (fix VLFs)               [BOX][MI]
  1. check log_reuse_wait_desc = NOTHING (08_storage 8.7)  2. take log backup
  3. shrink  4. regrow to the right size in one or a few large steps.
=============================================================================*/
/*
USE [YourDB];
SELECT name, log_reuse_wait_desc FROM sys.databases WHERE name = DB_NAME();
BACKUP LOG [YourDB] TO DISK = N'...';
DBCC SHRINKFILE (N'YourDB_log', 1024);          -- target MB
ALTER DATABASE [YourDB] MODIFY FILE (NAME = N'YourDB_log', SIZE = 16384MB, FILEGROWTH = 4096MB);
*/


/*=============================================================================
  19.4 FIND AN OBJECT BY NAME ACROSS ALL DATABASES                    [BOX][MI]
=============================================================================*/
DECLARE @obj nvarchar(128) = N'%Customer%';   -- <== change
IF OBJECT_ID('tempdb..#found') IS NOT NULL DROP TABLE #found;
CREATE TABLE #found (database_name sysname, schema_name sysname, object_name sysname, type_desc nvarchar(60), modify_date datetime);
DECLARE @sql nvarchar(max) = N'';
SELECT @sql += N'USE ' + QUOTENAME(name) + N';
INSERT #found SELECT DB_NAME(), SCHEMA_NAME(schema_id), name, type_desc, modify_date FROM sys.objects WHERE name LIKE @p;
'
FROM sys.databases WHERE state_desc = N'ONLINE' AND HAS_DBACCESS(name) = 1;
EXEC sys.sp_executesql @sql, N'@p nvarchar(128)', @p = @obj;
SELECT * FROM #found ORDER BY database_name, object_name;


/*=============================================================================
  19.5 FIND A COLUMN BY NAME - CURRENT DB                      [BOX][MI][SQLDB]
=============================================================================*/
SELECT OBJECT_SCHEMA_NAME(c.object_id) + N'.' + OBJECT_NAME(c.object_id) AS table_name,
       c.name AS column_name, TYPE_NAME(c.user_type_id) AS data_type, c.max_length, c.is_nullable
FROM sys.columns AS c
JOIN sys.objects AS o ON o.object_id = c.object_id AND o.type IN ('U', 'V')
WHERE c.name LIKE N'%Email%'                    -- <== change
ORDER BY table_name;


/*=============================================================================
  19.6 SEARCH CODE (procs, views, functions, triggers) - CURRENT DB
                                                               [BOX][MI][SQLDB]
=============================================================================*/
SELECT OBJECT_SCHEMA_NAME(m.object_id) + N'.' + OBJECT_NAME(m.object_id) AS object_name,
       o.type_desc, o.modify_date
FROM sys.sql_modules AS m
JOIN sys.objects AS o ON o.object_id = m.object_id
WHERE m.definition LIKE N'%YourSearchText%'      -- <== change
ORDER BY object_name;


/*=============================================================================
  19.7 FAST ROW COUNTS - CURRENT DB (no table scans)           [BOX][MI][SQLDB]
=============================================================================*/
SELECT OBJECT_SCHEMA_NAME(object_id) + N'.' + OBJECT_NAME(object_id) AS table_name,
       SUM(row_count) AS row_count
FROM sys.dm_db_partition_stats
WHERE index_id IN (0, 1) AND OBJECTPROPERTY(object_id, 'IsUserTable') = 1
GROUP BY object_id
ORDER BY row_count DESC;


/*=============================================================================
  19.8 RECENTLY MODIFIED OBJECTS (what changed?) - CURRENT DB  [BOX][MI][SQLDB]
=============================================================================*/
SELECT TOP (50) SCHEMA_NAME(schema_id) + N'.' + name AS object_name, type_desc, create_date, modify_date
FROM sys.objects
WHERE is_ms_shipped = 0
ORDER BY modify_date DESC;


/*=============================================================================
  19.9 SET DATABASE OWNER TO sa (generator)                           [BOX][MI]
=============================================================================*/
SELECT name, SUSER_SNAME(owner_sid) AS current_owner,
       N'ALTER AUTHORIZATION ON DATABASE::' + QUOTENAME(name) + N' TO [sa];' AS fix_cmd
FROM sys.databases
WHERE ISNULL(SUSER_SNAME(owner_sid), N'') <> N'sa' AND database_id > 4;


/*=============================================================================
  19.10 KICK EVERYONE OUT OF A DATABASE (templates)            [BOX][MI]
=============================================================================*/
/*
ALTER DATABASE [YourDB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
-- ... do the work ...
ALTER DATABASE [YourDB] SET MULTI_USER;

-- Or just generate KILLs for that DB:
SELECT 'KILL ' + CAST(session_id AS varchar(10)) + ';'
FROM sys.dm_exec_sessions WHERE database_id = DB_ID(N'YourDB') AND session_id <> @@SPID;
*/


/*=============================================================================
  19.11 MIGRATING LOGINS (with SIDs and password hashes)
=============================================================================*/
-- Use Microsoft's sp_help_revlogin (KB918992) or dbatools:
--   Copy-DbaLogin -Source SQL1 -Destination SQL2
--   Sync-DbaAvailabilityGroup -Primary SQL1 -AvailabilityGroup AG1   (logins + jobs to AG replicas)
