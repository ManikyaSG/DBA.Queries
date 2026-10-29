<#
.SYNOPSIS
    One-click SQL Server health check for every SQL instance on this VM.
    Runs scripts/44_health_check_report_email.sql against each instance, emails the
    full HTML report through that instance's Database Mail profile and saves a
    timestamped copy locally for PRE / POST change comparison.

.DESCRIPTION
    Typical use: RDP in with the generic admin account, double-click Run-HealthCheck.bat.
      1. Asks for a label (PRE / POST / DAILY) and an optional change ticket.
      2. Asks for YOUR Windows account (the one you use for "Run as different user"
         on SSMS) and relaunches itself as that account - so SQL Server sees your login.
         Cancel the credential prompt to run as the current user instead.
      3. Finds all SQL Server instances installed on this VM (default, named, FCI
         virtual names) + any extra instances listed in servers.txt.
      4. For each running instance: runs the health check, emails it, saves
         Reports\<instance>_<label>_<ticket>_<yyyyMMdd_HHmm>.html.
      5. Prints a summary and checks Database Mail actually sent each email.

    Requirements: Windows PowerShell 5.1 (built in). No SqlServer module, sqlcmd
    or internet access needed (uses .NET System.Data.SqlClient).
    Your account needs: VIEW SERVER STATE, read on msdb, and membership of
    DatabaseMailUserRole in msdb (or sysadmin) to send mail.

.PARAMETER Label
    PRE / POST / DAILY (or any short text). Prompted if omitted.
.PARAMETER Ticket
    Change / incident number, e.g. CHG0012345. Optional, prompted if omitted.
.PARAMETER UseCurrentUser
    Don't ask for credentials - run as the account that started the script.
.PARAMETER Instances
    Run only against these instances (overrides discovery and servers.txt).

.EXAMPLE
    .\Invoke-HealthCheck.ps1                                   # interactive (what the .bat does)
.EXAMPLE
    .\Invoke-HealthCheck.ps1 -Label PRE -Ticket CHG0012345
.EXAMPLE
    .\Invoke-HealthCheck.ps1 -Label POST -Ticket CHG0012345 -UseCurrentUser -Instances 'SQLVM1','SQLVM1\INST2'
#>
[CmdletBinding()]
param(
    [string]   $Label,
    [string]   $Ticket,
    [switch]   $UseCurrentUser,
    [string[]] $Instances,
    [string]   $SqlFile,
    [switch]   $Inner          # internal: set when relaunched as your account
)

# =============================================================================
#  CONFIGURATION  <== change these once
# =============================================================================
$Config = @{
    Recipients            = 'dba-team@yourcompany.com'   # ; separated
    CopyRecipients        = ''                           # optional
    MailProfile           = 'DBA_Mail'                   # preferred profile; falls back to the default / only profile on each instance
    ReportTitle           = 'SQL Server Health Check'
    IncludeLocalInstances = $true                        # discover instances installed on this VM
    ServersFile           = Join-Path $PSScriptRoot 'servers.txt'   # optional extra instances, one per line
    ReportsFolder         = Join-Path $PSScriptRoot 'Reports'
    LogsFolder            = Join-Path $PSScriptRoot 'Logs'
    ConnectTimeoutSec     = 15
    QueryTimeoutSec       = 900
    Encrypt               = $false                       # $true if the instance forces encryption
    MailCheckDelaySec     = 20                           # wait before checking Database Mail delivery status
}

$ErrorActionPreference = 'Stop'

# -Instances arrives as one comma-separated string when relaunched with -File
if ($Instances) { $Instances = @($Instances -split ',' | ForEach-Object { $_.Trim(" '`"") } | Where-Object { $_ }) }

# =============================================================================
#  HELPERS
# =============================================================================
function Write-Step([string]$Text, [string]$Color = 'Cyan') { Write-Host $Text -ForegroundColor $Color }

function Get-SqlFilePath {
    if ($SqlFile) { return (Resolve-Path $SqlFile).Path }
    $candidates = @(
        (Join-Path $PSScriptRoot '44_health_check_report_email.sql'),
        (Join-Path $PSScriptRoot '..\..\scripts\44_health_check_report_email.sql')
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return (Resolve-Path $c).Path } }
    throw "44_health_check_report_email.sql not found. Put it next to this script or pass -SqlFile."
}

function Get-LocalSqlInstances {
    # Default + named instances from the registry; FCI -> virtual network name.
    $result  = @()
    $regKey  = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
    if (-not (Test-Path $regKey)) { return $result }
    $skip    = 'PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider'
    $props   = Get-ItemProperty -Path $regKey
    foreach ($p in $props.PSObject.Properties | Where-Object { $skip -notcontains $_.Name }) {
        $instName = $p.Name
        $instId   = $p.Value
        $svcName  = if ($instName -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { 'MSSQL$' + $instName }
        $svc      = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        $hostName = $env:COMPUTERNAME
        $clusterKey = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instId\Cluster"
        if (Test-Path $clusterKey) {
            $vn = (Get-ItemProperty -Path $clusterKey -ErrorAction SilentlyContinue).ClusterName
            if ($vn) { $hostName = $vn }
        }
        $connName = if ($instName -eq 'MSSQLSERVER') { $hostName } else { "$hostName\$instName" }
        $result += [pscustomobject]@{
            Instance = $connName
            Service  = $svcName
            Status   = if ($svc) { [string]$svc.Status } else { 'Unknown' }
        }
    }
    return $result
}

function Get-TargetInstances {
    $targets = @()
    if ($Instances) {
        foreach ($i in $Instances) { $targets += [pscustomobject]@{ Instance = $i; Service = ''; Status = 'Listed' } }
        return $targets
    }
    if ($Config.IncludeLocalInstances) { $targets += Get-LocalSqlInstances }
    if (Test-Path $Config.ServersFile) {
        Get-Content $Config.ServersFile |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') } |
            ForEach-Object { $targets += [pscustomobject]@{ Instance = $_; Service = ''; Status = 'Listed' } }
    }
    # de-duplicate by instance name (case-insensitive)
    $seen = @{}
    $unique = @()
    foreach ($t in $targets) {
        $k = $t.Instance.ToUpperInvariant()
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $unique += $t }
    }
    return $unique
}

function New-SqlConnection([string]$Instance) {
    $enc = if ($Config.Encrypt) { 'True' } else { 'False' }
    $cs  = "Server=$Instance;Database=master;Integrated Security=SSPI;Application Name=DBA HealthCheck;" +
           "Connect Timeout=$($Config.ConnectTimeoutSec);Encrypt=$enc;TrustServerCertificate=True"
    return New-Object System.Data.SqlClient.SqlConnection $cs
}

function Invoke-Scalar($Connection, [string]$Query, [hashtable]$Params = @{}) {
    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = $Query
    $cmd.CommandTimeout = 60
    foreach ($k in $Params.Keys) { [void]$cmd.Parameters.AddWithValue($k, $Params[$k]) }
    return $cmd.ExecuteScalar()
}

function Get-MailProfileName($Connection) {
    # Preferred profile if it exists, else the default public/private profile, else the only/first one.
    $q = @"
SELECT TOP (1) p.name
FROM msdb.dbo.sysmail_profile AS p
LEFT JOIN msdb.dbo.sysmail_principalprofile AS pp ON pp.profile_id = p.profile_id AND pp.is_default = 1
ORDER BY CASE WHEN p.name = @pref THEN 0 WHEN pp.profile_id IS NOT NULL THEN 1 ELSE 2 END, p.profile_id;
"@
    $r = Invoke-Scalar $Connection $q @{ '@pref' = $Config.MailProfile }
    if ($r -is [DBNull]) { return $null }
    return [string]$r
}

function Set-SqlConfigValue([string]$Text, [string]$Pattern, [string]$NewValue, [string]$Name) {
    $m = [regex]::Matches($Text, $Pattern)
    if ($m.Count -ne 1) { throw "Could not find the $Name setting in the .sql file (found $($m.Count)). Has the config block in script 44 changed?" }
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator] { param($x) $x.Groups[1].Value + $NewValue }
    return [regex]::Replace($Text, $Pattern, $evaluator)
}

function ConvertTo-SqlLiteral([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'NULL' }
    return "N'" + $Value.Replace("'", "''") + "'"
}

function Get-SafeFileName([string]$Value) { return ($Value -replace '[\\/:*?"<>|\s]', '_') }

# =============================================================================
#  OUTER: prompt for label / ticket / credentials, relaunch as your account
# =============================================================================
if (-not $Inner) {
    Write-Step "=== SQL Server Health Check ===" 'Green'
    if (-not $Label) {
        $Label = Read-Host 'Label - PRE / POST / DAILY  (Enter = DAILY)'
        if ([string]::IsNullOrWhiteSpace($Label)) { $Label = 'DAILY' }
    }
    if (-not $PSBoundParameters.ContainsKey('Ticket')) {
        $Ticket = Read-Host 'Change / incident ticket (optional, Enter to skip)'
    }
    $Label  = ($Label.Trim().ToUpperInvariant() -replace '[^A-Z0-9_-]', '')
    $Ticket = ($Ticket.Trim() -replace '[^A-Za-z0-9_-]', '')
    if (-not $Label) { $Label = 'DAILY' }

    $cred = $null
    if (-not $UseCurrentUser) {
        try   { $cred = Get-Credential -Message "Enter YOUR Windows account (DOMAIN\user) that has access to SQL Server.`nCancel = run as $env:USERDOMAIN\$env:USERNAME" }
        catch { $cred = $null }
    }

    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Inner', '-Label', $Label)
    if ($Ticket)    { $argList += @('-Ticket', $Ticket) }
    if ($SqlFile)   { $argList += @('-SqlFile', "`"$((Resolve-Path $SqlFile).Path)`"") }
    if ($Instances) { $argList += @('-Instances', ($Instances -join ',')) }

    if ($cred) {
        Write-Step "Starting the health check as $($cred.UserName) in a new window..."
        try {
            Start-Process -FilePath "$PSHOME\powershell.exe" -Credential $cred -ArgumentList $argList `
                          -WorkingDirectory $PSScriptRoot -Wait
        }
        catch {
            Write-Step "Could not start as $($cred.UserName): $($_.Exception.Message)" 'Red'
            Write-Step "Check: password / account locked; the account may log on to this VM (same as 'Run as different user');" 'Yellow'
            Write-Step "       the account can READ this folder: $PSScriptRoot  (use e.g. C:\DBA\HealthCheck, not the admin's Desktop)." 'Yellow'
            Read-Host 'Press Enter to close'
            exit 1
        }
        exit 0
    }
    # Cancelled / -UseCurrentUser: continue in this window as the current user.
}

# =============================================================================
#  INNER: run the health check for every instance
# =============================================================================
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
foreach ($key in @('ReportsFolder', 'LogsFolder')) {
    try {
        if (-not (Test-Path $Config[$key])) { New-Item -ItemType Directory -Path $Config[$key] -Force | Out-Null }
        $probe = Join-Path $Config[$key] ('.write_test_' + $stamp)
        [System.IO.File]::WriteAllText($probe, 'x'); Remove-Item $probe -Force
    }
    catch {
        $fallback = Join-Path $env:TEMP ('DBA_HealthCheck\' + (Split-Path $Config[$key] -Leaf))
        New-Item -ItemType Directory -Path $fallback -Force | Out-Null
        Write-Warning "No write access to $($Config[$key]) for this account - using $fallback"
        $Config[$key] = $fallback
    }
}
$logFile = Join-Path $Config.LogsFolder "HealthCheck_${Label}_$stamp.log"
try { Start-Transcript -Path $logFile -Append | Out-Null } catch { Write-Warning "Transcript not started: $($_.Exception.Message)" }

$summary = @()
try {
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    Write-Step "Running as      : $me"
    Write-Step "Label / ticket  : $Label $Ticket"
    $sqlPath = Get-SqlFilePath
    Write-Step "SQL script      : $sqlPath"
    $sqlTemplate = [System.IO.File]::ReadAllText($sqlPath)

    $targets = Get-TargetInstances
    if (-not $targets) { throw 'No SQL Server instances found on this VM and servers.txt is empty.' }
    Write-Step "Instances found : $($targets.Count)"
    $targets | Format-Table Instance, Service, Status -AutoSize | Out-String | Write-Host

    $title = $Config.ReportTitle + ' [' + $Label + $(if ($Ticket) { ' ' + $Ticket } else { '' }) + ']'

    foreach ($t in $targets) {
        $row = [ordered]@{ Instance = $t.Instance; Result = ''; Critical = ''; Warnings = ''; MailProfile = ''; Report = ''; MailStatus = '' }
        Write-Step "`n--- $($t.Instance) ---" 'Green'

        if ($t.Status -notin @('Running', 'Listed')) {
            $row.Result = "SKIPPED - service $($t.Service) is $($t.Status)"
            Write-Step $row.Result 'Red'
            $summary += [pscustomobject]$row
            continue
        }

        $conn = $null
        try {
            $conn = New-SqlConnection $t.Instance
            $conn.Open()

            $mailProfile = Get-MailProfileName $conn
            if (-not $mailProfile) { throw 'No Database Mail profile exists on this instance - configure Database Mail first.' }
            $row.MailProfile = $mailProfile
            Write-Step "Mail profile    : $mailProfile"

            # Override the config block of script 44 for this run
            $sql = $sqlTemplate
            $sql = Set-SqlConfigValue $sql '(@SendEmail\s+bit\s*=\s*)\d'                                    '1'  '@SendEmail'
            $sql = Set-SqlConfigValue $sql '(@ShowResultSets\s+bit\s*=\s*)\d'                               '0'  '@ShowResultSets'
            $sql = Set-SqlConfigValue $sql '(@SendOnlyIfIssues\s+bit\s*=\s*)\d'                             '0'  '@SendOnlyIfIssues'
            $sql = Set-SqlConfigValue $sql "(@MailProfile\s+sysname\s*=\s*)N'(?:[^']|'')*'"                 (ConvertTo-SqlLiteral $mailProfile)                 '@MailProfile'
            $sql = Set-SqlConfigValue $sql "(@Recipients\s+nvarchar\(max\)\s*=\s*)N'(?:[^']|'')*'"          (ConvertTo-SqlLiteral $Config.Recipients)       '@Recipients'
            $sql = Set-SqlConfigValue $sql "(@CopyRecipients\s+nvarchar\(max\)\s*=\s*)(?:NULL|N'(?:[^']|'')*')" (ConvertTo-SqlLiteral $Config.CopyRecipients) '@CopyRecipients'
            $sql = Set-SqlConfigValue $sql "(@ReportTitle\s+nvarchar\(200\)\s*=\s*)N'(?:[^']|'')*'"         (ConvertTo-SqlLiteral $title)                   '@ReportTitle'
            $sql += "`r`nSELECT @html AS html_report;`r`n"      # return the report so we can save it

            # Capture PRINT output from the script
            $script:messages = New-Object System.Collections.ArrayList
            $handler = [System.Data.SqlClient.SqlInfoMessageEventHandler] { param($src, $e) [void]$script:messages.Add($e.Message) }
            $conn.add_InfoMessage($handler)

            $cmd = $conn.CreateCommand()
            $cmd.CommandText    = $sql
            $cmd.CommandTimeout = $Config.QueryTimeoutSec
            Write-Step 'Collecting health check data and sending email...'
            $reader = $cmd.ExecuteReader()
            $html = $null
            do {
                if ($reader.FieldCount -gt 0 -and $reader.GetName(0) -eq 'html_report') {
                    while ($reader.Read()) { if (-not $reader.IsDBNull(0)) { $html = $reader.GetString(0) } }
                }
                else { while ($reader.Read()) { } }
            } while ($reader.NextResult())
            $reader.Close()

            $script:messages | ForEach-Object { Write-Host "  $_" }
            $sentMsg = $script:messages | Where-Object { $_ -like 'Health check email queued*' } | Select-Object -First 1
            if ($sentMsg -and $sentMsg -match '\((\d+) critical, (\d+) warnings\)') { $row.Critical = $Matches[1]; $row.Warnings = $Matches[2] }

            if ($html) {
                $fileName = (Get-SafeFileName $t.Instance) + '_' + $Label + $(if ($Ticket) { '_' + $Ticket } else { '' }) + '_' + (Get-Date -Format 'yyyyMMdd_HHmm') + '.html'
                $path = Join-Path $Config.ReportsFolder $fileName
                [System.IO.File]::WriteAllText($path, $html, [System.Text.Encoding]::UTF8)
                $row.Report = $path
                Write-Step "Saved report    : $path"
            }
            $row.Result = if ($sentMsg) { 'EMAIL QUEUED' } else { 'RAN - email not confirmed (see messages)' }
        }
        catch {
            $row.Result = 'FAILED: ' + $_.Exception.Message
            Write-Step $row.Result 'Red'
            if ($_.Exception.Message -match 'Login failed') {
                Write-Step "  -> $me has no login on $($t.Instance). Use the account you use for SSMS (cancel = current user)." 'Yellow'
            }
        }
        finally {
            if ($conn) { $conn.Dispose() }
        }
        $summary += [pscustomobject]$row
    }

    # Check Database Mail actually delivered (sent / failed / unsent)
    $queued = $summary | Where-Object { $_.Result -eq 'EMAIL QUEUED' }
    if ($queued) {
        Write-Step "`nWaiting $($Config.MailCheckDelaySec)s to check Database Mail delivery..."
        Start-Sleep -Seconds $Config.MailCheckDelaySec
        foreach ($s in $queued) {
            $c = $null
            try {
                $c = New-SqlConnection $s.Instance; $c.Open()
                $q = @"
SELECT TOP (1) sent_status + CASE WHEN sent_status = 'failed'
       THEN ' - ' + ISNULL((SELECT TOP (1) LEFT(l.description, 200) FROM msdb.dbo.sysmail_event_log l WHERE l.mailitem_id = a.mailitem_id ORDER BY l.log_id DESC), '') ELSE '' END
FROM msdb.dbo.sysmail_allitems AS a
WHERE a.subject LIKE '%' + @t + '%' AND a.send_request_date >= DATEADD(MINUTE, -30, GETDATE())
ORDER BY a.mailitem_id DESC;
"@
                $st = Invoke-Scalar $c $q @{ '@t' = $title }
                $s.MailStatus = if ($st -is [DBNull] -or -not $st) { 'not found' } else { [string]$st }
            }
            catch { $s.MailStatus = 'check failed: ' + $_.Exception.Message }
            finally { if ($c) { $c.Dispose() } }
        }
    }
}
catch {
    Write-Step ('ERROR: ' + $_.Exception.Message) 'Red'
}
finally {
    Write-Step "`n=== SUMMARY ===" 'Green'
    if ($summary) { $summary | Format-Table Instance, Result, Critical, Warnings, MailProfile, MailStatus -AutoSize -Wrap | Out-String -Width 250 | Write-Host }
    Write-Step "Reports folder  : $($Config.ReportsFolder)"
    Write-Step "Log file        : $logFile"
    Write-Step "MailStatus 'unsent' = still queued (check again later); 'failed' = see msdb.dbo.sysmail_event_log." 'DarkGray'
    try { Stop-Transcript | Out-Null } catch { }
    Read-Host "`nPress Enter to close"
}
