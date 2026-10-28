/*******************************************************************************
 File    : 24_index_tuning.sql
 Purpose : Deeper index TUNING (beyond the health checks in 05): consolidated
           missing-index advice, key lookups & scans in plans, unindexed FKs,
           bad clustering keys, wide/over-indexed tables, page splits,
           compression candidates, partitioning, hypothetical/disabled indexes.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] Managed Instance   [SQLDB] Azure SQL DB
 Workflow: 1) find the expensive queries (03 / 04)  2) look at their plans
           (24.3/24.4)  3) check existing indexes (05 5.7)  4) consolidate
           suggestions (24.1)  5) test, deploy, re-measure (04 Query Store).
*******************************************************************************/

/*=============================================================================
  24.1 MISSING INDEXES CONSOLIDATED PER TABLE - CURRENT DB     [BOX][MI][SQLDB]
  Several suggestions with the same leading equality column can usually be
  served by ONE index - review them side by side before creating anything.
=============================================================================*/
SELECT
    mid.statement AS table_name,
    COUNT(*) OVER (PARTITION BY mid.object_id)                                 AS suggestions_on_table,
    mid.equality_columns, mid.inequality_columns, mid.included_columns,
    migs.user_seeks + migs.user_scans                                          AS uses,
    CAST(migs.avg_user_impact AS decimal(5,1))                                 AS avg_impact_pct,
    CAST(migs.avg_total_user_cost * migs.avg_user_impact / 100.0
         * (migs.user_seeks + migs.user_scans) AS decimal(18,0))               AS score,
    (SELECT COUNT(*) FROM sys.indexes i WHERE i.object_id = mid.object_id AND i.index_id > 0) AS existing_indexes
FROM sys.dm_db_missing_index_details     AS mid
JOIN sys.dm_db_missing_index_groups      AS mig  ON mig.index_handle = mid.index_handle
JOIN sys.dm_db_missing_index_group_stats AS migs ON migs.group_handle = mig.index_group_handle
WHERE mid.database_id = DB_ID()
ORDER BY SUM(migs.avg_total_user_cost * migs.avg_user_impact * (migs.user_seeks + migs.user_scans))
             OVER (PARTITION BY mid.object_id) DESC,
         mid.statement, mid.equality_columns;


/*=============================================================================
  24.2 EXISTING INDEX COLUMN MAP FOR A TABLE (compare with 24.1) [BOX][MI][SQLDB]
=============================================================================*/
DECLARE @tbl sysname = N'dbo.YourTable';   -- <== change
SELECT i.name AS index_name, i.type_desc, ic.key_ordinal, c.name AS column_name,
       CASE WHEN ic.is_included_column = 1 THEN 'INCLUDE' ELSE 'KEY' END AS role,
       ic.is_descending_key, TYPE_NAME(c.user_type_id) AS data_type, c.max_length
FROM sys.indexes AS i
JOIN sys.index_columns AS ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.object_id = OBJECT_ID(@tbl)
ORDER BY i.index_id, ic.is_included_column, ic.key_ordinal, c.name;


/*=============================================================================
  24.3 KEY / RID LOOKUPS IN CACHED PLANS (covering index candidates)
                                                               [BOX][MI][SQLDB]
  Heavy XML query - run off-peak. Output = the table + columns being looked up.
=============================================================================*/
WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan'),
lookups AS (
    SELECT TOP (500) qs.plan_handle, qs.execution_count, qs.total_logical_reads, qs.total_worker_time,
           qp.query_plan, t.text
    FROM sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
    WHERE qp.query_plan.exist('//IndexScan[@Lookup="1"]') = 1
    ORDER BY qs.total_logical_reads DESC
)
SELECT TOP (50)
    l.execution_count, l.total_logical_reads, l.total_worker_time / 1000 AS total_cpu_ms,
    n.op.value('(IndexScan/Object/@Database)[1]', 'sysname') + N'.'
      + n.op.value('(IndexScan/Object/@Schema)[1]', 'sysname') + N'.'
      + n.op.value('(IndexScan/Object/@Table)[1]', 'sysname')       AS lookup_table,
    n.op.value('(IndexScan/Object/@Index)[1]', 'sysname')           AS via_index,
    n.op.query('for $c in OutputList/ColumnReference return string($c/@Column)').value('.', 'nvarchar(max)') AS columns_fetched_by_lookup,
    n.op.value('@EstimateRows', 'float') * n.op.value('@EstimateRebinds', 'float') AS est_lookup_rows,
    l.text
FROM lookups AS l
CROSS APPLY l.query_plan.nodes('//RelOp[IndexScan[@Lookup="1"]]') AS n(op)
ORDER BY l.total_logical_reads DESC;


/*=============================================================================
  24.4 TABLE / CLUSTERED INDEX SCANS IN CACHED PLANS           [BOX][MI][SQLDB]
=============================================================================*/
WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
SELECT TOP (50)
    qs.execution_count, qs.total_logical_reads / qs.execution_count AS avg_reads,
    n.op.value('@PhysicalOp', 'nvarchar(60)')                           AS operator,
    n.op.value('(.//Object/@Table)[1]', 'sysname')                      AS table_name,
    n.op.value('(.//Object/@Index)[1]', 'sysname')                      AS index_name,
    n.op.value('@EstimatedRowsRead', 'float')                           AS est_rows_read,
    n.op.value('@EstimateRows', 'float')                                AS est_rows_out,
    n.op.exist('.//Predicate')                                          AS has_residual_predicate,
    t.text
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
CROSS APPLY qp.query_plan.nodes('//RelOp[@PhysicalOp="Table Scan" or @PhysicalOp="Clustered Index Scan" or @PhysicalOp="Index Scan"]') AS n(op)
WHERE qs.total_logical_reads / qs.execution_count > 10000
ORDER BY qs.total_logical_reads DESC;


/*=============================================================================
  24.5 FOREIGN KEYS WITHOUT A SUPPORTING INDEX - CURRENT DB    [BOX][MI][SQLDB]
  Causes scans on child table for parent DELETE/UPDATE + join slowness + blocking.
=============================================================================*/
WITH fk_cols AS (
    SELECT fk.object_id AS fk_id, fk.name AS fk_name, fk.parent_object_id,
           cols = STUFF((SELECT N',' + QUOTENAME(c.name)
                         FROM sys.foreign_key_columns AS fkc
                         JOIN sys.columns AS c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
                         WHERE fkc.constraint_object_id = fk.object_id
                         ORDER BY fkc.constraint_column_id
                         FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 1, N'')
    FROM sys.foreign_keys AS fk
), idx_cols AS (
    SELECT i.object_id, i.index_id,
           cols = STUFF((SELECT N',' + QUOTENAME(c.name)
                         FROM sys.index_columns AS ic
                         JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                         WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
                         ORDER BY ic.key_ordinal
                         FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 1, N'')
    FROM sys.indexes AS i
    WHERE i.index_id > 0 AND i.is_disabled = 0
)
SELECT OBJECT_SCHEMA_NAME(f.parent_object_id) + N'.' + OBJECT_NAME(f.parent_object_id) AS child_table,
       f.fk_name, f.cols AS fk_columns,
       N'CREATE INDEX ' + QUOTENAME(N'IX_' + OBJECT_NAME(f.parent_object_id) + N'_' + REPLACE(REPLACE(REPLACE(f.cols, N'[', N''), N']', N''), N',', N'_'))
         + N' ON ' + QUOTENAME(OBJECT_SCHEMA_NAME(f.parent_object_id)) + N'.' + QUOTENAME(OBJECT_NAME(f.parent_object_id))
         + N' (' + f.cols + N');' AS suggested_index
FROM fk_cols AS f
WHERE NOT EXISTS (SELECT 1 FROM idx_cols AS ix
                  WHERE ix.object_id = f.parent_object_id
                    AND (ix.cols = f.cols OR ix.cols LIKE f.cols + N',%'))
ORDER BY child_table;


/*=============================================================================
  24.6 CLUSTERED INDEX KEY REVIEW - CURRENT DB                 [BOX][MI][SQLDB]
  Flags: wide keys (copied into every NC index), random GUIDs (page splits),
  non-unique (hidden uniquifier), nullable key columns.
=============================================================================*/
SELECT OBJECT_SCHEMA_NAME(i.object_id) + N'.' + OBJECT_NAME(i.object_id) AS table_name,
       i.name AS clustered_index, i.is_unique,
       COUNT(*)                         AS key_columns,
       SUM(c.max_length)                AS key_bytes,
       MAX(CASE WHEN TYPE_NAME(c.user_type_id) = N'uniqueidentifier' THEN 1 ELSE 0 END) AS has_guid_key,
       MAX(CAST(c.is_nullable AS int))  AS has_nullable_key,
       CASE WHEN SUM(c.max_length) > 16 THEN 'WIDE KEY; ' ELSE '' END
     + CASE WHEN MAX(CASE WHEN TYPE_NAME(c.user_type_id) = N'uniqueidentifier' THEN 1 ELSE 0 END) = 1 THEN 'GUID KEY (use NEWSEQUENTIALID or other key); ' ELSE '' END
     + CASE WHEN i.is_unique = 0 THEN 'NOT UNIQUE; ' ELSE '' END AS findings
FROM sys.indexes AS i
JOIN sys.index_columns AS ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.type = 1 AND OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1
GROUP BY i.object_id, i.name, i.is_unique
HAVING SUM(c.max_length) > 16 OR i.is_unique = 0
    OR MAX(CASE WHEN TYPE_NAME(c.user_type_id) = N'uniqueidentifier' THEN 1 ELSE 0 END) = 1
ORDER BY key_bytes DESC;


/*=============================================================================
  24.7 OVER-INDEXED & WIDE INDEXES - CURRENT DB                [BOX][MI][SQLDB]
=============================================================================*/
-- Tables with many nonclustered indexes vs their write volume
SELECT OBJECT_SCHEMA_NAME(i.object_id) + N'.' + OBJECT_NAME(i.object_id) AS table_name,
       COUNT(*) AS nc_index_count,
       SUM(ISNULL(us.user_updates, 0)) AS total_index_writes,
       SUM(ISNULL(us.user_seeks + us.user_scans + us.user_lookups, 0)) AS total_index_reads
FROM sys.indexes AS i
LEFT JOIN sys.dm_db_index_usage_stats AS us ON us.object_id = i.object_id AND us.index_id = i.index_id AND us.database_id = DB_ID()
WHERE i.type = 2 AND OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1
GROUP BY i.object_id
HAVING COUNT(*) >= 8
ORDER BY nc_index_count DESC;

-- Indexes with many key / included columns
SELECT OBJECT_SCHEMA_NAME(i.object_id) + N'.' + OBJECT_NAME(i.object_id) AS table_name, i.name AS index_name,
       SUM(CASE WHEN ic.is_included_column = 0 THEN 1 ELSE 0 END) AS key_cols,
       SUM(CASE WHEN ic.is_included_column = 1 THEN 1 ELSE 0 END) AS included_cols,
       SUM(CASE WHEN ic.is_included_column = 0 THEN c.max_length ELSE 0 END) AS key_bytes   -- -1 = MAX type
FROM sys.indexes AS i
JOIN sys.index_columns AS ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.type = 2 AND OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1
GROUP BY i.object_id, i.name
HAVING SUM(CASE WHEN ic.is_included_column = 0 THEN 1 ELSE 0 END) > 5
    OR SUM(CASE WHEN ic.is_included_column = 1 THEN 1 ELSE 0 END) > 10
ORDER BY key_cols + included_cols DESC;


/*=============================================================================
  24.8 PAGE SPLITS (instance counter + per-index "bad" splits)  [BOX][MI][SQLDB]
=============================================================================*/
SELECT RTRIM(counter_name) AS counter_name, cntr_value
FROM sys.dm_os_performance_counters
WHERE counter_name IN (N'Page Splits/sec', N'Batch Requests/sec');   -- cumulative; sample twice

SELECT TOP (25)
    OBJECT_SCHEMA_NAME(os.object_id) + N'.' + OBJECT_NAME(os.object_id) AS table_name,
    i.name AS index_name, i.fill_factor,
    os.leaf_allocation_count AS leaf_page_allocations,      -- includes splits
    os.nonleaf_allocation_count,
    os.leaf_insert_count,
    CAST(100.0 * os.leaf_allocation_count / NULLIF(os.leaf_insert_count, 0) AS decimal(10,2)) AS alloc_per_100_inserts
FROM sys.dm_db_index_operational_stats(DB_ID(), NULL, NULL, NULL) AS os
JOIN sys.indexes AS i ON i.object_id = os.object_id AND i.index_id = os.index_id
WHERE OBJECTPROPERTY(os.object_id, 'IsUserTable') = 1 AND os.leaf_allocation_count > 0
ORDER BY os.leaf_allocation_count DESC;


/*=============================================================================
  24.9 NON-DEFAULT FILL FACTORS - CURRENT DB                   [BOX][MI][SQLDB]
  Low fill factor on ever-increasing keys only wastes space & memory.
=============================================================================*/
SELECT OBJECT_SCHEMA_NAME(object_id) + N'.' + OBJECT_NAME(object_id) AS table_name,
       name AS index_name, type_desc, fill_factor, is_padded
FROM sys.indexes
WHERE fill_factor NOT IN (0, 100) AND OBJECTPROPERTY(object_id, 'IsUserTable') = 1
ORDER BY fill_factor;


/*=============================================================================
  24.10 COMPRESSION CANDIDATES - LARGE UNCOMPRESSED INDEXES    [BOX][MI][SQLDB]
=============================================================================*/
SELECT TOP (25)
    OBJECT_SCHEMA_NAME(p.object_id) + N'.' + OBJECT_NAME(p.object_id) AS table_name,
    i.name AS index_name, i.index_id, p.data_compression_desc,
    SUM(p.rows) AS rows,
    CAST(SUM(ps.used_page_count) * 8 / 1024.0 AS decimal(18,2)) AS used_mb,
    N'EXEC sys.sp_estimate_data_compression_savings @schema_name = N''' + OBJECT_SCHEMA_NAME(p.object_id)
      + N''', @object_name = N''' + OBJECT_NAME(p.object_id) + N''', @index_id = '
      + CAST(i.index_id AS nvarchar(10)) + N', @partition_number = NULL, @data_compression = N''PAGE'';' AS estimate_cmd
FROM sys.partitions AS p
JOIN sys.indexes AS i ON i.object_id = p.object_id AND i.index_id = p.index_id
JOIN sys.dm_db_partition_stats AS ps ON ps.partition_id = p.partition_id
WHERE p.data_compression = 0 AND OBJECTPROPERTY(p.object_id, 'IsUserTable') = 1
GROUP BY p.object_id, i.name, i.index_id, p.data_compression_desc
ORDER BY used_mb DESC;
-- ALTER INDEX [IX] ON dbo.T REBUILD WITH (DATA_COMPRESSION = PAGE, ONLINE = ON);


/*=============================================================================
  24.11 PARTITIONED TABLES - BOUNDARIES & ROWS PER PARTITION   [BOX][MI][SQLDB]
=============================================================================*/
SELECT OBJECT_SCHEMA_NAME(p.object_id) + N'.' + OBJECT_NAME(p.object_id) AS table_name,
       i.name AS index_name, ps.name AS partition_scheme, pf.name AS partition_function,
       p.partition_number, prv.value AS boundary_value, pf.boundary_value_on_right,
       fg.name AS filegroup, p.rows, p.data_compression_desc
FROM sys.partitions AS p
JOIN sys.indexes AS i ON i.object_id = p.object_id AND i.index_id = p.index_id
JOIN sys.partition_schemes AS ps ON ps.data_space_id = i.data_space_id
JOIN sys.partition_functions AS pf ON pf.function_id = ps.function_id
LEFT JOIN sys.partition_range_values AS prv ON prv.function_id = pf.function_id
      AND prv.boundary_id = p.partition_number - CASE WHEN pf.boundary_value_on_right = 1 THEN 1 ELSE 0 END
JOIN sys.destination_data_spaces AS dds ON dds.partition_scheme_id = ps.data_space_id AND dds.destination_id = p.partition_number
JOIN sys.filegroups AS fg ON fg.data_space_id = dds.data_space_id
WHERE i.index_id IN (0, 1)
ORDER BY table_name, p.partition_number;


/*=============================================================================
  24.12 DISABLED & HYPOTHETICAL (leftover DTA) INDEXES         [BOX][MI][SQLDB]
=============================================================================*/
SELECT OBJECT_SCHEMA_NAME(object_id) + N'.' + OBJECT_NAME(object_id) AS table_name, name AS index_name,
       is_disabled, is_hypothetical,
       CASE WHEN is_hypothetical = 1 THEN N'DROP INDEX ' + QUOTENAME(name) + N' ON '
              + QUOTENAME(OBJECT_SCHEMA_NAME(object_id)) + N'.' + QUOTENAME(OBJECT_NAME(object_id)) + N';'
            ELSE N'ALTER INDEX ' + QUOTENAME(name) + N' ON '
              + QUOTENAME(OBJECT_SCHEMA_NAME(object_id)) + N'.' + QUOTENAME(OBJECT_NAME(object_id)) + N' REBUILD;  -- or DROP' END AS action
FROM sys.indexes
WHERE (is_disabled = 1 OR is_hypothetical = 1) AND OBJECTPROPERTY(object_id, 'IsMSShipped') = 0;


/*=============================================================================
  24.13 FILTERED INDEX / NULL-HEAVY COLUMN CANDIDATES (needs a table)
                                                               [BOX][MI][SQLDB]
  Columns that are mostly NULL or a single status value are good filtered
  index candidates (WHERE col IS NOT NULL / WHERE Status = 'Open').
=============================================================================*/
/*
SELECT COUNT(*) AS total_rows,
       SUM(CASE WHEN ShippedDate IS NULL THEN 1 ELSE 0 END) AS null_rows,
       COUNT(DISTINCT Status) AS distinct_status
FROM dbo.Orders;
CREATE INDEX IX_Orders_Open ON dbo.Orders (CustomerID) INCLUDE (OrderDate) WHERE Status = 'Open';
*/


/*=============================================================================
  24.14 BEFORE / AFTER TEST FOR A NEW INDEX (template)         [BOX][MI][SQLDB]
=============================================================================*/
/*
SET STATISTICS IO, TIME ON;
-- run the query, note logical reads + CPU
CREATE INDEX IX_Test ON dbo.T (...) INCLUDE (...) WITH (ONLINE = ON);
-- re-run, compare; check the actual plan uses IX_Test
-- After deploy: watch the query in Query Store (04 4.5 per-plan stats) and
-- the index in 05 5.2 for real seeks vs writes after a full business cycle.
SET STATISTICS IO, TIME OFF;
*/
