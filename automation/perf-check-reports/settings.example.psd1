# Settings for Collect-PerfCheckReports.ps1
# Copy this file to settings.psd1 in the same folder and change what you need.
# settings.psd1 is never part of a release, so updating the script keeps your values.
# Anything you leave out uses the default in the script. Paths can be relative to this folder.
@{
    # --- What to collect ---------------------------------------------------------------
    Instances         = @('SQLVM1\INST01', 'SQLVM2\INST01')   # instance names, not AG listeners
    ReportDatabase    = 'DBAdmin'
    RunLabel          = 'SCHEDULED'        # label of the check job's runs ('' = any label)
    MaxAgeMinutes     = 120                # only runs started within this many minutes count
    WaitMinutes       = 15                 # wait this long for runs still going / not started yet
    PollSec           = 30

    # --- Email -----------------------------------------------------------------------
    Recipients        = 'dba-team@yourcompany.com'   # ; separated
    CopyRecipients    = ''
    FromAddress       = ''                 # '' = the profile account's address
    MailInstance      = 'SQLVM1\INST01'    # instance on THIS machine that sends the email (Database Mail)
    MailProfile       = ''                 # '' = default public profile, else the first profile with an account
    ReportTitle       = 'SQL Server Health & Performance Check'
    EmailSubject      = ''                 # '' = automatic ([STATUS] title [label] - VMs - counts)
    SubjectTimeFormat = 'yyyy-MM-dd HH:mm' # appended as ' - <time>' to EmailSubject; '' = no time

    # --- SQL login that reads the results (Create_PerfCheck_Logins.sql) ----------------
    SqlLogin          = 'dba_perfcheck'
    CredentialScope   = 'CurrentUser'      # or 'LocalMachine'
    CredentialFile    = 'PerfCheck.cred'   # LocalMachine scope file
    Encrypt           = $false
    ConnectTimeoutSec = 15

    # --- Files on this machine ---------------------------------------------------------
    ReportsFolder     = 'Reports'
    LogsFolder        = 'Logs'
    KeepFilesDays     = 30

    # --- SMTP fallback (optional) ------------------------------------------------------
    SmtpServer        = ''                 # send straight from this machine if Database Mail can't
    SmtpPort          = 25
    SmtpUseSsl        = $false
    SmtpFrom          = ''
}
