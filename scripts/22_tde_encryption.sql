/*******************************************************************************
 File    : 22_tde_encryption.sql
 Purpose : TDE status & progress, certificates/keys (expiry, backups), backup
           encryption, AG cert consistency, Always Encrypted inventory,
           TDE setup/rotation/migration templates.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] Managed Instance   [SQLDB] Azure SQL DB
 WARNING : Losing the TDE certificate + private key = losing the database
           (and its backups). Check 22.3 pvt_key_last_backup_date regularly.
*******************************************************************************/

/*=============================================================================
  22.1 TDE STATUS PER DATABASE + PROTECTING CERTIFICATE        [BOX][MI][SQLDB]
  encryption_scan_state_desc needs 2019+ (remove that column on older builds).
  tempdb shows as encrypted automatically once any user DB uses TDE.
=============================================================================*/
SELECT DB_NAME(dek.database_id) AS database_name,
       dek.encryption_state,
       CASE dek.encryption_state WHEN 0 THEN 'No key' WHEN 1 THEN 'Unencrypted'
            WHEN 2 THEN 'Encryption in progress' WHEN 3 THEN 'ENCRYPTED'
            WHEN 4 THEN 'Key change in progress' WHEN 5 THEN 'Decryption in progress'
            WHEN 6 THEN 'Protection change in progress' END AS encryption_state_desc,
       dek.percent_complete,
       dek.encryption_scan_state_desc, dek.encryption_scan_modify_date,      -- 2019+
       dek.key_algorithm, dek.key_length,
       dek.encryptor_type,                          -- CERTIFICATE / ASYMMETRIC KEY (EKM / Azure Key Vault)
       c.name AS certificate_name, c.expiry_date AS cert_expiry, c.pvt_key_last_backup_date,
       dek.create_date, dek.regenerate_date, dek.set_date
FROM sys.dm_database_encryption_keys AS dek
LEFT JOIN master.sys.certificates AS c ON c.thumbprint = dek.encryptor_thumbprint
ORDER BY database_name;


/*=============================================================================
  22.2 USER DATABASES NOT ENCRYPTED                                    [BOX][MI]
=============================================================================*/
SELECT d.name, d.is_encrypted, d.state_desc
FROM sys.databases AS d
LEFT JOIN sys.dm_database_encryption_keys AS dek ON dek.database_id = d.database_id
WHERE d.database_id > 4
  AND ISNULL(dek.encryption_state, 1) <> 3
ORDER BY d.name;


/*=============================================================================
  22.3 CERTIFICATES IN MASTER - EXPIRY & PRIVATE KEY BACKUP           [BOX][MI]
  Note: an EXPIRED TDE cert keeps working for TDE - but rotate it anyway
  for compliance. A cert with pvt_key_last_backup_date NULL = never backed up!
=============================================================================*/
SELECT c.name, c.subject, c.start_date, c.expiry_date,
       DATEDIFF(DAY, GETDATE(), c.expiry_date) AS days_to_expiry,
       c.pvt_key_encryption_type_desc, c.pvt_key_last_backup_date,
       c.thumbprint,
       CASE WHEN EXISTS (SELECT 1 FROM sys.dm_database_encryption_keys AS d WHERE d.encryptor_thumbprint = c.thumbprint)
            THEN 'Used by TDE' ELSE '' END AS tde_usage,
       CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.backupset AS b WHERE b.encryptor_thumbprint = c.thumbprint)
            THEN 'Used for backup encryption' ELSE '' END AS backup_usage
FROM master.sys.certificates AS c
WHERE c.name NOT LIKE N'##%'
ORDER BY c.expiry_date;


/*=============================================================================
  22.4 DATABASE MASTER KEY (master DB) & SERVICE MASTER KEY            [BOX][MI]
  is_master_key_encrypted_by_server = 1 -> DMK opens automatically at startup.
=============================================================================*/
SELECT name, is_master_key_encrypted_by_server, is_encrypted, is_trustworthy_on
FROM sys.databases
WHERE name = N'master';

SELECT name, algorithm_desc, key_length, create_date, modify_date
FROM master.sys.symmetric_keys
WHERE name IN (N'##MS_DatabaseMasterKey##', N'##MS_ServiceMasterKey##');


/*=============================================================================
  22.5 TDE PROGRESS (encryption / decryption scan)              [BOX][MI][SQLDB]
=============================================================================*/
SELECT DB_NAME(database_id) AS database_name, encryption_state, percent_complete,
       encryption_scan_state_desc        -- 2019+: RUNNING / SUSPENDED / COMPLETE
FROM sys.dm_database_encryption_keys
WHERE encryption_state IN (2, 4, 5, 6);
-- 2019+: ALTER DATABASE [YourDB] SET ENCRYPTION SUSPEND;   / ... RESUME;


/*=============================================================================
  22.6 ENCRYPTED BACKUPS - WHICH CERT / ALGORITHM                     [BOX][MI]
=============================================================================*/
SELECT TOP (50) bs.database_name, bs.type, bs.backup_finish_date,
       bs.key_algorithm, bs.encryptor_type, bs.encryptor_thumbprint,
       c.name AS certificate_name,
       CASE WHEN dek.database_id IS NOT NULL THEN 'TDE' ELSE '' END AS db_is_tde
FROM msdb.dbo.backupset AS bs
LEFT JOIN master.sys.certificates AS c ON c.thumbprint = bs.encryptor_thumbprint
LEFT JOIN sys.dm_database_encryption_keys AS dek ON dek.database_id = DB_ID(bs.database_name) AND dek.encryption_state = 3
ORDER BY bs.backup_finish_date DESC;


/*=============================================================================
  22.7 ALWAYS ON + TDE: CERT THUMBPRINTS TO COMPARE ACROSS REPLICAS    [BOX]
  Run on EVERY replica - each TDE thumbprint must exist on all of them,
  otherwise the DB can't come online there after failover / seeding fails.
=============================================================================*/
SELECT @@SERVERNAME AS replica, DB_NAME(dek.database_id) AS database_name,
       dek.encryptor_thumbprint,
       c.name AS cert_on_this_replica,
       CASE WHEN c.thumbprint IS NULL THEN 'MISSING ON THIS REPLICA' ELSE 'OK' END AS status
FROM sys.dm_database_encryption_keys AS dek
LEFT JOIN master.sys.certificates AS c ON c.thumbprint = dek.encryptor_thumbprint
WHERE dek.database_id > 4;


/*=============================================================================
  22.8 EKM / AZURE KEY VAULT (customer-managed keys)                   [BOX][MI]
=============================================================================*/
SELECT * FROM sys.cryptographic_providers;
SELECT name, algorithm_desc, key_length, provider_type, thumbprint, cryptographic_provider_guid
FROM master.sys.asymmetric_keys;
SELECT name, credential_identity, target_type FROM sys.credentials;
-- Azure SQL DB / MI: TDE protector (service-managed vs AKV) is set at server level:
--   Get-AzSqlServerTransparentDataEncryptionProtector / Get-AzSqlInstanceTransparentDataEncryptionProtector


/*=============================================================================
  22.9 ALWAYS ENCRYPTED INVENTORY - CURRENT DB                 [BOX][MI][SQLDB]
=============================================================================*/
SELECT OBJECT_SCHEMA_NAME(c.object_id) + N'.' + OBJECT_NAME(c.object_id) AS table_name,
       c.name AS column_name, c.encryption_type_desc, c.encryption_algorithm_name,
       cek.name AS column_encryption_key
FROM sys.columns AS c
JOIN sys.column_encryption_keys AS cek ON cek.column_encryption_key_id = c.column_encryption_key_id
ORDER BY table_name, column_name;

SELECT cmk.name AS column_master_key, cmk.key_store_provider_name, cmk.key_path,
       cmk.allow_enclave_computations,             -- 2019+ secure enclaves
       cek.name AS column_encryption_key
FROM sys.column_master_keys AS cmk
LEFT JOIN sys.column_encryption_key_values AS v ON v.column_master_key_id = cmk.column_master_key_id
LEFT JOIN sys.column_encryption_keys AS cek ON cek.column_encryption_key_id = v.column_encryption_key_id;


/*=============================================================================
  22.10 TEMPLATES - ENABLE TDE                                         [BOX]
=============================================================================*/
/*
USE master;
CREATE MASTER KEY ENCRYPTION BY PASSWORD = N'<strong password>';     -- once per instance
CREATE CERTIFICATE TDE_Cert_2026 WITH SUBJECT = N'TDE certificate 2026', EXPIRY_DATE = '2031-12-31';

-- BACK UP THE CERT IMMEDIATELY and store it off-server:
BACKUP CERTIFICATE TDE_Cert_2026
  TO FILE = N'\\secure\share\TDE_Cert_2026.cer'
  WITH PRIVATE KEY (FILE = N'\\secure\share\TDE_Cert_2026.pvk',
                    ENCRYPTION BY PASSWORD = N'<another strong password>');

USE [YourDB];
CREATE DATABASE ENCRYPTION KEY WITH ALGORITHM = AES_256
  ENCRYPTION BY SERVER CERTIFICATE TDE_Cert_2026;
ALTER DATABASE [YourDB] SET ENCRYPTION ON;
-- Monitor with 22.5
*/


/*=============================================================================
  22.11 TEMPLATES - RESTORE TDE DB ON ANOTHER SERVER / AG REPLICA       [BOX]
=============================================================================*/
/*
-- On the target (each AG secondary BEFORE adding the DB to the AG):
USE master;
CREATE MASTER KEY ENCRYPTION BY PASSWORD = N'<password>';           -- if not already there
CREATE CERTIFICATE TDE_Cert_2026
  FROM FILE = N'\\secure\share\TDE_Cert_2026.cer'
  WITH PRIVATE KEY (FILE = N'\\secure\share\TDE_Cert_2026.pvk',
                    DECRYPTION BY PASSWORD = N'<another strong password>');
-- Then RESTORE DATABASE / add to AG as usual.
*/


/*=============================================================================
  22.12 TEMPLATES - ROTATE CERT / DISABLE TDE                          [BOX]
=============================================================================*/
/*
-- Rotate protector (fast - only the DEK is re-encrypted, no data scan):
USE master;  CREATE CERTIFICATE TDE_Cert_2027 WITH SUBJECT = N'TDE 2027';
             -- BACKUP CERTIFICATE TDE_Cert_2027 ... (as above) and copy to all AG replicas FIRST
USE [YourDB]; ALTER DATABASE ENCRYPTION KEY ENCRYPTION BY SERVER CERTIFICATE TDE_Cert_2027;
-- Keep the OLD cert as long as any backup encrypted with it might be restored.

-- Remove TDE (full data scan):
ALTER DATABASE [YourDB] SET ENCRYPTION OFF;          -- wait for state 1 in 22.5
USE [YourDB]; DROP DATABASE ENCRYPTION KEY;
*/
