/*******************************************************************************
 File    : 05_indexes_statistics.sql
 Purpose : Missing / unused / duplicate / fragmented indexes, statistics health.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] Managed Instance   [SQLDB] Azure SQL DB
 Note    : Most queries are for the CURRENT database (USE YourDB first).
           Index usage + missing index DMVs reset on restart / DB offline /
           index rebuild (usage) - check uptime before dropping anything.
*******************************************************************************/

/*=============================================================================
  5.1  MISSING INDEXES - ALL DATABASES, WITH CREATE STATEMENT  [BOX][MI][SQLDB]
  Treat as hints, not orders: merge overlapping suggestions, check column order.
=============================================================================*/
SELECT TOP (50)
    DB_NAME(mid.database_id)                                        AS database_name,
    mid.statement                                                   AS table_name,
    CAST(migs.avg_total_user_cost * (migs.avg_user_impact / 100.0)
         * (migs.user_seeks + migs.user_scans) AS decimal(18,0))    AS improvement_score,
    migs.user_seeks, migs.user_scans, migs.avg_user_impact, migs.last_user_seek,
    mid.equality_columns, mid.inequality_columns, mid.included_columns,
    N'CREATE NONCLUSTERED INDEX [IX_' + OBJECT_NAME(mid.object_id, mid.database_id) + N'_'
        + CAST(mid.index_handle AS nvarchar(10)) + N'] ON ' + mid.statement + N' ('
        + ISNULL(mid.equality_columns, N'')
        + CASE WHEN mid.equality_columns IS NOT NULL AND mid.inequality_columns IS NOT NULL THEN N', ' ELSE N'' END
        + ISNULL(mid.inequality_columns, N'') + N')'
        + ISNULL(N' INCLUDE (' + mid.included_columns + N')', N'')
        + N' WITH (ONLINE = ON);  -- ONLINE needs Enterprise/Azure'  AS create_statement
FROM sys.dm_db_missing_index_groups      AS mig
JOIN sys.dm_db_missing_index_group_stats AS migs ON migs.group_handle = mig.index_group_handle
JOIN sys.dm_db_missing_index_details     AS mid  ON mid.index_handle  = mig.index_handle
ORDER BY improvement_score DESC;


/*=============================================================================
  5.2  INDEX USAGE - CURRENT DB (reads vs writes, size)        [BOX][MI][SQLDB]
=============================================================================*/
SELECT
    OBJECT_SCHEMA_NAME(i.object_id) + N'.' + OBJECT_NAME(i.object_id) AS table_name,
    i.name AS index_name, i.index_id, i.type_desc, i.is_primary_key, i.is_unique,
    ISNULL(us.user_seeks, 0)   AS seeks,
    ISNULL(us.user_scans, 0)   AS scans,
    ISNULL(us.user_lookups, 0) AS lookups,
    ISNULL(us.user_updates, 0) AS writes,
    us.last_user_seek, us.last_user_scan, us.last_user_update,
    sz.size_mb, sz.row_count
FROM sys.indexes AS i
LEFT JOIN sys.dm_db_index_usage_stats AS us
       ON us.object_id = i.object_id AND us.index_id = i.index_id AND us.database_id = DB_ID()
OUTER APPLY (SELECT CAST(SUM(ps.used_page_count) * 8 / 1024.0 AS decimal(18,2)) AS size_mb,
                    SUM(CASE WHEN ps.index_id < 2 THEN ps.row_count ELSE 0 END) AS row_count
             FROM sys.dm_db_partition_stats AS ps
             WHERE ps.object_id = i.object_id AND ps.index_id = i.index_id) AS sz
WHERE OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1
ORDER BY table_name, i.index_id;


/*=============================================================================
  5.3  UNUSED / WRITE-ONLY NONCLUSTERED INDEXES - CURRENT DB   [BOX][MI][SQLDB]
  Candidates to drop (after checking uptime, month-end jobs, AG secondaries -
  reads on readable secondaries are NOT counted on the primary).
=============================================================================*/
SELECT
    OBJECT_SCHEMA_NAME(i.object_id) + N'.' + OBJECT_NAME(i.object_id) AS table_name,
    i.name AS index_name,
    ISNULL(us.user_seeks + us.user_scans + us.user_lookups, 0) AS total_reads,
    ISNULL(us.user_updates, 0)                                  AS total_writes,
    CAST(SUM(ps.used_page_count) * 8 / 1024.0 AS decimal(18,2)) AS size_mb,
    N'DROP INDEX ' + QUOTENAME(i.name) + N' ON '
        + QUOTENAME(OBJECT_SCHEMA_NAME(i.object_id)) + N'.' + QUOTENAME(OBJECT_NAME(i.object_id)) + N';' AS drop_statement
FROM sys.indexes AS i
JOIN sys.dm_db_partition_stats AS ps ON ps.object_id = i.object_id AND ps.index_id = i.index_id
LEFT JOIN sys.dm_db_index_usage_stats AS us
       ON us.object_id = i.object_id AND us.index_id = i.index_id AND us.database_id = DB_ID()
WHERE OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1
  AND i.type_desc = 'NONCLUSTERED'
  AND i.is_primary_key = 0 AND i.is_unique_constraint = 0
  AND ISNULL(us.user_seeks + us.user_scans + us.user_lookups, 0) = 0
GROUP BY i.object_id, i.name, us.user_seeks, us.user_scans, us.user_lookups, us.user_updates
ORDER BY total_writes DESC;


/*=============================================================================
  5.4  DUPLICATE & OVERLAPPING INDEXES - CURRENT DB            [BOX][MI][SQLDB]
  (FOR XML PATH used instead of STRING_AGG so it also works on 2016)
=============================================================================*/
WITH idx AS (
    SELECT i.object_id, i.index_id, i.name, i.type_desc, i.is_unique, i.filter_definition,
        key_cols = STUFF((
            SELECT N',' + QUOTENAME(c.name) + CASE WHEN ic.is_descending_key = 1 THEN N' DESC' ELSE N'' END
            FROM sys.index_columns AS ic
            JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
            WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
            ORDER BY ic.key_ordinal
            FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 1, N''),
        incl_cols = STUFF((
            SELECT N',' + QUOTENAME(c.name)
            FROM sys.index_columns AS ic
            JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
            WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1
            ORDER BY c.name
            FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 1, N'')
    FROM sys.indexes AS i
    WHERE OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1 AND i.type IN (1, 2)
)
SELECT
    OBJECT_SCHEMA_NAME(a.object_id) + N'.' + OBJECT_NAME(a.object_id) AS table_name,
    a.name AS index_1, a.key_cols AS keys_1, a.incl_cols AS includes_1,
    b.name AS index_2, b.key_cols AS keys_2, b.incl_cols AS includes_2,
    CASE WHEN a.key_cols = b.key_cols AND ISNULL(a.incl_cols, N'') = ISNULL(b.incl_cols, N'')
         THEN 'EXACT DUPLICATE'
         WHEN a.key_cols = b.key_cols THEN 'SAME KEYS, DIFFERENT INCLUDES'
         ELSE 'OVERLAPPING (left-prefix)' END AS finding
FROM idx AS a
JOIN idx AS b ON b.object_id = a.object_id AND b.index_id > a.index_id
WHERE ISNULL(a.filter_definition, N'') = ISNULL(b.filter_definition, N'')
  AND (a.key_cols = b.key_cols
       OR b.key_cols LIKE a.key_cols + N',%'
       OR a.key_cols LIKE b.key_cols + N',%')
ORDER BY table_name;


/*=============================================================================
  5.5  FRAGMENTATION - CURRENT DB (LIMITED mode, >1000 pages)  [BOX][MI][SQLDB]
  Modern guidance: fragmentation matters far less on SSD/SAN; prioritise stats.
  Common thresholds: 5-30% REORGANIZE, >30% REBUILD. See 19_maintenance.
=============================================================================*/
SELECT
    OBJECT_SCHEMA_NAME(ips.object_id) + N'.' + OBJECT_NAME(ips.object_id) AS table_name,
    i.name AS index_name, ips.index_type_desc, ips.partition_number,
    CAST(ips.avg_fragmentation_in_percent AS decimal(5,2)) AS frag_pct,
    ips.page_count, ips.fragment_count, i.fill_factor
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') AS ips
JOIN sys.indexes AS i ON i.object_id = ips.object_id AND i.index_id = ips.index_id
WHERE ips.page_count > 1000
  AND ips.index_id > 0
  AND ips.alloc_unit_type_desc = 'IN_ROW_DATA'
ORDER BY ips.avg_fragmentation_in_percent DESC;


/*=============================================================================
  5.6  HEAPS WITH FORWARDED RECORDS - CURRENT DB               [BOX][MI][SQLDB]
  Uses SAMPLED mode (needed for forwarded_record_count). Can be slow.
=============================================================================*/
SELECT OBJECT_SCHEMA_NAME(ips.object_id) + N'.' + OBJECT_NAME(ips.object_id) AS heap_name,
       ips.page_count, ips.record_count, ips.forwarded_record_count,
       CAST(100.0 * ips.forwarded_record_count / NULLIF(ips.record_count, 0) AS decimal(5,2)) AS forwarded_pct
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, 0, NULL, 'SAMPLED') AS ips
WHERE ips.index_type_desc = 'HEAP'
  AND ips.page_count > 100
ORDER BY ips.forwarded_record_count DESC;


/*=============================================================================
  5.7  ALL INDEXES ON ONE TABLE (better sp_helpindex)          [BOX][MI][SQLDB]
=============================================================================*/
DECLARE @table sysname = N'dbo.YourTable';   -- <== change
SELECT i.index_id, i.name, i.type_desc, i.is_primary_key, i.is_unique, i.fill_factor,
       i.has_filter, i.filter_definition, p.data_compression_desc,
       STUFF((SELECT N', ' + c.name + CASE WHEN ic.is_descending_key = 1 THEN N' DESC' ELSE N'' END
              FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
              WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
              ORDER BY ic.key_ordinal FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'') AS key_columns,
       STUFF((SELECT N', ' + c.name
              FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
              WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1
              FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'') AS included_columns,
       CAST(SUM(ps.used_page_count) * 8 / 1024.0 AS decimal(18,2)) AS size_mb
FROM sys.indexes AS i
JOIN sys.partitions AS p ON p.object_id = i.object_id AND p.index_id = i.index_id AND p.partition_number = 1
JOIN sys.dm_db_partition_stats AS ps ON ps.object_id = i.object_id AND ps.index_id = i.index_id
WHERE i.object_id = OBJECT_ID(@table)
GROUP BY i.object_id, i.index_id, i.name, i.type_desc, i.is_primary_key, i.is_unique, i.fill_factor,
         i.has_filter, i.filter_definition, p.data_compression_desc
ORDER BY i.index_id;


/*=============================================================================
  5.8  STATISTICS HEALTH - CURRENT DB (stale / low sample)     [BOX][MI][SQLDB]
=============================================================================*/
SELECT
    OBJECT_SCHEMA_NAME(s.object_id) + N'.' + OBJECT_NAME(s.object_id) AS table_name,
    s.name AS stats_name, s.auto_created, s.user_created, s.no_recompute, s.is_incremental,
    sp.last_updated, DATEDIFF(DAY, sp.last_updated, SYSDATETIME()) AS days_old,
    sp.rows, sp.rows_sampled,
    CAST(100.0 * sp.rows_sampled / NULLIF(sp.rows, 0) AS decimal(5,2)) AS sample_pct,
    sp.modification_counter,
    CAST(100.0 * sp.modification_counter / NULLIF(sp.rows, 0) AS decimal(10,2)) AS modified_pct,
    sp.steps
FROM sys.stats AS s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
WHERE OBJECTPROPERTY(s.object_id, 'IsUserTable') = 1
ORDER BY sp.modification_counter DESC;


/*=============================================================================
  5.9  INDEX OPERATIONAL STATS (lock/latch waits, splits proxy) [BOX][MI][SQLDB]
=============================================================================*/
SELECT TOP (25)
    OBJECT_SCHEMA_NAME(os.object_id) + N'.' + OBJECT_NAME(os.object_id) AS table_name,
    i.name AS index_name,
    os.leaf_insert_count, os.leaf_update_count, os.leaf_delete_count,
    os.leaf_allocation_count            AS leaf_page_splits_approx,
    os.row_lock_wait_count, os.row_lock_wait_in_ms,
    os.page_lock_wait_count, os.page_lock_wait_in_ms,
    os.page_latch_wait_count, os.page_latch_wait_in_ms,
    os.page_io_latch_wait_count, os.page_io_latch_wait_in_ms,
    os.index_lock_promotion_attempt_count, os.index_lock_promotion_count
FROM sys.dm_db_index_operational_stats(DB_ID(), NULL, NULL, NULL) AS os
JOIN sys.indexes AS i ON i.object_id = os.object_id AND i.index_id = os.index_id
WHERE OBJECTPROPERTY(os.object_id, 'IsUserTable') = 1
ORDER BY os.row_lock_wait_in_ms + os.page_lock_wait_in_ms DESC;


/*=============================================================================
  5.10 COLUMNSTORE ROWGROUP HEALTH - CURRENT DB                [BOX][MI][SQLDB]
=============================================================================*/
SELECT OBJECT_NAME(rg.object_id) AS table_name, i.name AS index_name,
       rg.state_desc, COUNT(*) AS rowgroups,
       SUM(rg.total_rows) AS total_rows, SUM(rg.deleted_rows) AS deleted_rows,
       CAST(100.0 * SUM(rg.deleted_rows) / NULLIF(SUM(rg.total_rows), 0) AS decimal(5,2)) AS deleted_pct,
       MIN(rg.trim_reason_desc) AS sample_trim_reason
FROM sys.dm_db_column_store_row_group_physical_stats AS rg
JOIN sys.indexes AS i ON i.object_id = rg.object_id AND i.index_id = rg.index_id
GROUP BY rg.object_id, i.name, rg.state_desc
ORDER BY table_name, rg.state_desc;


/*=============================================================================
  5.11 TABLES WITHOUT A CLUSTERED INDEX / PRIMARY KEY          [BOX][MI][SQLDB]
=============================================================================*/
SELECT OBJECT_SCHEMA_NAME(t.object_id) + N'.' + t.name AS table_name,
       OBJECTPROPERTY(t.object_id, 'TableHasClustIndex') AS has_clustered,
       OBJECTPROPERTY(t.object_id, 'TableHasPrimaryKey') AS has_pk,
       (SELECT SUM(row_count) FROM sys.dm_db_partition_stats ps WHERE ps.object_id = t.object_id AND ps.index_id IN (0,1)) AS row_count
FROM sys.tables AS t
WHERE t.is_ms_shipped = 0
  AND (OBJECTPROPERTY(t.object_id, 'TableHasClustIndex') = 0 OR OBJECTPROPERTY(t.object_id, 'TableHasPrimaryKey') = 0)
ORDER BY row_count DESC;


/*=============================================================================
  5.12 RESUMABLE INDEX OPERATIONS IN PROGRESS (2017+)          [BOX][MI][SQLDB]
=============================================================================*/
SELECT OBJECT_NAME(object_id) AS table_name, index_id, name, state_desc,
       percent_complete, start_time, last_pause_time, total_execution_time, sql_text
FROM sys.index_resumable_operations;
-- ALTER INDEX [IX_name] ON dbo.T RESUME;   |  ... PAUSE;  |  ... ABORT;
