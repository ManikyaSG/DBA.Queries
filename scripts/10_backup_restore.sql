/*******************************************************************************
 File    : 10_backup_restore.sql
 Purpose : Backup coverage, history, progress, restore chain generator.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] Managed Instance   [SQLDB] Azure SQL DB
 Note    : Always On: backups may run on another replica (backup preference) -
           msdb history is per-replica, so check every replica or centralise.
           Azure SQL DB / MI automated backups are platform-managed; use
           sys.dm_database_backups (Azure SQL DB) or the portal/PowerShell.
*******************************************************************************/

/*=============================================================================
  10.1 LAST BACKUP PER DATABASE + RPO FLAGS                           [BOX][MI]
=============================================================================*/
WITH last_bk AS (
    SELECT database_name,
           MAX(CASE WHEN type = 'D' THEN backup_finish_date END) AS last_full,
           MAX(CASE WHEN type = 'I' THEN backup_finish_date END) AS last_diff,
           MAX(CASE WHEN type = 'L' THEN backup_finish_date END) AS last_log
    FROM msdb.dbo.backupset
    WHERE is_copy_only = 0
    GROUP BY database_name
)
SELECT d.name, d.recovery_model_desc, d.state_desc,
       b.last_full, b.last_diff, b.last_log,
       DATEDIFF(HOUR,   b.last_full, GETDATE()) AS hours_since_full,
       DATEDIFF(MINUTE, b.last_log,  GETDATE()) AS minutes_since_log,
       CASE
           WHEN b.last_full IS NULL                                          THEN 'CRITICAL: never had a full backup'
           WHEN DATEDIFF(DAY, b.last_full, GETDATE()) > 7
            AND (b.last_diff IS NULL OR DATEDIFF(DAY, b.last_diff, GETDATE()) > 1) THEN 'WARN: full > 7 days and no recent diff'
           WHEN d.recovery_model_desc <> 'SIMPLE' AND b.last_log IS NULL      THEN 'CRITICAL: FULL recovery but no log backup'
           WHEN d.recovery_model_desc <> 'SIMPLE'
            AND DATEDIFF(MINUTE, b.last_log, GETDATE()) > 60                  THEN 'WARN: log backup > 60 min old'
           ELSE 'OK' END AS finding
FROM sys.databases AS d
LEFT JOIN last_bk  AS b ON b.database_name = d.name
WHERE d.database_id <> 2
ORDER BY finding, d.name;


/*=============================================================================
  10.2 BACKUP HISTORY - LAST N DAYS (size, speed, location)           [BOX][MI]
=============================================================================*/
DECLARE @days int = 7;
SELECT
    bs.database_name,
    CASE bs.type WHEN 'D' THEN 'FULL' WHEN 'I' THEN 'DIFF' WHEN 'L' THEN 'LOG'
                 WHEN 'F' THEN 'FILE' WHEN 'G' THEN 'DIFF FILE' ELSE bs.type END AS backup_type,
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


/*=============================================================================
  10.3 BACKUP / RESTORE / DBCC PROGRESS (live)                 [BOX][MI][SQLDB]
=============================================================================*/
SELECT r.session_id, r.command, DB_NAME(r.database_id) AS database_name,
       r.percent_complete,
       DATEADD(MILLISECOND, r.estimated_completion_time, SYSDATETIME()) AS est_finish_time,
       r.estimated_completion_time / 60000 AS est_minutes_left,
       r.total_elapsed_time / 60000        AS elapsed_minutes,
       r.wait_type, t.text
FROM sys.dm_exec_requests AS r
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE r.command LIKE N'BACKUP%' OR r.command LIKE N'RESTORE%' OR r.command LIKE N'DBCC%'
   OR r.command IN (N'DbccFilesCompact', N'DbccSpaceReclaim', N'ALTER INDEX');


/*=============================================================================
  10.4 RESTORE HISTORY                                                [BOX][MI]
=============================================================================*/
SELECT TOP (100)
    rh.destination_database_name, rh.restore_date,
    CASE rh.restore_type WHEN 'D' THEN 'FULL' WHEN 'I' THEN 'DIFF' WHEN 'L' THEN 'LOG' ELSE rh.restore_type END AS restore_type,
    rh.user_name, rh.replace, rh.recovery,
    bs.database_name AS source_database, bs.server_name AS source_server,
    bs.backup_finish_date AS backup_taken, bmf.physical_device_name
FROM msdb.dbo.restorehistory AS rh
JOIN msdb.dbo.backupset       AS bs  ON bs.backup_set_id = rh.backup_set_id
JOIN msdb.dbo.backupmediafamily AS bmf ON bmf.media_set_id = bs.media_set_id
ORDER BY rh.restore_date DESC;


/*=============================================================================
  10.5 GENERATE RESTORE SCRIPT (latest FULL + DIFF + LOG chain)       [BOX][MI]
  Output is a script - review, add MOVE clauses / STOPAT, then run.
=============================================================================*/
DECLARE @db sysname = N'YourDB';   -- <== change

DECLARE @full_id int, @full_lsn numeric(25,0), @base_last_lsn numeric(25,0), @diff_id int;

SELECT TOP (1) @full_id = backup_set_id, @full_lsn = checkpoint_lsn, @base_last_lsn = last_lsn
FROM msdb.dbo.backupset
WHERE database_name = @db AND type = 'D' AND is_copy_only = 0
ORDER BY backup_finish_date DESC;

SELECT TOP (1) @diff_id = backup_set_id, @base_last_lsn = last_lsn
FROM msdb.dbo.backupset
WHERE database_name = @db AND type = 'I' AND database_backup_lsn = @full_lsn
ORDER BY backup_finish_date DESC;

WITH files AS (
    SELECT bs.backup_set_id, bs.type, bs.first_lsn, bs.backup_finish_date,
           STUFF((SELECT N', DISK = N''' + bmf.physical_device_name + N''''
                  FROM msdb.dbo.backupmediafamily AS bmf
                  WHERE bmf.media_set_id = bs.media_set_id
                  ORDER BY bmf.family_sequence_number
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'') AS disks
    FROM msdb.dbo.backupset AS bs
    WHERE bs.database_name = @db
      AND (bs.backup_set_id IN (@full_id, @diff_id)
           OR (bs.type = 'L' AND bs.is_copy_only = 0 AND bs.last_lsn > @base_last_lsn))
)
SELECT CASE type WHEN 'D' THEN 1 WHEN 'I' THEN 2 ELSE 3 END AS step,
       backup_finish_date,
       CASE type WHEN 'L' THEN N'RESTORE LOG ' ELSE N'RESTORE DATABASE ' END
         + QUOTENAME(@db) + N' FROM ' + disks
         + N' WITH NORECOVERY' + CASE type WHEN 'D' THEN N', REPLACE, STATS = 10' ELSE N'' END + N';' AS restore_cmd
FROM files
UNION ALL
SELECT 9, NULL, N'RESTORE DATABASE ' + QUOTENAME(@db) + N' WITH RECOVERY;'
ORDER BY step, backup_finish_date;


/*=============================================================================
  10.6 BACKUP SIZE TREND (monthly FULL size per DB)                   [BOX][MI]
=============================================================================*/
SELECT database_name,
       DATEFROMPARTS(YEAR(backup_start_date), MONTH(backup_start_date), 1) AS month_start,
       CAST(AVG(backup_size) / 1073741824.0 AS decimal(18,2))            AS avg_full_gb,
       CAST(AVG(compressed_backup_size) / 1073741824.0 AS decimal(18,2)) AS avg_compressed_gb
FROM msdb.dbo.backupset
WHERE type = 'D' AND backup_start_date >= DATEADD(MONTH, -12, GETDATE())
GROUP BY database_name, DATEFROMPARTS(YEAR(backup_start_date), MONTH(backup_start_date), 1)
ORDER BY database_name, month_start;


/*=============================================================================
  10.7 BACKUP TO URL CREDENTIALS (Azure blob)                         [BOX][MI]
=============================================================================*/
SELECT name, credential_identity, create_date, modify_date FROM sys.credentials;


/*=============================================================================
  10.8 AZURE SQL DB - AUTOMATED BACKUP LIST                            [SQLDB]
=============================================================================*/
-- SELECT * FROM sys.dm_database_backups ORDER BY backup_finish_date DESC;


/*=============================================================================
  10.9 MSDB HISTORY CLEANUP (keeps msdb small)                        [BOX][MI]
=============================================================================*/
-- DECLARE @oldest datetime = DATEADD(DAY, -90, GETDATE());
-- EXEC msdb.dbo.sp_delete_backuphistory @oldest_date = @oldest;
