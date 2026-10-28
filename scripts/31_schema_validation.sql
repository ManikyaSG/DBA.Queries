/*******************************************************************************
 File    : 31_schema_validation.sql
 Purpose : Validate & compare schemas: object fingerprints for env-to-env
           comparison, two-database diff on the same instance, broken
           references, untrusted/disabled constraints, collation and data-type
           inconsistencies, identity exhaustion, row-count comparison.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] Managed Instance   [SQLDB] Azure SQL DB
 Use for : post-deployment checks, DEV/UAT/PROD drift, post-migration or
           post-refresh verification.
*******************************************************************************/

/*=============================================================================
  31.1 SCHEMA FINGERPRINT - CURRENT DB (run on both envs, compare)
                                                               [BOX][MI][SQLDB]
  Save output from each environment (copy to Excel / table) and join on
  object_name: different hash = different object; missing row = missing object.
=============================================================================*/
WITH cols AS (
    SELECT c.object_id,
           sig = (SELECT c2.name, TYPE_NAME(c2.user_type_id) AS t, c2.max_length AS l, c2.precision AS p, c2.scale AS s,
                         c2.is_nullable AS n, c2.is_identity AS i, c2.collation_name AS co,
                         OBJECT_DEFINITION(c2.default_object_id) AS d
                  FROM sys.columns AS c2 WHERE c2.object_id = c.object_id ORDER BY c2.name FOR XML RAW, TYPE)
    FROM sys.columns AS c GROUP BY c.object_id
)
SELECT SCHEMA_NAME(o.schema_id) + N'.' + o.name AS object_name, o.type_desc,
       CONVERT(varchar(66), HASHBYTES('SHA2_256',
            CASE WHEN m.object_id IS NOT NULL
                 THEN REPLACE(REPLACE(REPLACE(m.definition, NCHAR(13), N''), NCHAR(10), N''), N' ', N'')  -- ignore whitespace
                 ELSE CAST(cols.sig AS nvarchar(max)) END), 1) AS object_hash
FROM sys.objects AS o
LEFT JOIN sys.sql_modules AS m ON m.object_id = o.object_id
LEFT JOIN cols ON cols.object_id = o.object_id
WHERE o.is_ms_shipped = 0
  AND o.type IN ('U', 'V', 'P', 'FN', 'IF', 'TF', 'TR', 'SN', 'SO')
ORDER BY o.type_desc, object_name;

-- Index fingerprint (separate, so table vs index differences are easy to read)
SELECT OBJECT_SCHEMA_NAME(i.object_id) + N'.' + OBJECT_NAME(i.object_id) + N'.' + ISNULL(i.name, N'HEAP') AS index_name,
       i.type_desc,
       CONVERT(varchar(66), HASHBYTES('SHA2_256', CAST((
            SELECT i.is_unique AS u, i.is_primary_key AS pk, i.filter_definition AS f, i.fill_factor AS ff,
                   (SELECT c.name, ic.key_ordinal AS k, ic.is_descending_key AS d, ic.is_included_column AS inc
                    FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                    WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id
                    ORDER BY ic.is_included_column, ic.key_ordinal, c.name FOR XML RAW, TYPE)
            FOR XML RAW, TYPE) AS nvarchar(max))), 1) AS index_hash
FROM sys.indexes AS i
WHERE OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1
ORDER BY index_name;


/*=============================================================================
  31.2 COMPARE TWO DATABASES ON THE SAME INSTANCE - OBJECTS     [BOX][MI]
  (For different servers: restore a copy, use a linked server, or use
   SSDT Schema Compare / sqlpackage DeployReport - see 28.7.)
=============================================================================*/
DECLARE @src sysname = N'App_PROD_Copy', @tgt sysname = N'App_UAT';   -- <== change
DECLARE @sql nvarchar(max) = N'
SELECT COALESCE(s.obj, t.obj) AS object_name, COALESCE(s.type_desc, t.type_desc) AS type_desc,
       CASE WHEN t.obj IS NULL THEN ''ONLY IN SOURCE''
            WHEN s.obj IS NULL THEN ''ONLY IN TARGET''
            ELSE ''DEFINITION DIFFERS'' END AS difference
FROM (SELECT sc.name + N''.'' + o.name AS obj, o.type_desc, HASHBYTES(''SHA2_256'', m.definition) AS h
      FROM ' + QUOTENAME(@src) + N'.sys.objects o
      JOIN ' + QUOTENAME(@src) + N'.sys.schemas sc ON sc.schema_id = o.schema_id
      LEFT JOIN ' + QUOTENAME(@src) + N'.sys.sql_modules m ON m.object_id = o.object_id
      WHERE o.is_ms_shipped = 0 AND o.type IN (''U'',''V'',''P'',''FN'',''IF'',''TF'',''TR'',''SN'')) AS s
FULL JOIN
     (SELECT sc.name + N''.'' + o.name AS obj, o.type_desc, HASHBYTES(''SHA2_256'', m.definition) AS h
      FROM ' + QUOTENAME(@tgt) + N'.sys.objects o
      JOIN ' + QUOTENAME(@tgt) + N'.sys.schemas sc ON sc.schema_id = o.schema_id
      LEFT JOIN ' + QUOTENAME(@tgt) + N'.sys.sql_modules m ON m.object_id = o.object_id
      WHERE o.is_ms_shipped = 0 AND o.type IN (''U'',''V'',''P'',''FN'',''IF'',''TF'',''TR'',''SN'')) AS t
  ON t.obj = s.obj AND t.type_desc = s.type_desc
WHERE s.obj IS NULL OR t.obj IS NULL OR ISNULL(s.h, 0x0) <> ISNULL(t.h, 0x0)
ORDER BY difference, object_name;';
EXEC sys.sp_executesql @sql;
-- Tables compare by name here; column-level differences are in 31.3.


/*=============================================================================
  31.3 COMPARE TWO DATABASES - COLUMNS                           [BOX][MI]
=============================================================================*/
SET @sql = N'
WITH s AS (SELECT sc.name + N''.'' + t.name AS tbl, c.name AS col, ty.name AS data_type, c.max_length, c.precision, c.scale, c.is_nullable, c.collation_name
           FROM ' + QUOTENAME(@src) + N'.sys.columns c JOIN ' + QUOTENAME(@src) + N'.sys.tables t ON t.object_id = c.object_id
           JOIN ' + QUOTENAME(@src) + N'.sys.schemas sc ON sc.schema_id = t.schema_id
           JOIN ' + QUOTENAME(@src) + N'.sys.types ty ON ty.user_type_id = c.user_type_id WHERE t.is_ms_shipped = 0),
     t AS (SELECT sc.name + N''.'' + t.name AS tbl, c.name AS col, ty.name AS data_type, c.max_length, c.precision, c.scale, c.is_nullable, c.collation_name
           FROM ' + QUOTENAME(@tgt) + N'.sys.columns c JOIN ' + QUOTENAME(@tgt) + N'.sys.tables t ON t.object_id = c.object_id
           JOIN ' + QUOTENAME(@tgt) + N'.sys.schemas sc ON sc.schema_id = t.schema_id
           JOIN ' + QUOTENAME(@tgt) + N'.sys.types ty ON ty.user_type_id = c.user_type_id WHERE t.is_ms_shipped = 0)
SELECT COALESCE(s.tbl, t.tbl) AS table_name, COALESCE(s.col, t.col) AS column_name,
       s.data_type + ''('' + CAST(s.max_length AS varchar(10)) + '')'' + CASE s.is_nullable WHEN 1 THEN '' NULL'' ELSE '' NOT NULL'' END AS source_def,
       t.data_type + ''('' + CAST(t.max_length AS varchar(10)) + '')'' + CASE t.is_nullable WHEN 1 THEN '' NULL'' ELSE '' NOT NULL'' END AS target_def,
       CASE WHEN t.col IS NULL THEN ''ONLY IN SOURCE'' WHEN s.col IS NULL THEN ''ONLY IN TARGET'' ELSE ''DIFFERS'' END AS difference
FROM s FULL JOIN t ON t.tbl = s.tbl AND t.col = s.col
WHERE s.col IS NULL OR t.col IS NULL
   OR s.data_type <> t.data_type OR s.max_length <> t.max_length OR s.precision <> t.precision
   OR s.scale <> t.scale OR s.is_nullable <> t.is_nullable OR ISNULL(s.collation_name, '''') <> ISNULL(t.collation_name, '''')
ORDER BY table_name, column_name;';
EXEC sys.sp_executesql @sql;


/*=============================================================================
  31.4 BROKEN OBJECTS - CURRENT DB                             [BOX][MI][SQLDB]
=============================================================================*/
-- a) References to objects that don't exist (deferred name resolution hides these)
SELECT OBJECT_SCHEMA_NAME(d.referencing_id) + N'.' + OBJECT_NAME(d.referencing_id) AS referencing_object,
       ISNULL(d.referenced_schema_name + N'.', N'') + d.referenced_entity_name AS missing_reference
FROM sys.sql_expression_dependencies AS d
WHERE d.referenced_id IS NULL
  AND d.is_ambiguous = 0
  AND d.referenced_database_name IS NULL AND d.referenced_server_name IS NULL
  AND OBJECT_ID(ISNULL(d.referenced_schema_name + N'.', N'dbo.') + d.referenced_entity_name) IS NULL
  AND NOT EXISTS (SELECT 1 FROM sys.types t WHERE t.name = d.referenced_entity_name)
ORDER BY referencing_object;

-- b) Refresh every non-schema-bound module; anything that errors is broken
IF OBJECT_ID('tempdb..#broken') IS NOT NULL DROP TABLE #broken;
CREATE TABLE #broken (object_name nvarchar(300), error_message nvarchar(4000));
DECLARE @obj nvarchar(300);
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT QUOTENAME(OBJECT_SCHEMA_NAME(m.object_id)) + N'.' + QUOTENAME(OBJECT_NAME(m.object_id))
    FROM sys.sql_modules AS m JOIN sys.objects AS o ON o.object_id = m.object_id
    WHERE m.is_schema_bound = 0 AND o.is_ms_shipped = 0 AND o.type IN ('P', 'V', 'FN', 'IF', 'TF');
OPEN cur; FETCH NEXT FROM cur INTO @obj;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        BEGIN TRAN;                                   -- rolled back: we only test, don't change metadata
        EXEC sys.sp_refreshsqlmodule @name = @obj;
        ROLLBACK;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        INSERT #broken VALUES (@obj, ERROR_MESSAGE());
    END CATCH;
    FETCH NEXT FROM cur INTO @obj;
END
CLOSE cur; DEALLOCATE cur;
SELECT * FROM #broken ORDER BY object_name;


/*=============================================================================
  31.5 CONSTRAINT & TRIGGER INTEGRITY - CURRENT DB             [BOX][MI][SQLDB]
  Untrusted FKs/CHECKs (after NOCHECK / bulk loads) are ignored by the
  optimizer and may hide bad data.
=============================================================================*/
SELECT 'FOREIGN KEY' AS constraint_type, OBJECT_SCHEMA_NAME(parent_object_id) + N'.' + OBJECT_NAME(parent_object_id) AS table_name,
       name, is_disabled, is_not_trusted,
       N'ALTER TABLE ' + QUOTENAME(OBJECT_SCHEMA_NAME(parent_object_id)) + N'.' + QUOTENAME(OBJECT_NAME(parent_object_id))
         + N' WITH CHECK CHECK CONSTRAINT ' + QUOTENAME(name) + N';' AS fix_cmd
FROM sys.foreign_keys WHERE is_not_trusted = 1 OR is_disabled = 1
UNION ALL
SELECT 'CHECK', OBJECT_SCHEMA_NAME(parent_object_id) + N'.' + OBJECT_NAME(parent_object_id), name, is_disabled, is_not_trusted,
       N'ALTER TABLE ' + QUOTENAME(OBJECT_SCHEMA_NAME(parent_object_id)) + N'.' + QUOTENAME(OBJECT_NAME(parent_object_id))
         + N' WITH CHECK CHECK CONSTRAINT ' + QUOTENAME(name) + N';'
FROM sys.check_constraints WHERE is_not_trusted = 1 OR is_disabled = 1
ORDER BY table_name;

SELECT OBJECT_SCHEMA_NAME(parent_id) + N'.' + OBJECT_NAME(parent_id) AS table_name, name AS trigger_name, is_disabled
FROM sys.triggers WHERE parent_class = 1 AND is_disabled = 1;

-- Validate data against constraints (finds the actual violating rows):
-- DBCC CHECKCONSTRAINTS WITH ALL_CONSTRAINTS;


/*=============================================================================
  31.6 ROW COUNTS - CURRENT DB (run on source & target, compare)
                                                               [BOX][MI][SQLDB]
=============================================================================*/
SELECT OBJECT_SCHEMA_NAME(object_id) + N'.' + OBJECT_NAME(object_id) AS table_name,
       SUM(row_count) AS row_count
FROM sys.dm_db_partition_stats
WHERE index_id IN (0, 1) AND OBJECTPROPERTY(object_id, 'IsUserTable') = 1
GROUP BY object_id
ORDER BY table_name;

-- Same instance: side-by-side row count diff between @src and @tgt
SET @sql = N'
SELECT COALESCE(s.tbl, t.tbl) AS table_name, s.rows AS source_rows, t.rows AS target_rows, ISNULL(s.rows,0) - ISNULL(t.rows,0) AS diff
FROM (SELECT sc.name + N''.'' + tb.name AS tbl, SUM(p.rows) AS rows FROM ' + QUOTENAME(@src) + N'.sys.partitions p
      JOIN ' + QUOTENAME(@src) + N'.sys.tables tb ON tb.object_id = p.object_id JOIN ' + QUOTENAME(@src) + N'.sys.schemas sc ON sc.schema_id = tb.schema_id
      WHERE p.index_id IN (0,1) GROUP BY sc.name, tb.name) s
FULL JOIN
     (SELECT sc.name + N''.'' + tb.name AS tbl, SUM(p.rows) AS rows FROM ' + QUOTENAME(@tgt) + N'.sys.partitions p
      JOIN ' + QUOTENAME(@tgt) + N'.sys.tables tb ON tb.object_id = p.object_id JOIN ' + QUOTENAME(@tgt) + N'.sys.schemas sc ON sc.schema_id = tb.schema_id
      WHERE p.index_id IN (0,1) GROUP BY sc.name, tb.name) t ON t.tbl = s.tbl
WHERE ISNULL(s.rows, -1) <> ISNULL(t.rows, -1)
ORDER BY ABS(ISNULL(s.rows,0) - ISNULL(t.rows,0)) DESC;';
EXEC sys.sp_executesql @sql;
-- NOTE: both DBs must be on the same instance (BOX/MI). sys.partitions.rows is metadata (fast, near-exact).
-- For exact data comparison of a table: compare CHECKSUM_AGG(BINARY_CHECKSUM(*)) on both sides, or use tablediff.exe.


/*=============================================================================
  31.7 COLLATION MISMATCHES (column vs database) - CURRENT DB   [BOX][MI][SQLDB]
  Mismatches cause "Cannot resolve the collation conflict" + index scans.
=============================================================================*/
SELECT OBJECT_SCHEMA_NAME(c.object_id) + N'.' + OBJECT_NAME(c.object_id) AS table_name,
       c.name AS column_name, c.collation_name,
       CAST(DATABASEPROPERTYEX(DB_NAME(), 'Collation') AS sysname) AS database_collation
FROM sys.columns AS c
JOIN sys.tables AS t ON t.object_id = c.object_id AND t.is_ms_shipped = 0
WHERE c.collation_name IS NOT NULL
  AND c.collation_name <> CAST(DATABASEPROPERTYEX(DB_NAME(), 'Collation') AS sysname)
ORDER BY table_name, column_name;


/*=============================================================================
  31.8 SAME COLUMN NAME, DIFFERENT DATA TYPES - CURRENT DB      [BOX][MI][SQLDB]
  e.g. CustomerID int in one table, varchar in another -> implicit conversions.
=============================================================================*/
WITH c AS (
    SELECT c.name AS column_name, TYPE_NAME(c.user_type_id) + '(' + CAST(c.max_length AS varchar(10)) + ')' AS type_def,
           OBJECT_SCHEMA_NAME(c.object_id) + N'.' + OBJECT_NAME(c.object_id) AS table_name
    FROM sys.columns AS c JOIN sys.tables AS t ON t.object_id = c.object_id AND t.is_ms_shipped = 0
)
SELECT column_name, type_def, COUNT(*) AS tables_using, MIN(table_name) AS example_table
FROM c
WHERE column_name IN (SELECT column_name FROM c GROUP BY column_name HAVING COUNT(DISTINCT type_def) > 1)
GROUP BY column_name, type_def
ORDER BY column_name, tables_using DESC;


/*=============================================================================
  31.9 IDENTITY COLUMNS CLOSE TO THEIR MAXIMUM - CURRENT DB     [BOX][MI][SQLDB]
=============================================================================*/
SELECT OBJECT_SCHEMA_NAME(ic.object_id) + N'.' + OBJECT_NAME(ic.object_id) AS table_name,
       ic.name AS column_name, TYPE_NAME(ic.user_type_id) AS data_type,
       CAST(ic.last_value AS bigint) AS last_value,
       CASE TYPE_NAME(ic.user_type_id) WHEN 'tinyint' THEN 255 WHEN 'smallint' THEN 32767
            WHEN 'int' THEN 2147483647 WHEN 'bigint' THEN 9223372036854775807 END AS max_value,
       CAST(100.0 * CAST(ic.last_value AS bigint) /
            CASE TYPE_NAME(ic.user_type_id) WHEN 'tinyint' THEN 255 WHEN 'smallint' THEN 32767
                 WHEN 'int' THEN 2147483647 WHEN 'bigint' THEN 9223372036854775807 END AS decimal(6,2)) AS pct_used
FROM sys.identity_columns AS ic
WHERE ic.last_value IS NOT NULL
  AND TYPE_NAME(ic.user_type_id) IN ('tinyint', 'smallint', 'int', 'bigint')
ORDER BY pct_used DESC;


/*=============================================================================
  31.10 OBJECT COUNTS BY TYPE (quick env-to-env sanity check)  [BOX][MI][SQLDB]
=============================================================================*/
SELECT type_desc, COUNT(*) AS object_count
FROM sys.objects WHERE is_ms_shipped = 0
GROUP BY type_desc
UNION ALL SELECT 'INDEX', COUNT(*) FROM sys.indexes i WHERE i.index_id > 0 AND OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1
UNION ALL SELECT 'STATISTICS (user)', COUNT(*) FROM sys.stats s WHERE s.user_created = 1
UNION ALL SELECT 'USER', COUNT(*) FROM sys.database_principals WHERE type IN ('S','U','G','E','X') AND principal_id > 4
UNION ALL SELECT 'ROLE (custom)', COUNT(*) FROM sys.database_principals WHERE type = 'R' AND is_fixed_role = 0 AND principal_id > 0 AND name <> N'public'
ORDER BY type_desc;
