/*******************************************************************************
 File    : 26_filestream_filetable.sql
 Purpose : FILESTREAM / FileTable configuration, containers, space, open
           handles, garbage collection, setup templates.
 Tags    : [BOX] 2016-2025 on Windows / Azure VM
           NOT supported on Azure SQL Database, Managed Instance or SQL on Linux.
*******************************************************************************/

/*=============================================================================
  26.1 INSTANCE FILESTREAM CONFIGURATION                              [BOX]
  Level: 0 = disabled, 1 = T-SQL access, 2 = T-SQL + Win32 streaming,
         3 = + remote client streaming (needed for FileTable share access)
  Configured (sp_configure) vs Effective (what's active after restart / service config).
=============================================================================*/
SELECT SERVERPROPERTY('FilestreamConfiguredLevel') AS configured_level,
       SERVERPROPERTY('FilestreamEffectiveLevel')  AS effective_level,
       SERVERPROPERTY('FilestreamShareName')       AS windows_share_name;

SELECT name, value, value_in_use FROM sys.configurations WHERE name = N'filestream access level';


/*=============================================================================
  26.2 DATABASES USING FILESTREAM + NON-TRANSACTED ACCESS (FileTable) [BOX]
=============================================================================*/
SELECT DB_NAME(fo.database_id) AS database_name,
       fo.non_transacted_access_desc,     -- OFF / READ_ONLY / FULL (FULL needed for FileTable writes via share)
       fo.directory_name
FROM sys.database_filestream_options AS fo
WHERE fo.non_transacted_access <> 0 OR fo.directory_name IS NOT NULL;

-- All FILESTREAM containers on the instance (filegroup detail: 26.3, per DB)
SELECT DB_NAME(mf.database_id) AS database_name, mf.name AS container_name, mf.physical_name, mf.state_desc
FROM sys.master_files AS mf
WHERE mf.type_desc = N'FILESTREAM'
ORDER BY database_name;


/*=============================================================================
  26.3 FILESTREAM FILEGROUPS & CONTAINERS - CURRENT DB                [BOX]
  size for FILESTREAM files is reported in 8 KB-page units like other files.
=============================================================================*/
SELECT fg.name AS filegroup_name, fg.type_desc, fg.is_default,
       df.name AS container_name, df.physical_name, df.state_desc,
       CAST(CAST(df.size AS bigint) * 8 / 1024.0 AS decimal(18,2)) AS size_mb,
       CASE df.max_size WHEN -1 THEN 'Unlimited' ELSE CAST(CAST(df.max_size AS bigint) * 8 / 1024 AS varchar(20)) + ' MB' END AS max_size
FROM sys.filegroups AS fg
JOIN sys.database_files AS df ON df.data_space_id = fg.data_space_id
WHERE fg.type = 'FD'
ORDER BY fg.name, df.name;


/*=============================================================================
  26.4 TABLES / COLUMNS STORING FILESTREAM DATA - CURRENT DB          [BOX]
=============================================================================*/
SELECT OBJECT_SCHEMA_NAME(c.object_id) + N'.' + OBJECT_NAME(c.object_id) AS table_name,
       c.name AS filestream_column, ds.name AS filestream_filegroup,
       (SELECT SUM(p.rows) FROM sys.partitions p WHERE p.object_id = c.object_id AND p.index_id IN (0, 1)) AS row_count
FROM sys.columns AS c
JOIN sys.tables AS t ON t.object_id = c.object_id
LEFT JOIN sys.data_spaces AS ds ON ds.data_space_id = t.filestream_data_space_id
WHERE c.is_filestream = 1
ORDER BY table_name;

-- Logical size of FILESTREAM data in one table (scans the column - can be slow):
-- SELECT COUNT(*) AS blobs, SUM(DATALENGTH(FileData)) / 1048576 AS total_mb, MAX(DATALENGTH(FileData)) / 1048576 AS largest_mb FROM dbo.Documents;


/*=============================================================================
  26.5 FILETABLES - CURRENT DB                                        [BOX]
  UNC path: \\<server>\<FilestreamShareName>\<db directory_name>\<filetable directory>
=============================================================================*/
SELECT OBJECT_SCHEMA_NAME(ft.object_id) + N'.' + OBJECT_NAME(ft.object_id) AS filetable_name,
       ft.directory_name, ft.is_enabled, ft.filename_collation_name,
       FileTableRootPath(OBJECT_SCHEMA_NAME(ft.object_id) + N'.' + OBJECT_NAME(ft.object_id)) AS unc_root_path
FROM sys.filetables AS ft;

-- Contents summary of one FileTable
/*
SELECT COUNT(*) AS items,
       SUM(CASE WHEN is_directory = 1 THEN 1 ELSE 0 END) AS folders,
       SUM(CAST(cached_file_size AS bigint)) / 1048576 AS total_mb,
       MAX(last_write_time) AS last_write
FROM dbo.YourFileTable;
*/


/*=============================================================================
  26.6 OPEN NON-TRANSACTED HANDLES (who has FileTable files open)      [BOX]
  Open handles block ALTER DATABASE / disabling non-transacted access.
=============================================================================*/
SELECT DB_NAME(database_id) AS database_name, OBJECT_NAME(object_id, database_id) AS filetable_name,
       handle_id, opened_file_name, login_name, open_time, read_access, write_access, share_read, share_write
FROM sys.dm_filestream_non_transacted_handles
ORDER BY open_time;
-- Kill all handles in a DB:  EXEC sp_kill_filestream_non_transacted_handles @dbname = N'YourDB';
-- Kill one handle:            EXEC sp_kill_filestream_non_transacted_handles @dbname = N'YourDB', @filetable = N'dbo.Docs', @handle_id = 123;


/*=============================================================================
  26.7 GARBAGE COLLECTION (disk space not freed after deletes)         [BOX]
  Deleted FILESTREAM files are removed only after a checkpoint AND, in FULL
  recovery, a log backup has passed the delete. Then GC deletes them.
=============================================================================*/
/*
CHECKPOINT;
BACKUP LOG [YourDB] TO DISK = N'...';          -- FULL / BULK_LOGGED recovery
EXEC sp_filestream_force_garbage_collection @dbname = N'YourDB';
-- Returns: file_name, num_collected_items, num_marked_for_collection_items, num_unprocessed_items, last_collected_lsn
-- Run it a few times; items move from "marked" to "collected".
*/


/*=============================================================================
  26.8 FILESTREAM-RELATED WAITS                                        [BOX]
=============================================================================*/
SELECT wait_type, waiting_tasks_count, wait_time_ms,
       CAST(wait_time_ms * 1.0 / NULLIF(waiting_tasks_count, 0) AS decimal(10,2)) AS avg_wait_ms
FROM sys.dm_os_wait_stats
WHERE (wait_type LIKE N'FS%' OR wait_type LIKE N'FILESTREAM%' OR wait_type LIKE N'%FSAGENT%' OR wait_type LIKE N'FFT%')
  AND waiting_tasks_count > 0
ORDER BY wait_time_ms DESC;


/*=============================================================================
  26.9 TEMPLATES - ENABLE FILESTREAM & CREATE A FILETABLE              [BOX]
=============================================================================*/
/*
-- 1. SQL Server Configuration Manager -> SQL Server service -> FILESTREAM tab
--    -> enable T-SQL / file I/O / remote clients, set share name. (Windows only)
-- 2. Instance access level:
EXEC sp_configure 'filestream access level', 2;    -- 2 = T-SQL + Win32
RECONFIGURE;

-- 3. Database filegroup + container (folder must NOT exist; parent must):
ALTER DATABASE [YourDB] ADD FILEGROUP [FS_FG] CONTAINS FILESTREAM;
ALTER DATABASE [YourDB] ADD FILE (NAME = N'YourDB_FS', FILENAME = N'F:\FSData\YourDB_FS') TO FILEGROUP [FS_FG];

-- 4a. FILESTREAM column (table needs a ROWGUIDCOL UNIQUE column):
CREATE TABLE dbo.Documents (
    DocID    uniqueidentifier ROWGUIDCOL NOT NULL UNIQUE DEFAULT NEWSEQUENTIALID(),
    FileName nvarchar(260) NOT NULL,
    FileData varbinary(max) FILESTREAM NULL
) FILESTREAM_ON [FS_FG];

-- 4b. FileTable:
ALTER DATABASE [YourDB] SET FILESTREAM (NON_TRANSACTED_ACCESS = FULL, DIRECTORY_NAME = N'YourDB');
CREATE TABLE dbo.Docs AS FILETABLE
  WITH (FILETABLE_DIRECTORY = N'Docs', FILETABLE_COLLATE_FILENAME = database_default);

-- Add another container to spread IO / space (2012+ supports multiple containers):
ALTER DATABASE [YourDB] ADD FILE (NAME = N'YourDB_FS2', FILENAME = N'G:\FSData\YourDB_FS2') TO FILEGROUP [FS_FG];
*/


/*=============================================================================
  26.10 FILESTREAM + ALWAYS ON / BACKUP NOTES                          [BOX]
=============================================================================*/
/*
 - FILESTREAM DBs can be in an AG; enable FILESTREAM (same level) on EVERY replica
   before adding the DB. FileTable non-transacted access works on the primary; use
   the AG VNN (listener-based) share name for client access across failovers.
 - Backups include FILESTREAM data - expect large backups; container growth is not
   visible in the DB size until you include FILESTREAM files (8.6 / 26.3).
 - Antivirus must exclude FILESTREAM container folders.
 - Azure SQL DB / MI: no FILESTREAM - store blobs in Azure Blob Storage and keep
   the URL / metadata in the database.
*/
