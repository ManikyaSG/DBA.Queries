/*******************************************************************************
 File    : 34_point_in_time_recovery.sql
 Purpose : Logical recovery runbook: "someone deleted / updated / dropped
           data at 10:15". Find the exact time/LSN, restore side-by-side to
           just before it, copy the data back. Also: inspect backups, step
           through logs with STANDBY, page restore, database snapshots,
           tail-log backups, Azure PITR.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] (restore from URL, PITR via portal)
           [SQLDB] (PITR / copy only - see 34.11)
 RULES   : 1) NEVER restore over the production DB to fix a logical error -
              restore a COPY (new name) and move the rows back.
           2) Take a log backup (or tail-log) FIRST so the bad transaction
              is inside a backup you can restore up to.
           3) Requires FULL / BULK_LOGGED recovery + an unbroken log chain.
*******************************************************************************/

/*=============================================================================
  34.1 STEP 1 - CAPTURE THE LOG NOW                                   [BOX][MI]
=============================================================================*/
/*
BACKUP LOG [YourDB] TO DISK = N'\\backup\sql\YourDB_after_incident.trn' WITH COMPRESSION, CHECKSUM;
-- Optional: stop further damage
-- ALTER DATABASE [YourDB] SET RESTRICTED_USER WITH ROLLBACK IMMEDIATE;
*/


/*=============================================================================
  34.2 STEP 2 - FIND THE BAD TRANSACTION IN THE ACTIVE LOG             [BOX][MI]
  fn_dblog is undocumented but standard practice; read-only. Run in the
  affected DB. Works only while the records are still in the active log.
=============================================================================*/
-- a) Transactions by name/time (DELETE, UPDATE, DROPOBJ, TRUNCATE TABLE ...)
SELECT [Current LSN], [Transaction ID], [Transaction Name], [Begin Time],
       SUSER_SNAME([Transaction SID]) AS login_name
FROM fn_dblog(NULL, NULL)
WHERE Operation = N'LOP_BEGIN_XACT'
  AND [Transaction Name] IN (N'DELETE', N'UPDATE', N'DROPOBJ', N'TRUNCATE TABLE', N'user_transaction', N'INSERT')
ORDER BY [Current LSN] DESC;

-- b) Which table did a transaction touch, and how many rows?
DECLARE @tran_id nvarchar(30) = N'0000:0000abcd';   -- <== [Transaction ID] from (a)
SELECT AllocUnitName, Operation, COUNT(*) AS log_records
FROM fn_dblog(NULL, NULL)
WHERE [Transaction ID] = @tran_id
GROUP BY AllocUnitName, Operation
ORDER BY log_records DESC;

-- c) Dropped tables: find DROPOBJ transactions and the object they removed
SELECT [Current LSN], [Transaction ID], [Begin Time], SUSER_SNAME([Transaction SID]) AS login_name
FROM fn_dblog(NULL, NULL)
WHERE [Transaction Name] = N'DROPOBJ';
-- (Easier for drops: 28_version_control_schema_changes.sql 28.2 default trace -> who + when)


/*=============================================================================
  34.3 FIND THE TRANSACTION INSIDE A LOG BACKUP FILE                  [BOX][MI]
  fn_dump_dblog reads a .trn file (undocumented, 68 parameters).
=============================================================================*/
/*
SELECT [Current LSN], [Transaction ID], [Transaction Name], [Begin Time], SUSER_SNAME([Transaction SID]) AS login_name
FROM fn_dump_dblog(NULL, NULL, N'DISK', 1, N'\\backup\sql\YourDB_after_incident.trn',
     DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT,
     DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT,
     DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT,
     DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT,
     DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT,
     DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT,
     DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT)
WHERE Operation = N'LOP_BEGIN_XACT' AND [Transaction Name] IN (N'DELETE', N'UPDATE', N'DROPOBJ', N'TRUNCATE TABLE');
*/


/*=============================================================================
  34.4 CONVERT fn_dblog LSN (hex) TO RESTORE LSN (decimal)       [BOX][MI][SQLDB]
  '0000002a:000001b8:0003'  ->  '42000000044000003'
  Use with STOPBEFOREMARK = 'lsn:<decimal>' to stop JUST BEFORE the bad tran.
=============================================================================*/
DECLARE @hex_lsn varchar(30) = '0000002a:000001b8:0003';   -- <== [Current LSN] of LOP_BEGIN_XACT
SELECT @hex_lsn AS fn_dblog_lsn,
       CAST(CONVERT(int, CONVERT(varbinary(4), PARSENAME(REPLACE(@hex_lsn, ':', '.'), 3), 2)) AS varchar(10))
     + RIGHT('0000000000' + CAST(CONVERT(int, CONVERT(varbinary(4), PARSENAME(REPLACE(@hex_lsn, ':', '.'), 2), 2)) AS varchar(10)), 10)
     + RIGHT('00000'      + CAST(CONVERT(int, CONVERT(varbinary(2), PARSENAME(REPLACE(@hex_lsn, ':', '.'), 1), 2)) AS varchar(5)), 5)
       AS restore_lsn;


/*=============================================================================
  34.5 WHICH BACKUPS DO I NEED FOR TIME X?                            [BOX][MI]
  Latest full before X, latest diff based on it before X, then every log
  up to and including the first log that ends after X.
=============================================================================*/
DECLARE @db sysname = N'YourDB', @target datetime = '2026-10-28 10:14:00';   -- <== change

WITH f AS (SELECT TOP (1) backup_set_id, checkpoint_lsn, last_lsn, backup_finish_date
           FROM msdb.dbo.backupset WHERE database_name = @db AND type = 'D' AND is_copy_only = 0 AND backup_finish_date <= @target
           ORDER BY backup_finish_date DESC),
     d AS (SELECT TOP (1) b.backup_set_id, b.last_lsn, b.backup_finish_date
           FROM msdb.dbo.backupset b JOIN f ON b.differential_base_lsn = f.checkpoint_lsn
           WHERE b.database_name = @db AND b.type = 'I' AND b.backup_finish_date <= @target
           ORDER BY b.backup_finish_date DESC),
     base AS (SELECT COALESCE((SELECT last_lsn FROM d), (SELECT last_lsn FROM f)) AS lsn),
     logs AS (SELECT b.backup_set_id, b.first_lsn, b.last_lsn, b.backup_start_date, b.backup_finish_date,
                     ROW_NUMBER() OVER (ORDER BY b.first_lsn) AS rn
              FROM msdb.dbo.backupset b CROSS JOIN base
              WHERE b.database_name = @db AND b.type = 'L' AND b.last_lsn > base.lsn),
     stop_at AS (SELECT MIN(rn) AS rn FROM logs WHERE backup_finish_date >= @target)
SELECT 'FULL' AS step, f.backup_finish_date, m.physical_device_name FROM f JOIN msdb.dbo.backupset bs ON bs.backup_set_id = f.backup_set_id JOIN msdb.dbo.backupmediafamily m ON m.media_set_id = bs.media_set_id
UNION ALL
SELECT 'DIFF', d.backup_finish_date, m.physical_device_name FROM d JOIN msdb.dbo.backupset bs ON bs.backup_set_id = d.backup_set_id JOIN msdb.dbo.backupmediafamily m ON m.media_set_id = bs.media_set_id
UNION ALL
SELECT 'LOG', l.backup_finish_date, m.physical_device_name
FROM logs l JOIN msdb.dbo.backupset bs ON bs.backup_set_id = l.backup_set_id JOIN msdb.dbo.backupmediafamily m ON m.media_set_id = bs.media_set_id
WHERE l.rn <= ISNULL((SELECT rn FROM stop_at), 2147483647)
ORDER BY 2;
-- If the last row isn't after @target, you need the log backup from 34.1.


/*=============================================================================
  34.6 INSPECT A BACKUP FILE BEFORE RESTORING                  [BOX][MI]
=============================================================================*/
/*
RESTORE LABELONLY    FROM DISK = N'\\backup\sql\YourDB_FULL.bak';   -- media / stripes
RESTORE HEADERONLY   FROM DISK = N'\\backup\sql\YourDB_FULL.bak';   -- type, dates, LSNs, DB name, compat, recovery model
RESTORE FILELISTONLY FROM DISK = N'\\backup\sql\YourDB_FULL.bak';   -- logical names + sizes (for MOVE)
RESTORE VERIFYONLY   FROM DISK = N'\\backup\sql\YourDB_FULL.bak' WITH CHECKSUM;   -- readable? (not a substitute for a test restore)
*/


/*=============================================================================
  34.7 RESTORE A COPY TO A POINT IN TIME / LSN                         [BOX][MI]
=============================================================================*/
/*
-- Full (+ diff) WITH NORECOVERY under a NEW name and NEW file paths:
RESTORE DATABASE [YourDB_Recover] FROM DISK = N'\\backup\sql\YourDB_FULL.bak'
  WITH NORECOVERY, STATS = 5,
       MOVE N'YourDB'     TO N'D:\Data\YourDB_Recover.mdf',
       MOVE N'YourDB_log' TO N'L:\Log\YourDB_Recover.ldf';
RESTORE DATABASE [YourDB_Recover] FROM DISK = N'\\backup\sql\YourDB_DIFF.bak' WITH NORECOVERY;

-- Logs ... and the last one with ONE of:
RESTORE LOG [YourDB_Recover] FROM DISK = N'...trn' WITH STOPAT = '2026-10-28 10:14:59', RECOVERY;      -- by time
RESTORE LOG [YourDB_Recover] FROM DISK = N'...trn' WITH STOPBEFOREMARK = 'lsn:42000000044000003', RECOVERY;  -- by LSN (34.4)
RESTORE LOG [YourDB_Recover] FROM DISK = N'...trn' WITH STOPBEFOREMARK = 'BeforeRelease_v42', RECOVERY;     -- named mark

-- STOPAT on every log restore is safe: logs that end before the time are fully applied.
-- Managed Instance: native restore needs a NEW db name; use portal PITR for "same server, earlier time".
*/


/*=============================================================================
  34.8 NOT SURE OF THE EXACT TIME? STEP THROUGH WITH STANDBY            [BOX]
  STANDBY leaves the DB READ-ONLY between log restores so you can look.
=============================================================================*/
/*
RESTORE LOG [YourDB_Recover] FROM DISK = N'...trn'
  WITH STOPAT = '2026-10-28 10:10:00', STANDBY = N'D:\Data\YourDB_Recover_undo.dat';
SELECT COUNT(*) FROM YourDB_Recover.dbo.Orders;        -- data still there?
RESTORE LOG [YourDB_Recover] FROM DISK = N'...trn'
  WITH STOPAT = '2026-10-28 10:13:00', STANDBY = N'D:\Data\YourDB_Recover_undo.dat';
-- ... repeat moving forward; finish with:  RESTORE DATABASE [YourDB_Recover] WITH RECOVERY;
*/


/*=============================================================================
  34.9 COPY THE LOST ROWS BACK (template)                     [BOX][MI][SQLDB]
=============================================================================*/
/*
-- Deleted rows: insert what exists in the copy but not in prod
SET IDENTITY_INSERT YourDB.dbo.Orders ON;          -- if identity
INSERT YourDB.dbo.Orders (OrderID, CustomerID, OrderDate, Amount)
SELECT r.OrderID, r.CustomerID, r.OrderDate, r.Amount
FROM YourDB_Recover.dbo.Orders AS r
WHERE NOT EXISTS (SELECT 1 FROM YourDB.dbo.Orders AS p WHERE p.OrderID = r.OrderID);
SET IDENTITY_INSERT YourDB.dbo.Orders OFF;

-- Bad UPDATE: put old values back for affected rows
UPDATE p SET p.Amount = r.Amount, p.Status = r.Status
FROM YourDB.dbo.Orders AS p
JOIN YourDB_Recover.dbo.Orders AS r ON r.OrderID = p.OrderID
WHERE p.Amount <> r.Amount OR p.Status <> r.Status;      -- add a filter for the affected range!

-- Dropped table: script it from the copy (SSMS / dbatools Export-DbaScript), create, then INSERT ... SELECT.
-- Different server? use a linked server, SSIS, bcp, or dbatools Copy-DbaDbTableData.
-- Finally: DROP DATABASE [YourDB_Recover];  (after sign-off)
*/


/*=============================================================================
  34.10 PAGE RESTORE (few damaged pages, rest of DB fine)              [BOX][MI]
  Online page restore = Enterprise; Standard = DB offline during restore.
  Damaged pages: 15_database_health_errorlog.sql 15.3 (msdb.dbo.suspect_pages) or CHECKDB output.
=============================================================================*/
/*
RESTORE DATABASE [YourDB] PAGE = '1:57, 1:202' FROM DISK = N'\\backup\sql\YourDB_FULL.bak' WITH NORECOVERY;
RESTORE LOG [YourDB] FROM DISK = N'...log1.trn' WITH NORECOVERY;    -- every log since that full
RESTORE LOG [YourDB] FROM DISK = N'...log2.trn' WITH NORECOVERY;
BACKUP LOG  [YourDB] TO DISK = N'\\backup\sql\YourDB_tail_pages.trn'; -- new log backup covering now
RESTORE LOG [YourDB] FROM DISK = N'\\backup\sql\YourDB_tail_pages.trn' WITH RECOVERY;
DBCC CHECKDB ([YourDB]) WITH NO_INFOMSGS;
-- AG Enterprise: automatic page repair may already have fixed it -> 15.4
*/


/*=============================================================================
  34.11 TAIL-LOG BACKUP OF A DAMAGED / UNAVAILABLE DATABASE              [BOX]
  Captures every committed transaction since the last log backup, even if
  data files are gone - as long as the LOG file survives.
=============================================================================*/
/*
BACKUP LOG [YourDB] TO DISK = N'\\backup\sql\YourDB_TAIL.trn' WITH NO_TRUNCATE, NORECOVERY;
-- If it complains about damage:  ... WITH CONTINUE_AFTER_ERROR, NORECOVERY;
-- Then restore full + diff + logs + this tail to get to the moment of failure.
*/


/*=============================================================================
  34.12 DATABASE SNAPSHOTS - SAFETY NET BEFORE RISKY CHANGES      [BOX][MI*]
  Create before a release / big data fix; revert in seconds if it goes wrong.
  (*MI: not supported - use COPY_ONLY backup to URL instead.)
=============================================================================*/
-- Generator: one ON (...) entry per data file
DECLARE @snapdb sysname = DB_NAME(), @suffix nvarchar(30) = N'_snap_' + CONVERT(nvarchar(8), GETDATE(), 112);
SELECT N'CREATE DATABASE ' + QUOTENAME(@snapdb + @suffix) + N' ON '
     + STUFF((SELECT N', (NAME = ' + QUOTENAME(name) + N', FILENAME = N''' + physical_name + @suffix + N'.ss'')'
              FROM sys.database_files WHERE type = 0 ORDER BY file_id
              FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'')
     + N' AS SNAPSHOT OF ' + QUOTENAME(@snapdb) + N';' AS create_snapshot_cmd;

-- Existing snapshots + size on disk
SELECT s.name AS snapshot_name, DB_NAME(s.source_database_id) AS source_db, s.create_date,
       CAST(SUM(vfs.size_on_disk_bytes) / 1048576.0 AS decimal(18,2)) AS sparse_mb
FROM sys.databases AS s
JOIN sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs ON vfs.database_id = s.database_id
WHERE s.source_database_id IS NOT NULL
GROUP BY s.name, s.source_database_id, s.create_date;

/*
-- Revert (DB must have only ONE snapshot; drop others first; kills connections):
USE master;
RESTORE DATABASE [YourDB] FROM DATABASE_SNAPSHOT = 'YourDB_snap_20261028';
-- Or just read old data from it:  SELECT * FROM YourDB_snap_20261028.dbo.Orders WHERE ...
DROP DATABASE [YourDB_snap_20261028];   -- when done (snapshots slow down writes)
*/


/*=============================================================================
  34.13 AZURE SQL DB / MANAGED INSTANCE RECOVERY OPTIONS           [MI][SQLDB]
=============================================================================*/
/*
 Point-in-time restore (new database, same server, any time in retention window):
   Azure SQL DB:  Restore-AzSqlDatabase -FromPointInTimeBackup -PointInTime '2026-10-28T04:44:00Z' `
                    -ResourceGroupName rg -ServerName srv -TargetDatabaseName YourDB_Recover -ResourceId $db.ResourceId
                  az sql db restore -g rg -s srv -n YourDB --dest-name YourDB_Recover --time "2026-10-28T04:44:00Z"
   MI:            Restore-AzSqlInstanceDatabase -FromPointInTimeBackup ...  |  az sql midb restore ...
   (times are UTC - Asia/Kolkata 10:14 IST = 04:44 UTC)
 Deleted database:        portal > SQL server / MI > "Deleted databases" (within retention)
 Long-term retention:     Restore-AzSqlDatabase -FromLongTermRetentionBackup ...
 Geo-restore (region DR): Restore-AzSqlDatabase -FromGeoBackup ...
 Quick copy (Azure SQL DB, T-SQL, run in master):  CREATE DATABASE [YourDB_Copy] AS COPY OF [srv].[YourDB];
 Retention check:         portal > Backups, or Get-AzSqlDatabaseBackupShortTermRetentionPolicy
 Then copy rows back with 34.9 (cross-DB queries in Azure SQL DB need elastic query / SSIS / ADF / bcp).
*/
