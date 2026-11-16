<#
.SYNOPSIS
    PRE / POST change check and HEALTH check (with performance window) for every SQL Server
    instance on this VM.  (v2: performance window + scheduling; jobs/logins/roles removed)
    PRE  : collects a full health-check snapshot (HC_Snapshot.sql), stores it on the VM
           as JSON and emails a "PRE captured" report.
    POST : collects the same snapshot, compares it with the stored PRE and emails
           SUCCESS (no differences) or DIFFERENCES FOUND (with a before -> after table).

.DESCRIPTION
    RDP in with the generic admin account and double-click Run-PrePostCheck.bat:
      1. Choose PRE or POST and enter the change ticket.
      2. Enter YOUR Windows account (as for SSMS "Run as different user"); the script
         starts the Secondary Logon service if needed and relaunches itself as you.
         Fail-safe: any instance your account can't log in to (or has no VIEW SERVER
         STATE on) is retried as the logged-in RDP account, and if run-as can't start
         at all, your account is used from this window. Cancel = RDP account only.
      3. Every SQL instance on the VM (+ ExtraInstances in $Config) is checked.
      4. Files older than CleanupHours in Snapshots / Reports / Logs are removed (or run -Phase CLEANUP).
    Only 3 files are needed: Run-PrePostCheck.bat, Invoke-PrePostCheck.ps1, HC_Snapshot.sql.
    Snapshots : Snapshots\<ticket>\<instance>_PRE|POST_<yyyyMMdd_HHmmss>.json
    Reports   : Reports\<instance>_<PRE|POST>_<ticket>_<yyyyMMdd_HHmm>.html
    Email     : Database Mail on each instance (preferred profile, else default/only profile).

    What is compared (POST vs PRE):
      instance settings, services, sp_configure, global trace flags, databases (state,
      recovery model, compat, owner, options, AG role/sync, backup folders), AG replicas
      (roles, primary, modes, health, listeners), AG databases per replica, cluster &
      quorum, disks, data/log files (paths, growth, max size), linked servers,
      endpoints, certificates, XE sessions,
      and NEW problems (issues present after but not before).
    Expected changes (listed, not failures): build / CU / KB / product level, SQL start time.
    Size drift is ignored unless big: file/DB size change > FileSizeDriftPct % and
    > FileSizeDriftMinMB MB, disk free space change > DiskFreeDriftPct % of the disk.

    HEALTH performance window (v2): after the health check, samples every instance every
    PerfSampleSec seconds for PerfDurationMin minutes: throughput, compilations, connections and
    connection pool usage, locking/blocking/deadlocks, memory, wait stats per interval, file
    latency, tempdb, Always On queues/delay and listener connections, plus queries over
    LongQuerySec seconds and the top 20 queries of the window (plan cache, start vs end - no Query Store). Sets 'blocked process
    threshold' to BlockedProcessThresholdSec and a temporary XE session, both reverted at the end.
    Option 5 (SCHEDULE) creates a Windows scheduled task that runs it unattended.

    Requirements: Windows PowerShell 5.1. No modules, sqlcmd or internet needed.
    Your SQL permissions: VIEW SERVER STATE, read msdb, DatabaseMailUserRole (or sysadmin).

.EXAMPLE
    .\Invoke-PrePostCheck.ps1                                    # interactive (what the .bat does)
.EXAMPLE
    .\Invoke-PrePostCheck.ps1 -Phase PRE  -Ticket CHG0012345
.EXAMPLE
    .\Invoke-PrePostCheck.ps1 -Phase POST -Ticket CHG0012345 -UseCurrentUser
.EXAMPLE
    .\Invoke-PrePostCheck.ps1 -Phase HEALTH -SampleSec 30 -DurationMin 15     # performance window 15 min
.EXAMPLE
    .\Invoke-PrePostCheck.ps1 -Phase HEALTH -Unattended -Ticket SCHEDULED       # what the scheduled task runs
#>
[CmdletBinding()]
param(
    [string]   $Phase = '',          # PRE, POST or HEALTH (prompted if empty)
    [string]   $Ticket,
    [switch]   $UseCurrentUser,
    [string[]] $Instances,
    [string]   $SqlFile,
    [switch]   $Inner,
    [string]   $HandOff,              # internal: result file shared with the original (RDP) window
    [int]      $SampleSec = 0,        # HEALTH performance window: seconds between samples (0 = $Config value)
    [int]      $DurationMin = -1,     # HEALTH performance window: minutes (-1 = $Config value, 0 = skip)
    [switch]   $NoPerf,               # HEALTH without the performance window
    [switch]   $Unattended            # no prompts (Task Scheduler): runs as the task's account, no pauses
)

# =============================================================================
#  CONFIGURATION  <== change these once
# =============================================================================
$Config = @{
    Recipients            = 'dba-team@yourcompany.com'   # ; separated
    CopyRecipients        = ''
    FromAddress           = ''                           # optional, e.g. 'SQL Alerts <sqlalerts@yourcompany.com>' ('' = profile's account)
    ReplyTo               = ''                           # optional reply-to address
    MailProfile           = 'DBA_Mail'                   # preferred; else default / only profile on the instance
    ReportTitle           = 'SQL Server Change Check'
    HealthReportTitle     = 'SQL Server Health Check'      # used for -Phase HEALTH
    IncludeLocalInstances = $true
    ExtraInstances        = @()      # other instances to add, e.g. @('SQLVM2', 'SQLVM3\INST2', 'SQLVM4,14330')
    ServersFile           = Join-Path $PSScriptRoot 'servers.txt'   # optional, one instance per line (old setups)
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
    CleanupHours          = 48       # each run deletes Reports / Logs / finished Snapshots older than this (0 = off)
    KeepPreWithoutPostDays = 7       # a PRE still waiting for its POST is kept this long

    # ---- HEALTH performance window ----
    PerfSampling          = $true    # run the performance window after the HEALTH check
    PerfSampleSec         = 60       # seconds between samples
    PerfDurationMin       = 30       # length of the window in minutes
    PerfDatabases         = @()      # databases for 'Trans/s' e.g. @('MARS', 'CLR'); @() = all databases
    BlockedProcessThresholdSec = 5   # 'blocked process threshold' during the window (restored after)
    LongQuerySec          = 5        # capture every query running longer than this (XE)
    TopQueries            = $true    # top 20 queries of the window from the plan cache (dm_exec_query_stats start vs end); $false = skip
    PerfThresholds        = @{ PleMin = 300; DataReadMs = 20; LogWriteMs = 10; AgSendQueueMB = 100 }
    ScheduledTaskName     = 'DBA SQL Health Check'      # prefix of the Windows scheduled tasks created by option 5
}

$ErrorActionPreference = 'Stop'
$Phase = ([string]$Phase).Trim().ToUpperInvariant()
if ($Phase -eq 'HC') { $Phase = 'HEALTH' }
if ($Unattended) { $UseCurrentUser = $true; if (-not $Phase) { $Phase = 'HEALTH' } }
if (($Inner -or $Unattended) -and $Phase -notin @('PRE', 'POST', 'HEALTH', 'CLEANUP')) { throw "Invalid -Phase '$Phase' (use PRE, POST, HEALTH or CLEANUP)." }
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
        $has = if ($Row -is [System.Collections.Specialized.OrderedDictionary]) { $Row.Contains($Col) } else { $Row.ContainsKey($Col) }
        if ($has -and $null -ne $Row[$Col]) { return ([string]$Row[$Col]).Trim() }
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
    foreach ($x in @($Config.ExtraInstances)) { if ([string]$x) { $targets += [pscustomobject]@{ Instance = ([string]$x).Trim(); Service = ''; Status = 'Listed' } } }
    if (Test-Path $Config.ServersFile) {
        Get-Content $Config.ServersFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') } |
            ForEach-Object { $targets += [pscustomobject]@{ Instance = $_; Service = ''; Status = 'Listed' } }
    }
    $seen = @{}; $unique = @()
    foreach ($t in $targets) { $k = $t.Instance.ToUpperInvariant(); if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $unique += $t } }
    return $unique
}

function Invoke-Cleanup([int]$Hours = $Config.CleanupHours, [int]$KeepPreDays = $Config.KeepPreWithoutPostDays) {
    # Reports / Logs: files older than $Hours. Snapshots: only once the ticket has a POST
    # (a PRE still waiting for its POST is kept $KeepPreDays days). Empty ticket folders are removed.
    if ($Hours -le 0) { return }
    $cutoff = (Get-Date).AddHours(-$Hours); $preCutoff = (Get-Date).AddDays(-$KeepPreDays); $n = 0
    $del = { param($f) try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $true } catch { Write-Step "  could not delete $($f.FullName): $($_.Exception.Message)" 'DarkGray'; $false } }
    foreach ($folder in @($Config.ReportsFolder, $Config.LogsFolder)) {
        if (-not (Test-Path $folder)) { continue }
        Get-ChildItem -Path $folder -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cutoff } | ForEach-Object { if (& $del $_) { $n++ } }
    }
    if (Test-Path $Config.SnapshotRoot) {
        foreach ($dir in Get-ChildItem -Path $Config.SnapshotRoot -Directory -ErrorAction SilentlyContinue) {
            $files   = @(Get-ChildItem -Path $dir.FullName -File -ErrorAction SilentlyContinue)
            $hasPost = @($files | Where-Object { $_.Name -like '*_POST_*' }).Count -gt 0
            $limit   = if ($hasPost) { $cutoff } else { $preCutoff }
            foreach ($f in $files) { if ($f.LastWriteTime -lt $limit) { if (& $del $f) { $n++ } } }
            if (-not (Get-ChildItem -Path $dir.FullName -Force -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue }
        }
    }
    Write-Step "Cleanup    : $n file(s) older than $Hours h removed (PRE without POST kept $KeepPreDays days)" 'DarkGray'
}

function Grant-FolderAccess([string[]]$Accounts) {
    # Your account (run-as window) and the RDP account (fail-safe) both write snapshots, reports and logs.
    # Give both Modify on this folder, inherited by everything below it, so neither gets "Access denied".
    $ErrorActionPreference = 'Continue'      # icacls writes failures to stderr
    foreach ($f in @($Config.SnapshotRoot, $Config.ReportsFolder, $Config.LogsFolder)) {
        if (-not (Test-Path $f)) { try { New-Item -ItemType Directory -Path $f -Force | Out-Null } catch { } }
    }
    foreach ($a in @($Accounts | Where-Object { $_ } | Select-Object -Unique)) {
        $acct = if ($a -match '\\|@') { $a } else { "$env:USERDOMAIN\$a" }
        $out = & icacls.exe "$PSScriptRoot" /grant "$($acct):(OI)(CI)M" /T /C /Q 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Step "Folder access : $acct can write to $PSScriptRoot" 'DarkGray' }
        else { Write-Step "WARNING: could not give $acct write access to $PSScriptRoot - $(($out | Out-String).Trim())" 'Yellow'
               Write-Step '  Ask a local admin to grant it Modify on this folder, or snapshots for some instances may fail with Access denied.' 'Yellow' }
    }
}

function New-SqlConnection([string]$Instance) {
    $enc = if ($Config.Encrypt) { 'True' } else { 'False' }
    $cs = "Server=$Instance;Database=master;Integrated Security=SSPI;Application Name=DBA PrePostCheck;" +
          "Connect Timeout=$($Config.ConnectTimeoutSec);Encrypt=$enc;TrustServerCertificate=True"
    return New-Object System.Data.SqlClient.SqlConnection $cs
}

# ---- Fail-safe connections ----
# Normal path: the script relaunches itself as YOUR account (Secondary Logon) and connects as you.
# Fail-safe 1: if the relaunch can't start, this window logs on as you in-process (impersonation).
# Fail-safe 2: instances your account can't use are retried as the logged-in RDP account.
if (-not ('DbaLogon' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class DbaLogon {
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool LogonUser(string user, string domain, string password, int logonType, int provider, out IntPtr token);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr handle);
}
"@
}
$script:ImpIdentity = $null
$script:ImpUser     = $null
$script:RetryErrors = $null   # set in the original window when the run-as window hands instances back
$script:HandOffRows = $null
$script:HandOffMail = $null
$script:KeyedUser   = $null

function Connect-AsUser([pscredential]$Credential) {
    # Returns $true if the keyed-in Windows account could be logged on (password / logon rights OK).
    $name = $Credential.UserName; $domain = $null; $user = $name
    if ($name -match '^(.+)\\(.+)$') { $domain = $Matches[1]; $user = $Matches[2] }
    elseif ($name -notmatch '@') { $domain = $env:USERDOMAIN }
    $pw = $Credential.GetNetworkCredential().Password
    foreach ($type in 2, 8, 3) {        # interactive, network cleartext, network
        $token = [IntPtr]::Zero
        if ([DbaLogon]::LogonUser($user, $domain, $pw, $type, 0, [ref]$token)) {
            $script:ImpIdentity = New-Object System.Security.Principal.WindowsIdentity($token)
            [void][DbaLogon]::CloseHandle($token)
            $script:ImpUser = $script:ImpIdentity.Name
            return $true
        }
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($err -eq 1326) { Write-Step "Logon failed for $name - wrong user name or password." 'Red'; return $false }
        if ($err -in 1327, 1330, 1331, 1909) { Write-Step "Logon failed for $name - account restricted, expired, disabled or locked (error $err)." 'Red'; return $false }
    }
    Write-Step "Logon failed for $name (error $err)." 'Red'
    return $false
}

function Test-SqlAccess($Connection) {
    try { return ([int](Invoke-Scalar $Connection "SELECT ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE'), 0);") -eq 1) } catch { return $false }
}

function Open-SqlConnection([string]$Instance, [switch]$RequirePerms, [switch]$NoImpersonation) {
    # 1st: the keyed-in account (impersonated). 2nd: the account running this script.
    # -RequirePerms: fail instead of continuing without VIEW SERVER STATE (so the RDP user can retry it).
    $notes = @()
    $current = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ($script:ImpIdentity -and -not $NoImpersonation) {
        $conn = New-SqlConnection $Instance; $ctx = $null
        try { $ctx = $script:ImpIdentity.Impersonate(); $conn.Open() }
        catch { $notes += "$($script:ImpUser): $($_.Exception.Message)"; $conn.Dispose(); $conn = $null }
        finally { if ($ctx) { $ctx.Undo() } }
        if ($conn) {
            if (Test-SqlAccess $conn) { return [pscustomobject]@{ Connection = $conn; As = $script:ImpUser } }
            $notes += "$($script:ImpUser): connected but has no VIEW SERVER STATE"
            $conn.Dispose()
        }
        Write-Step "  $($script:ImpUser) can't be used on $Instance - trying $current" 'Yellow'
        $notes | ForEach-Object { Write-Step "    $_" 'DarkGray' }
    }
    $conn = New-SqlConnection $Instance
    try { $conn.Open() }
    catch {
        $conn.Dispose()
        throw ((@($notes) + "$($current): $($_.Exception.Message)") -join ' | ')
    }
    if (-not (Test-SqlAccess $conn)) {
        if ($RequirePerms) { $conn.Dispose(); throw "$current has no VIEW SERVER STATE on $Instance" }
        Write-Step "  WARNING: $current has no VIEW SERVER STATE on $Instance - some checks will be empty." 'Yellow'
    }
    return [pscustomobject]@{ Connection = $conn; As = $current }
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

# =============================================================================
#  PERFORMANCE WINDOW (HEALTH): sample every N seconds, then report trends
# =============================================================================
function Get-SqlBlocks([string]$Text) {
    # HC_Snapshot.sql = health-check part, then --##PERF_* blocks run separately
    $blocks = @{}; $name = 'HC'; $sb = New-Object System.Text.StringBuilder
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^--##(PERF_\w+)\s*$') { $blocks[$name] = $sb.ToString(); $name = $Matches[1]; $sb = New-Object System.Text.StringBuilder; continue }
        [void]$sb.AppendLine($line)
    }
    $blocks[$name] = $sb.ToString()
    return $blocks
}

function Expand-SqlTokens([string]$Sql, [hashtable]$Tokens) {
    foreach ($k in $Tokens.Keys) { $Sql = $Sql.Replace('{{' + $k + '}}', [string]$Tokens[$k]) }
    return $Sql
}

function ConvertTo-Num($Value) {
    $d = 0.0
    if ([double]::TryParse([string]$Value, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return 0.0
}

function Get-PcMap($Snap) {
    $m = @{}
    foreach ($r in @(Get-Rows $Snap 'pc')) { $m[('{0}|{1}|{2}' -f $r['obj'], $r['ctr'], $r['inst'])] = (ConvertTo-Num $r['val']) }
    return $m
}
function Get-Pc($Map, [string]$Key) { if ($Map.ContainsKey($Key)) { return [double]$Map[$Key] }; return 0.0 }
function Get-SampleTime($Snap) {
    $t = Get-Val (@(Get-Rows $Snap 'sample') | Select-Object -First 1) 'sample_time'
    return [datetime]::ParseExact($t, 'yyyy-MM-dd HH:mm:ss.fff', [System.Globalization.CultureInfo]::InvariantCulture)
}
function R1([double]$v) { return [math]::Round($v, 1) }

function Invoke-PerfWindow($Items, [hashtable]$Blocks, [int]$SampleSec, [int]$DurationMin) {
    # $Items: objects with Instance, Conn, Safe. Adds Samples, Setup, End, Notes, StartTime.
    $tok = @{ BPT_SEC = [int]$Config.BlockedProcessThresholdSec; LONG_SEC = [int]$Config.LongQuerySec; LONG_US = [int64]$Config.LongQuerySec * 1000000; TOPQ = $(if ($Config.TopQueries) { 1 } else { 0 }) }
    foreach ($it in $Items) {
        $it | Add-Member -NotePropertyName Samples -NotePropertyValue (New-Object System.Collections.ArrayList) -Force
        $it | Add-Member -NotePropertyName Notes -NotePropertyValue (New-Object System.Collections.ArrayList) -Force
        $it | Add-Member -NotePropertyName Setup -NotePropertyValue $null -Force
        $it | Add-Member -NotePropertyName End -NotePropertyValue $null -Force
        $it | Add-Member -NotePropertyName StartTime -NotePropertyValue ((Get-Date).ToString('o')) -Force
        $it | Add-Member -NotePropertyName RestoreFile -NotePropertyValue (Join-Path $Config.LogsFolder ("perf_restore_{0}.txt" -f $it.Safe)) -Force
        # A run that was interrupted left the threshold changed: put the value it recorded back first
        if (Test-Path -LiteralPath $it.RestoreFile) {
            $old = ([string](Get-Content -LiteralPath $it.RestoreFile -Raw)).Trim()
            if ($old -match '^\d+$') {
                try { [void](Get-Snapshot $it.Conn (Expand-SqlTokens $Blocks['PERF_TEARDOWN'] @{ RESTORE = 1; ORIG = $old })); Write-Step "  $($it.Instance): restored blocked process threshold ($old) left by an interrupted run" 'Yellow' } catch { }
            }
            Remove-Item -LiteralPath $it.RestoreFile -Force -ErrorAction SilentlyContinue
        }
        try {
            $r = Get-Snapshot $it.Conn (Expand-SqlTokens $Blocks['PERF_START'] $tok)
            $it.Setup = @(Get-Rows $r 'perf_setup') | Select-Object -First 1
            if ($it.Setup) {
                $it.StartTime = $it.Setup['start_time']
                if ($it.Setup['threshold_set'] -eq '1') { try { Set-Content -LiteralPath $it.RestoreFile -Value $it.Setup['orig_threshold'] } catch { } }
                if ($it.Setup['message']) { [void]$it.Notes.Add([string]$it.Setup['message']); Write-Step "  $($it.Instance): $($it.Setup['message'])" 'Yellow' }
                $xeTxt = if ($it.Setup['xe_started'] -eq '1') { 'XE session DBA_PerfWindow started' } else { 'no XE session (DMV sampling only)' }
                Write-Step ("  {0}: blocked process threshold {1} s -> {2} s, {3}" -f $it.Instance, $it.Setup['orig_threshold'], $(if ($it.Setup['threshold_set'] -eq '1') { $Config.BlockedProcessThresholdSec } else { $it.Setup['orig_threshold'] }), $xeTxt) 'DarkGray'
            }
        }
        catch { [void]$it.Notes.Add("Setup failed: $($_.Exception.Message)"); Write-Step "  $($it.Instance): setup failed - $($_.Exception.Message)" 'Yellow' }
    }

    $n = [math]::Max(1, [int][math]::Floor($DurationMin * 60 / $SampleSec))
    Write-Step ("Performance window: {0} intervals of {1} s, ends about {2}{3}" -f $n, $SampleSec, (Get-Date).AddSeconds($n * $SampleSec).ToString('HH:mm'), $(if ($Unattended) { '' } else { ' (press Q to stop early)' })) 'Green'
    try {
        for ($i = 0; $i -le $n; $i++) {
            $t0 = Get-Date
            foreach ($it in $Items) {
                try { [void]$it.Samples.Add((Get-Snapshot $it.Conn (Expand-SqlTokens $Blocks['PERF_SAMPLE'] $tok))) }
                catch { [void]$it.Notes.Add("Sample at $($t0.ToString('HH:mm:ss')) failed: $($_.Exception.Message)") }
            }
            Write-Host ("`r  sample {0}/{1} at {2}   " -f $i, $n, (Get-Date -Format 'HH:mm:ss')) -NoNewline
            if ($i -ge $n) { break }
            $stop = $false
            while (((Get-Date) - $t0).TotalSeconds -lt $SampleSec) {
                Start-Sleep -Milliseconds 500
                if (-not $Unattended) { try { if ([Console]::KeyAvailable -and ([Console]::ReadKey($true)).Key -eq 'Q') { $stop = $true; break } } catch { } }
            }
            if ($stop) { Write-Host ''; Write-Step 'Stopping early - taking the last sample now.' 'Yellow'; $n = $i + 1 }
        }
        Write-Host ''
        foreach ($it in $Items) {
            try { $it.End = Get-Snapshot $it.Conn (Expand-SqlTokens $Blocks['PERF_END'] @{ START = $it.StartTime; LONG_SEC = $Config.LongQuerySec; TOPQ = $tok.TOPQ }) }
            catch { [void]$it.Notes.Add("Blocked process / deadlock / top query collection failed: $($_.Exception.Message)") }
        }
    }
    finally {
        # Always put the server back: drop the XE session, restore the original threshold
        foreach ($it in $Items) {
            $restore = if ($it.Setup -and $it.Setup['threshold_set'] -eq '1') { 1 } else { 0 }
            $orig = if ($it.Setup) { $it.Setup['orig_threshold'] } else { '0' }
            try {
                $td = @(Get-Rows (Get-Snapshot $it.Conn (Expand-SqlTokens $Blocks['PERF_TEARDOWN'] @{ RESTORE = $restore; ORIG = $orig })) 'perf_teardown') | Select-Object -First 1
                if ($td -and $td['message']) { [void]$it.Notes.Add([string]$td['message']); Write-Step "  $($it.Instance): $($td['message'])" 'Yellow' }
                else { Remove-Item -LiteralPath $it.RestoreFile -Force -ErrorAction SilentlyContinue }
                if ($restore) { Write-Step "  $($it.Instance): blocked process threshold restored to $orig s, XE session dropped" 'DarkGray' }
            }
            catch {
                $fix = "EXEC sp_configure 'blocked process threshold (s)', $orig; RECONFIGURE; DROP EVENT SESSION DBA_PerfWindow ON SERVER;"
                [void]$it.Notes.Add("Clean-up failed ($($_.Exception.Message)) - run: $fix")
                Write-Step "  WARNING: $($it.Instance) clean-up failed - run: $fix" 'Red'
            }
        }
    }
}

function Get-PerfResult($It, [int]$SampleSec) {
    # Turns the samples into per-interval rows, window summary, issues and HTML.
    $th = $Config.PerfThresholds
    $S = @($It.Samples)
    $issues = New-Object System.Collections.ArrayList
    $addIssue = { param($sev, $area, $item, $detail) [void]$issues.Add([ordered]@{ severity = $sev; area = $area; item = $item; detail = $detail }) }
    $iv = New-Object System.Collections.ArrayList
    $wv = New-Object System.Collections.ArrayList
    $waitGroups = @('LCK_M_*', 'PAGEIOLATCH_*', 'PAGELATCH_*', 'WRITELOG', 'CXPACKET', 'CXCONSUMER', 'SOS_SCHEDULER_YIELD', 'HADR_SYNC_COMMIT', 'RESOURCE_SEMAPHORE')
    $waitTot = @{}; foreach ($g in $waitGroups) { $waitTot[$g] = 0.0 }
    $tx = @{}; $deadlocks = 0.0; $timeouts = 0.0
    $pool = @{}; $ag = @{}; $lsn = @{}
    $skipDb = @('_Total', 'mssqlsystemresource')

    for ($k = 1; $k -lt $S.Count; $k++) {
        $a = $S[$k - 1]; $b = $S[$k]
        try { $ta = Get-SampleTime $a; $tb = Get-SampleTime $b } catch { continue }
        $dt = ($tb - $ta).TotalSeconds; if ($dt -le 0) { continue }
        $ma = Get-PcMap $a; $mb = Get-PcMap $b
        $rate = { param($key) [math]::Max(0.0, ((Get-Pc $mb $key) - (Get-Pc $ma $key)) / $dt) }
        $delta = { param($key) [math]::Max(0.0, (Get-Pc $mb $key) - (Get-Pc $ma $key)) }

        # transactions/sec per database
        $tps = 0.0
        foreach ($key in @($mb.Keys | Where-Object { $_ -like 'Databases|Transactions/sec|*' })) {
            $db = $key.Substring('Databases|Transactions/sec|'.Length)
            if ($skipDb -contains $db) { continue }
            $v = & $rate $key
            if (-not $tx.ContainsKey($db)) { $tx[$db] = New-Object System.Collections.ArrayList }
            [void]$tx[$db].Add($v)
            if (@($Config.PerfDatabases).Count -gt 0) { if (@($Config.PerfDatabases) -contains $db) { $tps += $v } }
        }
        if (@($Config.PerfDatabases).Count -eq 0) { $tps = & $rate 'Databases|Transactions/sec|_Total' }

        # file latency (all databases)
        $io = @{}
        foreach ($snap in @($a, $b)) { foreach ($r in @(Get-Rows $snap 'io')) { $io[('{0}|{1}|{2}' -f [object]::ReferenceEquals($snap, $a), $r['db'], $r['ftype'])] = $r } }
        $dR = 0.0; $dRs = 0.0; $dW = 0.0; $dWs = 0.0
        foreach ($r in @(Get-Rows $b 'io')) {
            $p = $io[('True|{0}|{1}' -f $r['db'], $r['ftype'])]; if (-not $p) { continue }
            if ($r['ftype'] -eq 'DATA') { $dR += [math]::Max(0, (ConvertTo-Num $r['reads']) - (ConvertTo-Num $p['reads'])); $dRs += [math]::Max(0, (ConvertTo-Num $r['read_stall_ms']) - (ConvertTo-Num $p['read_stall_ms'])) }
            else { $dW += [math]::Max(0, (ConvertTo-Num $r['writes']) - (ConvertTo-Num $p['writes'])); $dWs += [math]::Max(0, (ConvertTo-Num $r['write_stall_ms']) - (ConvertTo-Num $p['write_stall_ms'])) }
        }

        $blk = @(Get-Rows $b 'blocking') | Select-Object -First 1
        $tdb = @(Get-Rows $b 'tempdb') | Select-Object -First 1
        $agRows = @(Get-Rows $b 'ag')
        $mirr = & $delta 'Database Replica|Mirrored Write Transactions/sec|_Total'
        $bchrBase = Get-Pc $mb 'Buffer Manager|Buffer cache hit ratio base|'
        $deadlocks += & $delta 'Locks|Number of Deadlocks/sec|_Total'
        $timeouts  += & $delta 'Locks|Lock Timeouts/sec|_Total'

        [void]$iv.Add([ordered]@{
            'Time'               = $tb.ToString('HH:mm:ss')
            'Batch req/s'        = R1 (& $rate 'SQL Statistics|Batch Requests/sec|')
            'Trans/s'            = R1 $tps
            'Compiles/s'         = R1 (& $rate 'SQL Statistics|SQL Compilations/sec|')
            'Recompiles/s'       = R1 (& $rate 'SQL Statistics|SQL Re-Compilations/sec|')
            'User conns'         = Get-Pc $mb 'General Statistics|User Connections|'
            'Lock waits/s'       = R1 (& $rate 'Locks|Lock Waits/sec|_Total')
            'Lock wait ms/s'     = R1 (& $rate 'Locks|Lock Wait Time (ms)|_Total')
            'Lock timeouts/s'    = R1 (& $rate 'Locks|Lock Timeouts/sec|_Total')
            'Deadlocks/s'        = [math]::Round((& $rate 'Locks|Number of Deadlocks/sec|_Total'), 3)
            'Blocked >5s'        = ConvertTo-Num (Get-Val $blk 'blocked')
            'Max block s'        = R1 ((ConvertTo-Num (Get-Val $blk 'max_wait_ms')) / 1000)
            'PLE s'              = Get-Pc $mb 'Buffer Manager|Page life expectancy|'
            'Buffer hit %'       = $(if ($bchrBase -gt 0) { R1 ((Get-Pc $mb 'Buffer Manager|Buffer cache hit ratio|') / $bchrBase * 100) } else { 0 })
            'Grants pending'     = Get-Pc $mb 'Memory Manager|Memory Grants Pending|'
            'Target MB'          = [math]::Round((Get-Pc $mb 'Memory Manager|Target Server Memory (KB)|') / 1024)
            'Total MB'           = [math]::Round((Get-Pc $mb 'Memory Manager|Total Server Memory (KB)|') / 1024)
            'Data read ms'       = $(if ($dR -gt 0) { R1 ($dRs / $dR) } else { 0 })
            'Log write ms'       = $(if ($dW -gt 0) { R1 ($dWs / $dW) } else { 0 })
            'Log flush wait ms/s'= R1 (& $rate 'Databases|Log Flush Wait Time|_Total')
            'Log MB/s'           = [math]::Round((& $rate 'Databases|Log Bytes Flushed/sec|_Total') / 1MB, 2)
            'TempDB used MB'     = R1 ((ConvertTo-Num (Get-Val $tdb 'user_mb')) + (ConvertTo-Num (Get-Val $tdb 'internal_mb')) + (ConvertTo-Num (Get-Val $tdb 'version_mb')))
            'Version store MB'   = R1 ((Get-Pc $mb 'Transactions|Version Store Size (KB)|') / 1024)
            'TempDB alloc waits' = ConvertTo-Num (Get-Val $tdb 'alloc_waiters')
            'AG send queue MB'   = R1 ((@($agRows | ForEach-Object { ConvertTo-Num $_['send_queue_kb'] }) + 0 | Measure-Object -Maximum).Maximum / 1024)
            'AG redo queue MB'   = R1 ((@($agRows | ForEach-Object { ConvertTo-Num $_['redo_queue_kb'] }) + 0 | Measure-Object -Maximum).Maximum / 1024)
            'AG trans delay ms'  = $(if ($mirr -gt 0) { R1 ((& $delta 'Database Replica|Transaction Delay|_Total') / $mirr) } else { 0 })
            'Listener conns'     = (@(Get-Rows $b 'listener' | ForEach-Object { ConvertTo-Num $_['connections'] }) + 0 | Measure-Object -Sum).Sum
        })

        # waits per interval (ms waited in the interval)
        $wa = @{}; foreach ($r in @(Get-Rows $a 'waits')) { $wa[$r['grp']] = ConvertTo-Num $r['wait_ms'] }
        $wrow = [ordered]@{ 'Time' = $tb.ToString('HH:mm:ss') }
        foreach ($g in $waitGroups) {
            $wb = 0.0; foreach ($r in @(Get-Rows $b 'waits')) { if ($r['grp'] -eq $g) { $wb = ConvertTo-Num $r['wait_ms'] } }
            $d = [math]::Max(0.0, $wb - $(if ($wa.ContainsKey($g)) { $wa[$g] } else { $wb }))
            $wrow[$g] = [math]::Round($d); $waitTot[$g] += $d
        }
        [void]$wv.Add($wrow)
    }

    # connection pool usage, Always On and listeners across all samples
    foreach ($snap in $S) {
        foreach ($r in @(Get-Rows $snap 'sessions')) {
            $key = '{0}|{1}|{2}' -f $r['program'], $r['host'], $r['login']
            if (-not $pool.ContainsKey($key)) { $pool[$key] = @{ program = $r['program']; host = $r['host']; login = $r['login']; max = 0.0; sum = 0.0; maxActive = 0.0 } }
            $p = $pool[$key]; $c = ConvertTo-Num $r['sessions']
            $p.sum += $c; if ($c -gt $p.max) { $p.max = $c }
            $ac = ConvertTo-Num $r['active']; if ($ac -gt $p.maxActive) { $p.maxActive = $ac }
        }
        foreach ($r in @(Get-Rows $snap 'ag')) {
            $key = '{0}|{1}|{2}' -f $r['ag_name'], $r['db'], $r['replica']
            if (-not $ag.ContainsKey($key)) { $ag[$key] = @{ ag = $r['ag_name']; db = $r['db']; replica = $r['replica']; states = @{}; send = 0.0; redo = 0.0; last = '' } }
            $g = $ag[$key]; $g.states[$r['sync_state']] = $true; $g.last = $r['sync_state']
            $sq = ConvertTo-Num $r['send_queue_kb']; if ($sq -gt $g.send) { $g.send = $sq }
            $rq = ConvertTo-Num $r['redo_queue_kb']; if ($rq -gt $g.redo) { $g.redo = $rq }
        }
        foreach ($r in @(Get-Rows $snap 'listener')) {
            $key = '{0}|{1}' -f $r['listener'], $r['ip_address']
            if (-not $lsn.ContainsKey($key)) { $lsn[$key] = @{ listener = $r['listener']; ip = $r['ip_address']; min = [double]::MaxValue; max = 0.0; sum = 0.0; n = 0 } }
            $l = $lsn[$key]; $c = ConvertTo-Num $r['connections']; $l.sum += $c; $l.n++
            if ($c -gt $l.max) { $l.max = $c }; if ($c -lt $l.min) { $l.min = $c }
        }
    }
    $first = if ($S.Count) { $S[0] } else { $null }; $last = if ($S.Count) { $S[$S.Count - 1] } else { $null }
    $mf = Get-PcMap $first; $ml = Get-PcMap $last

    # ---- tables ----
    $nS = [math]::Max(1, $S.Count)
    $poolRows = @($pool.Values | Sort-Object { $_.max } -Descending | Select-Object -First 15 | ForEach-Object {
        [ordered]@{ 'Program' = $_.program; 'Host' = $_.host; 'Login' = $_.login; 'Peak sessions' = $_.max; 'Avg sessions' = R1 ($_.sum / $nS); 'Peak active' = $_.maxActive } })
    $txRows = @($tx.Keys | ForEach-Object {
        $vals = @($tx[$_]); [ordered]@{ 'Database' = $_; 'Avg trans/s' = R1 (($vals | Measure-Object -Average).Average); 'Peak trans/s' = R1 (($vals | Measure-Object -Maximum).Maximum) } } |
        Where-Object { @($Config.PerfDatabases).Count -eq 0 -or @($Config.PerfDatabases) -contains $_['Database'] } |
        Sort-Object { $_['Avg trans/s'] } -Descending | Select-Object -First 15)
    $ioRows = @()
    if ($first -and $last) {
        $fio = @{}; foreach ($r in @(Get-Rows $first 'io')) { $fio[('{0}|{1}' -f $r['db'], $r['ftype'])] = $r }
        $ioRows = @(Get-Rows $last 'io' | ForEach-Object {
            $p = $fio[('{0}|{1}' -f $_['db'], $_['ftype'])]; if (-not $p) { return }
            $rd = [math]::Max(0, (ConvertTo-Num $_['reads']) - (ConvertTo-Num $p['reads'])); $wr = [math]::Max(0, (ConvertTo-Num $_['writes']) - (ConvertTo-Num $p['writes']))
            $rs = [math]::Max(0, (ConvertTo-Num $_['read_stall_ms']) - (ConvertTo-Num $p['read_stall_ms'])); $ws = [math]::Max(0, (ConvertTo-Num $_['write_stall_ms']) - (ConvertTo-Num $p['write_stall_ms']))
            if ($rd + $wr -eq 0) { return }
            [ordered]@{ 'Database' = $_['db']; 'File type' = $_['ftype']; 'Reads' = $rd; 'Avg read ms' = $(if ($rd) { R1 ($rs / $rd) } else { 0 }); 'Writes' = $wr; 'Avg write ms' = $(if ($wr) { R1 ($ws / $wr) } else { 0 }) }
        } | Sort-Object { [math]::Max($_['Avg read ms'], $_['Avg write ms']) } -Descending)
    }
    $agRows2 = @($ag.Values | Sort-Object { $_.ag }, { $_.db }, { $_.replica } | ForEach-Object {
        $dbKey = $_.db
        $dly = (Get-Pc $ml "Database Replica|Transaction Delay|$dbKey") - (Get-Pc $mf "Database Replica|Transaction Delay|$dbKey")
        $mw  = (Get-Pc $ml "Database Replica|Mirrored Write Transactions/sec|$dbKey") - (Get-Pc $mf "Database Replica|Mirrored Write Transactions/sec|$dbKey")
        $bad = @($_.states.Keys | Where-Object { $_ -and $_ -notin @('SYNCHRONIZED', 'SYNCHRONIZING') })
        [ordered]@{ 'status' = $(if ($bad.Count) { 'CRITICAL' } else { '' }); 'AG' = $_.ag; 'Database' = $_.db; 'Replica' = $_.replica; 'Sync state (last)' = $_.last
                    'States seen' = (@($_.states.Keys) -join ', '); 'Max send queue MB' = R1 ($_.send / 1024); 'Max redo queue MB' = R1 ($_.redo / 1024)
                    'Avg trans delay ms' = $(if ($mw -gt 0) { R1 ($dly / $mw) } else { '' }) } })
    $lsnRows = @($lsn.Values | Sort-Object { $_.listener } | ForEach-Object {
        [ordered]@{ 'Listener' = $_.listener; 'IP' = $_.ip; 'Min conns' = $(if ($_.n) { $_.min } else { 0 }); 'Avg conns' = $(if ($_.n) { R1 ($_.sum / $_.n) } else { 0 }); 'Max conns' = $_.max } })

    # ---- window summary (avg / min / max of every interval metric) ----
    $areas = [ordered]@{
        'Throughput' = @('Batch req/s', 'Trans/s'); 'Compilation' = @('Compiles/s', 'Recompiles/s'); 'Connections' = @('User conns')
        'Locking' = @('Lock waits/s', 'Lock wait ms/s', 'Lock timeouts/s', 'Deadlocks/s', 'Blocked >5s', 'Max block s')
        'Memory' = @('PLE s', 'Buffer hit %', 'Grants pending', 'Target MB', 'Total MB')
        'I/O' = @('Data read ms', 'Log write ms', 'Log flush wait ms/s', 'Log MB/s')
        'TempDB' = @('TempDB used MB', 'Version store MB', 'TempDB alloc waits')
        'Always On' = @('AG send queue MB', 'AG redo queue MB', 'AG trans delay ms', 'Listener conns')
    }
    $sum = New-Object System.Collections.ArrayList
    foreach ($area in $areas.Keys) {
        foreach ($m in $areas[$area]) {
            $vals = @($iv | ForEach-Object { [double]$_[$m] })
            if (-not $vals.Count) { continue }
            $st = $vals | Measure-Object -Average -Minimum -Maximum
            [void]$sum.Add([ordered]@{ 'Area' = $area; 'Metric' = $m; 'Avg' = R1 $st.Average; 'Min' = R1 $st.Minimum; 'Max' = R1 $st.Maximum })
        }
    }
    $metric = { param($name, $stat) $r = $sum | Where-Object { $_['Metric'] -eq $name } | Select-Object -First 1; if ($r) { [double]$r[$stat] } else { 0.0 } }

    # ---- issues ----
    $xeBlocked = @(Get-Rows $It.End 'xe_blocked'); $xeDl = @(Get-Rows $It.End 'xe_deadlocks'); $xeLong = @(Get-Rows $It.End 'xe_long')
    $blockedNow = @($S | ForEach-Object { Get-Rows $_ 'blocked_now' })
    if ($iv.Count -and (& $metric 'PLE s' 'Min') -lt $th.PleMin) { & $addIssue 'WARNING' 'Memory' 'Page Life Expectancy' ("Dropped to {0} s (threshold {1} s)" -f (& $metric 'PLE s' 'Min'), $th.PleMin) }
    if ((& $metric 'Grants pending' 'Max') -gt 0) { & $addIssue 'WARNING' 'Memory' 'Memory Grants Pending' ("Up to {0} queries waiting for memory" -f (& $metric 'Grants pending' 'Max')) }
    if ($waitTot['RESOURCE_SEMAPHORE'] -gt 0) { & $addIssue 'WARNING' 'Memory' 'RESOURCE_SEMAPHORE waits' ("{0:N0} ms waited for query memory" -f $waitTot['RESOURCE_SEMAPHORE']) }
    $dlCount = [math]::Max([math]::Round($deadlocks), $xeDl.Count)
    if ($dlCount -gt 0) { & $addIssue 'WARNING' 'Locking' 'Deadlocks' "$dlCount deadlock(s) in the window" }
    if ((& $metric 'Blocked >5s' 'Max') -gt 0 -or $xeBlocked.Count -gt 0) { & $addIssue 'WARNING' 'Locking' 'Blocking' ("Sessions blocked over {0} s: up to {1} at a time, {2} blocked process report(s), longest {3} s" -f $Config.BlockedProcessThresholdSec, (& $metric 'Blocked >5s' 'Max'), $xeBlocked.Count, (& $metric 'Max block s' 'Max')) }
    if ($timeouts -gt 0) { & $addIssue 'WARNING' 'Locking' 'Lock timeouts' ("{0:N0} lock timeout(s)" -f $timeouts) }
    if ((& $metric 'Data read ms' 'Avg') -gt $th.DataReadMs) { & $addIssue 'WARNING' 'I/O' 'Data file read latency' ("Average {0} ms (threshold {1} ms)" -f (& $metric 'Data read ms' 'Avg'), $th.DataReadMs) }
    if ((& $metric 'Log write ms' 'Avg') -gt $th.LogWriteMs) { & $addIssue 'WARNING' 'I/O' 'Log file write latency' ("Average {0} ms (threshold {1} ms)" -f (& $metric 'Log write ms' 'Avg'), $th.LogWriteMs) }
    if ((& $metric 'TempDB alloc waits' 'Max') -gt 0) { & $addIssue 'WARNING' 'TempDB' 'Allocation contention' ("Up to {0} tasks waiting on tempdb allocation pages (PAGELATCH)" -f (& $metric 'TempDB alloc waits' 'Max')) }
    foreach ($r in @($agRows2 | Where-Object { $_['status'] -eq 'CRITICAL' })) { & $addIssue 'CRITICAL' 'Always On' "$($r['Database']) on $($r['Replica'])" "Not synchronizing during the window (states: $($r['States seen']))" }
    if ((& $metric 'AG send queue MB' 'Max') -gt $th.AgSendQueueMB) { & $addIssue 'WARNING' 'Always On' 'Log send queue' ("Peaked at {0} MB (threshold {1} MB)" -f (& $metric 'AG send queue MB' 'Max'), $th.AgSendQueueMB) }
    if ($xeLong.Count -gt 0) { & $addIssue 'WARNING' 'Queries' "Queries over $($Config.LongQuerySec) s" ("{0} query(ies), longest {1} s" -f $xeLong.Count, (Get-Val $xeLong[0] 'duration_s')) }
    foreach ($note in @($It.Notes)) { & $addIssue 'WARNING' 'Collection' 'Performance window' $note }

    $crit = @($issues | Where-Object { $_.severity -eq 'CRITICAL' }).Count
    $warn = @($issues | Where-Object { $_.severity -eq 'WARNING' }).Count

    # ---- HTML ----
    $t1 = if ($S.Count) { try { (Get-SampleTime $S[0]).ToString('yyyy-MM-dd HH:mm') } catch { '' } } else { '' }
    $t2 = if ($S.Count) { try { (Get-SampleTime $S[$S.Count - 1]).ToString('HH:mm') } catch { '' } } else { '' }
    $cols = { param($rows) if (@($rows).Count) { @(@($rows)[0].Keys) } else { @() } }
    $tbl = { param($title, $rows, $statusCol = '') $r = @($rows); "<h3>$(Enc $title) ($($r.Count))</h3>" + $(if ($r.Count) { [string](ConvertTo-HtmlTable $r (& $cols $r) '' $statusCol) } else { '<div style="color:#2e7d32">None</div>' }) }
    $endTbl = { param($title, $sec) $r = @(Get-Rows $It.End $sec); $c = if ($It.End -and $It.End['columns'].ContainsKey($sec)) { @($It.End['columns'][$sec]) } else { @() }
                "<h3>$(Enc $title) ($($r.Count))</h3>" + $(if ($r.Count -and $c.Count) { [string](ConvertTo-HtmlTable $r $c) } else { '<div style="color:#2e7d32">None</div>' }) }
    $tqInfo = @(Get-Rows $It.End 'topq_info') | Select-Object -First 1
    $qsNote = if (-not $Config.TopQueries) { 'Top queries skipped (TopQueries = $false).' }
              elseif ($tqInfo) { "Top queries = plan cache (sys.dm_exec_query_stats) at the end of the window minus the start, grouped by query_hash ($(Get-Val $tqInfo 'plan_cache_entries') cached statements). Plans evicted or recompiled during the window and OPTION (RECOMPILE) statements are not counted; those over $($Config.LongQuerySec) s are still in the list above." }
              else { 'Top queries not collected.' }

    $short = (@(
        "<h2>Performance window: $t1 - $t2 ($($iv.Count) intervals of $SampleSec s)</h2>"
        & $tbl 'Performance - needs attention' $issues 'severity'
        & $tbl 'Performance summary for the window' $sum
    ) -join '')
    $full = $short + (@(
        & $tbl 'Per interval' $iv
        "<h3>Wait stats per interval - ms waited</h3>" + $(if ($wv.Count) { [string](ConvertTo-HtmlTable $wv (& $cols $wv)) } else { '<div>None</div>' })
        & $tbl 'Transactions/sec per database' $txRows
        & $tbl 'Data / log file latency in the window' $ioRows
        & $tbl 'Connection pool usage (sessions per application / host / login)' $poolRows
        & $tbl 'Always On during the window' $agRows2 'status'
        & $tbl 'Listener connections' $lsnRows
        & $endTbl "Blocked process reports (over $($Config.BlockedProcessThresholdSec) s)" 'xe_blocked'
        & $tbl "Blocked sessions seen in samples (over $($Config.BlockedProcessThresholdSec) s)" @($blockedNow | ForEach-Object { $h = [ordered]@{}; foreach ($c in @('seen_at', 'session_id', 'blocked_by', 'wait_type', 'wait_s', 'db', 'sql_text')) { $h[$c] = $_[$c] }; $h })
        & $endTbl 'Deadlocks' 'xe_deadlocks'
        & $endTbl "Queries over $($Config.LongQuerySec) s" 'xe_long'
        "<div style='color:#555;margin-top:12px'>$(Enc $qsNote)</div>"
        & $endTbl 'Top 20 queries in the window by duration' 'top_duration'
        & $endTbl 'Top 20 queries in the window by CPU' 'top_cpu'
        & $endTbl 'Top 20 queries in the window by logical reads' 'top_reads'
    ) -join '')
    return [pscustomobject]@{ Short = $short; Full = $full; Crit = $crit; Warn = $warn; Intervals = $iv.Count }
}

function Register-HealthTask {
    # Option 5: create / remove a Windows scheduled task that runs the HEALTH check (with performance window) unattended
    Write-Step '=== Schedule the HEALTH check (Windows Task Scheduler) ===' 'Green'
    $prefix = $Config.ScheduledTaskName
    $existing = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like "$prefix*" })
    if ($existing.Count) {
        Write-Step 'Existing scheduled checks:'
        $existing | ForEach-Object { $i = Get-ScheduledTaskInfo -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction SilentlyContinue; [pscustomobject]@{ Task = $_.TaskName; State = $_.State; RunAs = $_.Principal.UserId; NextRun = $i.NextRunTime; LastRun = $i.LastRunTime; LastResult = $i.LastTaskResult } } |
            Format-Table -AutoSize | Out-String | Write-Host
    }
    $ans = (Read-Host 'A = add or replace a schedule, D = delete one, Enter = cancel').Trim().ToUpperInvariant()
    if ($ans -eq 'D') {
        $n = Read-Host 'Task name to delete (as listed above)'
        if ($n) { try { Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction Stop; Write-Step "Deleted $n" 'Green' } catch { Write-Step "Could not delete: $($_.Exception.Message)" 'Red' } }
        return
    }
    if ($ans -ne 'A') { return }

    $label = ((Read-Host 'Label for the report and task name (Enter = SCHEDULED)').Trim() -replace '[^A-Za-z0-9_-]', '')
    if (-not $label) { $label = 'SCHEDULED' }
    do { $freq = (Read-Host 'Run: D = daily, W = weekly on chosen days, O = once').Trim().ToUpperInvariant() } while ($freq -notin @('D', 'W', 'O'))
    do { $time = (Read-Host 'Start time (HH:mm, 24-hour, this VM''s time zone)').Trim() } while ($time -notmatch '^([01]?\d|2[0-3]):[0-5]\d$')
    $at = [datetime]::ParseExact($time.PadLeft(5, '0'), 'HH:mm', $null)
    switch ($freq) {
        'D' { $trigger = New-ScheduledTaskTrigger -Daily -At $at; $when = "daily at $time" }
        'W' {
            do { $daysTxt = Read-Host 'Days (e.g. Mon,Wed,Fri)'; $days = @($daysTxt -split '[,; ]+' | Where-Object { $_ } | ForEach-Object {
                     $d = $_.Substring(0, [math]::Min(3, $_.Length)).ToLower(); @{ mon = 'Monday'; tue = 'Tuesday'; wed = 'Wednesday'; thu = 'Thursday'; fri = 'Friday'; sat = 'Saturday'; sun = 'Sunday' }[$d] } | Where-Object { $_ }) } while (-not $days.Count)
            $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $days -At $at; $when = "every $($days -join ', ') at $time"
        }
        'O' {
            do { $dTxt = (Read-Host 'Date (yyyy-MM-dd)').Trim(); $ok = $dTxt -match '^\d{4}-\d{2}-\d{2}$' } while (-not $ok)
            $trigger = New-ScheduledTaskTrigger -Once -At ([datetime]::ParseExact("$dTxt $($time.PadLeft(5, '0'))", 'yyyy-MM-dd HH:mm', $null)); $when = "once on $dTxt at $time"
        }
    }
    $s = Read-Host "Performance window - sample every N seconds (Enter = $($Config.PerfSampleSec), 0 = no performance window)"
    $s = if ($s -match '^\d+$') { [int]$s } else { [int]$Config.PerfSampleSec }
    $m = 0
    if ($s -gt 0) { $m = Read-Host "Window length in minutes (Enter = $($Config.PerfDurationMin))"; $m = if ($m -match '^\d+$') { [int]$m } else { [int]$Config.PerfDurationMin } }
    $perfArgs = if ($s -gt 0 -and $m -gt 0) { "-SampleSec $s -DurationMin $m" } else { '-NoPerf' }

    $cred = $null
    try { $cred = Get-Credential -Message 'Windows account the task runs as (needs SQL access on every instance). Task Scheduler stores the password.' } catch { }
    if (-not $cred) { Write-Step 'Cancelled - no account entered.' 'Yellow'; return }

    $bat = Join-Path $PSScriptRoot 'Run-PrePostCheck.bat'
    $action = New-ScheduledTaskAction -Execute $bat -Argument "-Phase HEALTH -Unattended -Ticket $label $perfArgs" -WorkingDirectory $PSScriptRoot
    $limitH = [math]::Max(2, [math]::Ceiling(($m + 60) / 60))
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours $limitH)
    $taskName = "$prefix - $label"
    try {
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -User $cred.UserName -Password $cred.GetNetworkCredential().Password `
            -Description "SQL Server HEALTH check for every instance on this VM ($perfArgs). Created by Invoke-PrePostCheck.ps1." -Force -ErrorAction Stop | Out-Null
        Write-Step "Scheduled '$taskName': $when as $($cred.UserName) ($perfArgs)." 'Green'
        Write-Step "Test it now with: Start-ScheduledTask -TaskName '$taskName'  (report emailed and saved in Reports\, log in Logs\)" 'DarkGray'
    }
    catch {
        Write-Step "Could not create the task: $($_.Exception.Message)" 'Red'
        Write-Step '  Run Run-PrePostCheck.bat as administrator, and check the account has "Log on as a batch job" on this VM.' 'Yellow'
    }
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
    if ($Config.FromAddress) { [void]$cmd.Parameters.AddWithValue('@from_address', $Config.FromAddress) }
    if ($Config.ReplyTo)     { [void]$cmd.Parameters.AddWithValue('@reply_to', $Config.ReplyTo) }
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
#  OUTER: prompts + log on as your account (used for SQL connections)
# =============================================================================
if ($Phase -eq 'CLEANUP') {
    Write-Step '=== Cleanup of old Snapshots / Reports / Logs ===' 'Green'
    $h = if ($Config.CleanupHours -gt 0) { $Config.CleanupHours } else { 48 }
    Invoke-Cleanup $h $Config.KeepPreWithoutPostDays
    if (-not $Inner -and -not $Unattended) { Read-Host 'Press Enter to close' }
    exit 0
}
if ($Phase -eq 'SCHEDULE') { Register-HealthTask; Read-Host 'Press Enter to close'; exit 0 }
if (-not $Inner) {
    Write-Step '=== SQL Server PRE / POST change check ===' 'Green'
    while ($Phase -notin @('PRE', 'POST', 'HEALTH')) {
        Write-Host '  1 = PRE      snapshot before a change'
        Write-Host '  2 = POST     compare after the change with PRE'
        Write-Host '  3 = HEALTH   health check report only'
        Write-Host '  4 = CLEANUP  delete old snapshots / reports / logs'
        Write-Host '  5 = SCHEDULE run the HEALTH check from Windows Task Scheduler'
        $Phase = (Read-Host 'Choose 1-5 (or type PRE / POST / HEALTH / CLEANUP / SCHEDULE)').Trim().ToUpperInvariant()
        $Phase = switch ($Phase) { '1' { 'PRE' } '2' { 'POST' } '3' { 'HEALTH' } 'HC' { 'HEALTH' } '4' { 'CLEANUP' } '5' { 'SCHEDULE' } default { $Phase } }
        if ($Phase -eq 'SCHEDULE') { Register-HealthTask; Read-Host 'Press Enter to close'; exit 0 }
        if ($Phase -eq 'CLEANUP') {
            Invoke-Cleanup $(if ($Config.CleanupHours -gt 0) { $Config.CleanupHours } else { 48 }) $Config.KeepPreWithoutPostDays
            Read-Host 'Press Enter to close'; exit 0
        }
    }
    if (-not $Unattended -and -not $PSBoundParameters.ContainsKey('Ticket')) {
        $Ticket = if ($Phase -eq 'HEALTH') { Read-Host 'Ticket / label (optional, Enter = DAILY)' }
                  else { Read-Host 'Change ticket (used to pair PRE and POST, e.g. CHG0012345)' }
    }
    $Ticket = ([string]$Ticket).Trim() -replace '[^A-Za-z0-9_-]', ''
    if (-not $Ticket) { $Ticket = if ($Phase -eq 'HEALTH') { 'DAILY' } else { 'NO-TICKET' } }
    if ($Phase -eq 'HEALTH' -and $Config.PerfSampling -and -not $NoPerf -and -not $Unattended -and $DurationMin -lt 0 -and $SampleSec -le 0) {
        $ans = Read-Host "Performance window - Enter = every $($Config.PerfSampleSec) s for $($Config.PerfDurationMin) min, 0 = skip, or <seconds>/<minutes> e.g. 30/15"
        if ($ans.Trim() -eq '0') { $NoPerf = $true }
        elseif ($ans -match '^\s*(\d+)\s*/\s*(\d+)\s*$') { $SampleSec = [int]$Matches[1]; $DurationMin = [int]$Matches[2] }
    }

    $rdpUser = "$env:USERDOMAIN\$env:USERNAME"
    $cred = $null
    if (-not $UseCurrentUser) {
        # FIRST PRIORITY: your own Windows account (same as SSMS "Run as different user")
        while (-not $cred) {
            try   { $cred = Get-Credential -Message "Enter YOUR Windows account (DOMAIN\user) that has access to SQL Server - same as SSMS 'Run as different user'." }
            catch { $cred = $null }
            if (-not $cred) {
                $ans = Read-Host "No credentials entered. R = retry, C = continue as $rdpUser only"
                if ($ans -notmatch '^[Rr]') { break }
            }
        }
    }
    if ($cred) {
        $launched = $false
        Grant-FolderAccess @($rdpUser, $cred.UserName)
        if (-not (Test-Path $Config.LogsFolder)) { try { New-Item -ItemType Directory -Path $Config.LogsFolder -Force | Out-Null } catch { } }
        $handOffFile = Join-Path $Config.LogsFolder ("handoff_{0}_{1}.json" -f (Get-Date -Format 'yyyyMMddHHmmss'), $PID)
        if (Start-SecondaryLogonService) {
            $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Inner', '-Phase', $Phase, '-Ticket', $Ticket, '-HandOff', "`"$handOffFile`"")
            if ($SqlFile)   { $argList += @('-SqlFile', "`"$((Resolve-Path $SqlFile).Path)`"") }
            if ($Instances) { $argList += @('-Instances', ($Instances -join ',')) }
            if ($NoPerf)           { $argList += '-NoPerf' }
            if ($SampleSec -gt 0)  { $argList += @('-SampleSec', $SampleSec) }
            if ($DurationMin -ge 0) { $argList += @('-DurationMin', $DurationMin) }
            Write-Step "Starting the check as $($cred.UserName) in a new window..." 'Green'
            try {
                Start-Process -FilePath "$PSHOME\powershell.exe" -Credential $cred -ArgumentList $argList -WorkingDirectory $PSScriptRoot -Wait -ErrorAction Stop
                $launched = $true
            }
            catch {
                Write-Step "Could not start as $($cred.UserName): $($_.Exception.Message)" 'Red'
                Write-Step '  (wrong password / locked account, no "log on locally" right, or the account cannot read this folder)' 'DarkGray'
            }
        }
        if ($launched) {
            $ho = $null
            if (Test-Path -LiteralPath $handOffFile) {
                try { $ho = $Json.DeserializeObject([System.IO.File]::ReadAllText($handOffFile)) } catch { }
                Remove-Item -LiteralPath $handOffFile -Force -ErrorAction SilentlyContinue
            }
            if ($ho -and $ho['status'] -eq 'done') { exit 0 }
            if ($ho -and $ho['status'] -eq 'retry') {
                # FAIL-SAFE: re-check only the instances your account could not use, as the RDP user
                $script:HandOffRows = @($ho['rows'] | ForEach-Object { New-Object psobject -Property $_ })
                $script:HandOffMail = @($ho['mail'] | ForEach-Object { New-Object psobject -Property $_ })
                $script:RetryErrors = @{}
                foreach ($r in $ho['retry']) { $script:RetryErrors[[string]$r['Instance']] = [string]$r['Error'] }
                $script:KeyedUser = [string]$ho['user']
                Write-Step "`n$($script:KeyedUser) could not check $($script:RetryErrors.Count) instance(s) - retrying them as $rdpUser (fail-safe):" 'Yellow'
                $script:RetryErrors.Keys | ForEach-Object { Write-Step "  $_" 'Yellow' }
                [void](Connect-AsUser $cred)      # lets the email still be sent as your account
            }
            else {
                $ans = Read-Host "The check as $($cred.UserName) ended without a result. Run it from this window instead ($($cred.UserName) first, then $rdpUser)? (Y/N)"
                if ($ans -notmatch '^[Yy]') { exit 1 }
                [void](Connect-AsUser $cred)
            }
        }
        else {
            # FAIL-SAFE: run-as not possible - use your account from this window, then the RDP user per instance
            Write-Step "Fail-safe: using $($cred.UserName) from this window (no new window), $rdpUser for instances it can't use." 'Yellow'
            if (-not (Connect-AsUser $cred)) {
                $ans = Read-Host "Continue with $rdpUser only? (Y/N)"
                if ($ans -notmatch '^[Yy]') { exit 1 }
            }
        }
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
        if ($key -eq 'SnapshotRoot' -and -not $script:RetryErrors) { Write-Step "ERROR: no write access to $($Config[$key]). Snapshots must be stored there - fix folder permissions." 'Red'; if (-not $Unattended) { Read-Host 'Press Enter to close' }; exit 1 }
        $fallback = Join-Path $env:TEMP ('DBA_PrePostCheck\' + (Split-Path $Config[$key] -Leaf))
        New-Item -ItemType Directory -Path $fallback -Force | Out-Null
        Write-Warning "No write access to $($Config[$key]) - using $fallback"; $Config[$key] = $fallback
    }
}
$logFile = Join-Path $Config.LogsFolder "PrePostCheck_${Phase}_${Ticket}_$stamp.log"
try { Start-Transcript -Path $logFile -Append | Out-Null } catch { }
if (-not $script:RetryErrors) { try { Invoke-Cleanup } catch { Write-Step "Cleanup skipped: $($_.Exception.Message)" 'DarkGray' } }

$summary = @()
if ($script:HandOffRows) { $summary = @($script:HandOffRows) }
$handedOff = $false
$combinedFile = $null
$mailStatus = 'Not sent'
try {
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    Write-Step "Running as : $me"
    Write-Step "Phase      : $Phase    Ticket: $Ticket"
    $sqlBlocks = Get-SqlBlocks ([System.IO.File]::ReadAllText((Get-SqlFilePath)))
    $sqlText = $sqlBlocks['HC']
    $targets = Get-TargetInstances
    if (-not $targets) { throw 'No SQL Server instances found on this VM and servers.txt is empty.' }
    if ($script:RetryErrors) { $targets = @($targets | Where-Object { $script:RetryErrors.ContainsKey([string]$_.Instance) }) }
    $targets | Format-Table Instance, Service, Status -AutoSize | Out-String | Write-Host
    $ticketDir = Join-Path $Config.SnapshotRoot $Ticket
    if ($Phase -ne 'HEALTH' -and -not (Test-Path $ticketDir)) { New-Item -ItemType Directory -Path $ticketDir -Force | Out-Null }
    if ($Phase -eq 'HEALTH') { $Config.ReportTitle = $Config.HealthReportTitle }

    # Machine-level SSIS / SSRS / SSAS data (services + SSAS databases), added to every LOCAL instance's snapshot
    $machineBi = $null
    if (@($targets | Where-Object { $_.Service }).Count -gt 0) {
        try {
            Write-Step 'Collecting SSIS / SSRS / SSAS service and SSAS database info...'
            $ctx = $null
            try { if ($script:ImpIdentity -and -not $script:RetryErrors) { $ctx = $script:ImpIdentity.Impersonate() }; $machineBi = Get-MachineBiSnapshot }
            finally { if ($ctx) { $ctx.Undo() } }
        }
        catch { Write-Step "WARNING: SSIS/SSRS/SSAS collection failed: $($_.Exception.Message)" 'Yellow' }
    }

    $diffCols  = @('Section', 'Item', 'Attribute', 'Before', 'After', 'Note')
    $issueCols = @('severity', 'area', 'item', 'detail')
    $mailCandidates = @()      # instances with a usable Database Mail profile (local ones first)
    if ($script:HandOffMail) { $mailCandidates = @($script:HandOffMail) }

    foreach ($t in $targets) {
        $row = [ordered]@{ Instance = $t.Instance; ConnectedAs = ''; Outcome = ''; State = ''; Unexpected = ''; NewProblems = ''; Expected = ''; Baseline = ''; ShortHtml = ''; FullHtml = '' }
        Write-Step "`n--- $($t.Instance) ---" 'Green'
        if ($t.Status -notin @('Running', 'Listed')) {
            $row.Outcome = "SKIPPED - service $($t.Service) is $($t.Status)"; $row.State = 'FAILED'
            $row.ShortHtml = "<h1>$(Enc $t.Instance)</h1><div class='banner' style='background:#f8d7da'>$(Enc $row.Outcome)</div>"
            $row.FullHtml = $row.ShortHtml
            Write-Step $row.Outcome 'Red'; $summary += [pscustomobject]$row; continue
        }
        $conn = $null; $stage = 'connect'
        try {
            $oc = Open-SqlConnection $t.Instance -RequirePerms:([bool]$HandOff) -NoImpersonation:([bool]$script:RetryErrors)
            $conn = $oc.Connection; $row.ConnectedAs = $oc.As; $stage = 'collect'
            Write-Step "Connected as   : $($oc.As)"
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
                meta     = @{ instance = $t.Instance; phase = $Phase; ticket = $Ticket; taken_at = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); taken_by = $row.ConnectedAs; machine = $env:COMPUTERNAME
                              build = (Get-Val (@(Get-Rows $data 'instance') | Where-Object { (Get-Val $_ 'property_code') -eq 'build' } | Select-Object -First 1) 'value') }
                sections = $data.sections
                columns  = $data.columns
            }
            $safe = Get-SafeFileName $t.Instance
            $snapFile = Join-Path $ticketDir ("{0}_{1}_{2}.json" -f $safe, $Phase, $stamp)
            if ($Phase -ne 'HEALTH') {
                $jsonText = ConvertTo-Json -InputObject (ConvertTo-PlainObject $snap) -Depth 20 -Compress
                try { [System.IO.File]::WriteAllText($snapFile, $jsonText, [System.Text.Encoding]::UTF8); Write-Step "Snapshot saved : $snapFile" }
                catch {
                    # Don't lose the check: save to this account's TEMP folder and say so in the report
                    $tmpDir = Join-Path $env:TEMP ("DBA_PrePostCheck\Snapshots\" + $Ticket)
                    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
                    $snapFile2 = Join-Path $tmpDir (Split-Path $snapFile -Leaf)
                    [System.IO.File]::WriteAllText($snapFile2, $jsonText, [System.Text.Encoding]::UTF8)
                    Write-Step "WARNING: no write access to $ticketDir as $($row.ConnectedAs) - snapshot saved to $snapFile2 instead. Copy it into $ticketDir before the POST run." 'Yellow'
                    $snapFile = "$snapFile2 (NOT in $ticketDir - copy it there before POST)"
                }
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
                        $ans = if ($Unattended) { 'N' } else { Read-Host ("Latest PRE is ticket {0}, taken {1} by {2}. Use it as the baseline? (Y/N)" -f $cm['ticket'], $cm['taken_at'], $cm['taken_by']) }
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
            if ($HandOff -and $stage -eq 'connect') { $row.State = 'RETRY'; $row.Outcome = $_.Exception.Message }
            if ($script:RetryErrors -and $stage -eq 'connect') { $row.Outcome = "FAILED: $($script:KeyedUser): $($script:RetryErrors[[string]$t.Instance]) | $($me): $($_.Exception.Message)" }
            $row.ShortHtml = "<h1>$(Enc $t.Instance)</h1><div class='banner' style='background:#f8d7da'>$(Enc $row.Outcome)</div>"
            $row.FullHtml = $row.ShortHtml
            if ($row.State -eq 'RETRY') { Write-Step "$($row.Outcome) -> will be retried as the RDP user" 'Yellow' } else { Write-Step $row.Outcome 'Red' }
            if ($row.State -ne 'RETRY' -and $_.Exception.Message -match 'Login failed') { Write-Step "  -> $me has no login on $($t.Instance). Use the account you use for SSMS." 'Yellow' }
        }
        finally { if ($conn) { $conn.Dispose() } }
        $summary += [pscustomobject]$row
    }

    # ---- HEALTH: performance window on every instance that was checked -------------------
    $perfSec = if ($SampleSec -gt 0) { $SampleSec } else { [int]$Config.PerfSampleSec }
    $perfMin = if ($DurationMin -ge 0) { $DurationMin } else { [int]$Config.PerfDurationMin }
    if ($Phase -eq 'HEALTH' -and $Config.PerfSampling -and -not $NoPerf -and $perfMin -gt 0 -and $perfSec -gt 0 -and $sqlBlocks.ContainsKey('PERF_SAMPLE')) {
        $perfItems = @()
        foreach ($r in @($summary | Where-Object { $_.State -in @('OK', 'WARN', 'CRIT') -and -not ($script:HandOffRows -and $script:HandOffRows -contains $_) })) {
            try {
                $oc = Open-SqlConnection $r.Instance -NoImpersonation:([bool]$script:RetryErrors)
                $perfItems += [pscustomobject]@{ Instance = $r.Instance; Conn = $oc.Connection; Safe = (Get-SafeFileName $r.Instance); Row = $r }
            }
            catch { Write-Step "Performance window skipped on $($r.Instance): $($_.Exception.Message)" 'Yellow' }
        }
        if ($perfItems.Count) {
            Write-Step "`n--- Performance window on $($perfItems.Count) instance(s) ---" 'Green'
            try { Invoke-PerfWindow $perfItems $sqlBlocks $perfSec $perfMin }
            finally {
                foreach ($pi in $perfItems) {
                    try {
                        $pr = Get-PerfResult $pi $perfSec
                        $pi.Row.ShortHtml += $pr.Short; $pi.Row.FullHtml += $pr.Full
                        if ($pr.Crit -gt 0) { $pi.Row.State = 'CRIT' } elseif ($pr.Warn -gt 0 -and $pi.Row.State -eq 'OK') { $pi.Row.State = 'WARN' }
                        $pi.Row.Outcome += "; performance: $($pr.Crit) critical, $($pr.Warn) warning(s)"
                        Write-Step ("{0}: performance window {1} intervals - {2} critical, {3} warning(s)" -f $pi.Instance, $pr.Intervals, $pr.Crit, $pr.Warn) $(if ($pr.Crit) { 'Red' } elseif ($pr.Warn) { 'Yellow' } else { 'Green' })
                    }
                    catch { Write-Step "Performance report failed for $($pi.Instance): $($_.Exception.Message)" 'Yellow' }
                    finally { $pi.Conn.Dispose() }
                }
            }
        }
    }

    # Run as your account (new window) and some instances failed: hand them to the original window
    $retryRows = @($summary | Where-Object { $_.State -eq 'RETRY' })
    if ($HandOff -and $retryRows.Count -gt 0) {
        $plain = { param($o) $h = @{}; foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = if ($p.Value -is [bool]) { $p.Value } else { [string]$p.Value } }; $h }
        $payload = @{
            status = 'retry'; user = $me
            rows   = @($summary | Where-Object { $_.State -ne 'RETRY' } | ForEach-Object { & $plain $_ })
            retry  = @($retryRows | ForEach-Object { @{ Instance = [string]$_.Instance; Error = [string]$_.Outcome } })
            mail   = @($mailCandidates | ForEach-Object { & $plain $_ })
        }
        [System.IO.File]::WriteAllText($HandOff, (ConvertTo-Json -InputObject $payload -Depth 6 -Compress), [System.Text.Encoding]::UTF8)
        $handedOff = $true
        $summary = @($summary | Where-Object { $_.State -ne 'RETRY' })
        Write-Step "`n$($retryRows.Count) instance(s) could not be checked as $me - the original window retries them as the RDP user and sends the combined report." 'Yellow'
    }

    if (-not $handedOff) {
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

    $summaryCols = if ($Phase -in @('PRE', 'HEALTH')) { @('Instance', 'ConnectedAs', 'Outcome') } else { @('Instance', 'ConnectedAs', 'Outcome', 'Unexpected', 'NewProblems', 'Expected', 'Baseline') }
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
            $c = (Open-SqlConnection $sender.Instance).Connection
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
    }   # end if (-not $handedOff)
}
catch { Write-Step ('ERROR: ' + $_.Exception.Message) 'Red' }
finally {
    if ($HandOff -and -not $handedOff) {
        try { [System.IO.File]::WriteAllText($HandOff, '{"status":"done"}') } catch { }
    }
    if ($handedOff) {
        Write-Step 'Handing over to the original window...' 'Yellow'
        try { Stop-Transcript | Out-Null } catch { }
        Start-Sleep -Seconds 3
    }
    else {
    Write-Step "`n=== SUMMARY ($Phase / $Ticket) ===" 'Green'
    if ($summary) { $summary | Format-Table Instance, ConnectedAs, Outcome, Unexpected, NewProblems, Expected, Baseline -AutoSize -Wrap | Out-String -Width 250 | Write-Host }
    Write-Step "Email     : $mailStatus"
    Write-Step "Snapshots : $(Join-Path $Config.SnapshotRoot $Ticket)"
    Write-Step "Reports   : $($Config.ReportsFolder)"
    Write-Step "Report    : $combinedFile"
    # No email sent: open the combined report in the browser
    if (-not $Unattended -and $combinedFile -and ($mailStatus -notlike 'Queued*') -and (Test-Path -LiteralPath $combinedFile)) {
        Write-Step 'Opening the combined report...' 'Yellow'
        try { Invoke-Item -LiteralPath $combinedFile } catch { Write-Step "Could not open it: $($_.Exception.Message)" 'Yellow' }
    }
    Write-Step "Log       : $logFile"
    try { Stop-Transcript | Out-Null } catch { }
    if (-not $Unattended) { Read-Host "`nPress Enter to close" }
    }
}
