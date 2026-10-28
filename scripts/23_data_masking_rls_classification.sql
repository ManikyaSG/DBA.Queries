/*******************************************************************************
 File    : 23_data_masking_rls_classification.sql
 Purpose : Dynamic Data Masking (DDM), who can UNMASK, Row-Level Security,
           data classification (sensitivity labels), sensitive-column finder.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] Managed Instance   [SQLDB] Azure SQL DB
 Note    : All queries run in the CURRENT database (USE YourDB).
           DDM is NOT a security boundary against users who can run ad-hoc
           queries (inference attacks) - pair it with permissions / AE / RLS.
*******************************************************************************/

/*=============================================================================
  23.1 MASKED COLUMNS                                          [BOX][MI][SQLDB]
=============================================================================*/
SELECT OBJECT_SCHEMA_NAME(mc.object_id) + N'.' + OBJECT_NAME(mc.object_id) AS table_name,
       mc.name AS column_name, TYPE_NAME(mc.user_type_id) AS data_type, mc.max_length,
       mc.masking_function
FROM sys.masked_columns AS mc
WHERE mc.is_masked = 1
ORDER BY table_name, column_name;


/*=============================================================================
  23.2 WHO CAN SEE UNMASKED DATA                               [BOX][MI][SQLDB]
  - Explicit UNMASK grants (2022+/Azure: can be DB, schema, table or column level)
  - db_owner members and CONTROL holders see everything regardless
=============================================================================*/
SELECT pr.name AS principal_name, pr.type_desc, pe.state_desc, pe.permission_name, pe.class_desc,
       CASE pe.class WHEN 0 THEN N'DATABASE'
                     WHEN 1 THEN OBJECT_SCHEMA_NAME(pe.major_id) + N'.' + OBJECT_NAME(pe.major_id)
                                 + ISNULL(N'.' + COL_NAME(pe.major_id, NULLIF(pe.minor_id, 0)), N'')
                     WHEN 3 THEN N'SCHEMA::' + SCHEMA_NAME(pe.major_id) END AS scope
FROM sys.database_permissions AS pe
JOIN sys.database_principals  AS pr ON pr.principal_id = pe.grantee_principal_id
WHERE pe.permission_name IN (N'UNMASK', N'CONTROL')
ORDER BY principal_name;

SELECT m.name AS db_owner_member, m.type_desc
FROM sys.database_role_members AS drm
JOIN sys.database_principals AS r ON r.principal_id = drm.role_principal_id AND r.name = N'db_owner'
JOIN sys.database_principals AS m ON m.principal_id = drm.member_principal_id;


/*=============================================================================
  23.3 TEST WHAT A USER ACTUALLY SEES                          [BOX][MI][SQLDB]
=============================================================================*/
/*
EXECUTE AS USER = N'ReportUser';
SELECT TOP (10) * FROM dbo.Customers;      -- should show masked values
REVERT;
*/


/*=============================================================================
  23.4 POSSIBLY SENSITIVE COLUMNS NOT MASKED (name-based finder) [BOX][MI][SQLDB]
=============================================================================*/
SELECT OBJECT_SCHEMA_NAME(c.object_id) + N'.' + OBJECT_NAME(c.object_id) AS table_name,
       c.name AS column_name, TYPE_NAME(c.user_type_id) AS data_type,
       CASE WHEN mc.is_masked = 1 THEN 'MASKED' ELSE 'not masked' END AS mask_status,
       CASE WHEN c.encryption_type IS NOT NULL THEN 'ALWAYS ENCRYPTED' ELSE '' END AS ae_status
FROM sys.columns AS c
JOIN sys.tables AS t ON t.object_id = c.object_id AND t.is_ms_shipped = 0
LEFT JOIN sys.masked_columns AS mc ON mc.object_id = c.object_id AND mc.column_id = c.column_id
WHERE c.name LIKE N'%email%'  OR c.name LIKE N'%phone%'   OR c.name LIKE N'%mobile%'
   OR c.name LIKE N'%ssn%'    OR c.name LIKE N'%pan%'     OR c.name LIKE N'%aadhaar%'
   OR c.name LIKE N'%passport%' OR c.name LIKE N'%card%'  OR c.name LIKE N'%account%'
   OR c.name LIKE N'%iban%'   OR c.name LIKE N'%salary%'  OR c.name LIKE N'%dob%'
   OR c.name LIKE N'%birth%'  OR c.name LIKE N'%address%' OR c.name LIKE N'%password%'
   OR c.name LIKE N'%tax%'    OR c.name LIKE N'%national%'
ORDER BY mask_status DESC, table_name, column_name;


/*=============================================================================
  23.5 ADD / CHANGE / DROP MASKS (templates)                   [BOX][MI][SQLDB]
=============================================================================*/
/*
ALTER TABLE dbo.Customers ALTER COLUMN Email     ADD MASKED WITH (FUNCTION = 'email()');
ALTER TABLE dbo.Customers ALTER COLUMN Phone     ADD MASKED WITH (FUNCTION = 'partial(0,"XXXXXX",4)');
ALTER TABLE dbo.Customers ALTER COLUMN CardNo    ADD MASKED WITH (FUNCTION = 'partial(0,"XXXX-XXXX-XXXX-",4)');
ALTER TABLE dbo.Customers ALTER COLUMN Salary    ADD MASKED WITH (FUNCTION = 'random(1, 100)');
ALTER TABLE dbo.Customers ALTER COLUMN Notes     ADD MASKED WITH (FUNCTION = 'default()');
ALTER TABLE dbo.Customers ALTER COLUMN BirthDate ADD MASKED WITH (FUNCTION = 'datetime("Y")');   -- 2022+/Azure

ALTER TABLE dbo.Customers ALTER COLUMN Email DROP MASKED;

GRANT UNMASK TO [SupportLead];                               -- whole DB
GRANT UNMASK ON SCHEMA::Sales TO [SalesManager];             -- 2022+/Azure granular
GRANT UNMASK ON dbo.Customers(Email) TO [CRMService];        -- 2022+/Azure column-level
REVOKE UNMASK TO [SupportLead];
*/


/*=============================================================================
  23.6 ROW-LEVEL SECURITY POLICIES & PREDICATES                [BOX][MI][SQLDB]
=============================================================================*/
SELECT sp.name AS policy_name, sp.is_enabled, sp.is_schema_bound,
       OBJECT_SCHEMA_NAME(pr.target_object_id) + N'.' + OBJECT_NAME(pr.target_object_id) AS target_table,
       pr.predicate_type_desc, pr.operation_desc, pr.predicate_definition
FROM sys.security_policies AS sp
JOIN sys.security_predicates AS pr ON pr.object_id = sp.object_id
ORDER BY policy_name, target_table;
-- ALTER SECURITY POLICY [Sales.RLS_Policy] WITH (STATE = OFF);   -- temporarily disable


/*=============================================================================
  23.7 DATA CLASSIFICATION / SENSITIVITY LABELS (2019+, Azure) [BOX][MI][SQLDB]
=============================================================================*/
SELECT OBJECT_SCHEMA_NAME(sc.major_id) + N'.' + OBJECT_NAME(sc.major_id) AS table_name,
       COL_NAME(sc.major_id, sc.minor_id) AS column_name,
       sc.label, sc.information_type, sc.rank_desc
FROM sys.sensitivity_classifications AS sc
ORDER BY sc.rank DESC, table_name;

/*
ADD SENSITIVITY CLASSIFICATION TO dbo.Customers.Email
WITH (LABEL = 'Confidential - GDPR', INFORMATION_TYPE = 'Contact Info', RANK = MEDIUM);
DROP SENSITIVITY CLASSIFICATION FROM dbo.Customers.Email;
*/


/*=============================================================================
  23.8 PROTECTION SUMMARY PER TABLE                            [BOX][MI][SQLDB]
=============================================================================*/
SELECT OBJECT_SCHEMA_NAME(t.object_id) + N'.' + t.name AS table_name,
       (SELECT COUNT(*) FROM sys.masked_columns mc WHERE mc.object_id = t.object_id AND mc.is_masked = 1)   AS masked_cols,
       (SELECT COUNT(*) FROM sys.columns c WHERE c.object_id = t.object_id AND c.encryption_type IS NOT NULL) AS always_encrypted_cols,
       (SELECT COUNT(*) FROM sys.sensitivity_classifications s WHERE s.major_id = t.object_id)             AS classified_cols,
       CASE WHEN EXISTS (SELECT 1 FROM sys.security_predicates p WHERE p.target_object_id = t.object_id)
            THEN 'Yes' ELSE 'No' END AS has_rls
FROM sys.tables AS t
WHERE t.is_ms_shipped = 0
ORDER BY masked_cols + always_encrypted_cols + classified_cols DESC, table_name;
