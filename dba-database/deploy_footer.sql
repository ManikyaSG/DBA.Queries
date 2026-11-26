
/*============================================================================
  CATALOG: what is installed and how to call it
     EXEC dbo.HC_help N'block';                                  -- find by keyword
     SELECT * FROM dbo.HC_catalog;                               -- everything
============================================================================*/
IF OBJECT_ID(N'dbo.HC_catalog', N'V') IS NULL
    EXEC (N'CREATE VIEW dbo.HC_catalog AS SELECT 1 AS placeholder;');
GO

ALTER VIEW dbo.HC_catalog
AS
SELECT
    r.name,
    r.section                     AS toolkit_section,
    r.title,
    CASE o.type WHEN 'V'  THEN 'view'
                WHEN 'IF' THEN 'function'
                WHEN 'P'  THEN 'procedure'
                ELSE 'not installed' END AS object_type,
    CASE WHEN o.type = 'P' AND r.usage LIKE N'SELECT%'      -- view/function that had to become a procedure
         THEN N'EXEC dbo.' + r.name + N';'
         ELSE r.usage END         AS how_to_run,
    r.sort_hint                   AS suggested_order_by,
    CASE WHEN r.usage LIKE N'%@database_name%' THEN 'yes' ELSE 'no' END AS all_databases_mode,
    CASE WHEN r.capture_sql IS NOT NULL THEN 'yes' ELSE 'no' END AS can_snapshot,
    r.tags                        AS runs_on,
    r.status,
    r.message,
    r.source_file,
    r.deployed_at
FROM dbo.HC_objects AS r
LEFT JOIN sys.objects AS o ON o.object_id = OBJECT_ID(N'dbo.' + QUOTENAME(r.name));
GO

/*============================================================================
  HELP
     EXEC dbo.HC_help;                       -- the main commands + checks per script
     EXEC dbo.HC_help N'block';              -- checks whose name/title matches (words in order)
     EXEC dbo.HC_help N'5.3';                -- by toolkit section
============================================================================*/
IF OBJECT_ID(N'dbo.HC_help', N'P') IS NULL
    EXEC (N'CREATE PROCEDURE dbo.HC_help AS RETURN;');
GO
ALTER PROCEDURE dbo.HC_help
    @search nvarchar(200) = NULL
AS
SET NOCOUNT ON;
IF @search IS NULL OR LTRIM(RTRIM(@search)) = N''
BEGIN
    SELECT command, what_it_does
    FROM (VALUES
        (1, N'EXEC dbo.HC_help N''keyword'';',                              N'Find checks by keyword or section number'),
        (2, N'SELECT * FROM dbo.HC_catalog;',                               N'Every check installed here and how to run it'),
        (3, N'EXEC dbo.HC_<check> @database_name = N''*'';',                N'Per-database checks: run in every online database'),
        (4, N'EXEC dbo.HC_snapshot N''change'', @label = N''pre-patch'';',  N'Save config/state checks for a before/after compare'),
        (5, N'EXEC dbo.HC_snapshot_diff @before_label = N''pre-patch'', @after_label = N''post-patch'';', N'What changed between two snapshots'),
        (6, N'SELECT * FROM dbo.HC_snapshot_list;',                         N'Saved snapshots'),
        (7, N'EXEC dbo.HC_snapshot_show @snapshot_id = 1;',                 N'One saved snapshot as a table'),
        (8, N'EXEC dbo.HC_selftest;',                                       N'Run every check once and log pass/fail (Results: discard)'),
        (9, N'SELECT * FROM dbo.HC_version;',                               N'Which build is installed here, and its health')
    ) AS v (n, command, what_it_does)
    ORDER BY n;

    SELECT source_file AS script, COUNT(*) AS checks_installed
    FROM dbo.HC_catalog
    WHERE object_type <> 'not installed'
    GROUP BY source_file
    ORDER BY source_file;
    RETURN;
END;

DECLARE @p nvarchar(450) = N'%' + REPLACE(REPLACE(LTRIM(RTRIM(@search)), N'_', N'[_]'), N' ', N'%') + N'%';
SELECT name, toolkit_section, title, object_type, how_to_run, runs_on, status
FROM
(
    SELECT name, toolkit_section, title, object_type, how_to_run, runs_on, status
    FROM dbo.HC_catalog
    WHERE title LIKE @p OR name LIKE @p OR toolkit_section = @search OR source_file LIKE @p
    UNION ALL
    SELECT NULL, section, title, 'run by hand',
           N'Open ' + source_file + N', section ' + section + N' (' + reason + N')', NULL, 'not installed'
    FROM dbo.HC_manual_sections
    WHERE title LIKE @p OR section = @search OR source_file LIKE @p
) AS x
ORDER BY TRY_CAST(PARSENAME(toolkit_section, 2) AS int), TRY_CAST(PARSENAME(toolkit_section, 1) AS int);
GO

/*============================================================================
  SELF-TEST: runs every installed check once and logs PASS / FAIL / SKIPPED
     EXEC dbo.HC_selftest;                                    -- per-database checks run in DBAdmin
     EXEC dbo.HC_selftest @test_database = N'Sales', @include_heavy = 1;
     SELECT * FROM dbo.HC_selftest_last WHERE result = 'FAIL';
  The checks return their normal result sets. In SSMS tick
  Query > Query Options > Results > Grid > "Discard results after execution"
  first; progress and failures still show on the Messages tab.
============================================================================*/
IF OBJECT_ID(N'dbo.HC_selftest_results', N'U') IS NULL
    CREATE TABLE dbo.HC_selftest_results
    (
        run_at       datetime2(3)   NOT NULL,
        name         sysname        NOT NULL,
        section      varchar(10)    NULL,
        result       varchar(10)    NOT NULL,     -- PASS | FAIL | SKIPPED
        duration_ms  int            NULL,
        message      nvarchar(4000) NULL,
        CONSTRAINT PK_HC_selftest_results PRIMARY KEY (run_at, name)
    );
GO
IF OBJECT_ID(N'dbo.HC_selftest', N'P') IS NULL
    EXEC (N'CREATE PROCEDURE dbo.HC_selftest AS RETURN;');
GO
ALTER PROCEDURE dbo.HC_selftest
    @test_database sysname       = NULL,   -- where per-database checks run (default: this database)
    @include_heavy bit           = 0,      -- 1 = also run checks that read index pages
    @name_like     nvarchar(200) = N'%',   -- e.g. N'HC_ag%'
    @keep_runs     int           = 10
AS
SET NOCOUNT ON;
SET LOCK_TIMEOUT 5000;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET DEADLOCK_PRIORITY LOW;
IF @test_database IS NULL SET @test_database = DB_NAME();
IF DB_ID(@test_database) IS NULL
BEGIN RAISERROR(N'Database %s not found.', 16, 1, @test_database); RETURN; END;

DECLARE @run_at datetime2(3) = SYSDATETIME(), @name sysname, @section varchar(10), @call nvarchar(2000),
        @mode varchar(100), @type char(2), @t0 datetime2(3), @err nvarchar(4000), @i int = 0, @total int,
        @cdc bit = (SELECT is_cdc_enabled FROM sys.databases WHERE name = @test_database);

DECLARE @todo TABLE (n int IDENTITY(1,1), name sysname, section varchar(10), call nvarchar(2000), mode varchar(100), type char(2));
INSERT @todo (name, section, call, mode, type)
SELECT r.name, r.section, r.test_call, r.test_mode, o.type
FROM dbo.HC_objects AS r
JOIN sys.objects AS o ON o.object_id = OBJECT_ID(N'dbo.' + QUOTENAME(r.name))
WHERE r.status LIKE 'OK%' AND r.name LIKE @name_like
ORDER BY TRY_CAST(PARSENAME(r.section, 2) AS int), TRY_CAST(PARSENAME(r.section, 1) AS int);
SET @total = @@ROWCOUNT;

WHILE @i < @total
BEGIN
    SET @i += 1;
    SELECT @name = name, @section = section, @call = call, @mode = ISNULL(mode, 'run'), @type = type
    FROM @todo WHERE n = @i;
    IF RTRIM(@type) = 'P' AND @call LIKE N'SELECT%'          -- a view/function that was installed as a procedure
        SET @call = N'EXEC dbo.' + QUOTENAME(@name) + N';';

    IF @call IS NULL OR @mode LIKE 'skip%'
       OR (@mode LIKE 'heavy%' AND @include_heavy = 0)
       OR (@mode = 'needs_cdc' AND ISNULL(@cdc, 0) = 0)
    BEGIN
        INSERT dbo.HC_selftest_results (run_at, name, section, result, message)
        VALUES (@run_at, @name, @section, 'SKIPPED',
                CASE WHEN @call IS NULL THEN N'no test call'
                     WHEN @mode = 'needs_cdc' THEN N'needs CDC enabled in ' + @test_database
                     WHEN @mode LIKE 'heavy%' THEN @mode + N' (use @include_heavy = 1)'
                     ELSE SUBSTRING(@mode, 7, 100) END);
        CONTINUE;
    END;

    RAISERROR(N'[%d/%d] %s', 0, 1, @i, @total, @name) WITH NOWAIT;
    SET @t0 = SYSDATETIME();
    BEGIN TRY
        EXEC sys.sp_executesql @call, N'@db sysname', @db = @test_database;
        INSERT dbo.HC_selftest_results (run_at, name, section, result, duration_ms)
        VALUES (@run_at, @name, @section, 'PASS', DATEDIFF(millisecond, @t0, SYSDATETIME()));
    END TRY
    BEGIN CATCH
        SET @err = ERROR_MESSAGE();
        IF @@TRANCOUNT > 0 ROLLBACK;
        INSERT dbo.HC_selftest_results (run_at, name, section, result, duration_ms, message)
        VALUES (@run_at, @name, @section, 'FAIL', DATEDIFF(millisecond, @t0, SYSDATETIME()), @err);
        RAISERROR(N'    FAIL %s: %s', 10, 1, @name, @err) WITH NOWAIT;
    END CATCH;
END;

DELETE dbo.HC_selftest_results
WHERE run_at NOT IN (SELECT DISTINCT TOP (@keep_runs) run_at FROM dbo.HC_selftest_results ORDER BY run_at DESC);

DECLARE @pass int, @fail int, @skip int;
SELECT @pass = SUM(CASE WHEN result = 'PASS' THEN 1 ELSE 0 END),
       @fail = SUM(CASE WHEN result = 'FAIL' THEN 1 ELSE 0 END),
       @skip = SUM(CASE WHEN result = 'SKIPPED' THEN 1 ELSE 0 END)
FROM dbo.HC_selftest_results WHERE run_at = @run_at;
RAISERROR(N'Self-test finished: %d passed, %d failed, %d skipped. Details: SELECT * FROM dbo.HC_selftest_last;', 10, 1,
          @pass, @fail, @skip) WITH NOWAIT;

SELECT result, COUNT(*) AS checks FROM dbo.HC_selftest_results WHERE run_at = @run_at GROUP BY result ORDER BY result;
SELECT name, section, result, duration_ms, message
FROM dbo.HC_selftest_results WHERE run_at = @run_at AND result <> 'PASS'
ORDER BY result, TRY_CAST(PARSENAME(section, 2) AS int), TRY_CAST(PARSENAME(section, 1) AS int);
GO
IF OBJECT_ID(N'dbo.HC_selftest_last', N'V') IS NULL
    EXEC (N'CREATE VIEW dbo.HC_selftest_last AS SELECT 1 AS placeholder;');
GO
ALTER VIEW dbo.HC_selftest_last
AS
SELECT run_at, name, section, result, duration_ms, message
FROM dbo.HC_selftest_results
WHERE run_at = (SELECT MAX(run_at) FROM dbo.HC_selftest_results);
GO

/*============================================================================
  SNAPSHOTS: save a check's output now, compare it later
     EXEC dbo.HC_snapshot N'change', @label = N'pre-patch';         -- the 'change' set
     EXEC dbo.HC_snapshot N'HC_logins, HC_job_inventory';            -- any list of checks
     EXEC dbo.HC_snapshot N'HC_index_usage', @database_name = N'Sales';
     EXEC dbo.HC_snapshot_diff @before_label = N'pre-patch', @after_label = N'post-patch';
     SELECT * FROM dbo.HC_snapshot_list;
     EXEC dbo.HC_snapshot_show @snapshot_id = 12;
  Checks made of plain queries can be saved (each result set separately); checks that
  use variables, temp tables or DBCC can't (HC_catalog.can_snapshot).
============================================================================*/
IF OBJECT_ID(N'dbo.HC_snapshots', N'U') IS NULL
    CREATE TABLE dbo.HC_snapshots
    (
        snapshot_id    int IDENTITY(1,1) NOT NULL CONSTRAINT PK_HC_snapshots PRIMARY KEY,
        captured_at    datetime2(0)  NOT NULL CONSTRAINT DF_HC_snapshots_at DEFAULT SYSDATETIME(),
        label          nvarchar(100) NOT NULL,
        object_name    sysname       NOT NULL,
        database_name  sysname       NULL,          -- NULL = server-level check
        result_set     int           NOT NULL CONSTRAINT DF_HC_snapshots_rs DEFAULT 1,
        row_count      int           NULL,
        captured_by    nvarchar(128) NOT NULL CONSTRAINT DF_HC_snapshots_by DEFAULT ORIGINAL_LOGIN(),
        data           nvarchar(max) NOT NULL       -- the rows, as a JSON array
    );
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.HC_snapshots') AND name = N'IX_HC_snapshots_label')
    CREATE INDEX IX_HC_snapshots_label ON dbo.HC_snapshots (label, object_name, database_name, result_set, snapshot_id);
GO

IF OBJECT_ID(N'dbo.HC_snapshot', N'P') IS NULL
    EXEC (N'CREATE PROCEDURE dbo.HC_snapshot AS RETURN;');
GO
ALTER PROCEDURE dbo.HC_snapshot
    @name          nvarchar(4000),          -- a set name (N'change'), one check, or a comma-separated list
    @label         nvarchar(100) = NULL,    -- default: the current date and time
    @database_name sysname       = N'*',    -- per-database checks: one database or N'*'
    @keep_days     int           = 90       -- older snapshots are removed
AS
SET NOCOUNT ON;
SET LOCK_TIMEOUT 5000;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET DEADLOCK_PRIORITY LOW;
IF @label IS NULL SET @label = CONVERT(nvarchar(19), SYSDATETIME(), 120);
IF CAST(SERVERPROPERTY('EngineEdition') AS int) = 5 AND @database_name = N'*' SET @database_name = DB_NAME();

DECLARE @list TABLE (n int IDENTITY(1,1), name sysname);
IF EXISTS (SELECT 1 FROM dbo.HC_snapshot_sets WHERE set_name = @name)
    INSERT @list (name) SELECT object_name FROM dbo.HC_snapshot_sets WHERE set_name = @name ORDER BY object_name;
ELSE
BEGIN
    -- split the comma list (XML, so it works at any compatibility level)
    DECLARE @x xml = CAST(N'<i>' + REPLACE((SELECT @name FOR XML PATH('')), N',', N'</i><i>') + N'</i>' AS xml);
    INSERT @list (name)
    SELECT DISTINCT CASE WHEN v LIKE N'HC[_]%' THEN v ELSE N'HC_' + v END
    FROM (SELECT LTRIM(RTRIM(i.value('.', 'nvarchar(128)'))) AS v FROM @x.nodes('/i') AS t(i)) AS s
    WHERE v <> N'';
END;

CREATE TABLE #frag (id int IDENTITY(1,1), chunk nvarchar(max));
DECLARE @out TABLE (object_name sysname, database_name sysname NULL, result_set int NULL, snapshot_id int NULL, row_count int NULL, note nvarchar(2000) NULL);
DECLARE @i int = 0, @cnt int = (SELECT COUNT(*) FROM @list), @obj sysname, @sql nvarchar(max), @scope varchar(10),
        @type char(2), @db sysname, @exec nvarchar(400), @json nvarchar(max), @rows int, @err nvarchar(2000), @j int, @dbcnt int;
DECLARE @dbs TABLE (n int IDENTITY(1,1), name sysname);
DECLARE @q TABLE (n int IDENTITY(1,1), query nvarchar(max));
DECLARE @sep nvarchar(40) = N'--#HC_NEXT_RESULT#',      -- marker line between queries (line endings don't matter)
        @rest nvarchar(max), @pos bigint, @k int, @qcnt int, @qid int;

WHILE @i < @cnt
BEGIN
    SET @i += 1;
    SELECT @obj = l.name, @sql = r.capture_sql, @scope = r.capture_scope, @type = o.type
    FROM @list AS l
    LEFT JOIN dbo.HC_objects AS r ON r.name = l.name
    LEFT JOIN sys.objects AS o ON o.object_id = OBJECT_ID(N'dbo.' + QUOTENAME(l.name))
    WHERE l.n = @i;

    IF @type IS NULL
    BEGIN INSERT @out (object_name, note) VALUES (@obj, N'not installed on this server'); CONTINUE; END;
    IF @sql IS NULL
    BEGIN INSERT @out (object_name, note) VALUES (@obj, N'uses variables / temp tables / DBCC - can''t be saved'); CONTINUE; END;
    IF RTRIM(@type) = 'P' AND @scope = 'server' AND @sql LIKE N'SELECT * FROM dbo.%'     -- view installed as a procedure
    BEGIN INSERT @out (object_name, note) VALUES (@obj, N'installed as a procedure here - can''t be saved'); CONTINUE; END;

    -- one query per result set
    DELETE @q;
    SET @rest = @sql;
    WHILE @rest IS NOT NULL
    BEGIN
        SET @pos = CHARINDEX(@sep, @rest);
        IF @pos = 0 BEGIN INSERT @q (query) VALUES (@rest); SET @rest = NULL; END
        ELSE BEGIN INSERT @q (query) VALUES (LEFT(@rest, @pos - 1)); SET @rest = SUBSTRING(@rest, @pos + LEN(@sep), LEN(@rest)); END;
    END;
    SET @qcnt = (SELECT COUNT(*) FROM @q);

    DELETE @dbs;
    IF @scope = 'database'
        INSERT @dbs (name) SELECT name FROM dbo.HC_fn_databases(@database_name) ORDER BY name;
    ELSE
        INSERT @dbs (name) VALUES (DB_NAME());
    SELECT @j = 0, @dbcnt = COUNT(*) FROM @dbs;
    IF @dbcnt = 0 INSERT @out (object_name, note) VALUES (@obj, N'no online database matches @database_name');

    WHILE @j < @dbcnt
    BEGIN
        SET @j += 1;
        SELECT @db = name FROM @dbs WHERE n = @j;
        SET @exec = QUOTENAME(@db) + N'.sys.sp_executesql';
        SET @k = 0;
        WHILE @k < @qcnt
        BEGIN
        SET @k += 1;
        BEGIN TRY
            TRUNCATE TABLE #frag;
            SELECT @json = query + N' FOR JSON PATH, INCLUDE_NULL_VALUES' FROM @q WHERE n = @k;
            INSERT #frag (chunk) EXEC @exec @json;
            SET @json = ISNULL((SELECT chunk AS [text()] FROM #frag ORDER BY id FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), N'[]');
            IF @json = N'' SET @json = N'[]';
            BEGIN TRY       -- row count needs OPENJSON (compatibility level 130+); NULL otherwise
                EXEC sys.sp_executesql N'SET @r = (SELECT COUNT(*) FROM OPENJSON(@j));', N'@j nvarchar(max), @r int OUTPUT',
                     @j = @json, @r = @rows OUTPUT;
            END TRY
            BEGIN CATCH
                SET @rows = NULL;
            END CATCH;
            INSERT dbo.HC_snapshots (label, object_name, database_name, result_set, row_count, data)
            VALUES (@label, @obj, CASE WHEN @scope = 'database' THEN @db END, @k, @rows, @json);
            INSERT @out (object_name, database_name, result_set, snapshot_id, row_count)
            VALUES (@obj, CASE WHEN @scope = 'database' THEN @db END, @k, SCOPE_IDENTITY(), @rows);
        END TRY
        BEGIN CATCH
            SET @err = ERROR_MESSAGE();
            INSERT @out (object_name, database_name, result_set, note) VALUES (@obj, @db, @k, N'failed: ' + @err);
        END CATCH;
        END;
    END;
END;

DELETE dbo.HC_snapshots WHERE captured_at < DATEADD(day, -@keep_days, SYSDATETIME());
SELECT @label AS label, object_name, database_name, result_set, snapshot_id, row_count, note
FROM @out ORDER BY object_name, database_name, result_set;
GO

IF OBJECT_ID(N'dbo.HC_snapshot_list', N'V') IS NULL
    EXEC (N'CREATE VIEW dbo.HC_snapshot_list AS SELECT 1 AS placeholder;');
GO
ALTER VIEW dbo.HC_snapshot_list
AS
SELECT snapshot_id, captured_at, label, object_name, database_name, result_set, row_count, captured_by,
       DATALENGTH(data) / 1024 AS size_kb
FROM dbo.HC_snapshots;
GO

-- Builds "OPENJSON(...) WITH ([col] nvarchar(max) '$."col"', ...)" column list from the first row of a snapshot
IF OBJECT_ID(N'dbo.HC_usp_snapshot_columns', N'P') IS NULL
    EXEC (N'CREATE PROCEDURE dbo.HC_usp_snapshot_columns AS RETURN;');
GO
ALTER PROCEDURE dbo.HC_usp_snapshot_columns
    @json  nvarchar(max),
    @with  nvarchar(max) OUTPUT,
    @first sysname       OUTPUT
AS
SET NOCOUNT ON;
DECLARE @k TABLE (n int IDENTITY(1,1), k nvarchar(4000));
INSERT @k (k) SELECT [key] FROM OPENJSON(@json, N'$[0]');
SET @first = (SELECT TOP (1) LEFT(k, 128) FROM @k ORDER BY n);
SET @with = STUFF((
    SELECT N', ' + QUOTENAME(LEFT(k, 128)) + N' nvarchar(max) ''$."'
         + REPLACE(REPLACE(REPLACE(k, N'\', N'\\'), N'"', N'\"'), N'''', N'''''') + N'"'''
    FROM @k ORDER BY n
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
GO

IF OBJECT_ID(N'dbo.HC_snapshot_show', N'P') IS NULL
    EXEC (N'CREATE PROCEDURE dbo.HC_snapshot_show AS RETURN;');
GO
ALTER PROCEDURE dbo.HC_snapshot_show
    @snapshot_id int
AS
SET NOCOUNT ON;
DECLARE @json nvarchar(max), @with nvarchar(max), @first sysname, @sql nvarchar(max);
SELECT @json = data FROM dbo.HC_snapshots WHERE snapshot_id = @snapshot_id;
IF @json IS NULL BEGIN RAISERROR(N'Snapshot %d not found.', 16, 1, @snapshot_id); RETURN; END;
SELECT snapshot_id, captured_at, label, object_name, database_name, result_set, row_count, captured_by
FROM dbo.HC_snapshots WHERE snapshot_id = @snapshot_id;
EXEC dbo.HC_usp_snapshot_columns @json, @with OUTPUT, @first OUTPUT;
IF @with IS NULL BEGIN SELECT N'(no rows)' AS result; RETURN; END;
SET @sql = N'SELECT j.* FROM OPENJSON(@json) WITH (' + @with + N') AS j;';
EXEC sys.sp_executesql @sql, N'@json nvarchar(max)', @json = @json;
GO

IF OBJECT_ID(N'dbo.HC_snapshot_diff', N'P') IS NULL
    EXEC (N'CREATE PROCEDURE dbo.HC_snapshot_diff AS RETURN;');
GO
ALTER PROCEDURE dbo.HC_snapshot_diff
    @before_label nvarchar(100) = NULL,   -- compare every check saved under both labels ...
    @after_label  nvarchar(100) = NULL,
    @before_id    int           = NULL,   -- ... or exactly two snapshots
    @after_id     int           = NULL,
    @name         sysname       = NULL,   -- limit to one check
    @show_rows    bit           = 1       -- 1 = one result set of changed rows per check
AS
SET NOCOUNT ON;
DECLARE @pairs TABLE (n int IDENTITY(1,1), object_name sysname, database_name sysname NULL, result_set int NULL,
                     before_id int NULL, after_id int NULL);

IF @before_id IS NOT NULL AND @after_id IS NOT NULL
    INSERT @pairs (object_name, database_name, result_set, before_id, after_id)
    SELECT b.object_name, b.database_name, b.result_set, @before_id, @after_id
    FROM dbo.HC_snapshots AS b WHERE b.snapshot_id = @before_id;
ELSE IF @before_label IS NOT NULL AND @after_label IS NOT NULL
BEGIN
    ;WITH b AS (SELECT object_name, database_name, result_set, MAX(snapshot_id) AS id FROM dbo.HC_snapshots
               WHERE label = @before_label AND (@name IS NULL OR object_name = @name)
               GROUP BY object_name, database_name, result_set),
         a AS (SELECT object_name, database_name, result_set, MAX(snapshot_id) AS id FROM dbo.HC_snapshots
               WHERE label = @after_label AND (@name IS NULL OR object_name = @name)
               GROUP BY object_name, database_name, result_set)
    INSERT @pairs (object_name, database_name, result_set, before_id, after_id)
    SELECT COALESCE(b.object_name, a.object_name), COALESCE(b.database_name, a.database_name),
           COALESCE(b.result_set, a.result_set), b.id, a.id
    FROM b FULL JOIN a ON a.object_name = b.object_name
                      AND ISNULL(a.database_name, N'') = ISNULL(b.database_name, N'')
                      AND a.result_set = b.result_set
    ORDER BY 1, 2, 3;
END
ELSE
BEGIN RAISERROR(N'Pass @before_label and @after_label, or @before_id and @after_id.', 16, 1); RETURN; END;

DECLARE @summary TABLE (object_name sysname, database_name sysname NULL, result_set int NULL, before_id int NULL, after_id int NULL,
                        before_rows int NULL, after_rows int NULL, only_before int NULL, only_after int NULL);
DECLARE @i int = 0, @cnt int = (SELECT COUNT(*) FROM @pairs), @b nvarchar(max), @a nvarchar(max), @bid int, @aid int,
        @with nvarchar(max), @first sysname, @sql nvarchar(max), @obj sysname, @db sysname, @rs int;
WHILE @i < @cnt
BEGIN
    SET @i += 1;
    SELECT @obj = object_name, @db = database_name, @rs = result_set, @bid = before_id, @aid = after_id FROM @pairs WHERE n = @i;
    SELECT @b = data FROM dbo.HC_snapshots WHERE snapshot_id = @bid;
    SELECT @a = data FROM dbo.HC_snapshots WHERE snapshot_id = @aid;
    IF @bid IS NULL SET @b = NULL;
    IF @aid IS NULL SET @a = NULL;
    INSERT @summary
    SELECT @obj, @db, @rs, @bid, @aid,
           (SELECT COUNT(*) FROM OPENJSON(@b)), (SELECT COUNT(*) FROM OPENJSON(@a)),
           (SELECT COUNT(*) FROM (SELECT value FROM OPENJSON(@b) EXCEPT SELECT value FROM OPENJSON(@a)) AS x),
           (SELECT COUNT(*) FROM (SELECT value FROM OPENJSON(@a) EXCEPT SELECT value FROM OPENJSON(@b)) AS y);
END;

SELECT object_name, database_name, result_set, before_id, after_id, before_rows, after_rows,
       only_before AS rows_only_before, only_after AS rows_only_after,
       CASE WHEN before_id IS NULL THEN 'only in after'
            WHEN after_id  IS NULL THEN 'only in before'
            WHEN only_before + only_after = 0 THEN 'same'
            ELSE 'changed' END AS result
FROM @summary
ORDER BY CASE WHEN before_id IS NOT NULL AND after_id IS NOT NULL AND only_before + only_after = 0 THEN 1 ELSE 0 END,
         object_name, database_name, result_set;

IF @show_rows = 1
BEGIN
    SET @i = 0;
    WHILE @i < @cnt
    BEGIN
        SET @i += 1;
        SELECT @obj = object_name, @db = database_name, @rs = result_set, @bid = before_id, @aid = after_id FROM @pairs WHERE n = @i;
        IF @bid IS NULL OR @aid IS NULL
           OR EXISTS (SELECT 1 FROM @summary WHERE before_id = @bid AND after_id = @aid AND only_before + only_after = 0)
            CONTINUE;
        SELECT @b = data FROM dbo.HC_snapshots WHERE snapshot_id = @bid;
        SELECT @a = data FROM dbo.HC_snapshots WHERE snapshot_id = @aid;
        SET @with = NULL;
        EXEC dbo.HC_usp_snapshot_columns @b, @with OUTPUT, @first OUTPUT;
        IF @with IS NULL EXEC dbo.HC_usp_snapshot_columns @a, @with OUTPUT, @first OUTPUT;
        IF @with IS NULL CONTINUE;
        SET @sql = N'
SELECT @obj AS [check], @db AS [database], @rs AS result_set, d.change, j.*
FROM (SELECT N''before'' AS change, value FROM (SELECT value FROM OPENJSON(@b) EXCEPT SELECT value FROM OPENJSON(@a)) AS x
      UNION ALL
      SELECT N''after'', value FROM (SELECT value FROM OPENJSON(@a) EXCEPT SELECT value FROM OPENJSON(@b)) AS y) AS d
CROSS APPLY OPENJSON(d.value) WITH (' + @with + N') AS j
ORDER BY j.' + QUOTENAME(@first) + N', d.change DESC;';
        EXEC sys.sp_executesql @sql, N'@b nvarchar(max), @a nvarchar(max), @obj sysname, @db sysname, @rs int',
             @b = @b, @a = @a, @obj = @obj, @db = @db, @rs = @rs;
    END;
END;
GO

/*============================================================================
  VERSION: which build is installed and how healthy it is
     SELECT * FROM dbo.HC_version;
============================================================================*/
IF OBJECT_ID(N'dbo.HC_version', N'V') IS NULL
    EXEC (N'CREATE VIEW dbo.HC_version AS SELECT 1 AS placeholder;');
GO
ALTER VIEW dbo.HC_version
AS
SELECT TOP (1)
    h.build_id,
    h.finished_at                      AS deployed_at,
    h.login_name                       AS deployed_by,
    h.product_version                  AS sql_version_at_deploy,
    h.objects_ok, h.objects_failed, h.objects_skipped,
    t.last_selftest_at, t.selftest_pass, t.selftest_fail, t.selftest_skipped
FROM dbo.HC_deploy_history AS h
OUTER APPLY (SELECT MAX(run_at) AS last_selftest_at,
                    SUM(CASE WHEN result = 'PASS' THEN 1 ELSE 0 END)    AS selftest_pass,
                    SUM(CASE WHEN result = 'FAIL' THEN 1 ELSE 0 END)    AS selftest_fail,
                    SUM(CASE WHEN result = 'SKIPPED' THEN 1 ELSE 0 END) AS selftest_skipped
             FROM dbo.HC_selftest_results
             WHERE run_at = (SELECT MAX(run_at) FROM dbo.HC_selftest_results)) AS t
WHERE h.finished_at IS NOT NULL
ORDER BY h.deploy_id DESC;
GO

/*----------------------------------------------------------------------------
  Remove objects an earlier run installed that this build no longer contains
  (only names registered in dbo.HC_objects are touched - nothing else in DBAdmin)
----------------------------------------------------------------------------*/
DECLARE @run_start datetime2(0) = CAST(SESSION_CONTEXT(N'hc_run_start') AS datetime2(0)),
        @n sysname, @t char(2), @cmd nvarchar(400);
IF @run_start IS NULL      -- batches ran on separate connections: use this run's history row instead
    SET @run_start = (SELECT TOP (1) started_at FROM dbo.HC_deploy_history WHERE finished_at IS NULL ORDER BY deploy_id DESC);
IF @run_start IS NOT NULL
   AND (SELECT COUNT(*) FROM dbo.HC_objects WHERE deployed_at >= @run_start) < {{OBJECT_COUNT}}
BEGIN
    PRINT N'Clean-up skipped: not every object of this build was deployed in this run (partial run?).';
    SET @run_start = NULL;
END;
IF @run_start IS NOT NULL
BEGIN
    DECLARE stale CURSOR LOCAL FAST_FORWARD FOR
        SELECT r.name, o.type
        FROM dbo.HC_objects AS r
        LEFT JOIN sys.objects AS o ON o.object_id = OBJECT_ID(N'dbo.' + QUOTENAME(r.name))
        WHERE r.deployed_at < @run_start;
    OPEN stale; FETCH NEXT FROM stale INTO @n, @t;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF RTRIM(@t) IN ('V', 'P', 'IF')
        BEGIN
            SET @cmd = N'DROP ' + CASE RTRIM(@t) WHEN 'V' THEN N'VIEW' WHEN 'P' THEN N'PROCEDURE' ELSE N'FUNCTION' END
                     + N' dbo.' + QUOTENAME(@n);
            EXEC sys.sp_executesql @cmd;
        END;
        DELETE dbo.HC_objects WHERE name = @n;
        PRINT N'Removed ' + @n + N' (no longer in the toolkit).';
        FETCH NEXT FROM stale INTO @n, @t;
    END;
    CLOSE stale; DEALLOCATE stale;
END;
GO

/*----------------------------------------------------------------------------
  Finish the deploy history row + summary
----------------------------------------------------------------------------*/
DECLARE @deploy_id int = ISNULL(CAST(SESSION_CONTEXT(N'hc_deploy_id') AS int),
        (SELECT MAX(deploy_id) FROM dbo.HC_deploy_history WHERE finished_at IS NULL));
UPDATE h
SET finished_at     = SYSDATETIME(),
    objects_ok      = s.ok,
    objects_failed  = s.failed,
    objects_skipped = s.skipped
FROM dbo.HC_deploy_history AS h
CROSS JOIN (SELECT SUM(CASE WHEN status LIKE 'OK%' THEN 1 ELSE 0 END)  AS ok,
                   SUM(CASE WHEN status = 'FAILED' THEN 1 ELSE 0 END) AS failed,
                   SUM(CASE WHEN status IN ('NOT APPLICABLE', 'NOT ON THIS VERSION') THEN 1 ELSE 0 END) AS skipped
            FROM dbo.HC_objects) AS s
WHERE h.deploy_id = @deploy_id;
DELETE dbo.HC_deploy_history WHERE deploy_id <= @deploy_id - 50;   -- keep the last 50 deploys

SELECT build_id, deployed_at, objects_ok, objects_failed, objects_skipped FROM dbo.HC_version;

SELECT status, COUNT(*) AS objects
FROM dbo.HC_objects
GROUP BY status
ORDER BY status;

SELECT toolkit_section, name, status, message
FROM dbo.HC_catalog
WHERE status NOT IN ('OK', 'NOT APPLICABLE', 'NOT ON THIS VERSION')
ORDER BY TRY_CAST(PARSENAME(toolkit_section, 2) AS int), TRY_CAST(PARSENAME(toolkit_section, 1) AS int);
GO

SET NOEXEC OFF;
GO

/*----------------------------------------------------------------------------
  OPTIONAL: let a team group use the objects. Replace DOMAIN\DBA-Team, then
  un-comment. Every step checks first, so it is safe to run repeatedly.
----------------------------------------------------------------------------
USE DBAdmin;
IF DATABASE_PRINCIPAL_ID(N'HC_users') IS NULL
    CREATE ROLE HC_users;
GRANT SELECT, EXECUTE ON SCHEMA::dbo TO HC_users;          -- re-granting is harmless
IF DATABASE_PRINCIPAL_ID(N'DOMAIN\DBA-Team') IS NULL
    CREATE USER [DOMAIN\DBA-Team] FOR LOGIN [DOMAIN\DBA-Team];
IF IS_ROLEMEMBER(N'HC_users', N'DOMAIN\DBA-Team') = 0
    ALTER ROLE HC_users ADD MEMBER [DOMAIN\DBA-Team];
USE master;
GRANT VIEW SERVER STATE TO [DOMAIN\DBA-Team];             -- 2022+: VIEW SERVER PERFORMANCE STATE + VIEW SERVER SECURITY STATE
GRANT VIEW ANY DEFINITION TO [DOMAIN\DBA-Team];
----------------------------------------------------------------------------*/
