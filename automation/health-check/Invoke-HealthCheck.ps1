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
    AttachReport          = $true                        # attach the combined report (falls back to the email body)
    PerInstanceReports    = $false                       # also save one HTML file per instance
}

$ErrorActionPreference = 'Stop'

# -Instances arrives as one comma-separated string when relaunched with -File
if ($Instances) { $Instances = @($Instances -split ',' | ForEach-Object { $_.Trim(" '`"") } | Where-Object { $_ }) }

# =============================================================================
#  HELPERS
# =============================================================================
function Write-Step([string]$Text, [string]$Color = 'Cyan') { Write-Host $Text -ForegroundColor $Color }

function Start-SecondaryLogonService {
    # "Run as different user" / Start-Process -Credential need the Secondary Logon service (seclogon).
    # Starts it if stopped; if it is Disabled, sets it to Manual first. Needs local admin - if this
    # window is not elevated, a UAC prompt starts it. Returns $true when the service is running.
    $svc = Get-Service -Name seclogon -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Step 'WARNING: Secondary Logon service (seclogon) not found on this VM.' 'Yellow'; return $false }
    if ($svc.Status -eq 'Running') { Write-Step 'Secondary Logon service: running'; return $true }

    $startType = (Get-CimInstance -ClassName Win32_Service -Filter "Name='seclogon'" -ErrorAction SilentlyContinue).StartMode
    Write-Step "Secondary Logon service is $($svc.Status) (startup: $startType) - starting it..." 'Yellow'
    try {
        if ($startType -eq 'Disabled') { Set-Service -Name seclogon -StartupType Manual -ErrorAction Stop }
        Start-Service -Name seclogon -ErrorAction Stop
    }
    catch {
        Write-Step 'Not running elevated - approve the UAC prompt to start the Secondary Logon service.' 'Yellow'
        $cmd = "if ((Get-CimInstance Win32_Service -Filter `"Name='seclogon'`").StartMode -eq 'Disabled') { Set-Service seclogon -StartupType Manual }; Start-Service seclogon"
        try { Start-Process -FilePath "$PSHOME\powershell.exe" -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList @('-NoProfile', '-Command', $cmd) }
        catch { Write-Step "Could not elevate: $($_.Exception.Message)" 'Red' }
    }
    $svc = Get-Service -Name seclogon
    for ($i = 0; $i -lt 10 -and $svc.Status -ne 'Running'; $i++) { Start-Sleep -Seconds 1; $svc.Refresh() }
    if ($svc.Status -eq 'Running') {
        Write-Step 'Secondary Logon service: started' 'Green'
        if ($startType -eq 'Disabled') { Write-Step 'NOTE: its startup type was Disabled and is now Manual (needed for Run as different user).' 'Yellow' }
        return $true
    }
    Write-Step 'WARNING: Secondary Logon service could not be started - running as a different user will fail.' 'Red'
    return $false
}

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
    # 'Database Mail XPs' off = profiles may exist but sp_send_dbmail is blocked -> treat as not configured
    $xps = Invoke-Scalar $Connection "SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'Database Mail XPs';"
    if ($null -eq $xps -or $xps -is [DBNull] -or [int]$xps -ne 1) { return $null }
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

function Enc([string]$Value) { return [System.Net.WebUtility]::HtmlEncode($Value) }

function Send-DbMail($Connection, [string]$MailProfileName, [string]$Subject, [string]$Html, [string]$Importance, [string]$Attachment = '') {
    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = 'msdb.dbo.sp_send_dbmail'
    $cmd.CommandType = [System.Data.CommandType]::StoredProcedure
    $cmd.CommandTimeout = 120
    [void]$cmd.Parameters.AddWithValue('@profile_name', $MailProfileName)
    [void]$cmd.Parameters.AddWithValue('@recipients', $Config.Recipients)
    if ($Config.CopyRecipients) { [void]$cmd.Parameters.AddWithValue('@copy_recipients', $Config.CopyRecipients) }
    [void]$cmd.Parameters.AddWithValue('@subject', $Subject)
    $pBody = $cmd.Parameters.Add('@body', [System.Data.SqlDbType]::NVarChar, -1); $pBody.Value = $Html
    [void]$cmd.Parameters.AddWithValue('@body_format', 'HTML')
    [void]$cmd.Parameters.AddWithValue('@importance', $Importance)
    if ($Attachment) { [void]$cmd.Parameters.AddWithValue('@file_attachments', $Attachment) }
    $pMailItemId = $cmd.Parameters.Add('@mailitem_id', [System.Data.SqlDbType]::Int); $pMailItemId.Direction = [System.Data.ParameterDirection]::Output
    [void]$cmd.ExecuteNonQuery()
    return [int]$pMailItemId.Value
}

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
        if (-not (Start-SecondaryLogonService)) {
            $ans = Read-Host 'Continue as the CURRENT user instead? (Y/N)'
            if ($ans -notmatch '^[Yy]') { exit 1 }
            $UseCurrentUser = $true
        }
    }
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
$combinedFile = $null
$mailStatus = 'Not sent'
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

    $mailCandidates = @()

    foreach ($t in $targets) {
        $row = [ordered]@{ Instance = $t.Instance; Result = ''; Critical = ''; Warnings = ''; Html = '' }
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

            $mailProfile = $null
            try { $mailProfile = Get-MailProfileName $conn } catch { }
            if ($mailProfile) { $mailCandidates += [pscustomobject]@{ Instance = $t.Instance; Profile = $mailProfile; Local = [bool]$t.Service } }
            else { Write-Step 'Database Mail not configured / enabled here - another instance will send the email, if any.' 'Yellow' }

            # Run script 44 without its own email; return the HTML + counts
            $sql = $sqlTemplate
            $sql = Set-SqlConfigValue $sql '(@SendEmail\s+bit\s*=\s*)\d'                            '0' '@SendEmail'
            $sql = Set-SqlConfigValue $sql '(@ShowResultSets\s+bit\s*=\s*)\d'                       '0' '@ShowResultSets'
            $sql = Set-SqlConfigValue $sql '(@SendOnlyIfIssues\s+bit\s*=\s*)\d'                     '0' '@SendOnlyIfIssues'
            $sql = Set-SqlConfigValue $sql "(@ReportTitle\s+nvarchar\(200\)\s*=\s*)N'(?:[^']|'')*'" (ConvertTo-SqlLiteral $title) '@ReportTitle'
            $sql += "`r`nSELECT @html AS html_report, @crit AS crit_count, @warn AS warn_count;`r`n"

            $cmd = $conn.CreateCommand()
            $cmd.CommandText    = $sql
            $cmd.CommandTimeout = $Config.QueryTimeoutSec
            Write-Step 'Collecting health check data...'
            $reader = $cmd.ExecuteReader()
            $html = $null
            do {
                if ($reader.FieldCount -gt 0 -and $reader.GetName(0) -eq 'html_report') {
                    while ($reader.Read()) {
                        if (-not $reader.IsDBNull(0)) { $html = $reader.GetString(0) }
                        $row.Critical = [string]$reader.GetValue(1); $row.Warnings = [string]$reader.GetValue(2)
                    }
                }
                else { while ($reader.Read()) { } }
            } while ($reader.NextResult())
            $reader.Close()

            if (-not $html) { throw 'The health check returned no report.' }
            $row.Html = $html
            $row.Result = if ([int]$row.Critical -gt 0) { 'CRITICAL' } elseif ([int]$row.Warnings -gt 0) { 'WARNING' } else { 'OK' }
            Write-Step "Result          : $($row.Result) ($($row.Critical) critical, $($row.Warnings) warnings)" $(if ($row.Result -eq 'OK') { 'Green' } else { 'Yellow' })
            if ($Config.PerInstanceReports) {
                $p = Join-Path $Config.ReportsFolder ((Get-SafeFileName $t.Instance) + '_' + $Label + $(if ($Ticket) { '_' + $Ticket } else { '' }) + '_' + (Get-Date -Format 'yyyyMMdd_HHmm') + '.html')
                [System.IO.File]::WriteAllText($p, $html, [System.Text.Encoding]::UTF8)
            }
        }
        catch {
            $row.Result = 'FAILED: ' + $_.Exception.Message
            Write-Step $row.Result 'Red'
            if ($_.Exception.Message -match 'Login failed') {
                Write-Step "  -> $me has no login on $($t.Instance). Use the account you use for SSMS (cancel = current user)." 'Yellow'
            }
        }
        finally { if ($conn) { $conn.Dispose() } }
        $summary += [pscustomobject]$row
    }

    # =========================================================================
    #  ONE COMBINED REPORT + ONE EMAIL FOR THE WHOLE VM
    # =========================================================================
    $nCrit = @($summary | Where-Object { $_.Result -eq 'CRITICAL' -or $_.Result -like 'FAILED*' -or $_.Result -like 'SKIPPED*' }).Count
    $nWarn = @($summary | Where-Object { $_.Result -eq 'WARNING' }).Count
    $tag   = if ($nCrit -gt 0) { 'CRITICAL' } elseif ($nWarn -gt 0) { 'WARNING' } else { 'OK' }
    $bannerColor = switch ($tag) { 'CRITICAL' { '#f8d7da' } 'WARNING' { '#fff3cd' } default { '#d4edda' } }

    # <head> (styles) from the first instance report, plus an instance heading style
    $firstHtml = ($summary | Where-Object { $_.Html } | Select-Object -First 1).Html
    $head = if ($firstHtml -and $firstHtml -match '(?s)^(.*?)<body[^>]*>') { $Matches[1] } else { '<html><head></head>' }
    $head = $head -replace '</head>', '<style>h1{color:#fff;background:#1f4e79;padding:6px 10px;font-size:18px;margin:28px 0 6px 0} .banner{padding:10px 14px;font-size:14px;font-weight:600;margin:8px 0}</style></head>'

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<h2>$(Enc $title) - $(Enc $env:COMPUTERNAME)</h2>")
    [void]$sb.Append("<div class='banner' style='background:$bannerColor'>$tag - $($summary.Count) instance(s): $nCrit critical / failed, $nWarn with warnings</div>")
    [void]$sb.Append("<div>Run by $(Enc $me) at $(Get-Date -Format 'yyyy-MM-dd HH:mm')</div><h3>Summary</h3><table><tr><th>Instance</th><th>Result</th><th>Critical</th><th>Warnings</th></tr>")
    foreach ($r in $summary) {
        $style = if ($r.Result -eq 'OK') { '' } elseif ($r.Result -eq 'WARNING') { " style='background-color:#fff3cd'" } else { " style='background-color:#f8d7da'" }
        [void]$sb.Append("<tr$style><td>$(Enc $r.Instance)</td><td>$(Enc $r.Result)</td><td>$(Enc $r.Critical)</td><td>$(Enc $r.Warnings)</td></tr>")
    }
    [void]$sb.Append('</table>')
    $header = $sb.ToString()

    $fullParts = @(); $shortParts = @()
    foreach ($r in $summary) {
        $body = if ($r.Html -and $r.Html -match '(?s)<body[^>]*>(.*)</body>') { $Matches[1] } else { "<div class='banner' style='background:#f8d7da'>$(Enc $r.Result)</div>" }
        $fullParts += "<h1>$(Enc $r.Instance)</h1>" + $body
        # email body: only each instance's "Needs attention" table
        $attn = if ($r.Html -and $r.Html -match '(?s)(<h3>Needs attention</h3>.*?</table>)') { $Matches[1] } else { "<div class='banner' style='background:#f8d7da'>$(Enc $r.Result)</div>" }
        $shortParts += "<h1>$(Enc $r.Instance)</h1>" + $attn
    }
    $combinedHtml = $head + '<body>' + $header + ($fullParts -join '') + '</body></html>'
    $combinedFile = Join-Path $Config.ReportsFolder ((Get-SafeFileName $env:COMPUTERNAME) + '_' + $Label + $(if ($Ticket) { '_' + $Ticket } else { '' }) + '_' + (Get-Date -Format 'yyyyMMdd_HHmm') + '.html')
    [System.IO.File]::WriteAllText($combinedFile, $combinedHtml, [System.Text.Encoding]::UTF8)
    Write-Step "`nCombined report : $combinedFile" 'Green'

    $subject = "[$tag] $title - $env:COMPUTERNAME - $($summary.Count) instance(s) - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    $importance = if ($tag -eq 'CRITICAL') { 'High' } else { 'Normal' }
    $sender = @($mailCandidates | Sort-Object @{ Expression = { -not $_.Local } }) | Select-Object -First 1
    if (-not $sender) {
        $mailStatus = 'Not sent - no instance with Database Mail'
        Write-Step 'No instance has Database Mail configured/enabled - email not sent.' 'Yellow'
    }
    else {
        $c = $null
        try {
            $c = New-SqlConnection $sender.Instance; $c.Open()
            $sizeBytes = (Get-Item -LiteralPath $combinedFile).Length
            $maxBytes = 0
            try { $maxBytes = [int64](Invoke-Scalar $c "SELECT CAST(paramvalue AS bigint) FROM msdb.dbo.sysmail_configuration WHERE paramname = N'MaxFileSize';") } catch { }
            $attach = $Config.AttachReport -and ($maxBytes -le 0 -or $sizeBytes -le $maxBytes)
            if ($Config.AttachReport -and -not $attach) { Write-Step ("Report is {0:N0} KB, above Database Mail MaxFileSize ({1:N0} KB) - sending it in the email body instead." -f ($sizeBytes / 1KB), ($maxBytes / 1KB)) 'Yellow' }
            $mailId = $null
            if ($attach) {
                try {
                    $shortHtml = $head + '<body>' + $header + ($shortParts -join '') + "<p style='color:#555'>The full report for every instance is attached: $(Enc (Split-Path $combinedFile -Leaf))</p></body></html>"
                    $mailId = Send-DbMail $c $sender.Profile $subject $shortHtml $importance $combinedFile
                    $mailStatus = 'Queued with attachment'
                }
                catch {
                    Write-Step "Attachment not possible ($($_.Exception.Message)) - sending the full report in the email body instead." 'Yellow'
                    Write-Step '  (the SQL Server service account must be able to read the Reports folder on a local disk)' 'DarkGray'
                }
            }
            if (-not $mailId) {
                $mailId = Send-DbMail $c $sender.Profile $subject $combinedHtml $importance
                $mailStatus = 'Queued (report in body)'
            }
            Write-Step "Email queued    : mailitem_id $mailId via $($sender.Instance) / profile '$($sender.Profile)'" 'Green'

            Write-Step "Waiting $($Config.MailCheckDelaySec)s to check Database Mail delivery..."
            Start-Sleep -Seconds $Config.MailCheckDelaySec
            $q = @"
SELECT a.sent_status + CASE WHEN a.sent_status = 'failed'
       THEN ' - ' + ISNULL((SELECT TOP (1) LEFT(l.description, 200) FROM msdb.dbo.sysmail_event_log l WHERE l.mailitem_id = a.mailitem_id ORDER BY l.log_id DESC), '') ELSE '' END
FROM msdb.dbo.sysmail_allitems AS a WHERE a.mailitem_id = @id;
"@
            $st = Invoke-Scalar $c $q @{ '@id' = $mailId }
            $mailStatus = "$mailStatus - " + $(if ($null -eq $st -or $st -is [DBNull]) { 'status not found' } else { [string]$st })
        }
        catch {
            $mailStatus = 'Send failed: ' + $_.Exception.Message
            Write-Step "WARNING: email not sent - $($_.Exception.Message)" 'Yellow'
        }
        finally { if ($c) { $c.Dispose() } }
    }
}
catch {
    Write-Step ('ERROR: ' + $_.Exception.Message) 'Red'
}
finally {
    Write-Step "`n=== SUMMARY ===" 'Green'
    if ($summary) { $summary | Format-Table Instance, Result, Critical, Warnings -AutoSize -Wrap | Out-String -Width 250 | Write-Host }
    Write-Step "Email           : $mailStatus"
    Write-Step "Report          : $combinedFile"
    Write-Step "Log file        : $logFile"
    if ($combinedFile -and ($mailStatus -notlike 'Queued*') -and (Test-Path -LiteralPath $combinedFile)) {
        Write-Step 'Opening the combined report...' 'Yellow'
        try { Invoke-Item -LiteralPath $combinedFile } catch { }
    }
    try { Stop-Transcript | Out-Null } catch { }
    Read-Host "`nPress Enter to close"
}
