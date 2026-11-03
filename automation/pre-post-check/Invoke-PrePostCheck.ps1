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
    [string]   $Phase = '',          # PRE, POST or HEALTH (prompted if empty)
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
    HealthReportTitle     = 'SQL Server Health Check'      # used for -Phase HEALTH
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
    AttachReport          = $true    # attach the combined HTML report to the email (falls back to the email body)
    PerInstanceReports    = $false   # also save one HTML file per instance
}

$ErrorActionPreference = 'Stop'
$Phase = ([string]$Phase).Trim().ToUpperInvariant()
if ($Phase -eq 'HC') { $Phase = 'HEALTH' }
if ($Inner -and $Phase -notin @('PRE', 'POST', 'HEALTH')) { throw "Invalid -Phase '$Phase' (use PRE, POST or HEALTH)." }
if ($Instances) { $Instances = @($Instances -split ',' | ForEach-Object { $_.Trim(" '`"") } | Where-Object { $_ }) }

# What to compare per section: Key = identifies a row, Compare = must be equal,
# Expected = may change (listed as expected), Drift = numeric tolerance rule.
$Spec = [ordered]@{
    instance       = @{ Title = 'Instance';            Key = @('property_code'); Compare = @('value'); ExpectedKeys = @('build', 'sp_level', 'cu', 'kb', 'start_time', 'os_boot_time'); IgnoreKeys = @('sql_uptime', 'os_uptime') }
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
    ag_listeners   = @{ Title = 'Always On listeners'; Key = @('ag_name', 'listener', 'ip_address'); Compare = @('port', 'subnet_mask', 'ip_type', 'network_subnet', 'ip_state', 'is_conformant') }
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
    bi_services    = @{ Title = 'SSIS / SSRS / SSAS services'; Key = @('name'); Compare = @('state', 'start_mode', 'account') }
    ssis_catalog   = @{ Title = 'SSIS catalog settings'; Key = @('property_name'); Compare = @('property_value'); ExpectedKeys = @('SCHEMA_BUILD', 'SCHEMA_VERSION') }
    ssis_projects  = @{ Title = 'SSIS projects';       Key = @('folder', 'project'); Compare = @('packages', 'object_version_lsn', 'deployed_by') }
    ssis_environments = @{ Title = 'SSIS environments'; Key = @('folder', 'environment'); Compare = @('variables') }
    ssrs_summary   = @{ Title = 'SSRS content';        Key = @('rs_database');   Compare = @('folders', 'reports', 'datasources', 'datasets', 'other_items', 'subscriptions', 'schedules') }
    ssrs_subscriptions = @{ Title = 'SSRS subscriptions'; Key = @('rs_database', 'subscription_id'); Compare = @('report_path', 'owner', 'inactive_flags', 'is_failing') }
    ssas_server    = @{ Title = 'SSAS instances';      Key = @('ssas_instance'); Compare = @('service_state', 'connected'); Expected = @('version') }
    ssas_databases = @{ Title = 'SSAS databases';      Key = @('ssas_instance', 'database'); Compare = @('compatibility_level', 'type'); Expected = @('date_modified') }
}
# Order + titles for the full report in the email
$ReportSections = [ordered]@{
    issues = 'Needs attention'; instance = 'Instance'; services = 'SQL Server services'; vitals = 'Vitals'; databases = 'Databases, backups & CHECKDB'
    ag_replicas = 'Always On - replicas (nodes)'; ag_listeners = 'Always On - listeners (IP / DHCP)'; ag_databases = 'Always On - databases per replica'; cluster = 'Cluster & quorum'; disks = 'Disk space'
    files = 'Data & log files'; job_failures = 'Failed job steps (24 h)'; errorlog = 'Severe error log entries (24 h)'
    traceflags = 'Global trace flags'; config = 'sp_configure'
    linked_servers = 'Linked servers'; endpoints = 'Endpoints'; certificates = 'Certificates'; xe_sessions = 'XE sessions'
    bi_services = 'SSIS / SSRS / SSAS services (this VM)'; ssis_catalog = 'SSIS catalog settings'; ssis_projects = 'SSIS projects'
    ssis_environments = 'SSIS environments'; ssis_failures = 'SSIS failed executions (24 h)'; ssrs_summary = 'SSRS content (report server databases)'
    ssrs_subscriptions = 'SSRS subscriptions'; ssas_server = 'SSAS instances (this VM)'; ssas_databases = 'SSAS databases'
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

function Get-MachineBiSnapshot {
    # SSIS / SSRS / SSAS Windows services on THIS VM (not visible from T-SQL) and SSAS databases via the MSOLAP provider.
    $sections = @{}; $columns = @{}
    $issues = New-Object System.Collections.ArrayList
    $pattern = '^(MsDtsServer\d*|SSISScaleOutMaster\d*|SSISScaleOutWorker\d*|ReportServer(\$.+)?|SQLServerReportingServices|PowerBIReportServer|MSSQLServerOLAPService|MSOLAP\$.+|SQLBrowser)$'
    $svcs = @(Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $pattern } | Sort-Object Name)

    $svcRows = New-Object System.Collections.ArrayList
    foreach ($s in $svcs) {
        [void]$svcRows.Add(@{ name = [string]$s.Name; display_name = [string]$s.DisplayName; state = [string]$s.State; start_mode = [string]$s.StartMode; account = [string]$s.StartName })
        if ($s.StartMode -eq 'Auto' -and $s.State -ne 'Running') {
            [void]$issues.Add(@{ severity = 'CRITICAL'; area = 'BI service'; item = [string]$s.Name; detail = "Startup type Automatic but service is $($s.State)" })
        }
    }
    if ($svcRows.Count -gt 0) { $sections['bi_services'] = $svcRows; $columns['bi_services'] = @('name', 'display_name', 'state', 'start_mode', 'account') }

    $srvRows = New-Object System.Collections.ArrayList
    $dbRows  = New-Object System.Collections.ArrayList
    foreach ($s in @($svcs | Where-Object { $_.Name -eq 'MSSQLServerOLAPService' -or $_.Name -like 'MSOLAP$*' })) {
        $inst = if ($s.Name -eq 'MSSQLServerOLAPService') { $env:COMPUTERNAME } else { $env:COMPUTERNAME + '\' + $s.Name.Substring(7) }
        $row = @{ ssas_instance = $inst; service_state = [string]$s.State; connected = '0'; version = ''; error = '' }
        if ($s.State -eq 'Running') {
            $c = $null
            try {
                $c = New-Object System.Data.OleDb.OleDbConnection "Provider=MSOLAP;Data Source=$inst;Integrated Security=SSPI;Connect Timeout=15"
                $c.Open()
                $row.connected = '1'; $row.version = [string]$c.ServerVersion
                $cmd = $c.CreateCommand(); $cmd.CommandText = 'SELECT * FROM $SYSTEM.DBSCHEMA_CATALOGS'
                $r = $cmd.ExecuteReader()
                while ($r.Read()) {
                    $vals = @{}
                    for ($i = 0; $i -lt $r.FieldCount; $i++) { $vals[$r.GetName($i).ToUpperInvariant()] = if ($r.IsDBNull($i)) { '' } else { [string]$r.GetValue($i) } }
                    [void]$dbRows.Add(@{ ssas_instance = $inst; database = [string]$vals['CATALOG_NAME']; compatibility_level = [string]$vals['COMPATIBILITY_LEVEL']
                                         type = [string]$vals['TYPE']; date_modified = [string]$vals['DATE_MODIFIED'] })
                }
                $r.Close()
            }
            catch {
                $row.error = $_.Exception.Message
                [void]$issues.Add(@{ severity = 'WARNING'; area = 'SSAS'; item = $inst; detail = 'Could not query SSAS (MSOLAP provider missing or no SSAS admin rights?): ' + $_.Exception.Message })
            }
            finally { if ($c) { $c.Dispose() } }
        }
        [void]$srvRows.Add($row)
    }
    if ($srvRows.Count -gt 0) { $sections['ssas_server'] = $srvRows; $columns['ssas_server'] = @('ssas_instance', 'service_state', 'connected', 'version', 'error') }
    if ($dbRows.Count -gt 0)  { $sections['ssas_databases'] = $dbRows; $columns['ssas_databases'] = @('ssas_instance', 'database', 'compatibility_level', 'type', 'date_modified') }
    return @{ sections = $sections; columns = $columns; issues = $issues }
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
            if ($sp.IgnoreKeys -and ($sp.IgnoreKeys -contains $k)) { continue }
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
h1{color:#fff;background:#1f4e79;padding:6px 10px;font-size:18px;margin:24px 0 6px 0} h2{color:#1f4e79;margin-bottom:2px} h3{color:#1f4e79;margin:18px 0 4px 0;border-bottom:1px solid #1f4e79}
table{border-collapse:collapse;margin-bottom:8px} th{background:#1f4e79;color:#fff;padding:4px 6px;text-align:left;font-weight:600}
td{border:1px solid #d0d0d0;padding:3px 6px;vertical-align:top}
.banner{padding:10px 14px;font-size:14px;font-weight:600;margin:8px 0}
</style></head><body>
'@

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
#  OUTER: prompts + relaunch as your account
# =============================================================================
if (-not $Inner) {
    Write-Step '=== SQL Server PRE / POST change check ===' 'Green'
    while ($Phase -notin @('PRE', 'POST', 'HEALTH')) {
        $Phase = (Read-Host 'Phase - PRE (before a change), POST (after a change) or HEALTH (health check only)').Trim().ToUpperInvariant()
        if ($Phase -eq 'HC') { $Phase = 'HEALTH' }
    }
    if (-not $PSBoundParameters.ContainsKey('Ticket')) {
        $Ticket = if ($Phase -eq 'HEALTH') { Read-Host 'Ticket / label (optional, Enter = DAILY)' }
                  else { Read-Host 'Change ticket (used to pair PRE and POST, e.g. CHG0012345)' }
    }
    $Ticket = ([string]$Ticket).Trim() -replace '[^A-Za-z0-9_-]', ''
    if (-not $Ticket) { $Ticket = if ($Phase -eq 'HEALTH') { 'DAILY' } else { 'NO-TICKET' } }

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
$combinedFile = $null
$mailStatus = 'Not sent'
try {
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    Write-Step "Running as : $me"
    Write-Step "Phase      : $Phase    Ticket: $Ticket"
    $sqlText = [System.IO.File]::ReadAllText((Get-SqlFilePath))
    $targets = Get-TargetInstances
    if (-not $targets) { throw 'No SQL Server instances found on this VM and servers.txt is empty.' }
    $targets | Format-Table Instance, Service, Status -AutoSize | Out-String | Write-Host
    $ticketDir = Join-Path $Config.SnapshotRoot $Ticket
    if ($Phase -ne 'HEALTH' -and -not (Test-Path $ticketDir)) { New-Item -ItemType Directory -Path $ticketDir -Force | Out-Null }
    if ($Phase -eq 'HEALTH') { $Config.ReportTitle = $Config.HealthReportTitle }

    # Machine-level SSIS / SSRS / SSAS data (services + SSAS databases), added to every LOCAL instance's snapshot
    $machineBi = $null
    if (@($targets | Where-Object { $_.Service }).Count -gt 0) {
        try { Write-Step 'Collecting SSIS / SSRS / SSAS service and SSAS database info...'; $machineBi = Get-MachineBiSnapshot }
        catch { Write-Step "WARNING: SSIS/SSRS/SSAS collection failed: $($_.Exception.Message)" 'Yellow' }
    }

    $diffCols  = @('Section', 'Item', 'Attribute', 'Before', 'After', 'Note')
    $issueCols = @('severity', 'area', 'item', 'detail')
    $mailCandidates = @()      # instances with a usable Database Mail profile (local ones first)

    foreach ($t in $targets) {
        $row = [ordered]@{ Instance = $t.Instance; Outcome = ''; State = ''; Unexpected = ''; NewProblems = ''; Expected = ''; Baseline = ''; ShortHtml = ''; FullHtml = '' }
        Write-Step "`n--- $($t.Instance) ---" 'Green'
        if ($t.Status -notin @('Running', 'Listed')) {
            $row.Outcome = "SKIPPED - service $($t.Service) is $($t.Status)"; $row.State = 'FAILED'
            $row.ShortHtml = "<h1>$(Enc $t.Instance)</h1><div class='banner' style='background:#f8d7da'>$(Enc $row.Outcome)</div>"
            $row.FullHtml = $row.ShortHtml
            Write-Step $row.Outcome 'Red'; $summary += [pscustomobject]$row; continue
        }
        $conn = $null
        try {
            $conn = New-SqlConnection $t.Instance; $conn.Open()
            $profileName = $null
            try { $profileName = Get-MailProfileName $conn }
            catch { Write-Step "WARNING: could not read Database Mail profiles on $($t.Instance): $($_.Exception.Message)" 'Yellow' }
            if ($profileName) { $mailCandidates += [pscustomobject]@{ Instance = $t.Instance; Profile = $profileName; Local = [bool]$t.Service } }
            else { Write-Step "Database Mail is not configured / enabled on $($t.Instance) - another instance will be used to send, if any." 'Yellow' }

            Write-Step 'Collecting snapshot...'
            $data = Get-Snapshot $conn $sqlText
            if ($machineBi -and $t.Service) {
                foreach ($k in @($machineBi.sections.Keys)) { $data.sections[$k] = $machineBi.sections[$k]; $data.columns[$k] = $machineBi.columns[$k] }
                if ($machineBi.issues.Count -gt 0) {
                    if (-not $data.sections.ContainsKey('issues')) {
                        $data.sections['issues'] = New-Object System.Collections.ArrayList
                        $data.columns['issues'] = @('severity', 'area', 'item', 'detail')
                    }
                    foreach ($i in $machineBi.issues) { [void]$data.sections['issues'].Add($i) }
                }
            }
            $snap = @{
                meta     = @{ instance = $t.Instance; phase = $Phase; ticket = $Ticket; taken_at = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); taken_by = $me; machine = $env:COMPUTERNAME
                              build = (Get-Val (@(Get-Rows $data 'instance') | Where-Object { (Get-Val $_ 'property_code') -eq 'build' } | Select-Object -First 1) 'value') }
                sections = $data.sections
                columns  = $data.columns
            }
            $safe = Get-SafeFileName $t.Instance
            $snapFile = Join-Path $ticketDir ("{0}_{1}_{2}.json" -f $safe, $Phase, $stamp)
            if ($Phase -ne 'HEALTH') {
                $jsonText = ConvertTo-Json -InputObject (ConvertTo-PlainObject $snap) -Depth 20 -Compress
                [System.IO.File]::WriteAllText($snapFile, $jsonText, [System.Text.Encoding]::UTF8)
                Write-Step "Snapshot saved : $snapFile"
            }
            $issues = @(Get-Rows $snap 'issues')
            $crit = @($issues | Where-Object { (Get-Val $_ 'severity') -eq 'CRITICAL' }).Count
            $warn = @($issues | Where-Object { (Get-Val $_ 'severity') -eq 'WARNING' }).Count
            $fullReport = [string](Get-FullReportHtml $snap)

            if ($Phase -eq 'HEALTH') {
                $color = if ($crit -gt 0) { '#f8d7da' } elseif ($warn -gt 0) { '#fff3cd' } else { '#d4edda' }
                $row.State = if ($crit -gt 0) { 'CRIT' } elseif ($warn -gt 0) { 'WARN' } else { 'OK' }
                $row.Outcome = if ($crit + $warn -gt 0) { "$crit critical, $warn warning(s)" } else { 'OK - no issues' }
                $row.ShortHtml = (@(
                    "<h1>$(Enc $t.Instance)</h1>"
                    "<div class='banner' style='background:$color'>$(Enc $row.Outcome)</div>"
                    "<div>Build: $(Enc $snap.meta.build)</div>"
                    "<h3>Needs attention ($($issues.Count))</h3>"
                    [string](ConvertTo-HtmlTable $issues $issueCols '' 'severity')
                ) -join '')
                $row.FullHtml = $row.ShortHtml + ([string](Get-FullReportHtml $snap) -replace '^<h3>Needs attention</h3>.*?(?=<h3>)', '')
                Write-Step $row.Outcome $(if ($row.State -eq 'OK') { 'Green' } else { 'Yellow' })
            }
            elseif ($Phase -eq 'PRE') {
                $color = if ($crit -gt 0) { '#f8d7da' } elseif ($warn -gt 0) { '#fff3cd' } else { '#d4edda' }
                $row.Outcome = 'PRE CAPTURED'; $row.State = 'PRE'
                $row.Expected = "$crit critical, $warn warning(s)"
                $row.ShortHtml = (@(
                    "<h1>$(Enc $t.Instance)</h1>"
                    "<div class='banner' style='background:$color'>PRE snapshot captured. Current state: $crit critical, $warn warning(s) - these will NOT count as new problems in the POST check.</div>"
                    "<div>Build: $(Enc $snap.meta.build) &nbsp;|&nbsp; Snapshot: $(Enc $snapFile)</div>"
                    "<h3>Needs attention now ($($issues.Count))</h3>"
                    [string](ConvertTo-HtmlTable $issues $issueCols '' 'severity')
                ) -join '')
                $row.FullHtml = $row.ShortHtml + $fullReport
                Write-Step $row.Outcome 'Green'
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
                    $row.State = if ($ok) { 'SUCCESS' } else { 'DIFF' }
                    $color = if ($ok) { '#d4edda' } else { '#f8d7da' }
                    $bannerText = if ($ok) { 'SUCCESS - no unexpected differences between PRE and POST, and no new problems.' }
                                  else { "DIFFERENCES FOUND - $nU unexpected difference(s), $nN new problem(s) after the change." }
                    $row.ShortHtml = (@(
                        "<h1>$(Enc $t.Instance)</h1>"
                        "<div class='banner' style='background:$color'>$(Enc $bannerText)</div>"
                        "<table><tr><th></th><th>PRE (before)</th><th>POST (after)</th></tr>"
                        "<tr><td>Ticket</td><td>$(Enc $pre['meta']['ticket'])</td><td>$(Enc $Ticket)</td></tr>"
                        "<tr><td>Taken</td><td>$(Enc $pre['meta']['taken_at'])</td><td>$(Enc $snap.meta.taken_at)</td></tr>"
                        "<tr><td>By</td><td>$(Enc $pre['meta']['taken_by'])</td><td>$(Enc $me)</td></tr>"
                        "<tr><td>Build</td><td>$(Enc $pre['meta']['build'])</td><td>$(Enc $snap.meta.build)</td></tr></table>"
                        "<h3>Unexpected differences ($nU)</h3>"
                        [string](ConvertTo-HtmlTable $cmp.Unexpected $diffCols 'background-color:#f8d7da')
                        "<h3>New problems after the change ($nN)</h3>"
                        [string](ConvertTo-HtmlTable $cmp.NewProblems $issueCols 'background-color:#f8d7da')
                        "<h3>Expected changes ($nE)</h3>"
                        [string](ConvertTo-HtmlTable $cmp.Expected $diffCols 'background-color:#eef3f8')
                        "<h3>Problems that already existed before the change ($($cmp.OldProblems.Count))</h3>"
                        [string](ConvertTo-HtmlTable $cmp.OldProblems $issueCols 'background-color:#fff3cd')
                    ) -join '')
                    $row.FullHtml = $row.ShortHtml + '<h2>Full POST report</h2>' + $fullReport
                    Write-Step $row.Outcome $(if ($ok) { 'Green' } else { 'Red' })
                    if (-not $ok) { $cmp.Unexpected | Select-Object -First 25 | Format-Table Section, Item, Attribute, Before, After -AutoSize | Out-String -Width 220 | Write-Host }
                }
                else {
                    $row.Outcome = 'NO BASELINE - POST report only'; $row.State = 'NOBASE'
                    $row.ShortHtml = (@(
                        "<h1>$(Enc $t.Instance)</h1>"
                        "<div class='banner' style='background:#fff3cd'>NO BASELINE - no PRE snapshot found for this instance, so nothing could be compared. Current state: $crit critical, $warn warning(s).</div>"
                        "<h3>Needs attention now ($($issues.Count))</h3>"
                        [string](ConvertTo-HtmlTable $issues $issueCols '' 'severity')
                    ) -join '')
                    $row.FullHtml = $row.ShortHtml + $fullReport
                    Write-Step $row.Outcome 'Yellow'
                }
            }

            if ($Config.PerInstanceReports) {
                $f = Join-Path $Config.ReportsFolder ("{0}_{1}_{2}_{3}.html" -f $safe, $Phase, $Ticket, (Get-Date -Format 'yyyyMMdd_HHmm'))
                [System.IO.File]::WriteAllText($f, ([string]$HtmlHead + $row.FullHtml + '</body></html>'), [System.Text.Encoding]::UTF8)
            }
        }
        catch {
            $row.Outcome = 'FAILED: ' + $_.Exception.Message; $row.State = 'FAILED'
            $row.ShortHtml = "<h1>$(Enc $t.Instance)</h1><div class='banner' style='background:#f8d7da'>$(Enc $row.Outcome)</div>"
            $row.FullHtml = $row.ShortHtml
            Write-Step $row.Outcome 'Red'
            if ($_.Exception.Message -match 'Login failed') { Write-Step "  -> $me has no login on $($t.Instance). Use the account you use for SSMS." 'Yellow' }
        }
        finally { if ($conn) { $conn.Dispose() } }
        $summary += [pscustomobject]$row
    }

    # =========================================================================
    #  ONE COMBINED REPORT + ONE EMAIL FOR THE WHOLE VM
    # =========================================================================
    $states = @($summary | ForEach-Object { $_.State })
    $nFail  = @($states | Where-Object { $_ -eq 'FAILED' }).Count
    if ($Phase -eq 'HEALTH') {
        $nCrit = @($states | Where-Object { $_ -eq 'CRIT' }).Count; $nWarn = @($states | Where-Object { $_ -eq 'WARN' }).Count
        $tag = if ($nCrit + $nFail -gt 0) { 'CRITICAL' } elseif ($nWarn -gt 0) { 'WARNING' } else { 'OK' }
        $overall = "$tag - $($summary.Count) instance(s): $nCrit critical, $nWarn with warnings, $nFail failed"
        $overallColor = switch ($tag) { 'CRITICAL' { '#f8d7da' } 'WARNING' { '#fff3cd' } default { '#d4edda' } }
        $importance = if ($tag -eq 'CRITICAL') { 'High' } else { 'Normal' }
    }
    elseif ($Phase -eq 'PRE') {
        $overall = if ($nFail -gt 0) { "PRE CAPTURED - $nFail instance(s) FAILED" } else { 'PRE CAPTURED' }
        $overallColor = if ($nFail -gt 0) { '#f8d7da' } else { '#d4edda' }
        $tag = 'PRE CAPTURED'; $importance = if ($nFail -gt 0) { 'High' } else { 'Normal' }
    }
    elseif ($states -contains 'DIFF')   { $overall = 'DIFFERENCES FOUND - review before closing the change'; $overallColor = '#f8d7da'; $tag = 'POST DIFFERENCES'; $importance = 'High' }
    elseif ($states -contains 'NOBASE') { $overall = 'NO BASELINE for some instances - nothing to compare';  $overallColor = '#fff3cd'; $tag = 'POST NO BASELINE'; $importance = 'High' }
    elseif ($nFail -gt 0)               { $overall = "INCOMPLETE - $nFail instance(s) FAILED";               $overallColor = '#f8d7da'; $tag = 'POST INCOMPLETE';  $importance = 'High' }
    else                                { $overall = 'SUCCESS - no differences on any instance';             $overallColor = '#d4edda'; $tag = 'POST SUCCESS';     $importance = 'Normal' }

    $summaryCols = if ($Phase -in @('PRE', 'HEALTH')) { @('Instance', 'Outcome') } else { @('Instance', 'Outcome', 'Unexpected', 'NewProblems', 'Expected', 'Baseline') }
    $summaryRows = @($summary | ForEach-Object {
        $st = switch ($_.State) { 'DIFF' { 'CRITICAL' } 'FAILED' { 'CRITICAL' } 'CRIT' { 'CRITICAL' } 'NOBASE' { 'WARNING' } 'WARN' { 'WARNING' } default { '' } }
        $o = [ordered]@{ status = $st }; foreach ($c in $summaryCols) { $o[$c] = [string]$_.$c }; [pscustomobject]$o })
    $header = (@(
        "<h2>$(Enc $Config.ReportTitle) - $Phase - $(Enc $env:COMPUTERNAME)</h2>"
        "<div class='banner' style='background:$overallColor'>$(Enc $overall)</div>"
        "<div>Ticket: <b>$(Enc $Ticket)</b> &nbsp;|&nbsp; Run by: $(Enc $me) &nbsp;|&nbsp; $(Get-Date -Format 'yyyy-MM-dd HH:mm') &nbsp;|&nbsp; Instances: $($summary.Count)</div>"
        '<h3>Summary</h3>'
        [string](ConvertTo-HtmlTable $summaryRows $summaryCols '' 'status')
    ) -join '')
    $combinedHtml = [string]$HtmlHead + $header + (($summary | ForEach-Object { $_.FullHtml }) -join "<hr style='margin:30px 0'>") + '</body></html>'
    $combinedFile = Join-Path $Config.ReportsFolder ("{0}_{1}_{2}_{3}.html" -f (Get-SafeFileName $env:COMPUTERNAME), $Phase, $Ticket, (Get-Date -Format 'yyyyMMdd_HHmm'))
    [System.IO.File]::WriteAllText($combinedFile, $combinedHtml, [System.Text.Encoding]::UTF8)
    Write-Step "`nCombined report: $combinedFile" 'Green'

    $subject = "[$tag] $($Config.ReportTitle) [$Ticket] - $env:COMPUTERNAME - $($summary.Count) instance(s)"
    $sender = @($mailCandidates | Sort-Object @{ Expression = { -not $_.Local } }) | Select-Object -First 1
    if (-not $sender) {
        $mailStatus = 'Not sent - no instance with Database Mail'
        Write-Step 'No instance has Database Mail configured/enabled - email not sent. Open the combined report instead.' 'Yellow'
    }
    else {
        $c = $null
        try {
            $c = New-SqlConnection $sender.Instance; $c.Open()
            $shortHtml = [string]$HtmlHead + $header + (($summary | ForEach-Object { $_.ShortHtml }) -join "<hr style='margin:30px 0'>")
            $sizeBytes = (Get-Item -LiteralPath $combinedFile).Length
            $maxBytes = 0
            try { $maxBytes = [int64](Invoke-Scalar $c "SELECT CAST(paramvalue AS bigint) FROM msdb.dbo.sysmail_configuration WHERE paramname = N'MaxFileSize';") } catch { }
            $attach = $Config.AttachReport -and ($maxBytes -le 0 -or $sizeBytes -le $maxBytes)
            if ($Config.AttachReport -and -not $attach) { Write-Step ("Report is {0:N0} KB, above Database Mail MaxFileSize ({1:N0} KB) - sending it in the email body instead." -f ($sizeBytes / 1KB), ($maxBytes / 1KB)) 'Yellow' }
            $mailId = $null
            if ($attach) {
                try {
                    $body = $shortHtml + "<p style='color:#555'>The full report for every instance is attached: $(Enc (Split-Path $combinedFile -Leaf))</p></body></html>"
                    $mailId = Send-DbMail $c $sender.Profile $subject $body $importance $combinedFile
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
            Write-Step "Email queued   : mailitem_id $mailId via $($sender.Instance) / profile '$($sender.Profile)'" 'Green'

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
catch { Write-Step ('ERROR: ' + $_.Exception.Message) 'Red' }
finally {
    Write-Step "`n=== SUMMARY ($Phase / $Ticket) ===" 'Green'
    if ($summary) { $summary | Format-Table Instance, Outcome, Unexpected, NewProblems, Expected, Baseline -AutoSize -Wrap | Out-String -Width 250 | Write-Host }
    Write-Step "Email     : $mailStatus"
    Write-Step "Snapshots : $(Join-Path $Config.SnapshotRoot $Ticket)"
    Write-Step "Reports   : $($Config.ReportsFolder)"
    Write-Step "Report    : $combinedFile"
    # No email sent: open the combined report in the browser
    if ($combinedFile -and ($mailStatus -notlike 'Queued*') -and (Test-Path -LiteralPath $combinedFile)) {
        Write-Step 'Opening the combined report...' 'Yellow'
        try { Invoke-Item -LiteralPath $combinedFile } catch { Write-Step "Could not open it: $($_.Exception.Message)" 'Yellow' }
    }
    Write-Step "Log       : $logFile"
    try { Stop-Transcript | Out-Null } catch { }
    Read-Host "`nPress Enter to close"
}
