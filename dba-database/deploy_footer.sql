
/*============================================================================
  CATALOG: what is installed and how to call it
     SELECT * FROM dbo.HC_catalog;                               -- everything
     SELECT * FROM dbo.HC_catalog WHERE title LIKE N'%block%';   -- find one
============================================================================*/
CREATE OR ALTER VIEW dbo.HC_catalog
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
  OPTIONAL: let a team group use the objects (run once, adjust names)
----------------------------------------------------------------------------
USE DBAdmin;
CREATE ROLE HC_users;
GRANT SELECT, EXECUTE ON SCHEMA::dbo TO HC_users;
CREATE USER [DOMAIN\DBA-Team] FOR LOGIN [DOMAIN\DBA-Team];
ALTER ROLE HC_users ADD MEMBER [DOMAIN\DBA-Team];
USE master;
GRANT VIEW SERVER STATE TO [DOMAIN\DBA-Team];      -- 2022+: VIEW SERVER PERFORMANCE STATE + VIEW SERVER SECURITY STATE
GRANT VIEW ANY DEFINITION TO [DOMAIN\DBA-Team];
----------------------------------------------------------------------------*/
