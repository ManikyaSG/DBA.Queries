/*******************************************************************************
 File    : Create_PerfCheck_Logins.sql   (automation/perf-check-reports)
 Purpose : The logins / users the perf check reports need.
   SECTION A - EVERY instance: SQL login dba_perfcheck, used ONLY by
               Collect-PerfCheckReports.ps1 to read DBAdmin.dbo.DBA_PerfCheck_Report.
               It gets SELECT on that table and nothing else (the check itself runs
               locally as the job owner).
   SECTION B - the COORDINATOR only (e.g. MARSDBW1\MARS01): lets the SQL Agent
               service account send the email through Database Mail (it usually
               already can - sysadmin by default).
   SECTION C - reference: change the password, remove old rights, remove the login.
 Run     : in SSMS as sysadmin. Run HealthPerfCheck_AgentJob.sql PART 1 first
           (the table must exist). Safe to re-run.
 Password: type it in @Password, run, then REMOVE it from the file - never save or
           commit it. Use the same password on all instances. An existing login
           keeps its password (nothing is changed on it).
*******************************************************************************/

/*=============================================================================
  SECTION A - READER LOGIN  (EVERY instance)
=============================================================================*/
USE [master];
GO
DECLARE @Login        sysname       = N'dba_perfcheck',
        @Password     nvarchar(128) = N'<strong password here>',
        @ReportDb     sysname       = N'DBAdmin',
        @sql          nvarchar(max);

-- SQL authentication must be enabled (mixed mode); changing it needs a service restart
IF CAST(SERVERPROPERTY('IsIntegratedSecurityOnly') AS int) = 1
    PRINT N'WARNING: this instance allows Windows authentication only - the login can''t connect until mixed mode is enabled (Server Properties > Security, then restart the service).';
IF DB_ID(@ReportDb) IS NULL
BEGIN RAISERROR(N'Database %s not found.', 16, 1, @ReportDb); RETURN; END;
IF OBJECT_ID(QUOTENAME(@ReportDb) + N'.dbo.DBA_PerfCheck_Report', N'U') IS NULL
BEGIN RAISERROR(N'%s.dbo.DBA_PerfCheck_Report not found - run HealthPerfCheck_AgentJob.sql PART 1 first.', 16, 1, @ReportDb); RETURN; END;

IF SUSER_ID(@Login) IS NULL
BEGIN
    IF @Password LIKE N'<%>' BEGIN RAISERROR(N'Set @Password first (and remove it from the file afterwards).', 16, 1); RETURN; END;
    SET @sql = N'CREATE LOGIN ' + QUOTENAME(@Login) + N' WITH PASSWORD = N''' + REPLACE(@Password, N'''', N'''''')
             + N''', CHECK_POLICY = ON, CHECK_EXPIRATION = OFF, DEFAULT_DATABASE = ' + QUOTENAME(@ReportDb) + N';';
    EXEC (@sql);
    PRINT N'Login created: ' + @Login;
END
ELSE
BEGIN
    IF EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = @Login AND is_disabled = 1)
        PRINT N'WARNING: login ' + @Login + N' exists but is DISABLED: ALTER LOGIN ' + QUOTENAME(@Login) + N' ENABLE;';
    PRINT N'Login exists (password not changed): ' + @Login;
END;

-- database user + SELECT on the results table only
SET @sql = N'USE ' + QUOTENAME(@ReportDb) + N';
IF USER_ID(N''' + REPLACE(@Login, N'''', N'''''') + N''') IS NULL
    CREATE USER ' + QUOTENAME(@Login) + N' FOR LOGIN ' + QUOTENAME(@Login) + N';
ELSE
    ALTER USER ' + QUOTENAME(@Login) + N' WITH LOGIN = ' + QUOTENAME(@Login) + N';   -- re-map if orphaned
GRANT SELECT ON dbo.DBA_PerfCheck_Report TO ' + QUOTENAME(@Login) + N';';
EXEC (@sql);
PRINT N'SELECT on ' + @ReportDb + N'.dbo.DBA_PerfCheck_Report granted to ' + @Login + N'.';

-- show what the login can do now (should be: CONNECT SQL at server level, SELECT on the table)
SET @sql = N'SELECT N''server'' AS level, sp.permission_name, sp.state_desc, N'''' AS object
FROM sys.server_permissions AS sp JOIN sys.server_principals AS p ON p.principal_id = sp.grantee_principal_id WHERE p.name = @l
UNION ALL
SELECT N''server role'', r.name, N''MEMBER'', N'''' FROM sys.server_role_members AS m
JOIN sys.server_principals AS r ON r.principal_id = m.role_principal_id JOIN sys.server_principals AS p ON p.principal_id = m.member_principal_id WHERE p.name = @l
UNION ALL
SELECT N''' + REPLACE(@ReportDb, N'''', N'''''') + N''', dp.permission_name, dp.state_desc, ISNULL(OBJECT_SCHEMA_NAME(dp.major_id, DB_ID(N''' + REPLACE(@ReportDb, N'''', N'''''') + N''')) + N''.'' + OBJECT_NAME(dp.major_id, DB_ID(N''' + REPLACE(@ReportDb, N'''', N'''''') + N''')), N'''')
FROM ' + QUOTENAME(@ReportDb) + N'.sys.database_permissions AS dp JOIN ' + QUOTENAME(@ReportDb) + N'.sys.database_principals AS u ON u.principal_id = dp.grantee_principal_id WHERE u.name = @l;';
EXEC sys.sp_executesql @sql, N'@l sysname', @l = @Login;
GO

/*=============================================================================
  SECTION B - EMAIL FROM THE COLLECTOR  (COORDINATOR only, e.g. MARSDBW1\MARS01)
  The collector job runs as this instance's SQL Agent service account and sends
  the email through Database Mail with Windows authentication (needed to attach
  files). Setup normally makes that account sysadmin - then nothing is done here.
=============================================================================*/
USE [master];
GO
DECLARE @AgentAccount sysname = NULL,   -- NULL = read from sys.dm_server_services, e.g. N'NT SERVICE\SQLAgent$MARS01'
        @sql nvarchar(max), @isSysadmin int;

IF @AgentAccount IS NULL
    SELECT TOP (1) @AgentAccount = service_account FROM sys.dm_server_services WHERE servicename LIKE N'SQL Server Agent%';
PRINT N'SQL Agent service account: ' + ISNULL(@AgentAccount, N'(not found - set @AgentAccount)');
IF @AgentAccount IS NULL RETURN;

-- the Agent process also carries its service SID (NT SERVICE\SQLSERVERAGENT / NT SERVICE\SQLAgent$<instance>),
-- which SQL Server setup adds as sysadmin
SELECT @isSysadmin = MAX(IS_SRVROLEMEMBER(N'sysadmin', name))
FROM sys.server_principals WHERE name = @AgentAccount OR name LIKE N'NT SERVICE\SQL%Agent%';
IF @isSysadmin = 1
    PRINT N'The Agent service account is sysadmin here: it can already send Database Mail. Nothing to do.';
ELSE
BEGIN
    IF SUSER_ID(@AgentAccount) IS NULL
    BEGIN
        SET @sql = N'CREATE LOGIN ' + QUOTENAME(@AgentAccount) + N' FROM WINDOWS;';
        EXEC (@sql);
        PRINT N'Windows login created: ' + @AgentAccount;
    END;
    SET @sql = N'USE msdb;
IF USER_ID(N''' + REPLACE(@AgentAccount, N'''', N'''''') + N''') IS NULL CREATE USER ' + QUOTENAME(@AgentAccount) + N' FOR LOGIN ' + QUOTENAME(@AgentAccount) + N';
ALTER ROLE DatabaseMailUserRole ADD MEMBER ' + QUOTENAME(@AgentAccount) + N';';
    EXEC (@sql);
    PRINT N'msdb DatabaseMailUserRole granted to ' + @AgentAccount + N' (Database Mail profile must be public or granted to it).';
END;
GO

/*=============================================================================
  SECTION C - REFERENCE (don't run as a whole; copy what you need)
=============================================================================*/
/*
-- Change the password (all instances), then hand it to the collector again on the coordinator:
--   delete C:\DBA\PerfCheck\PerfCheck.NT_SERVICE_SQLAgent$MARS01.cred and run
--   Collect-PerfCheckReports.ps1 -SaveCredentialFor "NT SERVICE\SQLAgent$MARS01"
ALTER LOGIN [dba_perfcheck] WITH PASSWORD = N'<new password>';

-- Login used by the older version of this check: remove the rights it no longer needs
REVOKE VIEW SERVER STATE, ALTER SETTINGS, ALTER ANY EVENT SESSION, VIEW ANY DEFINITION FROM [dba_perfcheck];
USE master; IF USER_ID(N'dba_perfcheck') IS NOT NULL DROP USER [dba_perfcheck];
USE msdb;   IF USER_ID(N'dba_perfcheck') IS NOT NULL DROP USER [dba_perfcheck];

-- Remove everything
USE DBAdmin; IF USER_ID(N'dba_perfcheck') IS NOT NULL DROP USER [dba_perfcheck];
USE master;  IF SUSER_ID(N'dba_perfcheck') IS NOT NULL DROP LOGIN [dba_perfcheck];
*/
