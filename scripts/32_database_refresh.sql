/*******************************************************************************
 File    : 32_database_refresh.sql
 Purpose : Refresh a lower environment (DEV/UAT/QA) from a production backup
           while keeping the TARGET's users, permissions and settings:
           capture -> restore with MOVE -> re-apply -> clean up -> sanitize
           -> validate.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] (restore from URL)
           Azure SQL DB: refresh = database copy / point-in-time restore +
           re-apply 32.2 output (CREATE DATABASE x AS COPY OF server.db).
 Order   : 32.1 -> 32.2 (SAVE OUTPUT!) -> 32.3 -> 32.4 -> 32.5 -> 32.6 ->
           32.7 -> 32.8 -> 32.9
*******************************************************************************/

/*=============================================================================
  32.1 PRE-REFRESH SNAPSHOT OF THE TARGET DB                          [BOX][MI]
  Run with the TARGET database selected (USE App_UAT).
=============================================================================*/
SELECT d.name, d.recovery_model_desc, SUSER_SNAME(d.owner_sid) AS owner_name, d.compatibility_level,
       d.is_read_committed_snapshot_on, d.snapshot_isolation_state_desc, d.is_broker_enabled,
       d.is_trustworthy_on, d.is_query_store_on, d.collation_name, d.is_cdc_enabled, d.is_published
FROM sys.databases AS d
WHERE d.database_id = DB_ID();

SELECT name AS logical_name, type_desc, physical_name, CAST(CAST(size AS bigint) * 8 / 1024 AS bigint) AS size_mb
FROM sys.database_files;

SELECT COUNT(*) AS users FROM sys.database_principals WHERE type IN ('S','U','G','E','X') AND principal_id > 4;


/*=============================================================================
  32.2 CAPTURE USERS, ROLES, MEMBERSHIPS, PERMISSIONS, SETTINGS        [BOX][MI][SQLDB]
  Run in the TARGET DB BEFORE the restore. The output is the re-apply script.
  >> SAVE IT (Results to file / copy) or INSERT it into a DBA table (32.2b) <<
  Covers DB / object / column / schema permissions (classes 0,1,3).
=============================================================================*/
WITH script AS (
    SELECT 0 AS step, 0 AS seq, N'USE ' + QUOTENAME(DB_NAME()) + N';' AS cmd
    UNION ALL
    -- custom roles
    SELECT 1, principal_id,
           N'IF DATABASE_PRINCIPAL_ID(N''' + REPLACE(name, '''', '''''') + N''') IS NULL CREATE ROLE ' + QUOTENAME(name) + N';'
    FROM sys.database_principals
    WHERE type = 'R' AND is_fixed_role = 0 AND principal_id > 0 AND name <> N'public'
    UNION ALL
    -- users
    SELECT 2, dp.principal_id,
           N'IF DATABASE_PRINCIPAL_ID(N''' + REPLACE(dp.name, '''', '''''') + N''') IS NULL CREATE USER ' + QUOTENAME(dp.name)
         + CASE dp.authentication_type_desc
               WHEN N'INSTANCE' THEN N' FOR LOGIN ' + QUOTENAME(ISNULL(SUSER_SNAME(dp.sid), dp.name))
                                     + ISNULL(N' WITH DEFAULT_SCHEMA = ' + QUOTENAME(dp.default_schema_name), N'')
               WHEN N'WINDOWS'  THEN N' FOR LOGIN ' + QUOTENAME(ISNULL(SUSER_SNAME(dp.sid), dp.name))
                                     + ISNULL(N' WITH DEFAULT_SCHEMA = ' + QUOTENAME(dp.default_schema_name), N'')
               WHEN N'EXTERNAL' THEN N' FROM EXTERNAL PROVIDER'
                                     + ISNULL(N' WITH DEFAULT_SCHEMA = ' + QUOTENAME(dp.default_schema_name), N'')
               WHEN N'DATABASE' THEN N' WITH PASSWORD = N''<SET_PASSWORD>'''
                                     + ISNULL(N', DEFAULT_SCHEMA = ' + QUOTENAME(dp.default_schema_name), N'')
               ELSE N' WITHOUT LOGIN' + ISNULL(N' WITH DEFAULT_SCHEMA = ' + QUOTENAME(dp.default_schema_name), N'')
           END + N';'
    FROM sys.database_principals AS dp
    WHERE dp.type IN ('S', 'U', 'G', 'E', 'X')
      AND dp.principal_id > 4
      AND dp.name NOT IN (N'dbo', N'guest', N'sys', N'INFORMATION_SCHEMA')
    UNION ALL
    -- role memberships
    SELECT 3, m.principal_id,
           N'ALTER ROLE ' + QUOTENAME(r.name) + N' ADD MEMBER ' + QUOTENAME(m.name) + N';'
    FROM sys.database_role_members AS drm
    JOIN sys.database_principals AS r ON r.principal_id = drm.role_principal_id
    JOIN sys.database_principals AS m ON m.principal_id = drm.member_principal_id
    WHERE m.name <> N'dbo'
    UNION ALL
    -- explicit permissions
    SELECT 4, pe.grantee_principal_id,
           CASE WHEN pe.state = 'W' THEN N'GRANT' ELSE pe.state_desc END + N' ' + pe.permission_name
         + CASE pe.class
               WHEN 0 THEN N''
               WHEN 1 THEN N' ON OBJECT::' + QUOTENAME(OBJECT_SCHEMA_NAME(pe.major_id)) + N'.' + QUOTENAME(OBJECT_NAME(pe.major_id))
                           + CASE WHEN pe.minor_id > 0 THEN N' (' + QUOTENAME(COL_NAME(pe.major_id, pe.minor_id)) + N')' ELSE N'' END
               WHEN 3 THEN N' ON SCHEMA::' + QUOTENAME(SCHEMA_NAME(pe.major_id)) END
         + N' TO ' + QUOTENAME(pr.name)
         + CASE WHEN pe.state = 'W' THEN N' WITH GRANT OPTION' ELSE N'' END + N';'
    FROM sys.database_permissions AS pe
    JOIN sys.database_principals AS pr ON pr.principal_id = pe.grantee_principal_id
    WHERE pe.class IN (0, 1, 3)
      AND pr.name NOT IN (N'dbo', N'sys', N'INFORMATION_SCHEMA')
      AND NOT (pe.class = 0 AND pe.permission_name = N'CONNECT' AND pr.name <> N'guest')   -- CREATE USER grants CONNECT
      AND (pe.class <> 1 OR OBJECT_NAME(pe.major_id) IS NOT NULL)
    UNION ALL
    -- database settings to put back
    SELECT 5, 1, N'ALTER DATABASE ' + QUOTENAME(name) + N' SET RECOVERY ' + recovery_model_desc + N';'          FROM sys.databases WHERE database_id = DB_ID()
    UNION ALL SELECT 5, 2, N'ALTER AUTHORIZATION ON DATABASE::' + QUOTENAME(name) + N' TO ' + QUOTENAME(ISNULL(SUSER_SNAME(owner_sid), N'sa')) + N';' FROM sys.databases WHERE database_id = DB_ID()
    UNION ALL SELECT 5, 3, N'ALTER DATABASE ' + QUOTENAME(name) + N' SET COMPATIBILITY_LEVEL = ' + CAST(compatibility_level AS nvarchar(5)) + N';' FROM sys.databases WHERE database_id = DB_ID()
    UNION ALL SELECT 5, 4, N'ALTER DATABASE ' + QUOTENAME(name) + N' SET READ_COMMITTED_SNAPSHOT ' + CASE is_read_committed_snapshot_on WHEN 1 THEN N'ON' ELSE N'OFF' END + N' WITH ROLLBACK IMMEDIATE;' FROM sys.databases WHERE database_id = DB_ID()
    UNION ALL SELECT 5, 5, N'ALTER DATABASE ' + QUOTENAME(name) + N' SET TRUSTWORTHY ' + CASE is_trustworthy_on WHEN 1 THEN N'ON' ELSE N'OFF' END + N';' FROM sys.databases WHERE database_id = DB_ID()
)
SELECT step, cmd FROM script ORDER BY step, seq, cmd;

/* 32.2b - optional: keep the capture in a DBA database instead of a file
CREATE TABLE DBAdmin.dbo.RefreshCapture (RefreshDate datetime2(0) NOT NULL DEFAULT SYSDATETIME(),
       DatabaseName sysname NOT NULL, Step int NOT NULL, Cmd nvarchar(max) NOT NULL);
-- wrap the query above:  INSERT DBAdmin.dbo.RefreshCapture (DatabaseName, Step, Cmd) SELECT DB_NAME(), step, cmd FROM script;
-- Re-apply later by running the rows for the latest RefreshDate in Step order.
*/


/*=============================================================================
  32.3 LOCATE THE SOURCE BACKUP                                       [BOX][MI]
=============================================================================*/
-- If the source DB is on THIS server (or msdb history was copied):
DECLARE @source_db sysname = N'App_PROD';   -- <== change
SELECT TOP (5) bs.database_name, bs.type, bs.backup_finish_date, bs.is_copy_only,
       CAST(bs.compressed_backup_size / 1073741824.0 AS decimal(18,2)) AS compressed_gb, bmf.physical_device_name
FROM msdb.dbo.backupset AS bs
JOIN msdb.dbo.backupmediafamily AS bmf ON bmf.media_set_id = bs.media_set_id
WHERE bs.database_name = @source_db AND bs.type = 'D'
ORDER BY bs.backup_finish_date DESC;

-- Inspect the backup file (logical file names are needed for MOVE):
-- RESTORE HEADERONLY   FROM DISK = N'\\share\App_PROD_FULL.bak';
-- RESTORE FILELISTONLY FROM DISK = N'\\share\App_PROD_FULL.bak';
-- RESTORE VERIFYONLY   FROM DISK = N'\\share\App_PROD_FULL.bak' WITH CHECKSUM;


/*=============================================================================
  32.4 GENERATE RESTORE ... WITH MOVE USING THE TARGET'S CURRENT FILE PATHS
                                                                      [BOX]
  Assumes PROD logical names match the target's (common for refreshes).
  If they differ, map them from RESTORE FILELISTONLY output.
=============================================================================*/
DECLARE @target_db sysname = N'App_UAT',                              -- <== change
        @backup    nvarchar(500) = N'\\share\App_PROD_FULL.bak';      -- <== change
SELECT N'RESTORE DATABASE ' + QUOTENAME(@target_db) + N' FROM DISK = N''' + @backup + N''' WITH REPLACE, STATS = 5,'
     + STUFF((SELECT N', MOVE N''' + mf.name + N''' TO N''' + mf.physical_name + N''''
              FROM sys.master_files AS mf WHERE mf.database_id = DB_ID(@target_db)
              ORDER BY mf.file_id FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 1, N'')
     + N';' AS restore_cmd;
-- Multiple stripes: FROM DISK = N'...1.bak', DISK = N'...2.bak'
-- Managed Instance: FROM URL = N'https://<acct>.blob.core.windows.net/<container>/App_PROD_FULL.bak' (no MOVE allowed/needed)


/*=============================================================================
  32.5 RUN THE RESTORE (template)                                     [BOX][MI]
=============================================================================*/
/*
USE master;
-- Target in an AG? remove it first (on primary), restore, then re-add (25.12):
-- ALTER AVAILABILITY GROUP [AG1] REMOVE DATABASE [App_UAT];
ALTER DATABASE [App_UAT] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
-- <paste restore_cmd from 32.4>
ALTER DATABASE [App_UAT] SET MULTI_USER;
-- Progress: 10_backup_restore.sql 10.3
*/


/*=============================================================================
  32.6 POST-RESTORE CLEANUP OF PRODUCTION ARTEFACTS                    [BOX][MI]
  Run in the refreshed TARGET DB.
=============================================================================*/
-- a) Production users that came with the backup -> review, then drop the ones not in the 32.2 capture
SELECT dp.name, dp.type_desc, dp.authentication_type_desc,
       CASE WHEN sp.sid IS NULL AND dp.authentication_type_desc IN (N'INSTANCE', N'WINDOWS') THEN 'ORPHANED' ELSE '' END AS status,
       N'DROP USER ' + QUOTENAME(dp.name) + N';' AS drop_cmd     -- fails if user owns a schema: ALTER AUTHORIZATION ON SCHEMA::x TO dbo first
FROM sys.database_principals AS dp
LEFT JOIN sys.server_principals AS sp ON sp.sid = dp.sid
WHERE dp.type IN ('S', 'U', 'G', 'E', 'X') AND dp.principal_id > 4
  AND dp.name NOT IN (N'dbo', N'guest', N'sys', N'INFORMATION_SCHEMA')
ORDER BY status DESC, dp.name;

-- b) Schemas owned by users you're about to drop
SELECT s.name AS schema_name, USER_NAME(s.principal_id) AS owner,
       N'ALTER AUTHORIZATION ON SCHEMA::' + QUOTENAME(s.name) + N' TO [dbo];' AS fix_cmd
FROM sys.schemas AS s
WHERE s.principal_id > 4 AND s.principal_id < 16384 AND s.name <> USER_NAME(s.principal_id);

-- c) Then run the 32.2 capture script (step order) to put target users/permissions back.

-- d) Fix any remaining orphaned users whose login exists under the same name
SELECT N'ALTER USER ' + QUOTENAME(dp.name) + N' WITH LOGIN = ' + QUOTENAME(dp.name) + N';' AS fix_cmd
FROM sys.database_principals AS dp
LEFT JOIN sys.server_principals AS sp ON sp.sid = dp.sid
WHERE sp.sid IS NULL AND dp.type = 'S' AND dp.authentication_type_desc = N'INSTANCE'
  AND SUSER_ID(dp.name) IS NOT NULL;

/*
-- e) Production-only features that must not run in DEV/UAT
EXEC sys.sp_cdc_disable_db;                                       -- if CDC came across (or RESTORE without KEEP_CDC)
EXEC sys.sp_removedbreplication @dbname = N'App_UAT';             -- leftover replication metadata
ALTER DATABASE [App_UAT] SET NEW_BROKER WITH ROLLBACK IMMEDIATE;  -- new Service Broker GUID, no cross-talk with PROD
-- Disable/redirect anything that sends email, calls PROD linked servers or external APIs (config tables!)

-- f) Settings: run step 5 lines from 32.2 (recovery, owner, compat, RCSI, TRUSTWORTHY).
--    Typical non-prod: SIMPLE recovery
ALTER DATABASE [App_UAT] SET RECOVERY SIMPLE;
*/


/*=============================================================================
  32.7 DATA SANITIZATION / MASKING FOR NON-PROD (template)       [BOX][MI][SQLDB]
  Required by most data-protection policies before devs/testers get access.
  Static masking = real UPDATEs (DDM in 23 only hides data at query time).
=============================================================================*/
/*
UPDATE dbo.Customers
SET Email     = CONCAT('user', CustomerID, '@example.invalid'),
    Phone     = CONCAT('99999', RIGHT(CONCAT('00000', CustomerID), 5)),
    FirstName = CONCAT('First', CustomerID),
    LastName  = CONCAT('Last',  CustomerID),
    DOB       = DATEFROMPARTS(YEAR(DOB), 1, 1);
UPDATE dbo.Payments SET CardNumber = CONCAT('XXXX-XXXX-XXXX-', RIGHT(CardNumber, 4));
UPDATE dbo.AppConfig SET Value = 'smtp.dev.local' WHERE Name = 'SmtpServer';     -- stop real emails
TRUNCATE TABLE dbo.AuditLog;                                                     -- if not needed in non-prod
-- Find candidate columns: 23_data_masking_rls_classification.sql 23.4
*/


/*=============================================================================
  32.8 SPACE & PERFORMANCE AFTER REFRESH                               [BOX][MI]
=============================================================================*/
/*
-- Shrink the PROD-sized log (SIMPLE recovery first):
CHECKPOINT;
DBCC SHRINKFILE (N'App_UAT_log', 1024);
-- Fresh stats (PROD stats are fine, but sanitization changed data):
EXEC sp_updatestats;
-- Query Store holds PROD history; clear it if you want a clean UAT baseline:
ALTER DATABASE [App_UAT] SET QUERY_STORE CLEAR;
*/


/*=============================================================================
  32.9 POST-REFRESH VALIDATION                                  [BOX][MI][SQLDB]
=============================================================================*/
-- DB online, settings as expected
SELECT name, state_desc, user_access_desc, recovery_model_desc, SUSER_SNAME(owner_sid) AS owner_name,
       compatibility_level, is_broker_enabled, is_trustworthy_on, is_cdc_enabled
FROM sys.databases WHERE database_id = DB_ID();

-- Data actually from the new backup (latest restore)
SELECT TOP (1) rh.destination_database_name, rh.restore_date, bs.database_name AS source_db,
       bs.server_name AS source_server, bs.backup_finish_date AS backup_taken
FROM msdb.dbo.restorehistory AS rh
JOIN msdb.dbo.backupset AS bs ON bs.backup_set_id = rh.backup_set_id
WHERE rh.destination_database_name = DB_NAME()
ORDER BY rh.restore_date DESC;

-- Users & permissions back: compare with 32.2 capture (count by step)
SELECT COUNT(*) AS users FROM sys.database_principals WHERE type IN ('S','U','G','E','X') AND principal_id > 4;
-- Orphans: 13_security.sql 13.5   |   Broken objects: 31_schema_validation.sql 31.4
-- Row counts vs source: 31_schema_validation.sql 31.6
