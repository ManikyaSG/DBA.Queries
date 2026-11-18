/*******************************************************************************
 File    : DBAdmin_HC_Deploy.sql            (GENERATED - do not edit by hand)
 Source  : the numbered scripts in this repo, rebuilt with dba-database/build_hc_deploy.py
 Purpose : Installs the toolkit's diagnostic queries as objects in the DBAdmin
           database, so the team can run them without opening the script files:

               SELECT * FROM DBAdmin.dbo.HC_catalog;          -- what is installed + how to call it
               SELECT * FROM DBAdmin.dbo.HC_active_sessions;  -- views
               SELECT * FROM DBAdmin.dbo.HC_top_queries(DEFAULT, DEFAULT);   -- functions with inputs
               EXEC DBAdmin.dbo.HC_blocking_tree;             -- multi-step checks
               EXEC DBAdmin.dbo.HC_index_usage @database_name = N'Sales';   -- per-database checks

 Runs on : SQL Server 2016 SP2 - 2025, Azure SQL Managed Instance, Azure SQL Database
           * Box / Azure VM / MI : creates DBAdmin if missing and installs into it.
             Install on EVERY AG replica (DBAdmin is a local database - keep it out of AGs).
           * Azure SQL Database  : connect to the user database you want it in and run
                                   the script there (the USE below errors harmlessly).
 Safe to  : re-run any number of times. Every object is IF NOT EXISTS -> create placeholder,
            then ALTER, inside TRY/CATCH (works on every 2016 build), so one
            failure never stops the rest. Objects that need a newer version or another
            platform are skipped and listed in dbo.HC_catalog with the reason.
 Security : objects run with the CALLER's permissions. Users still need
            VIEW SERVER STATE (2022+: VIEW SERVER PERFORMANCE STATE / VIEW SERVER SECURITY STATE)
            and access to msdb / the databases they query. Grant example at the end.
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

/*----------------------------------------------------------------------------
  Registry + deploy helper
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

-- Remember when this run started; the end of the script drops objects that an earlier
-- run installed but this version of the toolkit no longer contains.
DECLARE @hc_run_start datetime2(0) = SYSDATETIME();
EXEC sys.sp_set_session_context @key = N'hc_run_start', @value = @hc_run_start;
GO

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
     usage = @usage, sort_hint = @sort_hint, status = @status, message = LEFT(@msg, 4000), deployed_at = SYSDATETIME()
WHEN NOT MATCHED THEN INSERT (name, section, source_file, title, tags, usage, sort_hint, status, message)
     VALUES (@name, @section, @source_file, @title, @tags, @usage, @sort_hint, @status, LEFT(@msg, 4000));
GO

/*============================================================================
  OBJECTS (one EXEC per toolkit section)
============================================================================*/
