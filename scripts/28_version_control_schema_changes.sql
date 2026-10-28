/*******************************************************************************
 File    : 28_version_control_schema_changes.sql
 Purpose : Database version control & change auditing: who changed what,
           DDL audit trigger, schema version table, object hash baselines
           for drift detection, scripting objects out for git, tooling.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] Managed Instance   [SQLDB] Azure SQL DB
*******************************************************************************/

/*=============================================================================
  28.1 RECENTLY CREATED / MODIFIED OBJECTS - ALL DATABASES             [BOX][MI]
=============================================================================*/
DECLARE @days int = 7;
IF OBJECT_ID('tempdb..#changes') IS NOT NULL DROP TABLE #changes;
CREATE TABLE #changes (database_name sysname, object_name nvarchar(300), type_desc nvarchar(60), create_date datetime, modify_date datetime);
DECLARE @sql nvarchar(max) = N'';
SELECT @sql += N'USE ' + QUOTENAME(name) + N';
INSERT #changes SELECT DB_NAME(), SCHEMA_NAME(schema_id) + N''.'' + name, type_desc, create_date, modify_date
FROM sys.objects WHERE is_ms_shipped = 0 AND modify_date >= DATEADD(DAY, -@d, GETDATE());
'
FROM sys.databases WHERE state_desc = N'ONLINE' AND HAS_DBACCESS(name) = 1 AND database_id > 4;
EXEC sys.sp_executesql @sql, N'@d int', @d = @days;
SELECT * FROM #changes ORDER BY modify_date DESC;


/*=============================================================================
  28.2 WHO DID IT? DDL EVENTS FROM THE DEFAULT TRACE                     [BOX]
  Default trace keeps ~5 x 20 MB files - recent history only.
  46 = Object:Created  47 = Object:Deleted  164 = Object:Altered
=============================================================================*/
DECLARE @trc nvarchar(260);
SELECT @trc = REVERSE(SUBSTRING(REVERSE(path), CHARINDEX(N'\', REVERSE(path)), 260)) + N'log.trc'
FROM sys.traces WHERE is_default = 1;

SELECT t.StartTime, te.name AS event_name, t.DatabaseName, t.ObjectName,
       CASE t.ObjectType WHEN 8277 THEN 'Table' WHEN 8272 THEN 'Procedure' WHEN 8278 THEN 'View'
            WHEN 20038 THEN 'Function' WHEN 22601 THEN 'Index' WHEN 21075 THEN 'Login/User' ELSE CAST(t.ObjectType AS varchar(10)) END AS object_type,
       t.LoginName, t.HostName, t.ApplicationName
FROM sys.fn_trace_gettable(@trc, DEFAULT) AS t
JOIN sys.trace_events AS te ON te.trace_event_id = t.EventClass
WHERE t.EventClass IN (46, 47, 164)
  AND t.DatabaseName NOT IN (N'tempdb')
  AND t.EventSubClass = 0                      -- avoid begin/commit duplicates
ORDER BY t.StartTime DESC;


/*=============================================================================
  28.3 DDL AUDIT: TABLE + DATABASE TRIGGER (template)          [BOX][MI][SQLDB]
  Captures full T-SQL of every schema change, permanently.
=============================================================================*/
/*
CREATE TABLE dbo.DDL_Audit (
    AuditID     bigint IDENTITY PRIMARY KEY,
    EventTime   datetime2(3)  NOT NULL DEFAULT SYSDATETIME(),
    EventType   nvarchar(100) NOT NULL,
    SchemaName  sysname       NULL,
    ObjectName  sysname       NULL,
    ObjectType  nvarchar(60)  NULL,
    LoginName   sysname       NOT NULL DEFAULT ORIGINAL_LOGIN(),
    HostName    nvarchar(128) NULL DEFAULT HOST_NAME(),
    AppName     nvarchar(256) NULL DEFAULT APP_NAME(),
    TSQL        nvarchar(max) NULL,
    EventXML    xml           NULL);
GO
CREATE TRIGGER trg_DDL_Audit ON DATABASE
FOR DDL_DATABASE_LEVEL_EVENTS
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @e xml = EVENTDATA();
    IF @e.value('(/EVENT_INSTANCE/ObjectName)[1]', 'sysname') = N'DDL_Audit' RETURN;   -- don't audit ourselves
    INSERT dbo.DDL_Audit (EventType, SchemaName, ObjectName, ObjectType, TSQL, EventXML)
    VALUES (@e.value('(/EVENT_INSTANCE/EventType)[1]',  'nvarchar(100)'),
            @e.value('(/EVENT_INSTANCE/SchemaName)[1]', 'sysname'),
            @e.value('(/EVENT_INSTANCE/ObjectName)[1]', 'sysname'),
            @e.value('(/EVENT_INSTANCE/ObjectType)[1]', 'nvarchar(60)'),
            @e.value('(/EVENT_INSTANCE/TSQLCommand/CommandText)[1]', 'nvarchar(max)'),
            @e);
END;
GO
-- Server-level variant (logins, DB create/drop): CREATE TRIGGER ... ON ALL SERVER FOR DDL_SERVER_LEVEL_EVENTS  [BOX][MI]
*/

-- Read it:
-- SELECT TOP (100) EventTime, EventType, SchemaName, ObjectName, LoginName, HostName, AppName, TSQL FROM dbo.DDL_Audit ORDER BY AuditID DESC;

-- Which DB / server DDL triggers exist?
SELECT name, parent_class_desc, is_disabled, create_date FROM sys.triggers WHERE parent_class = 0;   -- database-level (current DB)
SELECT name, is_disabled, create_date FROM sys.server_triggers;                                      -- server-level [BOX][MI]


/*=============================================================================
  28.4 SCHEMA VERSION TABLE (deployment history) - template    [BOX][MI][SQLDB]
  Every deployment script inserts one row - you always know what's deployed.
  (Flyway / DbUp / Liquibase create an equivalent table automatically.)
=============================================================================*/
/*
CREATE TABLE dbo.SchemaVersion (
    VersionID    int IDENTITY PRIMARY KEY,
    Version      varchar(50)   NOT NULL,      -- e.g. 2026.10.28.1 or git tag
    ScriptName   nvarchar(260) NOT NULL,
    GitCommit    varchar(40)   NULL,
    AppliedBy    sysname       NOT NULL DEFAULT ORIGINAL_LOGIN(),
    AppliedAt    datetime2(0)  NOT NULL DEFAULT SYSDATETIME(),
    Success      bit           NOT NULL DEFAULT 1);

-- At the end of each release script:
INSERT dbo.SchemaVersion (Version, ScriptName, GitCommit) VALUES ('2026.10.28.1', N'release_2026_10_28.sql', 'abc1234');
*/
-- Current version of this DB:
-- SELECT TOP (1) * FROM dbo.SchemaVersion ORDER BY VersionID DESC;

-- Lightweight alternative: version as a database extended property
SELECT name, value FROM sys.extended_properties WHERE class = 0;     -- DB-level properties
-- EXEC sys.sp_addextendedproperty   @name = N'SchemaVersion', @value = N'2026.10.28.1';
-- EXEC sys.sp_updateextendedproperty @name = N'SchemaVersion', @value = N'2026.11.05.1';


/*=============================================================================
  28.5 OBJECT HASH BASELINE - DETECT DRIFT FROM WHAT'S IN GIT  [BOX][MI][SQLDB]
  Take a baseline after each release; re-run later and compare to spot
  "hotfixes" made directly in production.
=============================================================================*/
/*
CREATE TABLE dbo.SchemaBaseline (
    BaselineDate datetime2(0) NOT NULL DEFAULT SYSDATETIME(),
    ObjectName   nvarchar(300) NOT NULL,
    TypeDesc     nvarchar(60)  NOT NULL,
    DefHash      varbinary(32) NOT NULL);
*/
-- Current hashes (modules by definition; tables by column + index signature):
WITH tbl AS (
    SELECT t.object_id,
           sig = (SELECT c.name, TYPE_NAME(c.user_type_id) AS t, c.max_length AS l, c.precision AS p, c.scale AS s,
                         c.is_nullable AS n, c.is_identity AS i, c.collation_name AS co
                  FROM sys.columns AS c WHERE c.object_id = t.object_id ORDER BY c.column_id FOR XML RAW, TYPE),
           idx = (SELECT i.name, i.type, i.is_unique, ic.column_id, ic.key_ordinal, ic.is_included_column, i.filter_definition
                  FROM sys.indexes AS i JOIN sys.index_columns AS ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
                  WHERE i.object_id = t.object_id ORDER BY i.name, ic.is_included_column, ic.key_ordinal, ic.column_id FOR XML RAW, TYPE)
    FROM sys.tables AS t WHERE t.is_ms_shipped = 0
)
SELECT SCHEMA_NAME(o.schema_id) + N'.' + o.name AS object_name, o.type_desc, o.modify_date,
       HASHBYTES('SHA2_256', CAST(m.definition AS nvarchar(max))) AS def_hash
FROM sys.sql_modules AS m
JOIN sys.objects AS o ON o.object_id = m.object_id
WHERE o.is_ms_shipped = 0
UNION ALL
SELECT OBJECT_SCHEMA_NAME(tbl.object_id) + N'.' + OBJECT_NAME(tbl.object_id), N'USER_TABLE', o.modify_date,
       HASHBYTES('SHA2_256', CAST(tbl.sig AS nvarchar(max)) + ISNULL(CAST(tbl.idx AS nvarchar(max)), N''))
FROM tbl JOIN sys.objects AS o ON o.object_id = tbl.object_id
ORDER BY object_name;
-- Store:  INSERT dbo.SchemaBaseline (ObjectName, TypeDesc, DefHash) SELECT object_name, type_desc, def_hash FROM (<query above>) x;
-- Note: HASHBYTES input limit is removed from 2016 onward, so large procs are fine.


/*=============================================================================
  28.6 DUMP ALL MODULE DEFINITIONS (to paste into files for git) [BOX][MI][SQLDB]
=============================================================================*/
SELECT SCHEMA_NAME(o.schema_id) + N'.' + o.name AS object_name, o.type_desc,
       N'-- ' + SCHEMA_NAME(o.schema_id) + N'.' + o.name + NCHAR(13) + NCHAR(10) + m.definition + NCHAR(13) + NCHAR(10) + N'GO' AS script
FROM sys.sql_modules AS m
JOIN sys.objects AS o ON o.object_id = m.object_id
WHERE o.is_ms_shipped = 0
ORDER BY o.type_desc, object_name;
-- Better: one file per object with dbatools  ->  Get-DbaDbTable / Get-DbaDbStoredProcedure ... | Export-DbaScript -FilePath .\schema\
-- or SSMS: Tasks > Generate Scripts > "one file per object"


/*=============================================================================
  28.7 TOOLING CHEAT SHEET (state-based vs migration-based)
=============================================================================*/
/*
 STATE-BASED (desired schema in git, tool computes the diff)
   SSDT / SQL Database Project (.sqlproj, VS / VS Code / ADS) + sqlpackage:
     sqlpackage /Action:Extract       /SourceServerName:SQL1 /SourceDatabaseName:App /TargetFile:App.dacpac
     sqlpackage /Action:DeployReport  /SourceFile:App.dacpac /TargetServerName:SQL2 /TargetDatabaseName:App /OutputPath:report.xml
     sqlpackage /Action:Script        /SourceFile:App.dacpac /TargetServerName:SQL2 /TargetDatabaseName:App /OutputPath:deploy.sql
     sqlpackage /Action:Publish       /SourceFile:App.dacpac /TargetServerName:SQL2 /TargetDatabaseName:App /p:BlockOnPossibleDataLoss=true
 MIGRATION-BASED (numbered change scripts in git, applied in order once)
   Flyway (V1__init.sql, V2__add_col.sql)  |  DbUp (.NET)  |  Liquibase  |  RoundhousE
 GIT LAYOUT SUGGESTION
   /schema/Tables  /schema/Views  /schema/StoredProcedures  /schema/Functions
   /migrations/V2026_10_28_01__description.sql   /post-deploy/  /rollback/
 PIPELINE
   PR -> build dacpac / validate scripts -> DeployReport against UAT -> approve -> publish -> insert SchemaVersion row
*/
