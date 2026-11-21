<#
.SYNOPSIS
    Collects the latest health & performance check of every SQL Server instance from
    DBAdmin.dbo.DBA_PerfCheck_Report, writes ONE HTML report per VM and sends ONE email
    with all the files attached.

.DESCRIPTION
    The check itself runs on every instance as a SQL Agent job (HealthPerfCheck_AgentJob.sql,
    PART 2) and saves its result in DBAdmin. This script only reads those rows:
      - connects to every instance in $Config.Instances with a SQL login that has SELECT on
        DBAdmin.dbo.DBA_PerfCheck_Report and nothing else (PART 3)
      - takes each instance's latest run (started within MaxAgeMinutes); runs still going
        are waited for, up to WaitMinutes
      - instances that are SECONDARY for every availability group saved a SKIPPED row: listed,
        not reported; the others report only the AGs they are primary for
      - groups the instances by VM (physical host), writes <VM>_PERF_<label>_<time>.html
        per VM to Reports\ and emails them all through Database Mail on MailInstance
        (an instance on THIS machine, Windows authentication: Database Mail attaches files
        only for Windows logins), or SMTP if SmtpServer is set
      - an instance with no row, still running, failed or not reachable is shown as such

    Run by a SQL Agent job on ONE instance (HealthPerfCheck_AgentJob.sql, PART 4): CmdExec,
    no proxy, so it runs as the Agent service account and no Windows password is needed.

    The SQL login's password is stored encrypted with Windows DPAPI:
      CredentialScope 'CurrentUser' (default): only the Windows account that saved it can
        decrypt it, on this machine only (file PerfCheck.<account>.cred)
      'LocalMachine': any account on this machine that can read PerfCheck.cred (NTFS)
    It is decrypted only into memory (SecureString / SqlCredential), never written to a
    connection string, the log or job history.

    Exit codes: 0 = email sent (findings are in the email), 3 = script error, 4 = no email sent.

.EXAMPLE
    .\Collect-PerfCheckReports.ps1 -SaveCredentialFor 'NT SERVICE\SQLAgent$MARS01'
        # one-time, by an admin (secondary logon): hands the SQL login password over to the
        # account that runs the job; its first run re-encrypts it for that account only
.EXAMPLE
    .\Collect-PerfCheckReports.ps1        # manual test: asks for the password if none is saved for you
#>
[CmdletBinding()]
param(
    [string]   $Label = '',               # only rows with this label ('' = $Config.RunLabel)
    [string[]] $Instances,                # only these instances (default: $Config.Instances)
    [switch]   $ResetCredential,          # forget the saved SQL login (for the account running this) and ask again
    [string]   $SaveCredentialFor         # one-time: hand the SQL login password over to this Windows account, then exit
)

# =====================================================================================
#  CONFIG
# =====================================================================================
$Config = @{
    Instances         = @(
        'MARSDBW1\MARS01', 'MARSDBW1\MARS02', 'MARSDBW1\MARS03',
        'MARSDBW2\MARS01', 'MARSDBW2\MARS02', 'MARSDBW2\MARS03',
        'MARSDBW3\MARS01', 'MARSDBW3\MARS02', 'MARSDBW3\MARS03')   # instance names, not AG listeners
    ReportDatabase    = 'DBAdmin'
    RunLabel          = 'SCHEDULED'      # label of the check job's runs ('' = any label)
    MaxAgeMinutes     = 120              # only runs started within this many minutes count
    WaitMinutes       = 15               # wait this long for runs still going / not started yet
    PollSec           = 30

    Recipients        = 'dba-team@yourcompany.com'     # ; separated
    CopyRecipients    = ''
    FromAddress       = ''               # '' = the profile account's address
    MailInstance      = 'MARSDBW1\MARS01' # instance on THIS machine that sends the email (Database Mail)
    MailProfile       = ''               # '' = default public profile, else the first profile with an account
    ReportTitle       = 'SQL Server Health & Performance Check'

    SqlLogin          = 'dba_perfcheck'  # reader login (PART 3 of HealthPerfCheck_AgentJob.sql)
    CredentialScope   = 'CurrentUser'    # or 'LocalMachine'
    CredentialFile    = Join-Path $PSScriptRoot 'PerfCheck.cred'   # LocalMachine scope file
    Encrypt           = $false           # $true = encrypt the SQL connections
    ConnectTimeoutSec = 15

    ReportsFolder     = Join-Path $PSScriptRoot 'Reports'
    LogsFolder        = Join-Path $PSScriptRoot 'Logs'
    KeepFilesDays     = 30

    SmtpServer        = ''               # optional: send straight from this machine if Database Mail can't
    SmtpPort          = 25
    SmtpUseSsl        = $false
    SmtpFrom          = ''
}

$ErrorActionPreference = 'Stop'
$script:RunAs = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$script:Interactive = [Environment]::UserInteractive -and $Host.Name -eq 'ConsoleHost'
Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Web
$script:Entropy = [System.Text.Encoding]::UTF8.GetBytes('DBA.PerfCheck.v1')

function Write-Step([string]$Text, [string]$Color = 'Cyan') { Write-Host $Text -ForegroundColor $Color }
function Enc([string]$Value) { return [System.Web.HttpUtility]::HtmlEncode($Value) }
function Get-SafeFileName([string]$Value) { return ($Value -replace '[\\/:*?"<>|\s,]', '_') }
function Get-HostFromName([string]$Instance) { return (($Instance -replace '^(tcp|np|lpc):', '').Split('\')[0].Split(',')[0]).ToUpperInvariant() }

# =====================================================================================
#  SQL LOGIN - saved with DPAPI
# =====================================================================================
function Get-CredentialPath([string]$Scope) {
    if ($Scope -eq 'CurrentUser') { return (Join-Path $PSScriptRoot ('PerfCheck.{0}.cred' -f (Get-SafeFileName ($script:RunAs -replace '\\', '_')))) }
    return $Config.CredentialFile
}
function Get-HandoffPath([string]$Sid) { return (Join-Path $PSScriptRoot ('PerfCheck.{0}.handoff' -f $Sid)) }

function Protect-ToFile([pscredential]$Credential, [string]$Path, [string]$Scope, [string[]]$Grants, [hashtable]$Extra) {
    $plain = [System.Text.Encoding]::UTF8.GetBytes($Credential.GetNetworkCredential().Password)
    try {
        $enc = [System.Security.Cryptography.ProtectedData]::Protect($plain, $script:Entropy, [System.Security.Cryptography.DataProtectionScope]::$Scope)
        $obj = @{ user = $Credential.UserName; pwd = [Convert]::ToBase64String($enc); scope = $Scope; saved_by = $script:RunAs; saved_at = (Get-Date -Format 'yyyy-MM-dd HH:mm') }
        if ($Extra) { foreach ($k in $Extra.Keys) { $obj[$k] = $Extra[$k] } }
        [System.IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $obj -Compress))
        $ErrorActionPreference = 'Continue'
        $out = & icacls.exe "$Path" /inheritance:r /grant:r @Grants 2>&1
        $ok = ($LASTEXITCODE -eq 0); $ErrorActionPreference = 'Stop'
        if (-not $ok) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue; throw "Could not restrict the file permissions: $out" }
    }
    finally { [Array]::Clear($plain, 0, $plain.Length) }
}

function Unprotect-FromFile([string]$Path) {
    $obj = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $scope = if ($obj.scope -eq 'CurrentUser') { 'CurrentUser' } else { 'LocalMachine' }
    $dec = [System.Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($obj.pwd), $script:Entropy, [System.Security.Cryptography.DataProtectionScope]::$scope)
    $ss = New-Object System.Security.SecureString
    foreach ($ch in [System.Text.Encoding]::UTF8.GetString($dec).ToCharArray()) { $ss.AppendChar($ch) }
    [Array]::Clear($dec, 0, $dec.Length); $ss.MakeReadOnly()
    return [pscustomobject]@{ Credential = (New-Object System.Management.Automation.PSCredential ([string]$obj.user, $ss)); Info = $obj }
}

function Save-SqlCredential([pscredential]$Credential) {
    $scope = if ($Config.CredentialScope -eq 'LocalMachine') { 'LocalMachine' } else { 'CurrentUser' }
    $path = Get-CredentialPath $scope
    Protect-ToFile $Credential $path $scope @('*S-1-5-32-544:F', '*S-1-5-18:F', "$($script:RunAs):F") $null
    Write-Step "SQL login saved ($scope scope$(if ($scope -eq 'CurrentUser') { ", only $($script:RunAs) can read it" })): $path" 'Green'
}

function Read-SqlCredential {
    # 1. this account's CurrentUser file  2. a hand-over file for this account (re-saved, then deleted)  3. the LocalMachine file
    $cuPath = Get-CredentialPath 'CurrentUser'
    $handoff = Get-HandoffPath ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    if (-not (Test-Path -LiteralPath $cuPath) -and (Test-Path -LiteralPath $handoff)) {
        $h = Unprotect-FromFile $handoff
        Write-Step "SQL login  : $($h.Info.user) handed over by $($h.Info.saved_by) on $($h.Info.saved_at) - saving it for $($script:RunAs)" 'DarkGray'
        try { Save-SqlCredential $h.Credential; if (Test-Path -LiteralPath (Get-CredentialPath $Config.CredentialScope)) { Remove-Item -LiteralPath $handoff -Force; Write-Step '  hand-over file deleted' 'DarkGray' } }
        catch { Write-Step "  could not re-save it ($($_.Exception.Message)) - the hand-over file is kept and used." 'Yellow' }
        return $h.Credential
    }
    foreach ($path in @($cuPath, $Config.CredentialFile) | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            $r = Unprotect-FromFile $path
            Write-Step "SQL login  : $($r.Info.user) ($($r.Info.scope) scope, saved by $($r.Info.saved_by) on $($r.Info.saved_at))" 'DarkGray'
            return $r.Credential
        }
        catch { Write-Step "Saved SQL login $path could not be read ($($_.Exception.Message)). Save it again (-ResetCredential, or -SaveCredentialFor)." 'Yellow' }
    }
    return $null
}

# =====================================================================================
#  SQL
# =====================================================================================
function Open-Sql([string]$Instance, [pscredential]$Credential, [switch]$Windows) {
    $enc = if ($Config.Encrypt) { 'True' } else { 'False' }
    $cs = "Server=$Instance;Database=$($Config.ReportDatabase);Application Name=DBA PerfCheck Collector;Connect Timeout=$($Config.ConnectTimeoutSec);Encrypt=$enc;TrustServerCertificate=True"
    if ($Windows) { $conn = New-Object System.Data.SqlClient.SqlConnection ($cs + ';Integrated Security=SSPI') }
    else {
        $ss = $Credential.Password.Copy(); $ss.MakeReadOnly()
        $conn = New-Object System.Data.SqlClient.SqlConnection ($cs, (New-Object System.Data.SqlClient.SqlCredential ($Credential.UserName, $ss)))
    }
    $conn.Open()
    return $conn
}

function Get-LatestRun($Conn, [string]$RunLabel) {
    $cmd = $Conn.CreateCommand(); $cmd.CommandTimeout = 60
    $cmd.CommandText = @"
SELECT TOP (1) run_id, instance_name, vm_name, label, run_start, run_end, status, critical, warnings, ag_roles, summary_html, report_html, error_message
FROM dbo.DBA_PerfCheck_Report
WHERE run_start >= DATEADD(MINUTE, -@age, GETDATE()) AND (@label = N'' OR label = @label)
ORDER BY run_id DESC;
"@
    [void]$cmd.Parameters.AddWithValue('@age', [int]$Config.MaxAgeMinutes)
    [void]$cmd.Parameters.AddWithValue('@label', [string]$RunLabel)
    $rd = $cmd.ExecuteReader()
    try {
        if (-not $rd.Read()) { return $null }
        $row = @{}
        for ($i = 0; $i -lt $rd.FieldCount; $i++) { $row[$rd.GetName($i)] = if ($rd.IsDBNull($i)) { $null } else { $rd.GetValue($i) } }
        return $row
    }
    finally { $rd.Close() }
}

# =====================================================================================
#  EMAIL
# =====================================================================================
function Send-Report([string]$Subject, [string]$BodyAttached, [string]$BodyNoFiles, [string[]]$Files, [string]$Importance) {
    $notes = @()
    # 1. Database Mail on MailInstance (this machine) as the Windows account running the script
    if ($Config.MailInstance) {
        $c = $null
        try {
            $c = Open-Sql $Config.MailInstance $null -Windows
            $q = $c.CreateCommand(); $q.CommandTimeout = 60
            $q.CommandText = "SELECT CAST(paramvalue AS bigint) FROM msdb.dbo.sysmail_configuration WHERE paramname = N'MaxFileSize';"
            $maxBytes = [int64]$q.ExecuteScalar()
            $profile = $Config.MailProfile
            if (-not $profile) {
                $q.CommandText = @"
SELECT TOP (1) p.name FROM msdb.dbo.sysmail_profile AS p
LEFT JOIN msdb.dbo.sysmail_principalprofile AS pp ON pp.profile_id = p.profile_id AND pp.is_default = 1 AND pp.principal_sid = 0x00
WHERE EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profileaccount AS pa WHERE pa.profile_id = p.profile_id)
ORDER BY CASE WHEN pp.profile_id IS NOT NULL THEN 0 ELSE 1 END, p.profile_id;
"@
                $profile = [string]$q.ExecuteScalar()
            }
            if (-not $profile) { throw "no Database Mail profile with an account on $($Config.MailInstance) (run database_mail_setup.sql)" }
            $tooBig = @($Files | Where-Object { $maxBytes -gt 0 -and (Get-Item -LiteralPath $_).Length -gt $maxBytes })
            $attach = -not $tooBig.Count
            if (-not $attach) { $notes += ("{0} file(s) above Database Mail MaxFileSize ({1:N0} KB) - raise it with database_mail_setup.sql (@MaxFileSizeMB)" -f $tooBig.Count, ($maxBytes / 1KB)) }
            $s = $c.CreateCommand(); $s.CommandTimeout = 120
            $s.CommandText = 'EXEC @rc = msdb.dbo.sp_send_dbmail @profile_name = @p, @recipients = @to, @copy_recipients = @cc, @from_address = @from, @subject = @subj, @body = @body, @body_format = ''HTML'', @importance = @imp, @file_attachments = @files, @mailitem_id = @id OUTPUT;'
            [void]$s.Parameters.AddWithValue('@p', $profile)
            [void]$s.Parameters.AddWithValue('@to', $Config.Recipients)
            [void]$s.Parameters.AddWithValue('@cc', $(if ($Config.CopyRecipients) { $Config.CopyRecipients } else { [DBNull]::Value }))
            [void]$s.Parameters.AddWithValue('@from', $(if ($Config.FromAddress) { $Config.FromAddress } else { [DBNull]::Value }))
            [void]$s.Parameters.AddWithValue('@subj', $Subject)
            $pb = $s.Parameters.Add('@body', [System.Data.SqlDbType]::NVarChar, -1); $pb.Value = $(if ($attach) { $BodyAttached } else { $BodyNoFiles })
            [void]$s.Parameters.AddWithValue('@imp', $Importance)
            [void]$s.Parameters.AddWithValue('@files', $(if ($attach -and $Files.Count) { $Files -join ';' } else { [DBNull]::Value }))
            $pid_ = $s.Parameters.Add('@id', [System.Data.SqlDbType]::Int); $pid_.Direction = 'Output'
            $prc = $s.Parameters.Add('@rc', [System.Data.SqlDbType]::Int); $prc.Direction = 'Output'
            [void]$s.ExecuteNonQuery()
            if ($prc.Value -ne 0 -or $pid_.Value -is [DBNull]) { throw "sp_send_dbmail returned $($prc.Value)" }
            $id = [int]$pid_.Value
            # wait (up to 60 s) until Database Mail hands it to the SMTP server
            $st = 'unsent'
            for ($i = 0; $i -lt 12 -and $st -eq 'unsent'; $i++) {
                Start-Sleep -Seconds 5
                $q.CommandText = "SELECT sent_status FROM msdb.dbo.sysmail_allitems WHERE mailitem_id = $id;"; $st = [string]$q.ExecuteScalar()
            }
            if ($st -eq 'failed') {
                $q.CommandText = "SELECT TOP (1) description FROM msdb.dbo.sysmail_event_log WHERE mailitem_id = $id ORDER BY log_id DESC;"
                throw "Database Mail item $id failed: $([string]$q.ExecuteScalar())"
            }
            $how = if ($attach) { "$($Files.Count) file(s) attached" } else { 'no attachments (' + ($notes -join '; ') + ')' }
            Write-Step "Email      : Database Mail item $id ($st) via $($Config.MailInstance), profile '$profile', $how" 'Green'
            return @{ Sent = $true; Status = "Database Mail item $id ($st), $how" }
        }
        catch { $notes += "Database Mail on $($Config.MailInstance) as $($script:RunAs): $($_.Exception.Message)"; Write-Step "  $($notes[-1])" 'Yellow' }
        finally { if ($c) { $c.Dispose() } }
    }
    # 2. SMTP straight from this machine
    if ($Config.SmtpServer) {
        $msg = $null; $client = $null
        try {
            $msg = New-Object System.Net.Mail.MailMessage
            $msg.From = $(if ($Config.SmtpFrom) { $Config.SmtpFrom } else { "sqlperf@$env:COMPUTERNAME" })
            foreach ($r in ($Config.Recipients -split ';' | Where-Object { $_.Trim() })) { $msg.To.Add($r.Trim()) }
            foreach ($r in ($Config.CopyRecipients -split ';' | Where-Object { $_.Trim() })) { $msg.CC.Add($r.Trim()) }
            $msg.Subject = $Subject; $msg.Body = $BodyAttached; $msg.IsBodyHtml = $true
            if ($Importance -eq 'High') { $msg.Priority = [System.Net.Mail.MailPriority]::High }
            foreach ($f in $Files) { $msg.Attachments.Add((New-Object System.Net.Mail.Attachment $f)) }
            $client = New-Object System.Net.Mail.SmtpClient ($Config.SmtpServer, [int]$Config.SmtpPort)
            $client.EnableSsl = [bool]$Config.SmtpUseSsl
            $client.Send($msg)
            Write-Step "Email      : sent via SMTP $($Config.SmtpServer)" 'Green'
            return @{ Sent = $true; Status = "SMTP $($Config.SmtpServer)" }
        }
        catch { $notes += "SMTP $($Config.SmtpServer): $($_.Exception.Message)" }
        finally { if ($msg) { $msg.Dispose() }; if ($client) { $client.Dispose() } }
    }
    return @{ Sent = $false; Status = ($notes -join ' | ') }
}

# =====================================================================================
#  ONE-TIME: hand the SQL login password over to the account that runs the job
# =====================================================================================
if ($SaveCredentialFor) {
    $rc = 3
    try {
        $sid = (New-Object System.Security.Principal.NTAccount $SaveCredentialFor).Translate([System.Security.Principal.SecurityIdentifier]).Value
        $hc = Get-Credential -UserName $Config.SqlLogin -Message "Password of SQL login '$($Config.SqlLogin)' for $SaveCredentialFor"
        if (-not $hc) { throw 'cancelled' }
        $path = Get-HandoffPath $sid
        Protect-ToFile $hc $path 'LocalMachine' @('*S-1-5-32-544:F', '*S-1-5-18:F', "*$($sid):M") @{ for_account = $SaveCredentialFor; for_sid = $sid }
        Write-Step "Handed over to $SaveCredentialFor : $path" 'Green'
        Write-Step "Only Administrators, SYSTEM and $SaveCredentialFor can read it. Its first run re-encrypts it for that account only and deletes this file." 'Green'
        $rc = 0
    }
    catch { Write-Step "NOT SAVED: $($_.Exception.Message) (account name: SELECT servicename, service_account FROM sys.dm_server_services;)" 'Red' }
    exit $rc
}

# =====================================================================================
#  MAIN
# =====================================================================================
foreach ($d in @($Config.ReportsFolder, $Config.LogsFolder)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
$stamp = Get-Date -Format 'yyyyMMdd_HHmm'
$logFile = Join-Path $Config.LogsFolder "Collect_$stamp.log"
try { Start-Transcript -Path $logFile -Append | Out-Null } catch { }
$exitCode = 3
try {
    $runLabel = if ($Label) { $Label } else { [string]$Config.RunLabel }
    $list = if ($Instances) { $Instances } else { @($Config.Instances) }
    Write-Step "Collector  : $($script:RunAs) on $env:COMPUTERNAME - $($list.Count) instance(s), label '$runLabel', runs of the last $($Config.MaxAgeMinutes) min"

    # ---- SQL login ----
    if ($ResetCredential) { $rp = Get-CredentialPath $Config.CredentialScope; if (Test-Path -LiteralPath $rp) { Remove-Item -LiteralPath $rp -Force; Write-Step "Saved SQL login removed: $rp" 'Yellow' } }
    $cred = if ($ResetCredential) { $null } else { Read-SqlCredential }
    if (-not $cred -and $script:Interactive) {
        $cred = Get-Credential -UserName $Config.SqlLogin -Message "SQL login that reads DBAdmin.dbo.DBA_PerfCheck_Report"
        if ($cred -and (Read-Host "Save it encrypted for $($script:RunAs) on this machine? (Y/N)") -match '^[Yy]') { Save-SqlCredential $cred }
    }
    if (-not $cred) { throw "No saved SQL login for $($script:RunAs). Hand it over once: Collect-PerfCheckReports.ps1 -SaveCredentialFor '$($script:RunAs)' (from an admin prompt)." }

    # ---- read the latest run of every instance; wait for runs still going ----
    $res = [ordered]@{}
    foreach ($i in $list) { $res[$i] = [pscustomobject]@{ Instance = $i; VM = (Get-HostFromName $i); Status = 'NO DATA'; Roles = ''; Run = ''; Crit = 0; Warn = 0; Summary = ''; Report = ''; Note = '' } }
    $deadline = (Get-Date).AddMinutes([int]$Config.WaitMinutes)
    do {
        $pending = @($res.Values | Where-Object { $_.Status -in @('NO DATA', 'RUNNING', 'UNREACHABLE') })
        foreach ($r in $pending) {
            $conn = $null
            try {
                $conn = Open-Sql $r.Instance $cred
                $row = Get-LatestRun $conn $runLabel
                if (-not $row) { $r.Status = 'NO DATA'; $r.Note = "No run with label '$runLabel' in the last $($Config.MaxAgeMinutes) min"; continue }
                $r.VM = ([string]$row['vm_name']).ToUpperInvariant(); $r.Roles = [string]$row['ag_roles']
                $r.Run = ([datetime]$row['run_start']).ToString('yyyy-MM-dd HH:mm') + $(if ($row['run_end']) { ' - ' + ([datetime]$row['run_end']).ToString('HH:mm') } else { '' })
                $r.Status = [string]$row['status']; $r.Crit = [int]$row['critical']; $r.Warn = [int]$row['warnings']
                $r.Summary = [string]$row['summary_html']; $r.Report = [string]$row['report_html']
                $r.Note = switch ($r.Status) {
                    'RUNNING' { 'Still running' }
                    'SKIPPED' { 'Skipped - SECONDARY for every availability group' }
                    'FAILED'  { 'The check failed: ' + [string]$row['error_message'] }
                    default   { "$($r.Crit) critical, $($r.Warn) warning(s)" } }
            }
            catch { $r.Status = 'UNREACHABLE'; $r.Note = $_.Exception.Message }
            finally { if ($conn) { $conn.Dispose() } }
        }
        $pending = @($res.Values | Where-Object { $_.Status -in @('NO DATA', 'RUNNING', 'UNREACHABLE') })
        if ($pending.Count -and (Get-Date) -lt $deadline) {
            Write-Step "  waiting for: $(($pending | ForEach-Object { "$($_.Instance) ($($_.Status))" }) -join ', ')" 'DarkGray'
            Start-Sleep -Seconds ([int]$Config.PollSec)
        }
    } while ($pending.Count -and (Get-Date) -lt $deadline)
    foreach ($r in $res.Values) { Write-Step ("{0,-22} {1,-11} {2}" -f $r.Instance, $r.Status, $r.Note) $(switch ($r.Status) { 'OK' { 'Green' } 'WARNING' { 'Yellow' } 'SKIPPED' { 'DarkGray' } default { 'Red' } }) }

    # ---- one HTML file per VM ----
    $css = @"
<html><head><meta charset="utf-8"><style>
body{font-family:Segoe UI,Arial,sans-serif;font-size:12px;color:#222}
h1{color:#fff;background:#1f4e79;padding:6px 10px;font-size:18px;margin:24px 0 6px 0} h2{color:#1f4e79;margin-bottom:2px} h3{color:#1f4e79;margin:18px 0 4px 0;border-bottom:1px solid #1f4e79}
table{border-collapse:collapse;margin-bottom:8px} th{background:#1f4e79;color:#fff;padding:4px 6px;text-align:left;font-weight:600}
td{border:1px solid #d0d0d0;padding:3px 6px;vertical-align:top}
.banner{padding:10px 14px;font-size:14px;font-weight:600;margin:8px 0}
</style></head><body>
"@
    $bad = @('CRITICAL', 'FAILED', 'UNREACHABLE', 'NO DATA', 'RUNNING')
    $color = { param($t) switch ($t) { 'CRITICAL' { '#f8d7da' } 'WARNING' { '#fff3cd' } 'OK' { '#d4edda' } default { '#e2e3e5' } } }
    $rowColor = { param($st) if ($st -in $bad) { ' style="background:#f8d7da"' } elseif ($st -eq 'WARNING') { ' style="background:#fff3cd"' } else { '' } }
    $table = {
        param($rows, [switch]$WithVm)
        $h = '<table><tr>' + $(if ($WithVm) { '<th>VM</th>' } else { '' }) + '<th>status</th><th>instance</th><th>availability groups</th><th>run</th><th>outcome</th></tr>'
        foreach ($x in $rows) {
            $h += "<tr$(& $rowColor $x.Status)>" + $(if ($WithVm) { "<td>$(Enc $x.VM)</td>" } else { '' }) +
                  "<td>$(Enc $x.Status)</td><td>$(Enc $x.Instance)</td><td>$(Enc $x.Roles)</td><td>$(Enc $x.Run)</td><td>$(Enc $x.Note)</td></tr>"
        }
        return $h + '</table>'
    }
    $tagOf = { param($rows) if (@($rows | Where-Object { $_.Status -in $bad }).Count) { 'CRITICAL' } elseif (@($rows | Where-Object { $_.Status -eq 'WARNING' }).Count) { 'WARNING' } else { 'OK' } }
    $runInfo = "<div>Label: <b>$(Enc $runLabel)</b> &nbsp;|&nbsp; Collected by $(Enc $script:RunAs) on $(Enc $env:COMPUTERNAME) &nbsp;|&nbsp; $(Get-Date -Format 'yyyy-MM-dd HH:mm')</div>"
    $reported = @('OK', 'WARNING', 'CRITICAL')
    $files = @(); $vmBodies = @()
    foreach ($g in @($res.Values | Group-Object -Property VM | Sort-Object Name)) {
        $vm = [string]$g.Name; $rows = @($g.Group | Sort-Object Instance)
        $tag = & $tagOf $rows
        $checked = @($rows | Where-Object { $_.Status -in $reported })
        $headline = "$tag - $($checked.Count) instance(s) reported, $(@($rows | Where-Object { $_.Status -eq 'SKIPPED' }).Count) skipped (secondary only), $(@($rows | Where-Object { $_.Status -in $bad -and $_.Status -notin $reported }).Count) without a usable result"
        $head = "<h2>$(Enc $Config.ReportTitle) - $(Enc $vm)</h2><div class='banner' style='background:$(& $color $tag)'>$(Enc $headline)</div>$runInfo<h3>Instances on $(Enc $vm)</h3>$(& $table $rows)"
        $html = $css + $head + (($checked | ForEach-Object { $_.Report }) -join "<hr style='margin:30px 0'>") + '</body></html>'
        $f = Join-Path $Config.ReportsFolder ('{0}_PERF_{1}_{2}.html' -f (Get-SafeFileName $vm), (Get-SafeFileName $runLabel), $stamp)
        [System.IO.File]::WriteAllText($f, $html, [System.Text.Encoding]::UTF8)
        Write-Step "Report     : $f" 'Green'
        $files += $f
        $vmBodies += "<h2 style='margin-top:28px'>VM $(Enc $vm)</h2><div class='banner' style='background:$(& $color $tag)'>$(Enc $headline)</div>" + (($checked | ForEach-Object { $_.Summary }) -join "<hr style='margin:20px 0'>")
    }

    # ---- one email ----
    $all = @($res.Values)
    $tag = & $tagOf $all
    $vms = @($all | ForEach-Object { $_.VM } | Sort-Object -Unique)
    $nRep = @($all | Where-Object { $_.Status -in $reported }).Count; $nSkip = @($all | Where-Object { $_.Status -eq 'SKIPPED' }).Count
    $nMiss = @($all | Where-Object { $_.Status -notin $reported -and $_.Status -ne 'SKIPPED' }).Count
    $overall = "$tag - $nRep instance(s) reported on $($vms.Count) VM(s), $nSkip skipped (secondary only)" + $(if ($nMiss) { ", $nMiss without a usable result" } else { '' })
    $body = $css + "<h2>$(Enc $Config.ReportTitle) - $(Enc ($vms -join ', '))</h2><div class='banner' style='background:$(& $color $tag)'>$(Enc $overall)</div>$runInfo<h3>Summary</h3>$(& $table ($all | Sort-Object VM, Instance) -WithVm)" + ($vmBodies -join "<hr style='margin:30px 0'>")
    $names = (@($files | ForEach-Object { Split-Path $_ -Leaf })) -join ', '
    $bodyAttached = $body + "<p style='color:#555'>Full report per VM attached: $(Enc $names)</p></body></html>"
    $bodyNoFiles  = $body + "<p style='color:#555'>Full reports saved on $(Enc $env:COMPUTERNAME): $(Enc ($files -join '; '))</p></body></html>"
    $subject = "[$tag] $($Config.ReportTitle) [$runLabel] - $($vms -join ', ') - $nRep reported, $nSkip skipped" + $(if ($nMiss) { ", $nMiss missing" } else { '' })
    $sent = Send-Report $subject $bodyAttached $bodyNoFiles $files $(if ($tag -eq 'CRITICAL') { 'High' } else { 'Normal' })
    if ($sent.Sent) { $exitCode = 0 } else { Write-Step "EMAIL NOT SENT: $($sent.Status)" 'Red'; $exitCode = 4 }
}
catch {
    Write-Step "ERROR: $($_.Exception.Message)" 'Red'
    $exitCode = 3
}
finally {
    # housekeeping: reports and logs older than KeepFilesDays
    foreach ($d in @($Config.ReportsFolder, $Config.LogsFolder)) {
        try { Get-ChildItem -LiteralPath $d -File | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-[int]$Config.KeepFilesDays) } | Remove-Item -Force -ErrorAction SilentlyContinue } catch { }
    }
    Write-Step "Exit code  : $exitCode (0 email sent, 3 script error, 4 email not sent) - log: $logFile"
    try { Stop-Transcript | Out-Null } catch { }
}
exit $exitCode
