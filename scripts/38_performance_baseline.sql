/*******************************************************************************
 File    : 38_performance_baseline.sql
 Purpose : "Is this normal?" - you can't tune without a baseline.
           (1) Live perfmon dashboard from T-SQL with correct per-second /
               ratio maths, (2) a lightweight baseline collector (waits, file
               I/O, counters) into a DBA database, (3) trend & compare queries.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] Managed Instance
           (Azure SQL DB: use 16.2/16.3 resource stats + Query Store as baseline)
 Note    : Collector writes to DBAdmin (same DB as the community tools).
*******************************************************************************/

/*=============================================================================
  38.1 LIVE PERFMON DASHBOARD (two samples, correct maths)            [BOX][MI]
  cntr_type 272696576 = cumulative "/sec" -> (v2 - v1) / seconds
            65792     = point-in-time value
            537003264 = ratio -> value / matching "base" counter
            1073874176= average -> delta(value) / delta(base)
=============================================================================*/
DECLARE @sample_s int = 10;
DECLARE @delay char(8) = '00:00:' + RIGHT('0' + CAST(@sample_s AS varchar(2)), 2);

IF OBJECT_ID('tempdb..#pc1') IS NOT NULL DROP TABLE #pc1;
IF OBJECT_ID('tempdb..#pc2') IS NOT NULL DROP TABLE #pc2;
SELECT RTRIM(object_name) AS obj, RTRIM(counter_name) AS ctr, RTRIM(instance_name) AS inst, cntr_value, cntr_type
INTO #pc1 FROM sys.dm_os_performance_counters;
WAITFOR DELAY @delay;
SELECT RTRIM(object_name) AS obj, RTRIM(counter_name) AS ctr, RTRIM(instance_name) AS inst, cntr_value, cntr_type
INTO #pc2 FROM sys.dm_os_performance_counters;

WITH calc AS (
    SELECT p2.obj, p2.ctr, p2.inst, p2.cntr_type,
           CASE p2.cntr_type
               WHEN 272696576  THEN (p2.cntr_value - p1.cntr_value) * 1.0 / @sample_s
               WHEN 65792      THEN p2.cntr_value * 1.0
               WHEN 537003264  THEN 100.0 * p2.cntr_value / NULLIF(b2.cntr_value, 0)
               WHEN 1073874176 THEN (p2.cntr_value - p1.cntr_value) * 1.0 / NULLIF(ab2.cntr_value - ab1.cntr_value, 0)
           END AS value
    FROM #pc2 AS p2
    JOIN #pc1 AS p1 ON p1.obj = p2.obj AND p1.ctr = p2.ctr AND p1.inst = p2.inst
    LEFT JOIN #pc2 AS b2  ON p2.cntr_type = 537003264  AND b2.obj = p2.obj AND b2.inst = p2.inst AND b2.ctr = p2.ctr + ' base'
    LEFT JOIN #pc2 AS ab2 ON p2.cntr_type = 1073874176 AND ab2.obj = p2.obj AND ab2.inst = p2.inst AND ab2.ctr = REPLACE(p2.ctr, ' (ms)', '') + ' Base'
    LEFT JOIN #pc1 AS ab1 ON ab1.obj = ab2.obj AND ab1.inst = ab2.inst AND ab1.ctr = ab2.ctr
    WHERE p2.cntr_type IN (272696576, 65792, 537003264, 1073874176)
)
SELECT obj AS object_name, ctr AS counter_name, NULLIF(inst, '') AS instance_name, CAST(value AS decimal(18,2)) AS value,
       CASE ctr
           WHEN 'Page life expectancy'     THEN 'Watch for sudden drops; compare to baseline'
           WHEN 'Memory Grants Pending'    THEN '> 0 sustained = memory pressure'
           WHEN 'Processes blocked'        THEN '> 0 sustained = blocking (02)'
           WHEN 'SQL Compilations/sec'     THEN '> ~10% of Batch Requests/sec = plan reuse problem'
           WHEN 'SQL Re-Compilations/sec'  THEN '> ~10% of Compilations = recompile churn'
           WHEN 'Full Scans/sec'           THEN 'compare with Index Searches/sec'
           WHEN 'Page Splits/sec'          THEN '24.8 for which index'
           WHEN 'Lazy writes/sec'          THEN '> ~20 sustained = buffer pool pressure'
           WHEN 'Free list stalls/sec'     THEN '> 2 = memory pressure'
           WHEN 'Workfiles Created/sec'    THEN 'hash spills to tempdb'
           WHEN 'Log Flush Wait Time'      THEN 'ms waited for log flushes (WRITELOG)'
       END AS hint
FROM calc
WHERE (ctr IN ('Batch Requests/sec', 'SQL Compilations/sec', 'SQL Re-Compilations/sec', 'User Connections',
               'Logins/sec', 'Processes blocked', 'Errors/sec',
               'Page life expectancy', 'Lazy writes/sec', 'Page reads/sec', 'Page writes/sec', 'Checkpoint pages/sec',
               'Free list stalls/sec', 'Buffer cache hit ratio',
               'Memory Grants Pending', 'Memory Grants Outstanding', 'Target Server Memory (KB)', 'Total Server Memory (KB)',
               'Full Scans/sec', 'Index Searches/sec', 'Page Splits/sec', 'Forwarded Records/sec',
               'Workfiles Created/sec', 'Worktables Created/sec',
               'Latch Waits/sec', 'Average Latch Wait Time (ms)',
               'Number of Deadlocks/sec', 'Lock Timeouts (timeout > 0)/sec')
       AND inst IN ('', '_Total'))
   OR (ctr IN ('Lock Waits/sec', 'Average Wait Time (ms)') AND inst = '_Total')
   OR (ctr IN ('Transactions/sec', 'Log Flushes/sec', 'Log Flush Wait Time', 'Log Bytes Flushed/sec') AND inst = '_Total')
ORDER BY obj, ctr;


/*=============================================================================
  38.2 BASELINE COLLECTOR - SETUP (run once)                          [BOX][MI]
=============================================================================*/
/*
USE DBAdmin;
GO
CREATE TABLE dbo.BL_WaitStats (
    collection_time     datetime2(0) NOT NULL,
    wait_type           nvarchar(60) NOT NULL,
    waiting_tasks_count bigint NOT NULL,
    wait_time_ms        bigint NOT NULL,
    signal_wait_time_ms bigint NOT NULL,
    CONSTRAINT PK_BL_WaitStats PRIMARY KEY (collection_time, wait_type)) WITH (DATA_COMPRESSION = PAGE);

CREATE TABLE dbo.BL_FileStats (
    collection_time   datetime2(0) NOT NULL,
    database_name     sysname NOT NULL,
    file_id           int NOT NULL,
    type_desc         nvarchar(60) NOT NULL,
    num_of_reads      bigint NOT NULL,
    num_of_writes     bigint NOT NULL,
    io_stall_read_ms  bigint NOT NULL,
    io_stall_write_ms bigint NOT NULL,
    bytes_read        bigint NOT NULL,
    bytes_written     bigint NOT NULL,
    CONSTRAINT PK_BL_FileStats PRIMARY KEY (collection_time, database_name, file_id)) WITH (DATA_COMPRESSION = PAGE);

CREATE TABLE dbo.BL_PerfCounters (
    collection_time datetime2(0) NOT NULL,
    object_name     nvarchar(128) NOT NULL,
    counter_name    nvarchar(128) NOT NULL,
    instance_name   nvarchar(128) NOT NULL,
    cntr_value      bigint NOT NULL,
    cntr_type       int NOT NULL,
    CONSTRAINT PK_BL_PerfCounters PRIMARY KEY (collection_time, object_name, counter_name, instance_name)) WITH (DATA_COMPRESSION = PAGE);
GO
CREATE OR ALTER PROCEDURE dbo.usp_BL_Collect @RetentionDays int = 35
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now datetime2(0) = SYSDATETIME();

    INSERT dbo.BL_WaitStats (collection_time, wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms)
    SELECT @now, wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms
    FROM sys.dm_os_wait_stats WHERE waiting_tasks_count > 0;

    INSERT dbo.BL_FileStats (collection_time, database_name, file_id, type_desc, num_of_reads, num_of_writes,
                             io_stall_read_ms, io_stall_write_ms, bytes_read, bytes_written)
    SELECT @now, DB_NAME(v.database_id), v.file_id, mf.type_desc, v.num_of_reads, v.num_of_writes,
           v.io_stall_read_ms, v.io_stall_write_ms, v.num_of_bytes_read, v.num_of_bytes_written
    FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS v
    JOIN sys.master_files AS mf ON mf.database_id = v.database_id AND mf.file_id = v.file_id;

    INSERT dbo.BL_PerfCounters (collection_time, object_name, counter_name, instance_name, cntr_value, cntr_type)
    SELECT @now, RTRIM(object_name), RTRIM(counter_name), RTRIM(instance_name), cntr_value, cntr_type
    FROM sys.dm_os_performance_counters
    WHERE RTRIM(counter_name) IN (N'Batch Requests/sec', N'SQL Compilations/sec', N'SQL Re-Compilations/sec', N'User Connections',
          N'Page life expectancy', N'Lazy writes/sec', N'Page reads/sec', N'Memory Grants Pending', N'Processes blocked',
          N'Transactions/sec', N'Log Flushes/sec', N'Number of Deadlocks/sec', N'Full Scans/sec', N'Page Splits/sec',
          N'Target Server Memory (KB)', N'Total Server Memory (KB)', N'Workfiles Created/sec')
      AND RTRIM(instance_name) IN (N'', N'_Total');

    DELETE dbo.BL_WaitStats    WHERE collection_time < DATEADD(DAY, -@RetentionDays, @now);
    DELETE dbo.BL_FileStats    WHERE collection_time < DATEADD(DAY, -@RetentionDays, @now);
    DELETE dbo.BL_PerfCounters WHERE collection_time < DATEADD(DAY, -@RetentionDays, @now);
END;
GO
-- Agent job: every 15 minutes ->  EXEC DBAdmin.dbo.usp_BL_Collect;
-- Same proc on every AG replica (DBAdmin is not in the AG).
*/


/*=============================================================================
  38.3 TREND: TOP WAITS PER INTERVAL (deltas, restart-safe)            [BOX][MI]
=============================================================================*/
DECLARE @from datetime2(0) = DATEADD(DAY, -1, SYSDATETIME());
WITH d AS (
    SELECT collection_time, wait_type,
           wait_time_ms - LAG(wait_time_ms) OVER (PARTITION BY wait_type ORDER BY collection_time) AS wait_ms_delta,
           waiting_tasks_count - LAG(waiting_tasks_count) OVER (PARTITION BY wait_type ORDER BY collection_time) AS tasks_delta
    FROM DBAdmin.dbo.BL_WaitStats
    WHERE collection_time >= DATEADD(MINUTE, -30, @from)
)
SELECT collection_time, wait_type, wait_ms_delta, tasks_delta,
       CAST(wait_ms_delta * 1.0 / NULLIF(tasks_delta, 0) AS decimal(18,2)) AS avg_wait_ms,
       RANK() OVER (PARTITION BY collection_time ORDER BY wait_ms_delta DESC) AS rnk
FROM d
WHERE wait_ms_delta > 0                                -- negative = restart/clear in between -> skipped
  AND collection_time >= @from
  AND wait_type NOT LIKE N'%SLEEP%' AND wait_type NOT LIKE N'%QUEUE%' AND wait_type NOT LIKE N'XE_%'
  AND wait_type NOT IN (N'CXCONSUMER', N'WAITFOR', N'BROKER_TASK_STOP', N'BROKER_TO_FLUSH', N'CHECKPOINT_QUEUE',
                        N'DIRTY_PAGE_POLL', N'HADR_FILESTREAM_IOMGR_IOCOMPLETION', N'SP_SERVER_DIAGNOSTICS_SLEEP',
                        N'REQUEST_FOR_DEADLOCK_SEARCH', N'HADR_WORK_QUEUE', N'HADR_TIMER_TASK', N'PWAIT_EXTENSIBILITY_CLEANUP_TASK')
ORDER BY collection_time DESC, rnk;


/*=============================================================================
  38.4 COMPARE: LAST HOUR vs SAME HOUR, PREVIOUS 7 DAYS (waits)        [BOX][MI]
=============================================================================*/
WITH d AS (
    SELECT collection_time, wait_type,
           wait_time_ms - LAG(wait_time_ms) OVER (PARTITION BY wait_type ORDER BY collection_time) AS ms
    FROM DBAdmin.dbo.BL_WaitStats
    WHERE collection_time >= DATEADD(DAY, -8, SYSDATETIME())
),
now_ AS (SELECT wait_type, SUM(ms) AS ms FROM d
         WHERE ms > 0 AND collection_time >= DATEADD(HOUR, -1, SYSDATETIME()) GROUP BY wait_type),
base AS (SELECT wait_type, SUM(ms) / 7.0 AS ms FROM d
         WHERE ms > 0 AND collection_time < CAST(CAST(SYSDATETIME() AS date) AS datetime2(0))
           AND DATEPART(HOUR, collection_time) = DATEPART(HOUR, DATEADD(HOUR, -1, SYSDATETIME()))
         GROUP BY wait_type)
SELECT TOP (20) n.wait_type, n.ms AS last_hour_ms, CAST(b.ms AS bigint) AS baseline_same_hour_ms,
       CAST(n.ms / NULLIF(b.ms, 0) AS decimal(10,2)) AS times_normal
FROM now_ AS n
LEFT JOIN base AS b ON b.wait_type = n.wait_type
WHERE n.wait_type NOT LIKE N'%SLEEP%' AND n.wait_type NOT LIKE N'%QUEUE%' AND n.wait_type NOT LIKE N'XE_%'
ORDER BY n.ms DESC;


/*=============================================================================
  38.5 TREND: FILE LATENCY PER INTERVAL                               [BOX][MI]
=============================================================================*/
WITH d AS (
    SELECT collection_time, database_name, file_id, type_desc,
           num_of_reads  - LAG(num_of_reads)  OVER (PARTITION BY database_name, file_id ORDER BY collection_time) AS reads,
           num_of_writes - LAG(num_of_writes) OVER (PARTITION BY database_name, file_id ORDER BY collection_time) AS writes,
           io_stall_read_ms  - LAG(io_stall_read_ms)  OVER (PARTITION BY database_name, file_id ORDER BY collection_time) AS rstall,
           io_stall_write_ms - LAG(io_stall_write_ms) OVER (PARTITION BY database_name, file_id ORDER BY collection_time) AS wstall
    FROM DBAdmin.dbo.BL_FileStats
    WHERE collection_time >= DATEADD(DAY, -1, SYSDATETIME())
)
SELECT collection_time, database_name, type_desc, reads, writes,
       CAST(rstall * 1.0 / NULLIF(reads, 0)  AS decimal(10,2)) AS avg_read_ms,
       CAST(wstall * 1.0 / NULLIF(writes, 0) AS decimal(10,2)) AS avg_write_ms
FROM d
WHERE reads >= 0 AND writes >= 0 AND (reads + writes) > 0
ORDER BY collection_time DESC, rstall + wstall DESC;


/*=============================================================================
  38.6 TREND: KEY COUNTERS (per-sec counters as rates)                [BOX][MI]
=============================================================================*/
WITH d AS (
    SELECT collection_time, counter_name, cntr_type, cntr_value,
           cntr_value - LAG(cntr_value) OVER (PARTITION BY object_name, counter_name, instance_name ORDER BY collection_time) AS delta,
           DATEDIFF(SECOND, LAG(collection_time) OVER (PARTITION BY object_name, counter_name, instance_name ORDER BY collection_time), collection_time) AS secs
    FROM DBAdmin.dbo.BL_PerfCounters
    WHERE collection_time >= DATEADD(DAY, -1, SYSDATETIME())
)
SELECT collection_time, counter_name,
       CAST(CASE WHEN cntr_type = 272696576 THEN delta * 1.0 / NULLIF(secs, 0) ELSE cntr_value END AS decimal(18,2)) AS value
FROM d
WHERE NOT (cntr_type = 272696576 AND (delta IS NULL OR delta < 0))
ORDER BY counter_name, collection_time DESC;
-- Pivot in Excel / Power BI, or the FRK sp_BlitzFirst logging (33.4) for a ready-made dashboard.
