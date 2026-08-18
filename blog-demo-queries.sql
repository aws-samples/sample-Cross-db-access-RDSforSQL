-- ================================================================
-- BLOG DEMO: Cross-database access using module signing on RDS
-- (Secrets Manager edition)
--
-- This demo assumes you deployed the CloudFormation stack
-- (rds-crossdb-lab-secretsmanager.yaml) and are running from
-- the EC2 workload driver via SSM Session Manager.
--
-- All passwords are stored in AWS Secrets Manager and retrieved
-- at runtime — nothing is hardcoded.
--
-- Run each section one at a time and observe the results.
-- ================================================================

-- ================================================================
-- PREREQUISITES
-- ================================================================
-- 1. Deploy the CloudFormation stack:
--      aws cloudformation create-stack \
--        --stack-name rds-crossdb-lab \
--        --template-body file://rds-crossdb-lab-secretsmanager.yaml \
--        --capabilities CAPABILITY_IAM --region us-east-1
--
-- 2. Connect to the EC2 instance:
--      aws ssm start-session --target <InstanceId> --region us-east-1
--      sudo su - ec2-user
--
-- 3. Fetch passwords from Secrets Manager:
--      source ./fetch_secrets.sh
--
-- 4. Connect as admin (use -N for encrypted, validated TLS — do NOT use -C):
--    The EC2 workload driver already has the RDS CA bundle in its system trust
--    store (installed by the CloudFormation UserData), so -N validates the
--    server certificate. Never use -C ("Trust Server Certificate"), which
--    bypasses certificate validation.
--      /opt/mssql-tools18/bin/sqlcmd \
--        -S "$RDS_ENDPOINT,1433" -U "$ADMIN_USER" -P "$ADMIN_PASS" -N
--
-- The environment variables below are set by fetch_secrets.sh:
--   $ADMIN_PASS      - RDS master password
--   $APP_USER_PASS   - AppUser login password
--   $MK_A_PASS       - DatabaseA master key password
--   $MK_B_PASS       - DatabaseB master key password
--   $CERT_XFER_PASS  - Certificate transfer password
-- ================================================================

-- ================================================================
-- PART 1: SETUP (run as admin)
-- ================================================================

-- 1a. Create the two databases
IF DB_ID('DatabaseA') IS NULL CREATE DATABASE DatabaseA;
GO
IF DB_ID('DatabaseB') IS NULL CREATE DATABASE DatabaseB;
GO

-- 1b. Create target table in DatabaseB with sample data
--     NOTE: CustomerName/CreditScore below is SYNTHETIC data for this lab/demo
--     only. If you adapt this pattern for real credit or financial data, PCI-DSS
--     controls and AWS shared-responsibility obligations apply. See
--     https://aws.amazon.com/compliance/ for guidance on regulated data workloads.
USE DatabaseB;
GO
IF OBJECT_ID('dbo.SecretData', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.SecretData (
        Id           INT PRIMARY KEY,
        CustomerName VARCHAR(100),
        CreditScore  INT
    );
    INSERT INTO dbo.SecretData VALUES
        (1, 'Acme Corp',  780),
        (2, 'Globex Inc', 720);
END
GO

-- 1c. Create limited login and user
--     NOTE: Password is retrieved from Secrets Manager ($APP_USER_PASS).
--     If running interactively, replace <APP_USER_PASSWORD> with the value from:
--       aws secretsmanager get-secret-value --secret-id <AppUserSecretArn> \
--         --query 'SecretString' --output text | jq -r '.password'
USE master;
GO
IF SUSER_ID('AppUser') IS NULL
    CREATE LOGIN AppUser
        WITH PASSWORD = '<APP_USER_PASSWORD>',  -- Retrieved from Secrets Manager
             CHECK_POLICY = OFF,
             DEFAULT_DATABASE = DatabaseA;
GO

USE DatabaseA;
GO
IF USER_ID('AppUser') IS NULL CREATE USER AppUser FOR LOGIN AppUser;
GRANT EXECUTE TO AppUser;
GO

-- 1d. Create the cross-database stored procedure (unsigned)
IF OBJECT_ID('dbo.GetSecretData', 'P') IS NOT NULL
    DROP PROCEDURE dbo.GetSecretData;
GO
CREATE PROCEDURE dbo.GetSecretData
AS
    SELECT Id, CustomerName, CreditScore
    FROM DatabaseB.dbo.SecretData;
GO

-- ================================================================
-- PART 2: DEMONSTRATE THE PROBLEM
-- ================================================================

-- 2a. Confirm TRUSTWORTHY is OFF on both databases
SELECT name, is_trustworthy_on
FROM sys.databases
WHERE name IN ('DatabaseA', 'DatabaseB');
GO
-- EXPECTED: Both show 0

-- 2b. Try to enable TRUSTWORTHY (fails on RDS)
ALTER DATABASE DatabaseA SET TRUSTWORTHY ON;
GO
-- EXPECTED: Msg 15247 - User does not have permission

-- 2c. Run procedure as AppUser (fails - Error 916)
--     Connect as AppUser using the password from Secrets Manager
--     (-N for validated TLS; do NOT use -C):
--       /opt/mssql-tools18/bin/sqlcmd \
--         -S "$RDS_ENDPOINT,1433" -U AppUser -P "$APP_USER_PASS" -N -d DatabaseA
USE DatabaseA;
GO
EXEC dbo.GetSecretData;
GO
-- EXPECTED: Msg 916 - cannot access database "DatabaseB"

-- ================================================================
-- PART 3: APPLY THE FIX - MODULE SIGNING (run as admin)
-- ================================================================

-- 3a. Create database master keys
--     NOTE: Passwords retrieved from Secrets Manager ($MK_A_PASS, $MK_B_PASS).
--     If running interactively, replace placeholders with values from:
--       aws secretsmanager get-secret-value --secret-id <DbMasterKeyASecretArn> ...
--       aws secretsmanager get-secret-value --secret-id <DbMasterKeyBSecretArn> ...
USE DatabaseA;
GO
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<MK_A_PASSWORD>';  -- From Secrets Manager
GO

USE DatabaseB;
GO
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<MK_B_PASSWORD>';  -- From Secrets Manager
GO

-- 3b. Create certificate in DatabaseB and map to a user
USE DatabaseB;
GO
IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = 'CrossDBCert')
    CREATE CERTIFICATE CrossDBCert
        WITH SUBJECT = 'Cross-DB access cert';
GO

IF USER_ID('CertUser') IS NULL
    CREATE USER CertUser FROM CERTIFICATE CrossDBCert;
GRANT SELECT ON dbo.SecretData TO CertUser;
GO

-- 3c. Transfer certificate to DatabaseA using dynamic SQL (RDS-compatible)
--     NOTE: The transfer password is retrieved from Secrets Manager ($CERT_XFER_PASS).
--     This approach keeps the full binary server-side — no truncation, no copy-paste.
USE DatabaseB;
GO
DECLARE @cert VARBINARY(MAX) = CERTENCODED(CERT_ID('CrossDBCert'));
DECLARE @key  VARBINARY(MAX) = CERTPRIVATEKEY(CERT_ID('CrossDBCert'), '<CERT_TRANSFER_PASSWORD>');  -- From Secrets Manager
DECLARE @sql  NVARCHAR(MAX);

SET @sql = N'CREATE CERTIFICATE CrossDBCert FROM BINARY = '
         + CONVERT(VARCHAR(MAX), @cert, 1)
         + N' WITH PRIVATE KEY (BINARY = '
         + CONVERT(VARCHAR(MAX), @key, 1)
         + N', DECRYPTION BY PASSWORD = ''<CERT_TRANSFER_PASSWORD>'');';  -- Same password from Secrets Manager

-- Run in the context of DatabaseA
EXEC DatabaseA.dbo.sp_executesql @sql;
GO

-- 3d. Sign the stored procedure
USE DatabaseA;
GO
ADD SIGNATURE TO dbo.GetSecretData
    BY CERTIFICATE CrossDBCert;
GO

-- ================================================================
-- PART 4: VERIFY THE FIX
-- ================================================================

-- 4a. Confirm signature is attached
USE DatabaseA;
GO
SELECT
    OBJECT_NAME(cp.major_id) AS signed_module,
    c.name                   AS certificate_name,
    cp.crypt_type_desc       AS signature_type
FROM sys.crypt_properties cp
JOIN sys.certificates c ON cp.thumbprint = c.thumbprint;
GO
-- EXPECTED: GetSecretData | CrossDBCert | SIGNATURE BY CERTIFICATE

-- 4b. Run procedure as AppUser again (NOW IT WORKS!)
--     Connect as AppUser (-N for validated TLS; do NOT use -C):
--       /opt/mssql-tools18/bin/sqlcmd \
--         -S "$RDS_ENDPOINT,1433" -U AppUser -P "$APP_USER_PASS" -N -d DatabaseA
USE DatabaseA;
GO
EXEC dbo.GetSecretData;
GO
-- EXPECTED: Returns Acme Corp (780) and Globex Inc (720)

-- ================================================================
-- PART 5: PROVE LEAST PRIVILEGE
-- ================================================================

-- 5a. Create identical but UNSIGNED procedure (as admin)
USE DatabaseA;
GO
CREATE PROCEDURE dbo.GetSecretUnsigned
AS
    SELECT Id, CustomerName, CreditScore
    FROM DatabaseB.dbo.SecretData;
GO
GRANT EXECUTE ON dbo.GetSecretUnsigned TO AppUser;
GO

-- 5b. Run unsigned procedure as AppUser (still fails!)
--     Connect as AppUser and run:
USE DatabaseA;
GO
EXEC dbo.GetSecretUnsigned;
GO
-- EXPECTED: Msg 916 - same error as before
-- This proves ONLY the signed procedure gets cross-DB access

-- ================================================================
-- PART 6: CLEANUP
-- ================================================================
-- If using the CloudFormation stack, simply delete the stack:
--   aws cloudformation delete-stack --stack-name rds-crossdb-lab --region us-east-1
--
-- If running manually against an existing RDS instance, use the block below.
-- It is idempotent (safe to re-run) and evicts lingering connections so the
-- drops don't fail with "database is currently in use".
--
-- NOTE: DROP DATABASE cascades - it automatically removes every object the
-- database contains (procedures, certificates, users, master keys, tables), so
-- there is no need to drop those objects individually first. Only the
-- server-level login (AppUser) lives outside the databases and is dropped
-- separately.

USE DatabaseA;
GO
DROP SIGNATURE FROM dbo.GetSecretData BY CERTIFICATE CrossDBCert;
DROP CERTIFICATE CrossDBCert;
DROP PROCEDURE dbo.GetSecretData;
DROP PROCEDURE dbo.GetSecretUnsigned;
DROP USER AppUser;
DROP MASTER KEY;
GO

USE DatabaseB;
GO
DROP USER CertUser;
DROP CERTIFICATE CrossDBCert;
DROP TABLE dbo.SecretData;
DROP MASTER KEY;
GO

USE master;
GO
EXECUTE msdb.dbo.rds_drop_database N'DatabaseA'; EXECUTE msdb.dbo.rds_drop_database N'DatabaseB'; DROP LOGIN AppUser;
GO
