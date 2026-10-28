<#
.SYNOPSIS
    Installs / updates the community DBA tools on one or more SQL Server instances
    using dbatools, and downloads Glenn Berry's Diagnostic Information Queries.

    Tools (always the LATEST official version - nothing is copied into this repo):
      - sp_WhoIsActive               (Adam Machanic)        -> Install-DbaWhoIsActive
      - First Responder Kit          (Brent Ozar Unlimited) -> Install-DbaFirstResponderKit
      - Ola Hallengren Maint. Sol.   (Ola Hallengren)       -> Install-DbaMaintenanceSolution
      - Glenn Berry diagnostic queries (.sql files)         -> Save-DbaDiagnosticQueryScript

.PARAMETER SqlInstance
    One or more instances, e.g. "SQLVM1","SQLVM2\INST1","ag1-listener" or an MI FQDN.
.PARAMETER Database
    Database to install the procedures into (created if missing). Default: DBAdmin.
    Using a dedicated DBA DB keeps master clean and survives in-place upgrades.
.PARAMETER Tools
    Which tools to install. Default: all.
.PARAMETER BackupDirectory
    Only for Ola: default backup path used by the jobs it creates (local/UNC; or a URL for MI).
.PARAMETER CreateOlaJobs
    Create Ola's Agent jobs (disabled schedules - you schedule them). Default: $false.
.PARAMETER DiagnosticQueryPath
    Where to save Glenn Berry's .sql files. Default: .\GlennBerry

.EXAMPLE
    .\Install-CommunityTools.ps1 -SqlInstance SQLVM1,SQLVM2 -BackupDirectory '\\backup\sql' -CreateOlaJobs
.EXAMPLE
    .\Install-CommunityTools.ps1 -SqlInstance SQLVM1 -Tools WhoIsActive,FirstResponderKit
.NOTES
    Always On: install on EVERY replica (procs live in a non-AG DBA database), and
    let Ola's jobs run everywhere - DatabaseBackup / IndexOptimize are AG-aware.
    Azure SQL Database: WhoIsActive + FRK work (installed into the user DB); Ola's
    jobs need SQL Agent so use Elastic Jobs / Automation; Glenn has an Azure SQL DB version.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string[]] $SqlInstance,
    [string]   $Database = 'DBAdmin',
    [ValidateSet('WhoIsActive', 'FirstResponderKit', 'MaintenanceSolution', 'GlennBerry')]
    [string[]] $Tools = @('WhoIsActive', 'FirstResponderKit', 'MaintenanceSolution', 'GlennBerry'),
    [string]   $BackupDirectory,
    [switch]   $CreateOlaJobs,
    [string]   $DiagnosticQueryPath = (Join-Path $PSScriptRoot 'GlennBerry'),
    [pscredential] $SqlCredential
)

$ErrorActionPreference = 'Stop'

# --- 1. dbatools present? ----------------------------------------------------
if (-not (Get-Module -ListAvailable -Name dbatools)) {
    Write-Host 'Installing dbatools from the PowerShell Gallery (CurrentUser)...' -ForegroundColor Yellow
    Install-Module dbatools -Scope CurrentUser -Force
}
Import-Module dbatools
# Newer dbatools versions validate certificates by default; uncomment if your instances use self-signed certs:
# Set-DbatoolsConfig -FullName sql.connection.trustcert -Value $true -Register

$common = @{ EnableException = $true }
if ($SqlCredential) { $common.SqlCredential = $SqlCredential }

foreach ($instance in $SqlInstance) {
    Write-Host "`n=== $instance ===" -ForegroundColor Cyan
    try {
        # --- 2. DBA database ---------------------------------------------------
        if (-not (Get-DbaDatabase -SqlInstance $instance -Database $Database @common)) {
            Write-Host "Creating database $Database"
            New-DbaDatabase -SqlInstance $instance -Name $Database -RecoveryModel Simple @common | Out-Null
        }

        if ('WhoIsActive' -in $Tools) {
            Write-Host 'sp_WhoIsActive...'
            Install-DbaWhoIsActive -SqlInstance $instance -Database $Database -Force @common | Out-Null
        }

        if ('FirstResponderKit' -in $Tools) {
            Write-Host 'First Responder Kit (sp_Blitz*)...'
            Install-DbaFirstResponderKit -SqlInstance $instance -Database $Database -Force @common | Out-Null
        }

        if ('MaintenanceSolution' -in $Tools) {
            Write-Host 'Ola Hallengren Maintenance Solution...'
            $ola = @{
                SqlInstance  = $instance
                Database     = $Database
                LogToTable   = $true          # dbo.CommandLog - queried in scripts/33
                ReplaceExisting = $true
            }
            if ($BackupDirectory) { $ola.BackupLocation = $BackupDirectory }
            if ($CreateOlaJobs)   { $ola.InstallJobs = $true }
            Install-DbaMaintenanceSolution @ola @common | Out-Null
        }

        Write-Host "Done: $instance" -ForegroundColor Green
    }
    catch {
        Write-Warning "$instance failed: $($_.Exception.Message)"
    }
}

# --- 3. Glenn Berry's queries (files, not installed on a server) ---------------
if ('GlennBerry' -in $Tools) {
    if (-not (Test-Path $DiagnosticQueryPath)) { New-Item -ItemType Directory -Path $DiagnosticQueryPath | Out-Null }
    Write-Host "`nDownloading Glenn Berry's Diagnostic Information Queries to $DiagnosticQueryPath" -ForegroundColor Cyan
    Save-DbaDiagnosticQueryScript -Path $DiagnosticQueryPath
    Get-ChildItem $DiagnosticQueryPath -Filter *.sql | Select-Object Name, LastWriteTime | Format-Table -AutoSize
}

# --- 4. Verify ---------------------------------------------------------------
Write-Host "`nInstalled procedures:" -ForegroundColor Cyan
foreach ($instance in $SqlInstance) {
    Invoke-DbaQuery -SqlInstance $instance -Database $Database @common -Query @"
SELECT @@SERVERNAME AS instance, name, modify_date
FROM sys.procedures
WHERE name IN ('sp_WhoIsActive','sp_Blitz','sp_BlitzFirst','sp_BlitzCache','sp_BlitzIndex','sp_BlitzLock','sp_BlitzWho',
               'DatabaseBackup','DatabaseIntegrityCheck','IndexOptimize','CommandExecute')
ORDER BY name;
"@ | Format-Table -AutoSize
}
