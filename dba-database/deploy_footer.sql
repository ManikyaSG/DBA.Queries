
/*============================================================================
  CATALOG: what is installed and how to call it
     SELECT * FROM dbo.HC_catalog;                               -- everything
     SELECT * FROM dbo.HC_catalog WHERE title LIKE N'%block%';   -- find one
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
    r.tags                        AS runs_on,
    r.status,
    r.message,
    r.source_file,
    r.deployed_at
FROM dbo.HC_objects AS r
LEFT JOIN sys.objects AS o ON o.object_id = OBJECT_ID(N'dbo.' + QUOTENAME(r.name));
GO

/*----------------------------------------------------------------------------
  Remove objects an earlier run installed that this version no longer contains
  (only names registered in dbo.HC_objects are touched - nothing else in DBAdmin)
----------------------------------------------------------------------------*/
DECLARE @run_start datetime2(0) = CAST(SESSION_CONTEXT(N'hc_run_start') AS datetime2(0)),
        @n sysname, @t char(2), @cmd nvarchar(400);
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
  Deployment summary
----------------------------------------------------------------------------*/
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
