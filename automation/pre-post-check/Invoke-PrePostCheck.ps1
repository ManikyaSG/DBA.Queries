<#
.SYNOPSIS
    PRE / POST change health check for every SQL Server instance on this VM.
    PRE  : collects a full health-check snapshot (HC_Snapshot.sql), stores it on the VM
           as JSON and emails a "PRE captured" report.
    POST : collects the same snapshot, compares it with the stored PRE and emails
           SUCCESS (no differences) or DIFFERENCES FOUND (with a before -> after table).

.DESCRIPTION
    RDP in with the generic admin account and double-click Run-PrePostCheck.bat:
      1. Choose PRE or POST and enter the change ticket.
      2. Enter YOUR Windows account (as for SSMS "Run as different user"); the script
         relaunches itself as you. Cancel = run as the current account.
      3. Every SQL instance on the VM (+ servers.txt) is checked.
    Snapshots : Snapshots\<ticket>\<instance>_PRE|POST_<yyyyMMdd_HHmmss>.json
    Reports   : Reports\<instance>_<PRE|POST>_<ticket>_<yyyyMMdd_HHmm>.html
    Email     : Database Mail on each instance (preferred profile, else default/only profile).

    What is compared (POST vs PRE):
      instance settings, services, sp_configure, global trace flags, databases (state,
      recovery model, compat, owner, options, AG role/sync, backup folders), AG replicas
      (roles, primary, modes, health, listeners), AG databases per replica, cluster &
      quorum, disks, data/log files (paths, growth, max size), jobs (enabled, owner),
      logins, server role members, linked servers, endpoints, certificates, XE sessions,
      and NEW problems (issues present after but not before).
    Expected changes (listed, not failures): build / CU / KB / product level, SQL start time.
    Size drift is ignored unless big: file/DB size change > FileSizeDriftPct % and
    > FileSizeDriftMinMB MB, disk free space change > DiskFreeDriftPct % of the disk.

    Requirements: Windows PowerShell 5.1. No modules, sqlcmd or internet needed.
    Your SQL permissions: VIEW SERVER STATE, read msdb, DatabaseMailUserRole (or sysadmin).

.EXAMPLE
    .\Invoke-PrePostCheck.ps1                                    # interactive (what the .bat does)
.EXAMPLE
    .\Invoke-PrePostCheck.ps1 -Phase PRE  -Ticket CHG0012345
.EXAMPLE
    .\Invoke-PrePostCheck.ps1 -Phase POST -Ticket CHG0012345 -UseCurrentUser
#>
[CmdletBinding()]
param(
    [string]   $Phase = '',          # PRE or POST (prompted if empty)
    [string]   $Ticket,
    [switch]   $UseCurrentUser,
    [string[]] $Instances,
    [string]   $SqlFile,
    [switch]   $Inner
)

# =============================================================================
#  CONFIGURATION  <== change these once
# =============================================================================
$Config = @{
    Recipients            = 'dba-team@yourcompany.com'   # ; separated
    CopyRecipients        = ''
    MailProfile           = 'DBA_Mail'                   # preferred; else default / only profile on the instance
    ReportTitle           = 'SQL Server Change Check'
    IncludeLocalInstances = $true
    ServersFile           = Join-Path $PSScriptRoot 'servers.txt'
    SnapshotRoot          = Join-Path $PSScriptRoot 'Snapshots'
    ReportsFolder         = Join-Path $PSScriptRoot 'Reports'
    LogsFolder            = Join-Path $PSScriptRoot 'Logs'
    FileSizeDriftPct      = 10       # flag file / DB size change above this % ...
    FileSizeDriftMinMB    = 512      # ... and above this many MB
    DiskFreeDriftPct      = 5        # flag disk free-space change above this % of the disk size
    ConnectTimeoutSec     = 15
    QueryTimeoutSec       = 900
    Encrypt               = $false
    MailCheckDelaySec     = 20
}

$ErrorActionPreference = 'Stop'
$Phase = ([string]$Phase).Trim().ToUpperInvariant()
if ($Inner -and $Phase -notin @('PRE', 'POST')) { throw "Invalid -Phase '$Phase' (use PRE or POST)." }
if ($Instances) { $Instances = @($Instances -split ',' | ForEach-Object { $_.Trim(" '`"") } | Where-Object { $_ }) }

# What to compare per section: Key = identifies a row, Compare = must be equal,
# Expected = may change (listed as expected), Drift = numeric tolerance rule.
$Spec = [ordered]@{
    instance       = @{ Title = 'Instance';            Key = @('property_code'); Compare = @('value'); ExpectedKeys = @('build', 'sp_level', 'cu', 'kb', 'start_time') }
    services       = @{ Title = 'SQL Server services'; Key = @('servicename');   Compare = @('status', 'startup_type', 'service_account', 'ifi'); Expected = @('last_startup') }
    config         = @{ Title = 'sp_configure';        Key = @('name');          Compare = @('value_in_use') }
    traceflags     = @{ Title = 'Global trace flags';  Key = @('trace_flag');    Compare = @() }
    databases      = @{ Title = 'Databases';           Key = @('name');
                        Compare = @('state', 'user_access', 'recovery_model', 'compat_level', 'owner_name', 'is_read_only', 'page_verify', 'rcsi',
                                    'snapshot_isolation', 'is_encrypted', 'broker', 'trustworthy', 'query_store', 'ag_name', 'ag_role', 'ag_sync_state',
                                    'last_full_folder', 'last_log_folder')
                        Drift = @{ size_mb = 'pct' } }
    ag_replicas    = @{ Title = 'Always On replicas';  Key = @('ag_name', 'replica_node');
                        Compare = @('primary_replica', 'role', 'availability_mode', 'failover_mode', 'connected_state', 'sync_health', 'readable',
                                    'endpoint_url', 'backup_priority', 'listeners') }
    ag_databases   = @{ Title = 'Always On databases'; Key = @('ag_name', 'database_name', 'replica_node'); Compare = @('role', 'sync_state', 'sync_health', 'is_suspended') }
    cluster        = @{ Title = 'Cluster & quorum';    Key = @('member_name');   Compare = @('quorum_type', 'quorum_state', 'member_type', 'member_state', 'votes') }
    disks          = @{ Title = 'Disks';               Key = @('volume');        Compare = @('total_gb'); Drift = @{ free_gb = 'disk' } }
    files          = @{ Title = 'Data & log files';    Key = @('database_name', 'logical_name'); Compare = @('type', 'physical_name', 'state', 'growth', 'max_size'); Drift = @{ size_mb = 'pct' } }
    jobs           = @{ Title = 'Agent jobs';          Key = @('name');          Compare = @('enabled', 'owner', 'category') }
    logins         = @{ Title = 'Logins';              Key = @('name');          Compare = @('type', 'is_disabled', 'default_database') }
    server_roles   = @{ Title = 'Server role members'; Key = @('role', 'member'); Compare = @() }
    linked_servers = @{ Title = 'Linked servers';      Key = @('name');          Compare = @('product', 'provider', 'data_source') }
    endpoints      = @{ Title = 'Endpoints';           Key = @('name');          Compare = @('type', 'state', 'port') }
    certificates   = @{ Title = 'Certificates';        Key = @('name');          Compare = @('thumbprint', 'expiry') }
    xe_sessions    = @{ Title = 'XE sessions';         Key = @('name');          Compare = @('running') }
}
# Order + titles for the full report in the email
$ReportSections = [ordered]@{
    issues = 'Needs attention'; instance = 'Instance'; services = 'SQL Server services'; vitals = 'Vitals'; databases = 'Databases, backups & CHECKDB'
    ag_replicas = 'Always On - replicas (nodes)'; ag_databases = 'Always On - databases per replica'; cluster = 'Cluster & quorum'; disks = 'Disk space'
    files = 'Data & log files'; jobs = 'Agent jobs'; job_failures = 'Failed job steps (24 h)'; errorlog = 'Severe error log entries (24 h)'
    traceflags = 'Global trace flags'; config = 'sp_configure'; logins = 'Logins'; server_roles = 'Server role members'
    linked_servers = 'Linked servers'; endpoints = 'Endpoints'; certificates = 'Certificates'; xe_sessions = 'XE sessions'
}

# =============================================================================
#  HELPERS
# =============================================================================
Add-Type -AssemblyName System.Web.Extensions
$Json = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$Json.MaxJsonLength = [int]::MaxValue

function ConvertTo-PlainObject($InputObject) {
    # JavaScriptSerializer can't handle PowerShell-wrapped values (e.g. strings from Get-Date / function
    # output arrive as PSObject and cause "circular reference ... PSParameterizedProperty").
    # Recursively unwrap everything to plain .NET strings / numbers / dictionaries / arrays.
    if ($null -eq $InputObject) { return $null }
    $base = $InputObject.PSObject.BaseObject
    if ($base -is [string] -or $base -is [System.ValueType]) { return $base }
    if ($base -is [System.Collections.IDictionary]) {
        $d = New-Object 'System.Collections.Generic.Dictionary[string,object]'
        foreach ($k in @($base.Keys)) { $d[[string]$k] = ConvertTo-PlainObject $base[$k] }
        return ,$d
    }
    if ($base -is [System.Collections.IEnumerable]) {
        $l = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $base) { $l.Add((ConvertTo-PlainObject $item)) }
        return ,($l.ToArray())
    }
    return [string]$base
}

function Write-Step([string]$Text, [string]$Color = 'Cyan') { Write-Host $Text -ForegroundColor $Color }
function Get-SafeFileName([string]$Value) { return ($Value -replace '[\\/:*?"<>|\s,]', '_') }
function Enc([string]$Value) { return [System.Net.WebUtility]::HtmlEncode($Value) }

function Get-Val($Row, [string]$Col) {
    if ($null -eq $Row) { return '' }
    if ($Row -is [System.Collections.IDictionary]) {
        if ($Row.ContainsKey($Col) -and $null -ne $Row[$Col]) { return ([string]$Row[$Col]).Trim() }
        return ''
    }
    $p = $Row.PSObject.Properties[$Col]
    if ($p -and $null -ne $p.Value) { return ([string]$p.Value).Trim() }
    return ''
}

function Get-SqlFilePath {
    if ($SqlFile) { return (Resolve-Path $SqlFile).Path }
    $c = Join-Path $PSScriptRoot 'HC_Snapshot.sql'
    if (Test-Path $c) { return (Resolve-Path $c).Path }
    throw 'HC_Snapshot.sql not found next to this script (or pass -SqlFile).'
}

function Get-LocalSqlInstances {
    $result = @()
    $regKey = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
    if (-not (Test-Path $regKey)) { return $result }
    $skip = 'PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider'
    $props = Get-ItemProperty -Path $regKey
    foreach ($p in $props.PSObject.Properties | Where-Object { $skip -notcontains $_.Name }) {
        $instName = $p.Name; $instId = $p.Value
        $svcName  = if ($instName -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { 'MSSQL$' + $instName }
        $svc      = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        $hostName = $env:COMPUTERNAME
        $clusterKey = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instId\Cluster"
        if (Test-Path $clusterKey) {
            $vn = (Get-ItemProperty -Path $clusterKey -ErrorAction SilentlyContinue).ClusterName
            if ($vn) { $hostName = $vn }
        }
        $connName = if ($instName -eq 'MSSQLSERVER') { $hostName } else { "$hostName\$instName" }
        $result += [pscustomobject]@{ Instance = $connName; Service = $svcName; Status = $(if ($svc) { [string]$svc.Status } else { 'Unknown' }) }
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
        Get-Content $Config.ServersFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') } |
            ForEach-Object { $targets += [pscustomobject]@{ Instance = $_; Service = ''; Status = 'Listed' } }
    }
    $seen = @{}; $unique = @()
    foreach ($t in $targets) { $k = $t.Instance.ToUpperInvariant(); if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $unique += $t } }
    return $unique
}

function New-SqlConnection([string]$Instance) {
    $enc = if ($Config.Encrypt) { 'True' } else { 'False' }
    $cs = "Server=$Instance;Database=master;Integrated Security=SSPI;Application Name=DBA PrePostCheck;" +
          "Connect Timeout=$($Config.ConnectTimeoutSec);Encrypt=$enc;TrustServerCertificate=True"
    return New-Object System.Data.SqlClient.SqlConnection $cs
}

function Invoke-Scalar($Connection, [string]$Query, [hashtable]$Params = @{}) {
    $cmd = $Connection.CreateCommand(); $cmd.CommandText = $Query; $cmd.CommandTimeout = 60
    foreach ($k in $Params.Keys) { [void]$cmd.Parameters.AddWithValue($k, $Params[$k]) }
    return $cmd.ExecuteScalar()
}

function Get-MailProfileName($Connection) {
    # 'Database Mail XPs' off = profiles may exist but sp_send_dbmail is blocked -> treat as not configured
    $xps = Invoke-Scalar $Connection "SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'Database Mail XPs';"
    if ($null -eq $xps -or $xps -is [DBNull] -or [int]$xps -ne 1) { return $null }
    $q = @"
SELECT TOP (1) p.name
FROM msdb.dbo.sysmail_profile AS p
LEFT JOIN msdb.dbo.sysmail_principalprofile AS pp ON pp.profile_id = p.profile_id AND pp.is_default = 1
ORDER BY CASE WHEN p.name = @pref THEN 0 WHEN pp.profile_id IS NOT NULL THEN 1 ELSE 2 END, p.profile_id;
"@
    $r = Invoke-Scalar $Connection $q @{ '@pref' = $Config.MailProfile }
    if ($null -eq $r -or $r -is [DBNull]) { return $null }
    return [string]$r
}

function Get-Snapshot($Connection, [string]$SqlText) {
    # Runs HC_Snapshot.sql; returns @{ sections = @{ name = ArrayList of hashtables }; columns = @{ name = string[] } }
    $sections = @{}; $columns = @{}
    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = $SqlText
    $cmd.CommandTimeout = $Config.QueryTimeoutSec
    $reader = $cmd.ExecuteReader()
    do {
        if ($reader.FieldCount -gt 0 -and $reader.GetName(0) -eq '_section') {
            $names = @(); for ($i = 1; $i -lt $reader.FieldCount; $i++) { $names += $reader.GetName($i) }
            while ($reader.Read()) {
                $sec = [string]$reader.GetValue(0)
                if (-not $sections.ContainsKey($sec)) { $sections[$sec] = New-Object System.Collections.ArrayList; $columns[$sec] = $names }
                $row = @{}
                for ($i = 1; $i -lt $reader.FieldCount; $i++) {
                    $row[$reader.GetName($i)] = if ($reader.IsDBNull($i)) { $null } else { [string]$reader.GetValue($i) }
                }
                [void]$sections[$sec].Add($row)
            }
        }
        else { while ($reader.Read()) { } }
    } while ($reader.NextResult())
    $reader.Close()
    return @{ sections = $sections; columns = $columns }
}

function Get-Rows($Snap, [string]$Section) {
    if ($null -eq $Snap) { return @() }
    $s = $Snap['sections']
    if ($s -and $s.ContainsKey($Section) -and $null -ne $s[$Section]) { return @($s[$Section]) }
    return @()
}

function Get-RowKey($Row, [string[]]$KeyCols) { return (($KeyCols | ForEach-Object { Get-Val $Row $_ }) -join ' | ') }

function ConvertTo-Number([string]$Value) {
    $d = 0.0
    if ([double]::TryParse($Value, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return $null
}

function Compare-Snapshots($Pre, $Post) {
    $unexpected = New-Object System.Collections.ArrayList
    $expected   = New-Object System.Collections.ArrayList
    foreach ($section in $Spec.Keys) {
        $sp = $Spec[$section]
        $preMap = @{}; foreach ($r in @(Get-Rows $Pre $section))  { $preMap[(Get-RowKey $r $sp.Key)]  = $r }
        $postMap = @{}; foreach ($r in @(Get-Rows $Post $section)) { $postMap[(Get-RowKey $r $sp.Key)] = $r }

        foreach ($k in $preMap.Keys) {
            if (-not $postMap.ContainsKey($k)) {
                [void]$unexpected.Add([pscustomobject]@{ Section = $sp.Title; Item = $k; Attribute = '(row)'; Before = 'present'; After = 'MISSING'; Note = 'Existed before the change, gone after' })
            }
        }
        foreach ($k in $postMap.Keys) {
            if (-not $preMap.ContainsKey($k)) {
                [void]$unexpected.Add([pscustomobject]@{ Section = $sp.Title; Item = $k; Attribute = '(row)'; Before = 'not present'; After = 'NEW'; Note = 'Appeared after the change' })
            }
        }
        foreach ($k in $preMap.Keys) {
            if (-not $postMap.ContainsKey($k)) { continue }
            $a = $preMap[$k]; $b = $postMap[$k]
            foreach ($col in $sp.Compare) {
                $va = Get-Val $a $col; $vb = Get-Val $b $col
                if ($va -ne $vb) {
                    $d = [pscustomobject]@{ Section = $sp.Title; Item = $k; Attribute = $col; Before = $va; After = $vb; Note = '' }
                    if ($sp.ExpectedKeys -and ($sp.ExpectedKeys -contains $k)) { $d.Note = 'Expected (patch / upgrade)'; [void]$expected.Add($d) }
                    else { [void]$unexpected.Add($d) }
                }
            }
            foreach ($col in @($sp.Expected)) {
                if (-not $col) { continue }
                $va = Get-Val $a $col; $vb = Get-Val $b $col
                if ($va -ne $vb) { [void]$expected.Add([pscustomobject]@{ Section = $sp.Title; Item = $k; Attribute = $col; Before = $va; After = $vb; Note = 'Expected' }) }
            }
            if ($sp.Drift) {
                foreach ($col in $sp.Drift.Keys) {
                    $na = ConvertTo-Number (Get-Val $a $col); $nb = ConvertTo-Number (Get-Val $b $col)
                    if ($null -eq $na -or $null -eq $nb) { continue }
                    $diff = [math]::Abs($nb - $na)
                    $flag = $false; $note = ''
                    switch ($sp.Drift[$col]) {
                        'pct' {
                            $pct = if ($na -gt 0) { 100.0 * $diff / $na } else { 100.0 }
                            if ($pct -gt $Config.FileSizeDriftPct -and $diff -gt $Config.FileSizeDriftMinMB) {
                                $flag = $true; $note = ('Size changed {0:N1}% ({1:N0} MB)' -f $pct, $diff)
                            }
                        }
                        'disk' {
                            $total = ConvertTo-Number (Get-Val $b 'total_gb')
                            if ($total -and (100.0 * $diff / $total) -gt $Config.DiskFreeDriftPct) {
                                $flag = $true; $note = ('Free space changed {0:N1} GB ({1:N1}% of disk)' -f ($nb - $na), (100.0 * $diff / $total))
                            }
                        }
                    }
                    if ($flag) { [void]$unexpected.Add([pscustomobject]@{ Section = $sp.Title; Item = $k; Attribute = $col; Before = (Get-Val $a $col); After = (Get-Val $b $col); Note = $note }) }
                }
            }
        }
    }
    # Problems: new after the change vs. already there before
    $preIssues = @{}; foreach ($r in @(Get-Rows $Pre 'issues')) { $preIssues[(Get-RowKey $r @('area', 'item'))] = $r }
    $newProblems = New-Object System.Collections.ArrayList
    $oldProblems = New-Object System.Collections.ArrayList
    foreach ($r in @(Get-Rows $Post 'issues')) {
        if ($preIssues.ContainsKey((Get-RowKey $r @('area', 'item')))) { [void]$oldProblems.Add($r) } else { [void]$newProblems.Add($r) }
    }
    return @{ Unexpected = $unexpected; Expected = $expected; NewProblems = $newProblems; OldProblems = $oldProblems }
}

function ConvertTo-HtmlTable($Rows, [string[]]$Columns, [string]$RowStyle = '', [string]$StatusColumn = '') {
    $rowsArr = @($Rows)
    if ($rowsArr.Count -eq 0) { return '<div style="color:#2e7d32">None</div>' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<table><tr>')
    foreach ($c in $Columns) { [void]$sb.Append('<th>' + (Enc $c) + '</th>') }
    [void]$sb.Append('</tr>')
    foreach ($r in $rowsArr) {
        $style = $RowStyle
        if ($StatusColumn) {
            switch (Get-Val $r $StatusColumn) { 'CRITICAL' { $style = 'background-color:#f8d7da' } 'WARNING' { $style = 'background-color:#fff3cd' } }
        }
        if ($style) { [void]$sb.Append('<tr style="' + $style + '">') } else { [void]$sb.Append('<tr>') }
        foreach ($c in $Columns) { [void]$sb.Append('<td>' + (Enc (Get-Val $r $c)) + '</td>') }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</table>')
    return $sb.ToString()
}

function Get-FullReportHtml($Snap) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($sec in $ReportSections.Keys) {
        $rows = @(Get-Rows $Snap $sec)
        $cols = $null
        if ($Snap['columns'] -and $Snap['columns'].ContainsKey($sec)) { $cols = @($Snap['columns'][$sec]) }
        if ($sec -ne 'issues' -and $rows.Count -eq 0) { continue }       # skip empty sections (e.g. no AG)
        [void]$sb.Append('<h3>' + (Enc $ReportSections[$sec]) + '</h3>')
        if (-not $cols) { [void]$sb.Append('<div style="color:#2e7d32">None</div>'); continue }
        $statusCol = if ($cols -contains 'status') { 'status' } elseif ($cols -contains 'severity') { 'severity' } else { '' }
        [void]$sb.Append((ConvertTo-HtmlTable $rows $cols '' $statusCol))
    }
    return $sb.ToString()
}

$HtmlHead = @'
<html><head><style>
body{font-family:Segoe UI,Arial,sans-serif;font-size:12px;color:#222}
h2{color:#1f4e79;margin-bottom:2px} h3{color:#1f4e79;margin:18px 0 4px 0;border-bottom:1px solid #1f4e79}
table{border-collapse:collapse;margin-bottom:8px} th{background:#1f4e79;color:#fff;padding:4px 6px;text-align:left;font-weight:600}
td{border:1px solid #d0d0d0;padding:3px 6px;vertical-align:top}
.banner{padding:10px 14px;font-size:14px;font-weight:600;margin:8px 0}
</style></head><body>
'@

function Send-DbMail($Connection, [string]$MailProfileName, [string]$Subject, [string]$Html, [string]$Importance) {
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
    $pMailItemId = $cmd.Parameters.Add('@mailitem_id', [System.Data.SqlDbType]::Int); $pMailItemId.Direction = [System.Data.ParameterDirection]::Output
    [void]$cmd.ExecuteNonQuery()
    return [int]$pMailItemId.Value
}

# =============================================================================
#  OUTER: prompts + relaunch as your account
# =============================================================================
if (-not $Inner) {
    Write-Step '=== SQL Server PRE / POST change check ===' 'Green'
    while ($Phase -notin @('PRE', 'POST')) {
        $Phase = (Read-Host 'Phase - PRE (before the change) or POST (after the change)').Trim().ToUpperInvariant()
    }
    if (-not $PSBoundParameters.ContainsKey('Ticket')) { $Ticket = Read-Host 'Change ticket (used to pair PRE and POST, e.g. CHG0012345)' }
    $Ticket = ([string]$Ticket).Trim() -replace '[^A-Za-z0-9_-]', ''
    if (-not $Ticket) { $Ticket = 'NO-TICKET' }

    $cred = $null
    if (-not $UseCurrentUser) {
        try   { $cred = Get-Credential -Message "Enter YOUR Windows account (DOMAIN\user) that has access to SQL Server.`nCancel = run as $env:USERDOMAIN\$env:USERNAME" }
        catch { $cred = $null }
    }
    if ($cred) {
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Inner', '-Phase', $Phase, '-Ticket', $Ticket)
        if ($SqlFile)   { $argList += @('-SqlFile', "`"$((Resolve-Path $SqlFile).Path)`"") }
        if ($Instances) { $argList += @('-Instances', ($Instances -join ',')) }
        Write-Step "Starting the $Phase check as $($cred.UserName) in a new window..."
        try {
            Start-Process -FilePath "$PSHOME\powershell.exe" -Credential $cred -ArgumentList $argList -WorkingDirectory $PSScriptRoot -Wait
        }
        catch {
            Write-Step "Could not start as $($cred.UserName): $($_.Exception.Message)" 'Red'
            Write-Step "Check the password, that the account may log on to this VM, and that it can READ $PSScriptRoot (e.g. use C:\DBA\PrePostCheck)." 'Yellow'
            Read-Host 'Press Enter to close'; exit 1
        }
        exit 0
    }
}

# =============================================================================
#  INNER: collect / store / compare / email
# =============================================================================
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
foreach ($key in @('SnapshotRoot', 'ReportsFolder', 'LogsFolder')) {
    try {
        if (-not (Test-Path $Config[$key])) { New-Item -ItemType Directory -Path $Config[$key] -Force | Out-Null }
        $probe = Join-Path $Config[$key] ('.write_test_' + $stamp); [System.IO.File]::WriteAllText($probe, 'x'); Remove-Item $probe -Force
    }
    catch {
        if ($key -eq 'SnapshotRoot') { Write-Step "ERROR: no write access to $($Config[$key]). Snapshots must be stored there - fix folder permissions." 'Red'; Read-Host 'Press Enter to close'; exit 1 }
        $fallback = Join-Path $env:TEMP ('DBA_PrePostCheck\' + (Split-Path $Config[$key] -Leaf))
        New-Item -ItemType Directory -Path $fallback -Force | Out-Null
        Write-Warning "No write access to $($Config[$key]) - using $fallback"; $Config[$key] = $fallback
    }
}
$logFile = Join-Path $Config.LogsFolder "PrePostCheck_${Phase}_${Ticket}_$stamp.log"
try { Start-Transcript -Path $logFile -Append | Out-Null } catch { }

$summary = @()
try {
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    Write-Step "Running as : $me"
    Write-Step "Phase      : $Phase    Ticket: $Ticket"
    $sqlText = [System.IO.File]::ReadAllText((Get-SqlFilePath))
    $targets = Get-TargetInstances
    if (-not $targets) { throw 'No SQL Server instances found on this VM and servers.txt is empty.' }
    $targets | Format-Table Instance, Service, Status -AutoSize | Out-String | Write-Host
    $ticketDir = Join-Path $Config.SnapshotRoot $Ticket
    if (-not (Test-Path $ticketDir)) { New-Item -ItemType Directory -Path $ticketDir -Force | Out-Null }

    foreach ($t in $targets) {
        $row = [ordered]@{ Instance = $t.Instance; Outcome = ''; Unexpected = ''; NewProblems = ''; Expected = ''; Baseline = ''; MailId = $null; MailStatus = ''; Report = '' }
        Write-Step "`n--- $($t.Instance) ---" 'Green'
        if ($t.Status -notin @('Running', 'Listed')) {
            $row.Outcome = "SKIPPED - service $($t.Service) is $($t.Status)"
            Write-Step $row.Outcome 'Red'; $summary += [pscustomobject]$row; continue
        }
        $conn = $null
        try {
            $conn = New-SqlConnection $t.Instance; $conn.Open()
            $profileName = $null
            try { $profileName = Get-MailProfileName $conn }
            catch { Write-Step "WARNING: could not read Database Mail profiles on $($t.Instance): $($_.Exception.Message)" 'Yellow' }

            if (-not $profileName) {
                Write-Step "WARNING: Database Mail is not configured on $($t.Instance)." 'Yellow'
                Write-Step 'Continuing with snapshot collection and report generation (report saved locally, no email).' 'Yellow'
                $row.MailStatus = 'Database Mail Not Configured'
            }

            Write-Step 'Collecting snapshot...'
            $data = Get-Snapshot $conn $sqlText
            $snap = @{
                meta     = @{ instance = $t.Instance; phase = $Phase; ticket = $Ticket; taken_at = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); taken_by = $me; machine = $env:COMPUTERNAME
                              build = (Get-Val (@(Get-Rows $data 'instance') | Where-Object { (Get-Val $_ 'property_code') -eq 'build' } | Select-Object -First 1) 'value') }
                sections = $data.sections
                columns  = $data.columns
            }
            $safe = Get-SafeFileName $t.Instance
            $snapFile = Join-Path $ticketDir ("{0}_{1}_{2}.json" -f $safe, $Phase, $stamp)
            # ConvertTo-Json copes with PowerShell-wrapped values (JavaScriptSerializer.Serialize does not);
            # ConvertTo-PlainObject strips extra PowerShell note properties first. Files are read back with $Json.DeserializeObject.
            $jsonText = ConvertTo-Json -InputObject (ConvertTo-PlainObject $snap) -Depth 20 -Compress
            [System.IO.File]::WriteAllText($snapFile, $jsonText, [System.Text.Encoding]::UTF8)
            Write-Step "Snapshot saved : $snapFile"
            $issues = @(Get-Rows $snap 'issues')
            $crit = @($issues | Where-Object { (Get-Val $_ 'severity') -eq 'CRITICAL' }).Count
            $warn = @($issues | Where-Object { (Get-Val $_ 'severity') -eq 'WARNING' }).Count

            $now = Get-Date -Format 'yyyy-MM-dd HH:mm'
            if ($Phase -eq 'PRE') {
                $color = if ($crit -gt 0) { '#f8d7da' } elseif ($warn -gt 0) { '#fff3cd' } else { '#d4edda' }
                $html = $HtmlHead +
                        "<h2>$(Enc $Config.ReportTitle) - PRE snapshot - $(Enc $t.Instance)</h2>" +
                        "<div class='banner' style='background:$color'>PRE snapshot captured for $(Enc $Ticket) at $now by $(Enc $me). " +
                        "Current state: $crit critical, $warn warning(s) - these will NOT count as new problems in the POST check.</div>" +
                        "<div>Build: $(Enc $snap.meta.build) &nbsp;|&nbsp; Stored on $(Enc $env:COMPUTERNAME): $(Enc $snapFile)</div>" +
                        (Get-FullReportHtml $snap) + '</body></html>'
                $subject = "[PRE CAPTURED] $($Config.ReportTitle) [$Ticket] - $($t.Instance) - $now"
                $importance = 'Normal'
                $row.Outcome = 'PRE CAPTURED'
            }
            else {
                # ---- find the PRE baseline -------------------------------------------------
                $preFile = Get-ChildItem -Path $ticketDir -Filter ("{0}_PRE_*.json" -f $safe) -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
                if (-not $preFile) {
                    $cand = Get-ChildItem -Path $Config.SnapshotRoot -Recurse -Filter ("{0}_PRE_*.json" -f $safe) -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                    if ($cand) {
                        $cm = $Json.DeserializeObject([System.IO.File]::ReadAllText($cand.FullName))['meta']
                        Write-Step "No PRE snapshot for ticket $Ticket on this instance." 'Yellow'
                        $ans = Read-Host ("Latest PRE is ticket {0}, taken {1} by {2}. Use it as the baseline? (Y/N)" -f $cm['ticket'], $cm['taken_at'], $cm['taken_by'])
                        if ($ans -match '^[Yy]') { $preFile = $cand }
                    }
                }
                $pre = $null
                if ($preFile) {
                    $pre = $Json.DeserializeObject([System.IO.File]::ReadAllText($preFile.FullName))
                    $row.Baseline = "$($pre['meta']['ticket']) @ $($pre['meta']['taken_at'])"
                    Write-Step "Baseline (PRE) : $($preFile.FullName)"
                }

                if ($pre) {
                    $cmp = Compare-Snapshots $pre $snap
                    $nU = $cmp.Unexpected.Count; $nN = $cmp.NewProblems.Count; $nE = $cmp.Expected.Count
                    $row.Unexpected = $nU; $row.NewProblems = $nN; $row.Expected = $nE
                    $ok = ($nU + $nN) -eq 0
                    $row.Outcome = if ($ok) { 'SUCCESS - no differences' } else { 'DIFFERENCES FOUND' }
                    $color = if ($ok) { '#d4edda' } else { '#f8d7da' }
                    $bannerText = if ($ok) { "SUCCESS - no unexpected differences between PRE and POST, and no new problems." }
                                  else { "DIFFERENCES FOUND - $nU unexpected difference(s), $nN new problem(s) after the change. Review before closing $Ticket." }
                    $diffCols = @('Section', 'Item', 'Attribute', 'Before', 'After', 'Note')
                    $issueCols = @('severity', 'area', 'item', 'detail')
                    $html = $HtmlHead +
                            "<h2>$(Enc $Config.ReportTitle) - POST check - $(Enc $t.Instance)</h2>" +
                            "<div class='banner' style='background:$color'>$(Enc $bannerText)</div>" +
                            "<table><tr><th></th><th>PRE (before)</th><th>POST (after)</th></tr>" +
                            "<tr><td>Ticket</td><td>$(Enc $pre['meta']['ticket'])</td><td>$(Enc $Ticket)</td></tr>" +
                            "<tr><td>Taken</td><td>$(Enc $pre['meta']['taken_at'])</td><td>$(Enc $snap.meta.taken_at)</td></tr>" +
                            "<tr><td>By</td><td>$(Enc $pre['meta']['taken_by'])</td><td>$(Enc $me)</td></tr>" +
                            "<tr><td>Build</td><td>$(Enc $pre['meta']['build'])</td><td>$(Enc $snap.meta.build)</td></tr></table>" +
                            "<h3>Unexpected differences ($nU)</h3>" + (ConvertTo-HtmlTable $cmp.Unexpected $diffCols 'background-color:#f8d7da') +
                            "<h3>New problems after the change ($nN)</h3>" + (ConvertTo-HtmlTable $cmp.NewProblems $issueCols 'background-color:#f8d7da') +
                            "<h3>Expected changes ($nE)</h3>" + (ConvertTo-HtmlTable $cmp.Expected $diffCols 'background-color:#eef3f8') +
                            "<h3>Problems that already existed before the change ($($cmp.OldProblems.Count))</h3>" + (ConvertTo-HtmlTable $cmp.OldProblems $issueCols 'background-color:#fff3cd') +
                            "<p style='color:#777'>Tolerances: file/DB size &gt; $($Config.FileSizeDriftPct)% and &gt; $($Config.FileSizeDriftMinMB) MB; disk free space &gt; $($Config.DiskFreeDriftPct)% of disk. " +
                            "AG primary / role changes are flagged on purpose. Run POST after AG databases are SYNCHRONIZED.</p>" +
                            "<h2>Full POST report</h2>" + (Get-FullReportHtml $snap) + '</body></html>'
                    $subject = if ($ok) { "[POST SUCCESS] $($Config.ReportTitle) [$Ticket] - $($t.Instance) - no differences" }
                               else { "[POST DIFFERENCES] $($Config.ReportTitle) [$Ticket] - $($t.Instance) - $nU difference(s), $nN new problem(s)" }
                    $importance = if ($ok) { 'Normal' } else { 'High' }
                    Write-Step $row.Outcome $(if ($ok) { 'Green' } else { 'Red' })
                    if (-not $ok) { $cmp.Unexpected | Select-Object -First 25 | Format-Table Section, Item, Attribute, Before, After -AutoSize | Out-String -Width 220 | Write-Host }
                }
                else {
                    $row.Outcome = 'NO BASELINE - POST report only'
                    $html = $HtmlHead +
                            "<h2>$(Enc $Config.ReportTitle) - POST check - $(Enc $t.Instance)</h2>" +
                            "<div class='banner' style='background:#fff3cd'>NO BASELINE - no PRE snapshot found for this instance, so nothing could be compared. " +
                            "Current state: $crit critical, $warn warning(s).</div>" + (Get-FullReportHtml $snap) + '</body></html>'
                    $subject = "[POST NO BASELINE] $($Config.ReportTitle) [$Ticket] - $($t.Instance) - $crit critical, $warn warning(s)"
                    $importance = 'High'
                    Write-Step $row.Outcome 'Yellow'
                }
            }

            $reportFile = Join-Path $Config.ReportsFolder ("{0}_{1}_{2}_{3}.html" -f $safe, $Phase, $Ticket, (Get-Date -Format 'yyyyMMdd_HHmm'))
            [System.IO.File]::WriteAllText($reportFile, $html, [System.Text.Encoding]::UTF8)
            $row.Report = $reportFile
            if ($profileName) {
                try {
                    $row.MailId = Send-DbMail $conn $profileName $subject $html $importance
                    Write-Step "Email queued   : mailitem_id $($row.MailId) via profile '$profileName'"
                }
                catch {
                    $row.MailStatus = 'Send failed: ' + $_.Exception.Message
                    Write-Step "WARNING: email not sent - $($_.Exception.Message)" 'Yellow'
                    Write-Step "Report is saved locally: $reportFile" 'Yellow'
                }
            }
            else {
                Write-Step "Email skipped  : no Database Mail - open the saved report: $reportFile" 'Yellow'
            }
        }
        catch {
            $row.Outcome = 'FAILED: ' + $_.Exception.Message
            Write-Step $row.Outcome 'Red'
            if ($_.Exception.Message -match 'Login failed') { Write-Step "  -> $me has no login on $($t.Instance). Use the account you use for SSMS." 'Yellow' }
        }
        finally { if ($conn) { $conn.Dispose() } }
        $summary += [pscustomobject]$row
    }

    # Delivery check
    $sent = @($summary | Where-Object { $_.MailId })
    if ($sent.Count -gt 0) {
        Write-Step "`nWaiting $($Config.MailCheckDelaySec)s to check Database Mail delivery..."
        Start-Sleep -Seconds $Config.MailCheckDelaySec
        foreach ($s in $sent) {
            $c = $null
            try {
                $c = New-SqlConnection $s.Instance; $c.Open()
                $q = @"
SELECT a.sent_status + CASE WHEN a.sent_status = 'failed'
       THEN ' - ' + ISNULL((SELECT TOP (1) LEFT(l.description, 200) FROM msdb.dbo.sysmail_event_log l WHERE l.mailitem_id = a.mailitem_id ORDER BY l.log_id DESC), '') ELSE '' END
FROM msdb.dbo.sysmail_allitems AS a WHERE a.mailitem_id = @id;
"@
                $st = Invoke-Scalar $c $q @{ '@id' = $s.MailId }
                $s.MailStatus = if ($null -eq $st -or $st -is [DBNull]) { 'not found' } else { [string]$st }
            }
            catch { $s.MailStatus = 'check failed: ' + $_.Exception.Message }
            finally { if ($c) { $c.Dispose() } }
        }
    }
}
catch { Write-Step ('ERROR: ' + $_.Exception.Message) 'Red' }
finally {
    Write-Step "`n=== SUMMARY ($Phase / $Ticket) ===" 'Green'
    if ($summary) { $summary | Format-Table Instance, Outcome, Unexpected, NewProblems, Expected, Baseline, MailStatus -AutoSize -Wrap | Out-String -Width 250 | Write-Host }
    Write-Step "Snapshots : $(Join-Path $Config.SnapshotRoot $Ticket)"
    Write-Step "Reports   : $($Config.ReportsFolder)"
    Write-Step "Log       : $logFile"
    try { Stop-Transcript | Out-Null } catch { }
    Read-Host "`nPress Enter to close"
}
