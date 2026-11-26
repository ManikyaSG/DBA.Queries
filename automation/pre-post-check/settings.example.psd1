# Settings for Invoke-PrePostCheck.ps1
# Copy this file to settings.psd1 in the same folder and change what you need.
# settings.psd1 is never part of a release, so updating the scripts keeps your values.
# Anything you leave out (or delete from here) uses the default shown below.
# Paths can be relative to this folder. A setting name the script doesn't know is reported.
@{
    # --- Email -----------------------------------------------------------------------
    Recipients             = 'dba-team@yourcompany.com'   # ; separated
    CopyRecipients         = ''
    FromAddress            = ''                 # e.g. 'SQL Alerts <sqlalerts@yourcompany.com>' ('' = profile's account)
    ReplyTo                = ''
    MailProfile            = 'DBA_Mail'         # preferred; else the default / only profile on the instance
    AttachReport           = $true              # attach the combined HTML report (falls back to the email body)
    MailCheckDelaySec      = 20
    AutoSetupDbMail        = $true              # XPs off -> enable them; no profile with an SMTP account -> run DbMailSetupFile
    DbMailSetupFile        = 'db_mail_setup.sql'
    ReportTitle            = 'SQL Server Change Check'
    HealthReportTitle      = 'SQL Server Health Check'

    # --- Which instances ---------------------------------------------------------------
    IncludeLocalInstances  = $true
    ExtraInstances         = @()                # e.g. @('SQLVM2', 'SQLVM3\INST2', 'SQLVM4,14330')
    ServersFile            = 'servers.txt'      # optional, one instance per line

    # --- Comparison tolerances ---------------------------------------------------------
    FileSizeDriftPct       = 10                 # flag file / DB size change above this % ...
    FileSizeDriftMinMB     = 512                # ... and above this many MB
    DiskFreeDriftPct       = 5                  # flag disk free-space change above this % of the disk size

    # --- Connections -------------------------------------------------------------------
    ConnectTimeoutSec      = 15
    QueryTimeoutSec        = 900
    Encrypt                = $false

    # --- Files on this VM --------------------------------------------------------------
    SnapshotRoot           = 'Snapshots'
    ReportsFolder          = 'Reports'
    LogsFolder             = 'Logs'
    PerInstanceReports     = $false             # also save one HTML file per instance
    CleanupHours           = 48                 # every run deletes Reports / Logs / finished Snapshots older than this (0 = off)
    KeepPreWithoutPostDays = 7                  # a PRE still waiting for its POST is kept this long
}
