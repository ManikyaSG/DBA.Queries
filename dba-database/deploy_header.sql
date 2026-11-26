/*******************************************************************************
 File    : DBAdmin_HC_Deploy.sql            (GENERATED - do not edit by hand)
 Build   : {{BUILD_ID}}
 Source  : the numbered scripts in this repo, rebuilt with dba-database/build_hc_deploy.py
 Purpose : Installs the toolkit's diagnostic queries as objects in the DBAdmin
           database, so the team can run them without opening the script files:

               EXEC DBAdmin.dbo.HC_help N'block';             -- find a check by keyword
               SELECT * FROM DBAdmin.dbo.HC_active_sessions;  -- views
               EXEC DBAdmin.dbo.HC_blocking_tree;             -- multi-step checks
               EXEC DBAdmin.dbo.HC_index_usage @database_name = N'Sales';   -- one database
               EXEC DBAdmin.dbo.HC_index_usage @database_name = N'*';       -- every database
               EXEC DBAdmin.dbo.HC_snapshot N'change', @label = N'pre-patch';   -- save for a later compare
               EXEC DBAdmin.dbo.HC_selftest;                  -- run every check once, log pass/fail

 Runs on : SQL Server 2016 - 2025, Azure SQL Managed Instance, Azure SQL Database
           * Box / Azure VM / MI : creates DBAdmin if missing and installs into it.
             Install on EVERY AG replica (DBAdmin is a local database - keep it out of AGs).
           * Azure SQL Database  : connect to the user database you want it in and run
                                   the script there (the USE below errors harmlessly).
 Safe to  : re-run any number of times. Everything is checked first (IF EXISTS / IF NOT
            EXISTS); objects are created as placeholders only when missing and then
            ALTERed, inside TRY/CATCH, so one failure never stops the rest. Objects that
            need a newer version or another platform are skipped and listed in
            dbo.HC_catalog with the reason.
 Security : objects run with the CALLER's permissions. Users still need
            VIEW SERVER STATE (2022+: VIEW SERVER PERFORMANCE STATE / VIEW SERVER SECURITY STATE)
            and access to msdb / the databases they query. Grant example at the end.
            Every procedure reads with LOCK_TIMEOUT 5 s, READ UNCOMMITTED and
            DEADLOCK_PRIORITY LOW, so a check never blocks production work.
*******************************************************************************/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

IF CAST(SERVERPROPERTY('EngineEdition') AS int) <> 5 AND DB_ID(N'DBAdmin') IS NULL
BEGIN
    CREATE DATABASE DBAdmin;
    ALTER DATABASE DBAdmin SET RECOVERY SIMPLE;
    PRINT 'Created database DBAdmin.';
END;
GO

USE DBAdmin;   -- Azure SQL Database: this line errors; that is expected, the script continues in the current DB
GO

IF (CAST(SERVERPROPERTY('EngineEdition') AS int) <> 5 AND DB_NAME() <> N'DBAdmin')
OR (CAST(SERVERPROPERTY('EngineEdition') AS int) = 5 AND DB_NAME() = N'master')
BEGIN
    RAISERROR(N'Not in DBAdmin (or in master on Azure SQL Database) - nothing will be installed.', 16, 1);
    SET NOEXEC ON;
END;
GO

IF (SELECT compatibility_level FROM sys.databases WHERE name = DB_NAME()) < 130
    RAISERROR(N'WARNING: this database is below compatibility level 130. HC_snapshot_show and HC_snapshot_diff need 130+; everything else works.', 10, 1) WITH NOWAIT;
GO

/*----------------------------------------------------------------------------
  Registry, deploy history
----------------------------------------------------------------------------*/
IF OBJECT_ID(N'dbo.HC_objects', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.HC_objects
    (
        name          sysname        NOT NULL CONSTRAINT PK_HC_objects PRIMARY KEY,
        section       varchar(10)    NOT NULL,
        source_file   nvarchar(128)  NOT NULL,
        title         nvarchar(400)  NOT NULL,
        tags          varchar(30)    NOT NULL,
        usage         nvarchar(1000) NOT NULL,
        sort_hint     nvarchar(1000) NULL,
        status        varchar(30)    NOT NULL,
        message       nvarchar(4000) NULL,
        deployed_at   datetime2(0)   NOT NULL CONSTRAINT DF_HC_objects_deployed DEFAULT SYSDATETIME()
    );
    PRINT 'Created table dbo.HC_objects.';
END;
GO
-- columns added in later builds (existing installs get them without losing anything)
IF COL_LENGTH(N'dbo.HC_objects', N'test_call')     IS NULL ALTER TABLE dbo.HC_objects ADD test_call     nvarchar(2000) NULL;
IF COL_LENGTH(N'dbo.HC_objects', N'test_mode')     IS NULL ALTER TABLE dbo.HC_objects ADD test_mode     varchar(100)   NULL;
IF COL_LENGTH(N'dbo.HC_objects', N'capture_scope') IS NULL ALTER TABLE dbo.HC_objects ADD capture_scope varchar(10)    NULL;
IF COL_LENGTH(N'dbo.HC_objects', N'capture_sql')   IS NULL ALTER TABLE dbo.HC_objects ADD capture_sql   nvarchar(max)  NULL;
GO

IF OBJECT_ID(N'dbo.HC_deploy_history', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.HC_deploy_history
    (
        deploy_id         int IDENTITY(1,1) NOT NULL CONSTRAINT PK_HC_deploy_history PRIMARY KEY,
        build_id          varchar(20)    NOT NULL,
        started_at        datetime2(0)   NOT NULL CONSTRAINT DF_HC_deploy_history_started DEFAULT SYSDATETIME(),
        finished_at       datetime2(0)   NULL,
        login_name        nvarchar(128)  NOT NULL CONSTRAINT DF_HC_deploy_history_login DEFAULT ORIGINAL_LOGIN(),
        host_name         nvarchar(128)  NULL     CONSTRAINT DF_HC_deploy_history_host  DEFAULT HOST_NAME(),
        product_version   nvarchar(128)  NULL     CONSTRAINT DF_HC_deploy_history_ver   DEFAULT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)),
        objects_ok        int NULL,
        objects_failed    int NULL,
        objects_skipped   int NULL
    );
    PRINT 'Created table dbo.HC_deploy_history.';
END;
GO

-- Remember this run: the end of the script finishes the history row and drops objects that an
-- earlier run installed but this build no longer contains.
DECLARE @hc_run_start datetime2(0) = SYSDATETIME(), @hc_deploy_id int;
INSERT dbo.HC_deploy_history (build_id) VALUES ('{{BUILD_ID}}');
SET @hc_deploy_id = SCOPE_IDENTITY();
EXEC sys.sp_set_session_context @key = N'hc_run_start', @value = @hc_run_start;
EXEC sys.sp_set_session_context @key = N'hc_deploy_id', @value = @hc_deploy_id;
GO

/*----------------------------------------------------------------------------
  Helpers used by the per-database procedures
----------------------------------------------------------------------------*/
-- Databases a per-database check runs in: one name, or N'*' = every online user database
-- this login can open (Azure SQL Database: only the current one).
IF OBJECT_ID(N'dbo.HC_fn_databases', N'IF') IS NULL
    EXEC (N'CREATE FUNCTION dbo.HC_fn_databases() RETURNS TABLE AS RETURN (SELECT 1 AS placeholder);');
GO
ALTER FUNCTION dbo.HC_fn_databases (@database_name sysname)
RETURNS TABLE
AS
RETURN
(
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.state = 0
      AND (   (@database_name = N'*'
               AND d.database_id > 4
               AND d.source_database_id IS NULL                      -- not a database snapshot
               AND HAS_DBACCESS(d.name) = 1                          -- skips non-readable AG secondaries
               AND (CAST(SERVERPROPERTY('EngineEdition') AS int) <> 5 OR d.name = DB_NAME()))
           OR (@database_name <> N'*' AND d.name = @database_name))
);
GO

-- Adds the columns of a query's result to the caller's #hc_out table, so results from many
-- databases can be collected into one result set. Raises an error if the shape can't be used.
IF OBJECT_ID(N'dbo.HC_usp_shape_out', N'P') IS NULL
    EXEC (N'CREATE PROCEDURE dbo.HC_usp_shape_out AS RETURN;');
GO
ALTER PROCEDURE dbo.HC_usp_shape_out
    @database sysname,
    @sql      nvarchar(max),
    @params   nvarchar(max) = NULL,
    @cols     nvarchar(max) OUTPUT
AS
SET NOCOUNT ON;
DECLARE @d TABLE (column_ordinal int, name sysname NULL, system_type_name nvarchar(256) NULL,
                  is_hidden bit NULL, error_message nvarchar(4000) NULL);
DECLARE @exec nvarchar(400) = QUOTENAME(@database) + N'.sys.sp_executesql', @alter nvarchar(max), @err nvarchar(4000);
INSERT @d
EXEC @exec N'SELECT column_ordinal, name, system_type_name, is_hidden, error_message
             FROM sys.dm_exec_describe_first_result_set(@t, @p, 0);',
           N'@t nvarchar(max), @p nvarchar(max)', @t = @sql, @p = @params;

SET @err = (SELECT TOP (1) error_message FROM @d WHERE error_message IS NOT NULL);
IF @err IS NOT NULL THROW 50001, @err, 1;
IF NOT EXISTS (SELECT 1 FROM @d WHERE ISNULL(is_hidden, 0) = 0)
    THROW 50002, N'the query has no result columns', 1;
IF EXISTS (SELECT 1 FROM @d WHERE ISNULL(is_hidden, 0) = 0 AND name IS NULL)
    THROW 50003, N'a result column has no name', 1;
IF EXISTS (SELECT name FROM @d WHERE ISNULL(is_hidden, 0) = 0 GROUP BY name HAVING COUNT(*) > 1)
    THROW 50004, N'two result columns have the same name', 1;

SET @alter = N'ALTER TABLE #hc_out ADD ' + STUFF((
        SELECT N', ' + QUOTENAME(name) + N' '
             + CASE WHEN system_type_name IN (N'timestamp', N'rowversion') THEN N'binary(8)' ELSE system_type_name END
             + N' NULL'
        FROM @d WHERE ISNULL(is_hidden, 0) = 0 ORDER BY column_ordinal
        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
EXEC sys.sp_executesql @alter;
SET @cols = STUFF((
        SELECT N', ' + QUOTENAME(name)
        FROM @d WHERE ISNULL(is_hidden, 0) = 0 ORDER BY column_ordinal
        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
GO

/*----------------------------------------------------------------------------
  Deploy helper: installs one object and records the outcome
----------------------------------------------------------------------------*/
IF OBJECT_ID(N'dbo.HC_usp_deploy', N'P') IS NULL
    EXEC (N'CREATE PROCEDURE dbo.HC_usp_deploy AS RETURN;');
GO

ALTER PROCEDURE dbo.HC_usp_deploy
    @name                sysname,
    @section             varchar(10),
    @source_file         nvarchar(128),
    @title               nvarchar(400),
    @tags                varchar(30),
    @usage               nvarchar(1000),
    @sort_hint           nvarchar(1000) = NULL,
    @min_version         int            = NULL,   -- SQL Server major version: 13=2016 14=2017 15=2019 16=2022 17=2025
    @test_call           nvarchar(2000) = NULL,   -- how HC_selftest runs it (@db = the test database)
    @test_mode           varchar(100)   = NULL,   -- run | heavy: ... | skip: ... | needs_cdc
    @capture_scope       varchar(10)    = NULL,   -- server | database | NULL (HC_snapshot can't capture it)
    @capture_sql         nvarchar(max)  = NULL,   -- query HC_snapshot runs (FOR JSON is appended)
    @definition          nvarchar(max),            -- 'ALTER VIEW|FUNCTION|PROCEDURE dbo.HC_x ...'
    @fallback_definition nvarchar(max)  = NULL
AS
SET NOCOUNT ON;
DECLARE @platform varchar(5) =
        CASE CAST(SERVERPROPERTY('EngineEdition') AS int) WHEN 5 THEN 'SQLDB' WHEN 8 THEN 'MI' ELSE 'BOX' END;
DECLARE @status varchar(30), @msg nvarchar(4000), @fq nvarchar(300) = N'dbo.' + QUOTENAME(@name),
        @want char(2), @have char(2), @try nvarchar(max), @attempt int = 1, @errno int,
        @stub nvarchar(400), @created bit,
        @major int = CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)), 4) AS int);

IF (@tags <> '' AND CHARINDEX(@platform, @tags) = 0)
OR (@platform = 'BOX' AND @min_version IS NOT NULL AND @major < @min_version)
BEGIN
    IF @tags <> '' AND CHARINDEX(@platform, @tags) = 0
        SELECT @status = 'NOT APPLICABLE', @msg = N'Written for ' + @tags + N'; this is ' + @platform + N'.';
    ELSE
        SELECT @status = 'NOT ON THIS VERSION',
               @msg = N'Needs major version ' + CAST(@min_version AS nvarchar(5)) + N'+; this is ' + CAST(@major AS nvarchar(5)) + N'.';
    IF OBJECT_ID(@fq) IS NOT NULL      -- installed by an earlier run on a different platform/version
    BEGIN
        SET @try = N'DROP ' + CASE (SELECT type FROM sys.objects WHERE object_id = OBJECT_ID(@fq))
                                WHEN 'V' THEN N'VIEW' WHEN 'P' THEN N'PROCEDURE' ELSE N'FUNCTION' END + N' ' + @fq;
        EXEC sys.sp_executesql @try;
    END;
END
ELSE
BEGIN
    SET @try = @definition;
    WHILE @try IS NOT NULL
    BEGIN
        SELECT @want = CASE WHEN @try LIKE N'ALTER VIEW%'     THEN 'V'
                            WHEN @try LIKE N'ALTER FUNCTION%' THEN 'IF'
                            ELSE 'P' END,
               @created = 0;
        BEGIN TRY
            -- IF EXISTS with a different type (e.g. was a view, now a procedure): drop it first
            SELECT @have = type FROM sys.objects WHERE object_id = OBJECT_ID(@fq);
            IF @have IS NOT NULL AND RTRIM(@have) <> RTRIM(@want)
            BEGIN
                DECLARE @drop nvarchar(400) = N'DROP ' + CASE RTRIM(@have) WHEN 'V' THEN N'VIEW' WHEN 'P' THEN N'PROCEDURE'
                                                          ELSE N'FUNCTION' END + N' ' + @fq;
                EXEC sys.sp_executesql @drop;
            END;
            -- IF NOT EXISTS: create an empty placeholder, then ALTER it into the real object
            IF OBJECT_ID(@fq) IS NULL
            BEGIN
                SET @stub = CASE @want
                    WHEN 'V'  THEN N'CREATE VIEW ' + @fq + N' AS SELECT 1 AS placeholder;'
                    WHEN 'IF' THEN N'CREATE FUNCTION ' + @fq + N'() RETURNS TABLE AS RETURN (SELECT 1 AS placeholder);'
                    ELSE           N'CREATE PROCEDURE ' + @fq + N' AS RETURN;' END;
                EXEC sys.sp_executesql @stub;
                SET @created = 1;
            END;
            EXEC sys.sp_executesql @try;
            SELECT @status = CASE WHEN @attempt = 1 THEN 'OK' ELSE 'OK (as procedure)' END,
                   @msg    = CASE WHEN @attempt = 1 THEN NULL ELSE N'Created as a procedure instead: ' + @msg END,
                   @try    = NULL;
        END TRY
        BEGIN CATCH
            SELECT @msg = CASE WHEN @msg IS NULL THEN N'' ELSE @msg + N' | ' END + ERROR_MESSAGE(),
                   @errno = ERROR_NUMBER();
            IF @created = 1 AND OBJECT_ID(@fq) IS NOT NULL      -- don't leave an empty placeholder behind
            BEGIN
                SET @stub = N'DROP ' + CASE @want WHEN 'V' THEN N'VIEW' WHEN 'IF' THEN N'FUNCTION' ELSE N'PROCEDURE' END + N' ' + @fq;
                EXEC sys.sp_executesql @stub;
            END;
            IF @attempt = 1 AND @fallback_definition IS NOT NULL
                SELECT @try = @fallback_definition, @attempt = 2;
            ELSE      -- 207/208/195/4121 on older builds = column/function/syntax the version lacks
                SELECT @status = CASE WHEN @errno IN (207, 208, 195, 4121) THEN 'NOT ON THIS VERSION' ELSE 'FAILED' END,
                       @try = NULL;
        END CATCH;
        SET @have = NULL;
    END;
END;

MERGE dbo.HC_objects AS t
USING (SELECT @name AS name) AS s ON t.name = s.name
WHEN MATCHED THEN UPDATE SET section = @section, source_file = @source_file, title = @title, tags = @tags,
     usage = @usage, sort_hint = @sort_hint, status = @status, message = LEFT(@msg, 4000), deployed_at = SYSDATETIME(),
     test_call = @test_call, test_mode = @test_mode, capture_scope = @capture_scope, capture_sql = @capture_sql
WHEN NOT MATCHED THEN INSERT (name, section, source_file, title, tags, usage, sort_hint, status, message,
                              test_call, test_mode, capture_scope, capture_sql)
     VALUES (@name, @section, @source_file, @title, @tags, @usage, @sort_hint, @status, LEFT(@msg, 4000),
             @test_call, @test_mode, @capture_scope, @capture_sql);
GO

/*============================================================================
  OBJECTS (one EXEC per toolkit section)
============================================================================*/
