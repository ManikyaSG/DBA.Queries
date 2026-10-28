/*******************************************************************************
 File    : 13_security.sql
 Purpose : Logins, privileged access, orphaned users, permissions, TDE, audit.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] Managed Instance   [SQLDB] Azure SQL DB
*******************************************************************************/

/*=============================================================================
  13.1 SERVER ROLE MEMBERS (who is sysadmin etc.)                     [BOX][MI]
=============================================================================*/
SELECT r.name AS server_role, m.name AS member_name, m.type_desc, m.is_disabled,
       m.create_date, m.modify_date
FROM sys.server_role_members AS rm
JOIN sys.server_principals AS r ON r.principal_id = rm.role_principal_id
JOIN sys.server_principals AS m ON m.principal_id = rm.member_principal_id
ORDER BY CASE r.name WHEN N'sysadmin' THEN 0 ELSE 1 END, r.name, m.name;


/*=============================================================================
  13.2 LOGINS - STATUS, POLICY, LAST PASSWORD CHANGE                  [BOX][MI]
=============================================================================*/
SELECT sp.name, sp.type_desc, sp.is_disabled, sp.default_database_name,
       sl.is_policy_checked, sl.is_expiration_checked,
       LOGINPROPERTY(sp.name, 'PasswordLastSetTime') AS password_last_set,
       LOGINPROPERTY(sp.name, 'IsLocked')            AS is_locked,
       LOGINPROPERTY(sp.name, 'IsExpired')           AS is_expired,
       LOGINPROPERTY(sp.name, 'BadPasswordCount')    AS bad_password_count,
       sp.create_date, sp.modify_date
FROM sys.server_principals AS sp
LEFT JOIN sys.sql_logins AS sl ON sl.principal_id = sp.principal_id
WHERE sp.type IN ('S', 'U', 'G', 'E', 'X')        -- SQL, Win user, Win group, Entra user, Entra group
  AND sp.name NOT LIKE N'##%'
ORDER BY sp.type_desc, sp.name;


/*=============================================================================
  13.3 WEAK SQL LOGIN PASSWORDS (blank or = login name)               [BOX][MI]
=============================================================================*/
SELECT name,
       CASE WHEN PWDCOMPARE(N'', password_hash) = 1 THEN 'BLANK PASSWORD'
            WHEN PWDCOMPARE(name, password_hash) = 1 THEN 'PASSWORD = LOGIN NAME' END AS finding
FROM sys.sql_logins
WHERE PWDCOMPARE(N'', password_hash) = 1
   OR PWDCOMPARE(name, password_hash) = 1;


/*=============================================================================
  13.4 HIGH-RISK SERVER PERMISSIONS (CONTROL SERVER, IMPERSONATE...)  [BOX][MI]
=============================================================================*/
SELECT SUSER_NAME(sp.grantee_principal_id) AS grantee, sp.permission_name, sp.state_desc,
       sp.class_desc, SUSER_NAME(sp.grantor_principal_id) AS grantor
FROM sys.server_permissions AS sp
WHERE sp.permission_name IN (N'CONTROL SERVER', N'IMPERSONATE', N'ALTER ANY LOGIN',
        N'ALTER ANY SERVER ROLE', N'ALTER SERVER STATE', N'VIEW SERVER STATE',
        N'ALTER ANY DATABASE', N'ADMINISTER BULK OPERATIONS', N'UNSAFE ASSEMBLY')
  AND SUSER_NAME(sp.grantee_principal_id) NOT LIKE N'##%'
ORDER BY sp.permission_name, grantee;


/*=============================================================================
  13.5 ORPHANED USERS - CURRENT DB (+ fix statement)           [BOX][MI]
=============================================================================*/
SELECT dp.name AS user_name, dp.type_desc, dp.sid,
       N'ALTER USER ' + QUOTENAME(dp.name) + N' WITH LOGIN = ' + QUOTENAME(dp.name) + N';' AS fix_if_login_exists
FROM sys.database_principals AS dp
LEFT JOIN sys.server_principals AS sp ON sp.sid = dp.sid
WHERE sp.sid IS NULL
  AND dp.type IN ('S', 'U', 'G')
  AND dp.authentication_type_desc IN (N'INSTANCE', N'WINDOWS')   -- excludes contained users
  AND dp.name NOT IN (N'dbo', N'guest', N'INFORMATION_SCHEMA', N'sys')
  AND dp.principal_id > 4;


/*=============================================================================
  13.6 DATABASE ROLE MEMBERS - CURRENT DB                      [BOX][MI][SQLDB]
=============================================================================*/
SELECT r.name AS db_role, m.name AS member_name, m.type_desc, m.authentication_type_desc
FROM sys.database_role_members AS drm
JOIN sys.database_principals AS r ON r.principal_id = drm.role_principal_id
JOIN sys.database_principals AS m ON m.principal_id = drm.member_principal_id
ORDER BY CASE r.name WHEN N'db_owner' THEN 0 ELSE 1 END, r.name, m.name;


/*=============================================================================
  13.7 EXPLICIT PERMISSIONS - CURRENT DB                       [BOX][MI][SQLDB]
=============================================================================*/
SELECT pr.name AS principal_name, pr.type_desc, pe.state_desc, pe.permission_name,
       pe.class_desc,
       CASE pe.class WHEN 0 THEN DB_NAME()
                     WHEN 1 THEN OBJECT_SCHEMA_NAME(pe.major_id) + N'.' + OBJECT_NAME(pe.major_id)
                     WHEN 3 THEN SCHEMA_NAME(pe.major_id) END AS securable,
       COL_NAME(pe.major_id, pe.minor_id) AS column_name
FROM sys.database_permissions AS pe
JOIN sys.database_principals  AS pr ON pr.principal_id = pe.grantee_principal_id
WHERE pr.name NOT IN (N'public', N'guest') OR pe.permission_name <> N'CONNECT'
ORDER BY principal_name, securable;


/*=============================================================================
  13.8 EVERYTHING ONE LOGIN CAN DO (effective permissions)     [BOX][MI][SQLDB]
=============================================================================*/
/*
EXECUTE AS LOGIN = N'DOMAIN\someone';
SELECT * FROM fn_my_permissions(NULL, 'SERVER');
SELECT * FROM fn_my_permissions(NULL, 'DATABASE');
REVERT;
*/


/*=============================================================================
  13.9 GUEST ENABLED IN USER DATABASES (should be off)                [BOX][MI]
=============================================================================*/
IF OBJECT_ID('tempdb..#guest') IS NOT NULL DROP TABLE #guest;
CREATE TABLE #guest (database_name sysname, guest_has_connect bit);
DECLARE @sql nvarchar(max) = N'';
SELECT @sql += N'USE ' + QUOTENAME(name) + N'; INSERT #guest SELECT DB_NAME(), 1 FROM sys.database_permissions
  WHERE grantee_principal_id = DATABASE_PRINCIPAL_ID(''guest'') AND permission_name = ''CONNECT'' AND state IN (''G'',''W'');
'
FROM sys.databases WHERE database_id > 4 AND state_desc = N'ONLINE' AND HAS_DBACCESS(name) = 1;
EXEC sys.sp_executesql @sql;
SELECT * FROM #guest;


/*=============================================================================
  13.10 RISKY DATABASE SETTINGS (TRUSTWORTHY, odd owners, chaining)   [BOX][MI]
=============================================================================*/
SELECT name, SUSER_SNAME(owner_sid) AS owner_name, is_trustworthy_on, is_db_chaining_on,
       containment_desc
FROM sys.databases
WHERE (is_trustworthy_on = 1 AND name <> N'msdb')
   OR is_db_chaining_on = 1
   OR SUSER_SNAME(owner_sid) IS NULL
ORDER BY name;


/*=============================================================================
  13.11 TDE STATUS & CERTIFICATE EXPIRY                        [BOX][MI][SQLDB]
=============================================================================*/
SELECT DB_NAME(dek.database_id) AS database_name, dek.encryption_state,
       CASE dek.encryption_state WHEN 0 THEN 'No key' WHEN 1 THEN 'Unencrypted'
            WHEN 2 THEN 'Encryption in progress' WHEN 3 THEN 'Encrypted'
            WHEN 4 THEN 'Key change in progress' WHEN 5 THEN 'Decryption in progress'
            WHEN 6 THEN 'Protection change in progress' END AS state_desc,
       dek.percent_complete, dek.key_algorithm, dek.key_length,
       dek.encryptor_type, dek.encryptor_thumbprint
FROM sys.dm_database_encryption_keys AS dek;

-- Certificates in master (TDE / backup encryption) - BACK THESE UP! [BOX]
SELECT name, subject, start_date, expiry_date, thumbprint, pvt_key_encryption_type_desc,
       pvt_key_last_backup_date,
       DATEDIFF(DAY, GETDATE(), expiry_date) AS days_to_expiry
FROM master.sys.certificates
WHERE name NOT LIKE N'##%'
ORDER BY expiry_date;


/*=============================================================================
  13.12 UNENCRYPTED CONNECTIONS                                [BOX][MI][SQLDB]
=============================================================================*/
SELECT c.encrypt_option, c.auth_scheme, c.net_transport, COUNT(*) AS connections
FROM sys.dm_exec_connections AS c
GROUP BY c.encrypt_option, c.auth_scheme, c.net_transport;


/*=============================================================================
  13.13 FAILED LOGINS FROM ERROR LOG                                  [BOX]
  Requires login auditing = "Failed logins only" or "Both".
=============================================================================*/
EXEC sys.xp_readerrorlog 0, 1, N'Login failed';


/*=============================================================================
  13.14 SQL SERVER AUDIT STATUS                                       [BOX][MI]
=============================================================================*/
SELECT a.name, a.type_desc, a.on_failure_desc, a.is_state_enabled, s.status_desc, s.audit_file_path
FROM sys.server_audits AS a
LEFT JOIN sys.dm_server_audit_status AS s ON s.audit_id = a.audit_id;

SELECT sas.name AS server_audit_spec, sas.is_state_enabled, sasd.audit_action_name
FROM sys.server_audit_specifications AS sas
JOIN sys.server_audit_specification_details AS sasd ON sasd.server_specification_id = sas.server_specification_id;


/*=============================================================================
  13.15 LINKED SERVERS & THEIR LOGIN MAPPINGS                         [BOX][MI]
=============================================================================*/
SELECT s.name, s.product, s.provider, s.data_source, s.is_rpc_out_enabled, s.is_data_access_enabled,
       ll.uses_self_credential, ll.remote_name, SUSER_NAME(ll.local_principal_id) AS local_login
FROM sys.servers AS s
LEFT JOIN sys.linked_logins AS ll ON ll.server_id = s.server_id
WHERE s.is_linked = 1;


/*=============================================================================
  13.16 AZURE SQL DB - FIREWALL RULES & ENTRA ADMINS                   [SQLDB]
=============================================================================*/
-- In master:      SELECT * FROM sys.firewall_rules;
-- In user DB:     SELECT * FROM sys.database_firewall_rules;
-- Entra users:    SELECT name, type_desc, authentication_type_desc FROM sys.database_principals WHERE type IN ('E','X');
