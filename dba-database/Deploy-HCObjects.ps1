<#
.SYNOPSIS
    Installs (or updates) the DBAdmin HC_ objects on many SQL Server instances and
    shows one summary line per instance.

.DESCRIPTION
    Runs DBAdmin_HC_Deploy.sql on every instance, then reads DBAdmin.dbo.HC_version and
    the object status counts back. With -SelfTest it also runs EXEC dbo.HC_selftest on each
    instance (result sets are discarded; only the pass/fail counts come back).

    Safe to re-run: the deploy script checks everything before it creates or changes it.
    Uses your Windows login by default (run PowerShell / your RDP session as the account
    that holds the SQL permissions), or -SqlCredential for SQL authentication.

    Needs the dbatools module:  Install-Module dbatools -Scope CurrentUser

.EXAMPLE
    .\Deploy-HCObjects.ps1 -SqlInstance SQLVM01, SQLVM02\INST2
.EXAMPLE
    .\Deploy-HCObjects.ps1 -ServerListFile .\servers.txt -SelfTest -OutCsv .\hc_deploy.csv
.EXAMPLE
    # Azure SQL Database: name the user database the objects go into
    .\Deploy-HCObjects.ps1 -SqlInstance myserver.database.windows.net -Database AppDb -SqlCredential (Get-Credential)
#>
[CmdletBinding(DefaultParameterSetName = 'List')]
param(
    [Parameter(Mandatory, ParameterSetName = 'List')]
    [string[]] $SqlInstance,

    # one instance per line; blank lines and lines starting with # are ignored
    [Parameter(Mandatory, ParameterSetName = 'File')]
    [string] $ServerListFile,

    [string] $DeployScript = (Join-Path $PSScriptRoot 'DBAdmin_HC_Deploy.sql'),

    # Azure SQL Database only: the database to install into (other platforms always use DBAdmin)
    [string] $Database,

    [pscredential] $SqlCredential,

    # run EXEC dbo.HC_selftest after deploying
    [switch] $SelfTest,

    # accept self-signed / untrusted server certificates (dbatools 2.x encrypts connections by default)
    [switch] $TrustServerCertificate,

    [string] $OutCsv,

    [int] $QueryTimeoutSec = 1800
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Module -ListAvailable -Name dbatools)) {
    throw 'dbatools is not installed. Run: Install-Module dbatools -Scope CurrentUser'
}
Import-Module dbatools

if (-not (Test-Path -LiteralPath $DeployScript)) { throw "Deploy script not found: $DeployScript" }
$scriptText = Get-Content -LiteralPath $DeployScript -Raw
$expectedBuild = if ($scriptText -match '(?m)^\s*Build\s*:\s*(\w+)') { $Matches[1] } else { '?' }

$instances = if ($PSCmdlet.ParameterSetName -eq 'File') {
    Get-Content -LiteralPath $ServerListFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^#' }
} else { $SqlInstance }

Write-Host "Deploying build $expectedBuild to $(@($instances).Count) instance(s)" -ForegroundColor Cyan

$results = foreach ($inst in $instances) {
    $row = [ordered]@{
        Instance = $inst; Platform = $null; Version = $null; Build = $null; UpToDate = $false
        Ok = $null; Failed = $null; Skipped = $null
        SelfTestPass = $null; SelfTestFail = $null; SelfTestSkipped = $null; Error = $null
    }
    try {
        $conn = @{ SqlInstance = $inst }
        if ($SqlCredential)          { $conn.SqlCredential = $SqlCredential }
        if ($TrustServerCertificate) { $conn.TrustServerCertificate = $true }
        $server = Connect-DbaInstance @conn

        $edition = [int]$server.Query("SELECT CAST(SERVERPROPERTY('EngineEdition') AS int) AS e").e
        $row.Platform = switch ($edition) { 5 { 'Azure SQL DB' } 8 { 'Managed Instance' } default { 'SQL Server' } }
        $row.Version  = $server.VersionString

        $target = 'DBAdmin'
        $text   = $scriptText
        if ($edition -eq 5) {
            if (-not $Database) { throw 'Azure SQL Database: pass -Database <user database> to install into.' }
            $target = $Database
            $text   = $text -replace '(?m)^USE DBAdmin;.*$', ''    # no USE on Azure SQL Database
            $server = Connect-DbaInstance @conn -Database $Database
        }

        Write-Host "[$inst] deploying..." -NoNewline
        $warnings = $null
        $null = Invoke-DbaQuery -SqlInstance $server -Database $(if ($edition -eq 5) { $target } else { 'master' }) `
                    -Query $text -QueryTimeout $QueryTimeoutSec -WarningVariable warnings -WarningAction SilentlyContinue
        if ($warnings) { $row.Error = ($warnings | Select-Object -First 3) -join ' | ' }

        $v = Invoke-DbaQuery -SqlInstance $server -Database $target -Query 'SELECT TOP (1) build_id FROM dbo.HC_version;'
        $row.Build    = $v.build_id
        $row.UpToDate = ($v.build_id -eq $expectedBuild)
        $s = Invoke-DbaQuery -SqlInstance $server -Database $target -Query @'
SELECT SUM(CASE WHEN status LIKE 'OK%' THEN 1 ELSE 0 END) AS ok,
       SUM(CASE WHEN status = 'FAILED' THEN 1 ELSE 0 END) AS failed,
       SUM(CASE WHEN status IN ('NOT APPLICABLE', 'NOT ON THIS VERSION') THEN 1 ELSE 0 END) AS skipped
FROM dbo.HC_objects;
'@
        $row.Ok = $s.ok; $row.Failed = $s.failed; $row.Skipped = $s.skipped
        Write-Host " $($s.ok) ok, $($s.failed) failed" -ForegroundColor $(if ($s.failed -gt 0) { 'Yellow' } else { 'Green' })

        if ($SelfTest) {
            Write-Host "[$inst] self-test..." -NoNewline
            $null = Invoke-DbaQuery -SqlInstance $server -Database $target -Query 'EXEC dbo.HC_selftest;' `
                        -QueryTimeout $QueryTimeoutSec -WarningAction SilentlyContinue
            $t = Invoke-DbaQuery -SqlInstance $server -Database $target -Query @'
SELECT SUM(CASE WHEN result = 'PASS' THEN 1 ELSE 0 END) AS pass,
       SUM(CASE WHEN result = 'FAIL' THEN 1 ELSE 0 END) AS fail,
       SUM(CASE WHEN result = 'SKIPPED' THEN 1 ELSE 0 END) AS skipped
FROM dbo.HC_selftest_last;
'@
            $row.SelfTestPass = $t.pass; $row.SelfTestFail = $t.fail; $row.SelfTestSkipped = $t.skipped
            Write-Host " $($t.pass) pass, $($t.fail) fail" -ForegroundColor $(if ($t.fail -gt 0) { 'Yellow' } else { 'Green' })
        }
    }
    catch {
        $row.Error = $_.Exception.Message
        Write-Host " ERROR: $($row.Error)" -ForegroundColor Red
    }
    [pscustomobject]$row
}

$results | Format-Table Instance, Platform, Build, UpToDate, Ok, Failed, Skipped, SelfTestPass, SelfTestFail, Error -AutoSize
if ($OutCsv) {
    $results | Export-Csv -LiteralPath $OutCsv -NoTypeInformation
    Write-Host "Saved $OutCsv"
}
Write-Host 'Failures on an instance:  SELECT * FROM DBAdmin.dbo.HC_catalog WHERE status = ''FAILED'';  /  SELECT * FROM DBAdmin.dbo.HC_selftest_last WHERE result = ''FAIL'';'
