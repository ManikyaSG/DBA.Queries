/*******************************************************************************
 File    : 40_rpo_rto_compliance.sql
 Purpose : Prove (and keep) RPO / RTO: one-shot scorecard against your SLA,
           worst-case real RPO, broken log chains & rogue backups, backup
           quality, do the files still exist, restore-time estimate, restore
           test evidence, crash-recovery RTO, HA/DR coverage per database.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] (msdb shows only YOUR backups)
           Azure SQL DB: PITR is platform-managed (RPO ~5-10 min, see 34.13)
 Always On: msdb is per replica. Run on the replica that takes backups
           (25.10), or on every replica and combine.
 SLA     : Optional table DBAdmin.dbo.DatabaseSLA (template in 40.12). If it
           doesn't exist, the defaults below apply to every database.
*******************************************************************************/

/*=============================================================================
  40.1 RPO / RTO SCORECARD vs SLA - ONE RESULT SET                    [BOX][MI]
  rpo_now_min      = data you would lose if the server died NOW (backups only)
  worst_gap_min    = largest gap between log backups in the last @days
                     (your REAL worst-case RPO - what auditors ask for)
  est_restore_min  = rough time to restore full + diff + logs, from measured
                     backup throughput x @restore_factor (+ file zeroing)
=============================================================================*/
DECLARE @default_rpo_min int = 15,          -- <== your standard SLA
        @default_rto_min int = 60,
        @restore_factor  decimal(5,2) = 1.30,   -- restores are usually slower than backups
        @zero_mb_per_s   int = 300,             -- disk write speed for zeroing log (and data if no IFI)
        @days            int = 7;

DECLARE @ifi char(1) = 'Y';
IF CAST(SERVERPROPERTY('EngineEdition') AS int) NOT IN (5, 8)
    EXEC sys.sp_executesql
         N'SELECT TOP (1) @i = instant_file_initialization_enabled FROM sys.dm_server_services WHERE servicename LIKE N''SQL Server (%''',
         N'@i char(1) OUTPUT', @i = @ifi OUTPUT;

IF OBJECT_ID('tempdb..#sla') IS NOT NULL DROP TABLE #sla;
CREATE TABLE #sla (database_name sysname COLLATE DATABASE_DEFAULT PRIMARY KEY, tier varchar(20), rpo_minutes int, rto_minutes int);
IF OBJECT_ID(N'DBAdmin.dbo.DatabaseSLA') IS NOT NULL
    EXEC (N'INSERT #sla (database_name, tier, rpo_minutes, rto_minutes) SELECT database_name, tier, rpo_minutes, rto_minutes FROM DBAdmin.dbo.DatabaseSLA;');
INSERT #sla (database_name, tier, rpo_minutes, rto_minutes)
SELECT d.name, 'default', @default_rpo_min, @default_rto_min
FROM sys.databases AS d
WHERE d.database_id > 4 AND NOT EXISTS (SELECT 1 FROM #sla AS s WHERE s.database_name = d.name);

WITH bk AS (
    SELECT d.name, d.recovery_model_desc, d.state_desc, d.replica_id,
           f.backup_finish_date AS last_full, f.backup_size AS full_bytes, f.dur_s AS full_dur_s,
           df.backup_finish_date AS last_diff, df.backup_size AS diff_bytes,
           lg.log_count, lg.log_bytes,
           (SELECT MAX(b.backup_finish_date) FROM msdb.dbo.backupset AS b WHERE b.database_name = d.name AND b.type = 'L') AS last_log,
           (SELECT SUM(CAST(mf.size AS bigint)) * 8 / 1024 FROM sys.master_files AS mf WHERE mf.database_id = d.database_id AND mf.type = 0) AS data_mb,
           (SELECT SUM(CAST(mf.size AS bigint)) * 8 / 1024 FROM sys.master_files AS mf WHERE mf.database_id = d.database_id AND mf.type = 1) AS log_mb
    FROM sys.databases AS d
    OUTER APPLY (SELECT TOP (1) b.backup_finish_date, b.backup_size, b.checkpoint_lsn,
                        NULLIF(DATEDIFF(SECOND, b.backup_start_date, b.backup_finish_date), 0) AS dur_s
                 FROM msdb.dbo.backupset AS b
                 WHERE b.database_name = d.name AND b.type = 'D' AND b.is_copy_only = 0
                 ORDER BY b.backup_finish_date DESC) AS f
    OUTER APPLY (SELECT TOP (1) b.backup_finish_date, b.backup_size
                 FROM msdb.dbo.backupset AS b
                 WHERE b.database_name = d.name AND b.type = 'I' AND b.differential_base_lsn = f.checkpoint_lsn
                 ORDER BY b.backup_finish_date DESC) AS df
    OUTER APPLY (SELECT COUNT(*) AS log_count, SUM(b.backup_size) AS log_bytes
                 FROM msdb.dbo.backupset AS b
                 WHERE b.database_name = d.name AND b.type = 'L'
                   AND b.backup_finish_date > COALESCE(df.backup_finish_date, f.backup_finish_date)) AS lg
    WHERE d.database_id > 4 AND d.source_database_id IS NULL
),
gaps AS (
    SELECT database_name, MAX(gap_min) AS worst_gap_min
    FROM (SELECT database_name,
                 DATEDIFF(MINUTE, LAG(backup_finish_date) OVER (PARTITION BY database_name ORDER BY backup_finish_date), backup_finish_date) AS gap_min
          FROM msdb.dbo.backupset
          WHERE type = 'L' AND backup_finish_date >= DATEADD(DAY, -@days, GETDATE())) AS x
    GROUP BY database_name
),
sc AS (
SELECT
    bk.name AS database_name, s.tier, bk.recovery_model_desc, bk.state_desc,
    CASE WHEN bk.replica_id IS NULL THEN '' WHEN sys.fn_hadr_backup_is_preferred_replica(bk.name) = 1
         THEN 'AG - backups here' ELSE 'AG - backups on other replica' END AS ag_backup_role,
    bk.last_full, bk.last_diff, bk.last_log,
    s.rpo_minutes AS rpo_sla_min,
    DATEDIFF(MINUTE, lp.latest, GETDATE())                     AS rpo_now_min,
    CASE WHEN bk.recovery_model_desc = 'SIMPLE' THEN NULL ELSE g.worst_gap_min END AS worst_gap_min,
    s.rto_minutes AS rto_sla_min,
    CAST(rt.est_s / 60.0 AS decimal(10,1))                     AS est_restore_min,
    bk.log_count AS logs_to_restore,
    CAST(bk.full_bytes / 1048576.0 / ISNULL(bk.full_dur_s, 1) AS decimal(10,1)) AS backup_mb_per_s,
    @ifi AS ifi_enabled,
    CASE
        WHEN bk.replica_id IS NOT NULL AND sys.fn_hadr_backup_is_preferred_replica(bk.name) = 0
             AND (lp.latest IS NULL OR DATEDIFF(MINUTE, lp.latest, GETDATE()) > s.rpo_minutes) THEN 'CHECK PREFERRED REPLICA'
        WHEN bk.last_full IS NULL                                                         THEN 'RPO BREACH - no full backup'
        WHEN bk.recovery_model_desc = 'SIMPLE' AND s.rpo_minutes < 1440                   THEN 'RPO BREACH - SIMPLE recovery cannot meet SLA'
        WHEN DATEDIFF(MINUTE, lp.latest, GETDATE()) > s.rpo_minutes                       THEN 'RPO BREACH - now'
        WHEN bk.recovery_model_desc <> 'SIMPLE' AND g.worst_gap_min > s.rpo_minutes       THEN 'RPO BREACHED in last ' + CAST(@days AS varchar(3)) + ' days'
        WHEN rt.est_s / 60.0 > s.rto_minutes                                              THEN 'RTO RISK - restore too slow (add diffs / faster storage / HA)'
        ELSE 'OK' END AS status
FROM bk
JOIN #sla AS s ON s.database_name = bk.name
LEFT JOIN gaps AS g ON g.database_name = bk.name
CROSS APPLY (SELECT MAX(v) AS latest
             FROM (VALUES (bk.last_full), (bk.last_diff),
                          (CASE WHEN bk.recovery_model_desc <> 'SIMPLE' THEN bk.last_log END)) AS x(v)) AS lp
CROSS APPLY (SELECT (ISNULL(bk.full_bytes, 0) + ISNULL(bk.diff_bytes, 0) + ISNULL(bk.log_bytes, 0)) / 1048576.0
                    / NULLIF(bk.full_bytes / 1048576.0 / ISNULL(bk.full_dur_s, 1), 0) * @restore_factor
                  + CASE WHEN @ifi = 'N' THEN ISNULL(bk.data_mb, 0) * 1.0 / @zero_mb_per_s ELSE 0 END
                  + ISNULL(bk.log_mb, 0) * 1.0 / @zero_mb_per_s AS est_s) AS rt
)
SELECT * FROM sc
ORDER BY CASE WHEN status = 'OK' THEN 1 ELSE 0 END, database_name
OPTION (RECOMPILE);


/*=============================================================================
  40.2 WORST-CASE RPO DETAIL - WHEN DID THE BIG GAPS HAPPEN?          [BOX][MI]
  Gaps usually = log backup job failed / disabled / blocked by a long full
  backup or by maintenance. Cross-check with 14.1 for that time.
=============================================================================*/
DECLARE @gap_days int = 7, @gap_threshold_min int = 15;   -- <== your log RPO
WITH l AS (
    SELECT database_name, backup_finish_date,
           LAG(backup_finish_date) OVER (PARTITION BY database_name ORDER BY backup_finish_date) AS prev_finish
    FROM msdb.dbo.backupset
    WHERE type = 'L' AND backup_finish_date >= DATEADD(DAY, -@gap_days, GETDATE())
)
SELECT database_name, prev_finish AS gap_from, backup_finish_date AS gap_to,
       DATEDIFF(MINUTE, prev_finish, backup_finish_date) AS gap_min
FROM l
WHERE DATEDIFF(MINUTE, prev_finish, backup_finish_date) > @gap_threshold_min
UNION ALL   -- the gap that is still open right now
SELECT database_name, MAX(backup_finish_date), GETDATE(), DATEDIFF(MINUTE, MAX(backup_finish_date), GETDATE())
FROM msdb.dbo.backupset WHERE type = 'L'
GROUP BY database_name
HAVING DATEDIFF(MINUTE, MAX(backup_finish_date), GETDATE()) > @gap_threshold_min
ORDER BY gap_min DESC;


/*=============================================================================
  40.3 BROKEN LOG CHAINS (an unrestorable point in time)               [BOX][MI]
  In a valid chain each log's first_lsn = previous log's last_lsn. A gap
  means you CANNOT restore past it -> take a FULL (or DIFF) backup now.
  AG: if log backups move between replicas, the other replica's msdb has
  the missing pieces - check there before panicking.
=============================================================================*/
WITH l AS (
    SELECT database_name, database_guid, backup_start_date, first_lsn, last_lsn, server_name,
           LAG(last_lsn)          OVER (PARTITION BY database_name, database_guid ORDER BY first_lsn) AS prev_last_lsn,
           LAG(backup_start_date) OVER (PARTITION BY database_name, database_guid ORDER BY first_lsn) AS prev_start
    FROM msdb.dbo.backupset
    WHERE type = 'L' AND is_copy_only = 0 AND backup_start_date >= DATEADD(DAY, -14, GETDATE())
)
SELECT database_name, prev_start AS previous_log_backup, backup_start_date AS log_backup_after_gap,
       prev_last_lsn, first_lsn, server_name,
       'CHAIN BROKEN - point-in-time restore impossible between these backups' AS finding
FROM l
WHERE prev_last_lsn IS NOT NULL AND first_lsn > prev_last_lsn
ORDER BY backup_start_date DESC;


/*=============================================================================
  40.4 CHAIN-BREAKING / ROGUE BACKUPS                                  [BOX][MI]
  - BACKUP to NUL: log thrown away, chain broken
  - non-COPY_ONLY full by another tool/person: becomes the new DIFF base
    (your diffs now depend on a backup you may not have)
  - VSS / VM snapshot / 3rd-party (virtual device) backups that are not COPY_ONLY
  - recovery model switched to SIMPLE and back: chain broken
=============================================================================*/
SELECT bs.database_name, bs.type, bs.backup_start_date, bs.user_name, bs.server_name,
       bs.is_copy_only, bs.is_snapshot, bmf.device_type, bmf.physical_device_name,
       CASE WHEN bmf.physical_device_name = N'NUL' THEN 'BACKUP TO NUL - chain broken'
            WHEN bmf.device_type = 7 AND bs.is_copy_only = 0 THEN 'Virtual device (VSS / VM snapshot / 3rd-party) - not COPY_ONLY'
            WHEN bs.is_snapshot = 1 AND bs.is_copy_only = 0 THEN 'Snapshot backup - not COPY_ONLY'
            ELSE 'Full by a different user/tool than usual - review' END AS finding
FROM msdb.dbo.backupset AS bs
JOIN msdb.dbo.backupmediafamily AS bmf ON bmf.media_set_id = bs.media_set_id
WHERE bs.backup_start_date >= DATEADD(DAY, -30, GETDATE())
  AND (   bmf.physical_device_name = N'NUL'
       OR (bmf.device_type = 7 AND bs.is_copy_only = 0)
       OR (bs.is_snapshot = 1 AND bs.is_copy_only = 0)
       OR (bs.type = 'D' AND bs.is_copy_only = 0
           AND bs.user_name NOT IN (SELECT TOP (1) WITH TIES b2.user_name      -- not the usual full-backup account
                                    FROM msdb.dbo.backupset AS b2
                                    WHERE b2.database_name = bs.database_name AND b2.type = 'D'
                                    GROUP BY b2.user_name ORDER BY COUNT(*) DESC)))
ORDER BY bs.backup_start_date DESC;

-- Recovery model changes recorded in the backups themselves
WITH r AS (
    SELECT database_name, backup_start_date, recovery_model,
           LAG(recovery_model) OVER (PARTITION BY database_name ORDER BY backup_start_date) AS prev_model
    FROM msdb.dbo.backupset WHERE backup_start_date >= DATEADD(DAY, -30, GETDATE())
)
SELECT database_name, backup_start_date, prev_model, recovery_model
FROM r WHERE prev_model IS NOT NULL AND prev_model <> recovery_model;
-- and in the error log:
EXEC sys.xp_readerrorlog 0, 1, N'Setting database option RECOVERY';


/*=============================================================================
  40.5 BACKUP QUALITY (last 7 days)                                   [BOX][MI]
=============================================================================*/
SELECT bs.database_name, bs.type, bs.backup_finish_date,
       bs.has_backup_checksums, bs.is_damaged, bs.has_incomplete_metadata,
       CASE WHEN bs.compressed_backup_size < bs.backup_size THEN 1 ELSE 0 END AS is_compressed,
       bs.key_algorithm AS encryption,
       bmf.physical_device_name
FROM msdb.dbo.backupset AS bs
JOIN msdb.dbo.backupmediafamily AS bmf ON bmf.media_set_id = bs.media_set_id
WHERE bs.backup_finish_date >= DATEADD(DAY, -7, GETDATE())
  AND (bs.has_backup_checksums = 0 OR bs.is_damaged = 1 OR bs.has_incomplete_metadata = 1)
ORDER BY bs.backup_finish_date DESC;
-- Fix: EXEC sp_configure 'backup checksum default', 1; RECONFIGURE;   (or Ola @CheckSum = 'Y')


/*=============================================================================
  40.6 DO THE FILES NEEDED FOR A RESTORE STILL EXIST?                     [BOX]
  Checks every disk backup file since each DB's last full (as seen by the
  SQL Server service account). xp_fileexist is undocumented but long-standing.
  URL / tape / virtual devices are skipped. For real proof: 40.9 restore tests.
=============================================================================*/
IF OBJECT_ID('tempdb..#files') IS NOT NULL DROP TABLE #files;
CREATE TABLE #files (database_name sysname, type char(1), backup_finish_date datetime, path nvarchar(260), file_exists bit NULL);

INSERT #files (database_name, type, backup_finish_date, path)
SELECT bs.database_name, bs.type, bs.backup_finish_date, bmf.physical_device_name
FROM msdb.dbo.backupset AS bs
JOIN msdb.dbo.backupmediafamily AS bmf ON bmf.media_set_id = bs.media_set_id
WHERE bmf.device_type = 2                                  -- disk
  AND bs.backup_finish_date >= (SELECT MAX(f.backup_finish_date) FROM msdb.dbo.backupset AS f
                                WHERE f.database_name = bs.database_name AND f.type = 'D' AND f.is_copy_only = 0);

DECLARE @path nvarchar(260), @exists int;
DECLARE fc CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT path FROM #files;
OPEN fc; FETCH NEXT FROM fc INTO @path;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC master.dbo.xp_fileexist @path, @exists OUTPUT;
    UPDATE #files SET file_exists = @exists WHERE path = @path;
    FETCH NEXT FROM fc INTO @path;
END
CLOSE fc; DEALLOCATE fc;

SELECT database_name, type, backup_finish_date, path, file_exists
FROM #files
WHERE file_exists = 0
ORDER BY database_name, backup_finish_date;
-- 0 rows = every file needed for "restore to latest" is still there (from this server's point of view).


/*=============================================================================
  40.7 RESTORE CHAIN LENGTH (long chains = long RTO, more ways to fail)  [BOX][MI]
=============================================================================*/
SELECT d.name, d.recovery_model_desc,
       f.backup_finish_date AS last_full,
       df.backup_finish_date AS last_diff,
       (SELECT COUNT(*) FROM msdb.dbo.backupset AS b
        WHERE b.database_name = d.name AND b.type = 'L'
          AND b.backup_finish_date > COALESCE(df.backup_finish_date, f.backup_finish_date)) AS logs_to_restore,
       CASE WHEN df.backup_finish_date IS NULL AND DATEDIFF(DAY, f.backup_finish_date, GETDATE()) >= 2
            THEN 'Add DIFF backups to shorten the chain' ELSE '' END AS advice
FROM sys.databases AS d
OUTER APPLY (SELECT TOP (1) backup_finish_date, checkpoint_lsn FROM msdb.dbo.backupset
             WHERE database_name = d.name AND type = 'D' AND is_copy_only = 0 ORDER BY backup_finish_date DESC) AS f
OUTER APPLY (SELECT TOP (1) backup_finish_date FROM msdb.dbo.backupset
             WHERE database_name = d.name AND type = 'I' AND differential_base_lsn = f.checkpoint_lsn ORDER BY backup_finish_date DESC) AS df
WHERE d.database_id > 4 AND d.recovery_model_desc <> 'SIMPLE'
ORDER BY logs_to_restore DESC;


/*=============================================================================
  40.8 CRASH-RECOVERY RTO (how long a restart / failover takes)         [BOX][MI]
  log_recovery_size_mb = log that must be processed on restart/failover.
  Big numbers + many VLFs + legacy checkpoints (target_recovery_time 0)
  = long outage after a crash, failover or service restart.
=============================================================================*/
SELECT d.name, d.target_recovery_time_in_seconds,
       ls.log_recovery_size_mb, ls.log_since_last_checkpoint_mb,
       ls.total_vlf_count, ls.active_vlf_count, ls.total_log_size_mb,
       CASE WHEN d.target_recovery_time_in_seconds = 0 THEN 'Set TARGET_RECOVERY_TIME = 60 SECONDS; ' ELSE '' END
     + CASE WHEN ls.total_vlf_count > 1000 THEN 'Too many VLFs (19.3); ' ELSE '' END
     + CASE WHEN ls.log_recovery_size_mb > 10240 THEN 'Large recovery size - long txn open? (02 2.5); ' ELSE '' END AS advice
FROM sys.databases AS d
CROSS APPLY sys.dm_db_log_stats(d.database_id) AS ls
WHERE d.state_desc = N'ONLINE' AND d.database_id <> 2
ORDER BY ls.log_recovery_size_mb DESC;
-- 2019+: ADR makes recovery/rollback time nearly independent of transaction size (20.2).
-- ALTER DATABASE [YourDB] SET TARGET_RECOVERY_TIME = 60 SECONDS;


/*=============================================================================
  40.9 RESTORE TESTS - EVIDENCE THAT BACKUPS ACTUALLY WORK             [BOX][MI]
  A backup you haven't restored is a hope, not a backup. Measured restore
  time from a test is your REAL RTO (better than the 40.1 estimate).
=============================================================================*/
-- Restores done on THIS server, latest per source database (run on your test/restore server)
SELECT bs.database_name AS source_db, bs.server_name AS source_server,
       MAX(rh.restore_date) AS last_test_restore,
       DATEDIFF(DAY, MAX(rh.restore_date), GETDATE()) AS days_ago
FROM msdb.dbo.restorehistory AS rh
JOIN msdb.dbo.backupset AS bs ON bs.backup_set_id = rh.backup_set_id
GROUP BY bs.database_name, bs.server_name
ORDER BY days_ago DESC;

/* Automate weekly with dbatools (restores latest backups to a test server, runs CHECKDB, drops it,
   and records restore duration = measured RTO):

   Test-DbaLastBackup -SqlInstance SQLPROD1 -Destination SQLTEST1 -Database App1, App2 |
       Write-DbaDbTableData -SqlInstance SQLTEST1 -Database DBAdmin -Table dbo.RestoreTestResults -AutoCreateTable

   Then (on SQLTEST1):
SELECT SourceServer, Database, RestoreResult, DbccResult, RestoreElapsed, DbccElapsed, BackupDate, BackupFiles
FROM DBAdmin.dbo.RestoreTestResults ORDER BY BackupDate DESC;
*/


/*=============================================================================
  40.10 HA / DR COVERAGE PER DATABASE                                  [BOX][MI]
  Which databases can survive a server loss with near-zero RTO, and which
  depend on a restore (RTO = restore time, RPO = last log backup)?
=============================================================================*/
SELECT d.name, d.recovery_model_desc,
       ag.name AS availability_group,
       agx.replicas, agx.sync_replicas, agx.auto_failover_replicas, agx.has_listener,
       CASE WHEN lsp.primary_database IS NOT NULL THEN 1 ELSE 0 END AS log_shipping,
       CASE WHEN dm.mirroring_guid IS NOT NULL THEN 1 ELSE 0 END AS mirroring,
       CASE
           WHEN ag.name IS NOT NULL AND agx.auto_failover_replicas >= 2 THEN 'HA: AG sync + automatic failover'
           WHEN ag.name IS NOT NULL AND agx.sync_replicas >= 2         THEN 'HA: AG sync, MANUAL failover (someone must act)'
           WHEN ag.name IS NOT NULL                                    THEN 'DR: AG async only (data loss possible)'
           WHEN dm.mirroring_guid IS NOT NULL                          THEN 'Mirroring (deprecated)'
           WHEN lsp.primary_database IS NOT NULL                       THEN 'DR: log shipping (manual, RPO = LS interval)'
           ELSE 'BACKUPS ONLY - RTO = full restore time (40.1)' END AS protection
FROM sys.databases AS d
LEFT JOIN sys.availability_databases_cluster AS adc ON adc.database_name = d.name
LEFT JOIN sys.availability_groups AS ag ON ag.group_id = adc.group_id
OUTER APPLY (SELECT COUNT(*) AS replicas,
                    SUM(CASE WHEN ar.availability_mode = 1 THEN 1 ELSE 0 END) AS sync_replicas,
                    SUM(CASE WHEN ar.failover_mode = 0 AND ar.availability_mode = 1 THEN 1 ELSE 0 END) AS auto_failover_replicas,
                    (SELECT COUNT(*) FROM sys.availability_group_listeners AS agl WHERE agl.group_id = ag.group_id) AS has_listener
             FROM sys.availability_replicas AS ar WHERE ar.group_id = ag.group_id) AS agx
LEFT JOIN msdb.dbo.log_shipping_primary_databases AS lsp ON lsp.primary_database = d.name
LEFT JOIN sys.database_mirroring AS dm ON dm.database_id = d.database_id AND dm.mirroring_guid IS NOT NULL
WHERE d.database_id > 4
ORDER BY protection DESC, d.name;
-- Azure VM AG with a DNN listener shows has_listener = 0 here (DNN is a cluster resource) - check 11.8.


/*=============================================================================
  40.11 AG: CAN WE FAIL OVER WITHIN RTO / WITHOUT DATA LOSS RIGHT NOW?   [BOX]
  Run on the PRIMARY. One row per database per secondary.
=============================================================================*/
SELECT ag.name AS ag_name, DB_NAME(drs.database_id) AS database_name, ar.replica_server_name AS secondary,
       ar.availability_mode_desc, ar.failover_mode_desc,
       drs.synchronization_state_desc, dcs.is_failover_ready,
       CAST(drs.redo_queue_size * 1.0 / NULLIF(drs.redo_rate, 0) AS decimal(18,1)) AS est_failover_redo_s,
       drs.log_send_queue_size AS unsent_log_kb,
       DATEDIFF(SECOND, drs.last_commit_time, p.last_commit_time) AS data_loss_s_if_forced,
       CASE WHEN ar.availability_mode = 1 AND dcs.is_failover_ready = 1 THEN 'Planned failover OK - no data loss'
            WHEN ar.availability_mode = 1 THEN 'SYNC but NOT failover ready - fix first (25.2)'
            ELSE 'ASYNC - only FORCE_FAILOVER_ALLOW_DATA_LOSS (or switch to SYNC and wait)' END AS verdict
FROM sys.dm_hadr_database_replica_states AS drs
JOIN sys.availability_replicas AS ar ON ar.replica_id = drs.replica_id
JOIN sys.availability_groups AS ag ON ag.group_id = drs.group_id
JOIN sys.dm_hadr_database_replica_cluster_states AS dcs ON dcs.replica_id = drs.replica_id AND dcs.group_database_id = drs.group_database_id
JOIN sys.dm_hadr_database_replica_states AS p ON p.group_database_id = drs.group_database_id AND p.is_primary_replica = 1
WHERE drs.is_primary_replica = 0
ORDER BY ag.name, database_name, ar.replica_server_name;


/*=============================================================================
  40.12 SLA TABLE (template) - RECORD THE AGREED RPO / RTO PER DATABASE
=============================================================================*/
/*
USE DBAdmin;
CREATE TABLE dbo.DatabaseSLA (
    database_name sysname      NOT NULL PRIMARY KEY,
    tier          varchar(20)  NOT NULL,            -- e.g. Tier1 / Tier2 / Tier3
    rpo_minutes   int          NOT NULL,
    rto_minutes   int          NOT NULL,
    app_owner     nvarchar(128) NULL,
    notes         nvarchar(400) NULL);

INSERT dbo.DatabaseSLA (database_name, tier, rpo_minutes, rto_minutes, app_owner) VALUES
 (N'OrdersDB',  'Tier1',   5,   30, N'Payments team'),
 (N'ReportsDB', 'Tier3', 1440, 480, N'BI team');

 Typical design per tier:
   Tier1 (RPO <= 5 min, RTO <= 30 min): AG sync + auto failover, log backups every 5 min, diffs daily
   Tier2 (RPO 15 min, RTO 2-4 h):       log backups every 15 min, daily diff, tested restores
   Tier3 (RPO 24 h):                    daily full or diff; SIMPLE recovery acceptable
 Re-run 40.1 after any change.
*/
