/*******************************************************************************
 File    : 45_database_mail_setup.sql
 Purpose : Make Database Mail usable on an instance, safely re-runnable.
             - Profile missing  -> creates the SMTP account + profile and links them.
             - Profile present but not usable ("disabled") -> fixes whatever is off:
                 'Database Mail XPs' = 0, profile has no account linked, Database Mail
                 service (external program / queue) STOPPED, profile not public/default.
           Existing accounts and profiles are never changed or deleted: anything
           that already exists is reported and left as it is.
 Tags    : [BOX] SQL Server 2016 - 2025 / Azure VM   [MI] (Database Mail works on MI;
           'Database Mail XPs' and msdb broker steps are skipped there)
 Run as  : sysadmin. Set the parameters below, run the whole script, read the
           Messages tab (every action is printed) and the result grid at the end.
 Note    : the SMTP password, if any, is in this script - don't save it with the password.
*******************************************************************************/
SET NOCOUNT ON;

/*=============================================================================
  PARAMETERS  <== change these
=============================================================================*/
DECLARE
    @ProfileName        sysname       = N'DBA_Mail',
    @ProfileDescription nvarchar(256) = N'DBA alerts and reports',
    @AccountName        sysname       = N'DBA_Mail_Account',
    @EmailAddress       nvarchar(128) = N'sqlalerts@yourcompany.com',  -- From address
    @DisplayName        nvarchar(128) = NULL,          -- NULL = '<server name> SQL Server'
    @ReplyTo            nvarchar(128) = NULL,
    @SmtpServer         sysname       = N'smtp.yourcompany.com',
    @SmtpPort           int           = 25,            -- 25 relay, 587 submission (usually with SSL)
    @EnableSSL          bit           = 0,
    @SmtpUser           nvarchar(128) = NULL,          -- NULL = anonymous relay (or Windows, see below)
    @SmtpPassword       nvarchar(128) = NULL,
    @UseDefaultCreds    bit           = 0,             -- 1 = authenticate as the SQL Server service account
    @MakePublicDefault  bit           = 1,             -- profile usable by everyone with DatabaseMailUserRole, and the default
    @SetAgentProfile    bit           = 0,             -- 1 = SQL Agent uses this profile for alerts / job notifications (restart Agent after)
    @FixMsdbBroker      bit           = 0,             -- 1 = enable Service Broker in msdb if it is off (needs exclusive access to msdb!)
    @TestRecipient      nvarchar(256) = NULL;          -- e.g. N'dba-team@yourcompany.com' to send a test email at the end

/*=============================================================================*/
DECLARE @isMI bit = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 8 THEN 1 ELSE 0 END,
        @adv int, @xps int, @msg nvarchar(400), @status nvarchar(20),
        @profileId int, @accountId int, @created bit = 0;
IF @DisplayName IS NULL SET @DisplayName = CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)) + N' SQL Server';

IF IS_SRVROLEMEMBER(N'sysadmin') <> 1
BEGIN
    RAISERROR(N'Run this as sysadmin.', 16, 1);
    RETURN;
END;

PRINT N'=== Database Mail setup on ' + CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)) + N' ===';

/*---- 1. 'Database Mail XPs' ---------------------------------------------*/
IF @isMI = 0
BEGIN
    SELECT @xps = CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'Database Mail XPs';
    IF @xps = 1
        PRINT N'[OK]     Database Mail XPs already enabled.';
    ELSE
    BEGIN
        SELECT @adv = CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'show advanced options';
        IF @adv = 0 BEGIN EXEC sys.sp_configure N'show advanced options', 1; RECONFIGURE; END;
        EXEC sys.sp_configure N'Database Mail XPs', 1; RECONFIGURE;
        IF @adv = 0 BEGIN EXEC sys.sp_configure N'show advanced options', 0; RECONFIGURE; END;
        PRINT N'[FIXED]  Database Mail XPs enabled.';
    END;

    /*---- 2. Service Broker in msdb (Database Mail queues need it) --------*/
    IF (SELECT is_broker_enabled FROM sys.databases WHERE name = N'msdb') = 1
        PRINT N'[OK]     Service Broker enabled in msdb.';
    ELSE IF @FixMsdbBroker = 1
    BEGIN
        PRINT N'[FIXING] Enabling Service Broker in msdb (stops SQL Agent''s msdb connections for a moment)...';
        ALTER DATABASE msdb SET ENABLE_BROKER WITH ROLLBACK IMMEDIATE;
        PRINT N'[FIXED]  Service Broker enabled in msdb.';
    END
    ELSE
        PRINT N'[WARN]   Service Broker is OFF in msdb - mail will stay queued. Re-run with @FixMsdbBroker = 1 in a quiet moment.';
END;

/*---- 3. SMTP account ---------------------------------------------------*/
SELECT @accountId = account_id FROM msdb.dbo.sysmail_account WHERE name = @AccountName;
IF @accountId IS NOT NULL
    PRINT N'[OK]     Account "' + @AccountName + N'" exists - left unchanged.';
ELSE
BEGIN
    EXEC msdb.dbo.sysmail_add_account_sp
         @account_name            = @AccountName,
         @email_address           = @EmailAddress,
         @display_name            = @DisplayName,
         @replyto_address         = @ReplyTo,
         @description             = N'Created by 45_database_mail_setup.sql',
         @mailserver_name         = @SmtpServer,
         @mailserver_type         = N'SMTP',
         @port                    = @SmtpPort,
         @enable_ssl              = @EnableSSL,
         @username                = @SmtpUser,
         @password                = @SmtpPassword,
         @use_default_credentials = @UseDefaultCreds,
         @account_id              = @accountId OUTPUT;
    PRINT N'[CREATED] Account "' + @AccountName + N'" -> ' + @SmtpServer + N':' + CAST(@SmtpPort AS nvarchar(10)) + N' as ' + @EmailAddress + N'.';
END;

/*---- 4. Profile --------------------------------------------------------*/
SELECT @profileId = profile_id FROM msdb.dbo.sysmail_profile WHERE name = @ProfileName;
IF @profileId IS NOT NULL
    PRINT N'[OK]     Profile "' + @ProfileName + N'" exists.';
ELSE
BEGIN
    EXEC msdb.dbo.sysmail_add_profile_sp @profile_name = @ProfileName, @description = @ProfileDescription, @profile_id = @profileId OUTPUT;
    SET @created = 1;
    PRINT N'[CREATED] Profile "' + @ProfileName + N'".';
END;

/*---- 5. Profile must have at least one account ---------------------------*/
IF EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profileaccount WHERE profile_id = @profileId)
BEGIN
    IF @created = 0 AND NOT EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profileaccount WHERE profile_id = @profileId AND account_id = @accountId)
        PRINT N'[OK]     Profile already has its own account(s) - "' + @AccountName + N'" not added to it.';
    ELSE
        PRINT N'[OK]     Profile is linked to an account.';
END
ELSE
BEGIN
    EXEC msdb.dbo.sysmail_add_profileaccount_sp @profile_name = @ProfileName, @account_name = @AccountName, @sequence_number = 1;
    PRINT N'[FIXED]  Account "' + @AccountName + N'" linked to profile "' + @ProfileName + N'" (it had no account).';
END;

/*---- 6. Public / default profile ---------------------------------------*/
IF @MakePublicDefault = 1
BEGIN
    IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysmail_principalprofile WHERE profile_id = @profileId AND principal_sid = 0x00)
    BEGIN
        EXEC msdb.dbo.sysmail_add_principalprofile_sp @principal_name = N'public', @profile_name = @ProfileName, @is_default = 1;
        PRINT N'[FIXED]  Profile made public and default.';
    END
    ELSE IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysmail_principalprofile WHERE profile_id = @profileId AND principal_sid = 0x00 AND is_default = 1)
    BEGIN
        EXEC msdb.dbo.sysmail_update_principalprofile_sp @principal_name = N'public', @profile_name = @ProfileName, @is_default = 1;
        PRINT N'[FIXED]  Profile made the default public profile.';
    END
    ELSE
        PRINT N'[OK]     Profile is public and default.';
END;

/*---- 7. Database Mail service (external program / queue) -----------------*/
IF OBJECT_ID('tempdb..#mailstatus') IS NOT NULL DROP TABLE #mailstatus;
CREATE TABLE #mailstatus (Status nvarchar(20));
BEGIN TRY
    INSERT #mailstatus EXEC msdb.dbo.sysmail_help_status_sp;
    SELECT @status = Status FROM #mailstatus;
END TRY
BEGIN CATCH SET @status = N'UNKNOWN'; END CATCH;
IF @status = N'STARTED'
    PRINT N'[OK]     Database Mail is STARTED.';
ELSE
BEGIN
    EXEC msdb.dbo.sysmail_start_sp;
    PRINT N'[FIXED]  Database Mail was ' + ISNULL(@status, N'UNKNOWN') + N' - started.';
END;

/*---- 8. SQL Agent mail profile (optional) --------------------------------*/
IF @SetAgentProfile = 1 AND @isMI = 0
BEGIN
    EXEC msdb.dbo.sp_set_sqlagent_properties @email_save_in_sent_folder = 1, @use_databasemail = 1, @databasemail_profile = @ProfileName;
    PRINT N'[FIXED]  SQL Agent alert system set to profile "' + @ProfileName + N'" - restart SQL Server Agent for it to take effect.';
END;

/*---- 9. Test email (optional) --------------------------------------------*/
IF @TestRecipient IS NOT NULL
BEGIN
    DECLARE @mailId int, @subj nvarchar(255) = N'Database Mail test - ' + CAST(SERVERPROPERTY('ServerName') AS nvarchar(128));
    EXEC msdb.dbo.sp_send_dbmail @profile_name = @ProfileName, @recipients = @TestRecipient, @subject = @subj,
         @body = N'Database Mail is working on this instance (sent by 45_database_mail_setup.sql).', @mailitem_id = @mailId OUTPUT;
    PRINT N'[SENT]   Test email queued, mailitem_id ' + CAST(@mailId AS nvarchar(10)) + N'. Check it in ~30 s with the last query in this script.';
END;

/*---- Result ----------------------------------------------------------------*/
SELECT p.name AS profile_name, a.name AS account_name, a.email_address, a.display_name,
       s.servername AS smtp_server, s.port, s.enable_ssl, ISNULL(s.username, N'') AS smtp_user, s.use_default_credentials,
       pa.sequence_number,
       CASE WHEN pp.principal_sid = 0x00 THEN N'public' ELSE N'' END AS public_profile, ISNULL(pp.is_default, 0) AS is_default,
       (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'Database Mail XPs') AS database_mail_xps,
       (SELECT is_broker_enabled FROM sys.databases WHERE name = N'msdb') AS msdb_broker_enabled,
       (SELECT TOP (1) Status FROM #mailstatus) AS status_before_script
FROM msdb.dbo.sysmail_profile AS p
LEFT JOIN msdb.dbo.sysmail_profileaccount AS pa ON pa.profile_id = p.profile_id
LEFT JOIN msdb.dbo.sysmail_account AS a ON a.account_id = pa.account_id
LEFT JOIN msdb.dbo.sysmail_server AS s ON s.account_id = a.account_id
LEFT JOIN msdb.dbo.sysmail_principalprofile AS pp ON pp.profile_id = p.profile_id AND pp.principal_sid = 0x00
WHERE p.name = @ProfileName
ORDER BY pa.sequence_number;

/* Check the test email / recent mail (run separately):
SELECT TOP (10) a.mailitem_id, a.recipients, a.subject, a.sent_status, a.send_request_date, a.sent_date,
       (SELECT TOP (1) l.description FROM msdb.dbo.sysmail_event_log AS l WHERE l.mailitem_id = a.mailitem_id ORDER BY l.log_id DESC) AS last_error
FROM msdb.dbo.sysmail_allitems AS a ORDER BY a.mailitem_id DESC;
*/
