<#
.SYNOPSIS
    SQL Server health check + performance window for every instance on this VM: a health check
    (incl. SSIS / SSRS / SSAS), then samples every N seconds for M minutes, then emails one
    combined report (Database Mail) and saves it in Reports\.

.DESCRIPTION
    Double-click Run-PerfCheck.bat. No menu.
    Health check (once, at the start): instance & build, SQL / Windows uptime, services, vitals,
      databases (state, recovery, backups, CHECKDB, log use, AG role), Always On replicas /
      listeners (IP, DHCP) / databases, cluster & quorum, disks, failed job steps (24 h), severe
      error log entries, sp_configure, trace flags, linked servers, endpoints, certificates,
      XE sessions, SSIS catalog / projects / environments / failures, SSRS content /
      subscriptions, and for this VM the SSIS / SSRS / SSAS services and SSAS databases.
      Not included: data/log file list, Agent job list, logins, server role members.
    Performance window, per instance:
      Throughput   Batch Requests/sec, Transactions/sec (PerfDatabases, e.g. MARS and CLR)
      Compilation  SQL Compilations/sec, SQL Re-Compilations/sec
      Connections  User Connections, connection pool usage (sessions per app / host / login)
      Locking      Lock Waits/sec, Lock Wait Time, Lock Timeouts/sec, Deadlocks/sec, blocked
                   processes (blocked process threshold 5 s + XE blocked process reports)
      Memory       Page Life Expectancy, Buffer cache hit ratio, Memory Grants Pending,
                   Target vs Total Server Memory
      Wait stats   per interval: LCK_M_*, PAGEIOLATCH_*, PAGELATCH_*, WRITELOG, CXPACKET,
                   CXCONSUMER, SOS_SCHEDULER_YIELD, HADR_SYNC_COMMIT, RESOURCE_SEMAPHORE
      Queries      top 20 by duration / CPU / logical reads in the window (plan cache, start vs
                   end - no Query Store needed) and every query longer than LongQuerySec (XE)
      I/O          data / log file read and write latency, Log Flush Wait Time, Log Bytes Flushed/sec
      TempDB       space used, version store size, allocation contention
      Always On    synchronization state, log send queue, redo queue, transaction delay,
                   listener connections
      Root cause   SPID, login, host, program, database, wait, statement for: blocked sessions,
                   head blockers (incl. idle sessions with an open transaction), I/O / log /
                   memory-grant / tempdb waits, long-running requests, big or waiting memory
                   grants, top tempdb users; every deadlock process + the graph as .xdl files

    Login: a dedicated SQL login (default dba_perfcheck, created once with the SETUP block at
    the top of PerfCheck.sql). The first run asks for its password and can save it on this VM
    (encrypted with Windows DPAPI, machine scope - only usable on this VM) so later runs and the
    scheduled task need no prompt. Fail-safe: if the SQL login can't connect to an instance
    (mixed mode off, login missing, wrong password, no VIEW SERVER STATE) that instance is
    checked with Windows authentication as the account running the script.

    Server changes during the window, always put back: 'blocked process threshold (s)' and the
    XE session DBA_PerfWindow (needs ALTER SETTINGS / ALTER ANY EVENT SESSION, else read-only).

    -NoPerf runs the health check only.
    Only 3 files: Run-PerfCheck.bat, Invoke-PerfCheck.ps1, PerfCheck.sql.

.EXAMPLE
    .\Invoke-PerfCheck.ps1                                   # $Config interval / length
.EXAMPLE
    .\Invoke-PerfCheck.ps1 -SampleSec 30 -DurationMin 15 -Label LOADTEST1
.EXAMPLE
    .\Invoke-PerfCheck.ps1 -Unattended -Label SCHEDULED      # Task Scheduler (no prompts, no pauses)
.EXAMPLE
    .\Invoke-PerfCheck.ps1 -ResetCredential                  # re-enter / re-save the SQL login password
#>
[CmdletBinding()]
param(
    [int]      $SampleSec = 0,        # seconds between samples (0 = $Config.SampleSec)
    [int]      $DurationMin = 0,      # window length in minutes (0 = $Config.DurationMin)
    [string]   $Label = '',           # shown in the subject and file name (default PERF)
    [string[]] $Instances,            # only these instances, e.g. 'SQLVM1','SQLVM1\INST2'
    [switch]   $Unattended,           # no prompts, no pauses (Task Scheduler)
    [switch]   $ResetCredential,      # forget the saved SQL login and ask again
    [switch]   $WindowsAuth,          # skip the SQL login, use Windows authentication only
    [switch]   $NoPerf,               # health check only (no performance window)
    [switch]   $NoHealth,             # performance window only (no health check)
    [string]   $SqlFile
)

# =============================================================================
#  CONFIGURATION  <== change these once
# =============================================================================
$Config = @{
    Recipients            = 'dba-team@yourcompany.com'   # ; separated
    CopyRecipients        = ''
    FromAddress           = ''                           # optional, e.g. 'SQL Perf <sqlperf@yourcompany.com>' ('' = profile's account)
    ReplyTo               = ''
    MailProfile           = 'DBA_Mail'                   # preferred; else default / only profile on the instance
    ReportTitle           = 'SQL Server Health & Performance Check'

    SqlLogin              = 'dba_perfcheck'              # dedicated SQL login (see SETUP in PerfCheck.sql)
    CredentialFile        = Join-Path $PSScriptRoot 'PerfCheck.cred'   # saved, DPAPI-encrypted password (this VM only)
    CredentialReaders     = @()      # extra Windows accounts allowed to read the saved login, e.g. the scheduled task's account @('DOMAIN\svc_sqltask')

    SampleSec             = 60       # seconds between samples
    DurationMin           = 30       # length of the window in minutes
    PerfDatabases         = @()      # databases for 'Trans/s', e.g. @('MARS', 'CLR'); @() = all databases
    BlockedProcessThresholdSec = 5   # 'blocked process threshold' during the window (restored after)
    LongQuerySec          = 5        # capture every query running longer than this (XE)
    TopQueries            = $true    # top 20 queries of the window from the plan cache; $false = skip
    BigGrantMB            = 1024     # list memory grants of at least this size (MB); waiting grants are always listed
    TempdbSessionMB       = 500      # list sessions using at least this much tempdb (MB)
    PerfThresholds        = @{ PleMin = 300; DataReadMs = 20; LogWriteMs = 10; AgSendQueueMB = 100 }

    IncludeLocalInstances = $true
    ExtraInstances        = @()      # other instances, e.g. @('SQLVM2', 'SQLVM3\INST2')
    ServersFile           = Join-Path $PSScriptRoot 'servers.txt'   # optional, one instance per line
    ReportsFolder         = Join-Path $PSScriptRoot 'Reports'
    LogsFolder            = Join-Path $PSScriptRoot 'Logs'
    CleanupHours          = 168      # delete reports / logs older than this (0 = keep everything)
    ConnectTimeoutSec     = 15
    QueryTimeoutSec       = 600
    Encrypt               = $false
    MailCheckDelaySec     = 20
    AttachReport          = $true    # attach the full report (falls back to the email body)
    # ---- Fallback when no instance can send through Database Mail (or it reports 'failed') ----
    SmtpServer            = ''       # e.g. 'smtp.yourcompany.com' - sends directly from this VM with .NET; '' = no fallback
    SmtpPort              = 25
    SmtpFrom              = ''       # '' = FromAddress, else sqlperfcheck@<VM name>
    SmtpUseSsl            = $false
    SmtpUseDefaultCredentials = $false   # $true = authenticate as the Windows account running the script
}

$ErrorActionPreference = 'Stop'
if ($Instances) { $Instances = @($Instances -split ',' | ForEach-Object { $_.Trim(" '`"") } | Where-Object { $_ }) }
if (-not $Label) { $Label = if ($Unattended) { 'SCHEDULED' } else { 'PERF' } }
$Label = $Label -replace '[^A-Za-z0-9_-]', ''

# =============================================================================
#  HELPERS
# =============================================================================
function Write-Step([string]$Text, [string]$Color = 'Cyan') { Write-Host $Text -ForegroundColor $Color }

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
WHERE EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profileaccount AS pa WHERE pa.profile_id = p.profile_id)      -- has an SMTP account
  AND (   IS_SRVROLEMEMBER(N'sysadmin') = 1                                                                   -- usable by this login
       OR EXISTS (SELECT 1 FROM msdb.dbo.sysmail_principalprofile AS x
                  WHERE x.profile_id = p.profile_id AND (x.principal_sid = 0x00 OR x.principal_sid = SUSER_SID())))
ORDER BY CASE WHEN p.name = @pref THEN 0 WHEN pp.profile_id IS NOT NULL THEN 1 ELSE 2 END, p.profile_id;
"@
    $r = Invoke-Scalar $Connection $q @{ '@pref' = $Config.MailProfile }
    if ($null -eq $r -or $r -is [DBNull]) { return $null }
    return [string]$r
}

function Invoke-SqlSections($Connection, [string]$SqlText) {
    # Runs a batch; returns @{ sections = @{ name = ArrayList of hashtables }; columns = @{ name = string[] } }
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

function Get-SqlBlocks([string]$Text) {
    # PerfCheck.sql: header, then --##PERF_* blocks run separately
    $blocks = @{}; $name = 'HC'; $sb = New-Object System.Text.StringBuilder
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*GO\s*$') { continue }      # SSMS batch separator
        if ($line -match '^--##(HEALTH|PERF_\w+)\s*$') { $blocks[$name] = $sb.ToString(); $name = $Matches[1]; $sb = New-Object System.Text.StringBuilder; continue }
        [void]$sb.AppendLine($line)
    }
    $blocks[$name] = $sb.ToString()
    return $blocks
}

function Set-SqlParams([string]$Sql, [hashtable]$Params) {
    # Sets the default of each "DECLARE @p_Name type = value;" line at the top of a PerfCheck.sql block
    foreach ($k in $Params.Keys) {
        $v = $Params[$k]
        $lit = if ($null -eq $v) { 'NULL' } elseif ($v -is [string]) { "N'" + $v.Replace("'", "''") + "'" } else { [string]$v }
        $Sql = [regex]::Replace($Sql, '(?m)^(\s*DECLARE\s+@' + [regex]::Escape($k) + '\s+[\w\(\)]+\s*=\s*)[^;]*;', { param($m) $m.Groups[1].Value + $lit + ';' }.GetNewClosure())
    }
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
    $tok = @{ p_BptSec = [int]$Config.BlockedProcessThresholdSec; p_LongUs = [int64]$Config.LongQuerySec * 1000000; p_TopQ = $(if ($Config.TopQueries) { 1 } else { 0 })
              p_LongSec = [int]$Config.LongQuerySec; p_BigGrantMB = [int]$Config.BigGrantMB; p_TempdbMB = [int]$Config.TempdbSessionMB }
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
                try { [void](Invoke-SqlSections $it.Conn (Set-SqlParams $Blocks['PERF_TEARDOWN'] @{ p_Restore = 1; p_Orig = [int]$old })); Write-Step "  $($it.Instance): restored blocked process threshold ($old) left by an interrupted run" 'Yellow' } catch { }
            }
            Remove-Item -LiteralPath $it.RestoreFile -Force -ErrorAction SilentlyContinue
        }
        try {
            $r = Invoke-SqlSections $it.Conn (Set-SqlParams $Blocks['PERF_START'] $tok)
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
                try { [void]$it.Samples.Add((Invoke-SqlSections $it.Conn (Set-SqlParams $Blocks['PERF_SAMPLE'] $tok))) }
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
            try { $it.End = Invoke-SqlSections $it.Conn (Set-SqlParams $Blocks['PERF_END'] @{ p_Start = [string]$it.StartTime; p_TopQ = $tok.p_TopQ }) }
            catch { [void]$it.Notes.Add("Blocked process / deadlock / top query collection failed: $($_.Exception.Message)") }
        }
    }
    finally {
        # Always put the server back: drop the XE session, restore the original threshold
        foreach ($it in $Items) {
            $restore = if ($it.Setup -and $it.Setup['threshold_set'] -eq '1') { 1 } else { 0 }
            $orig = if ($it.Setup) { $it.Setup['orig_threshold'] } else { '0' }
            try {
                $td = @(Get-Rows (Invoke-SqlSections $it.Conn (Set-SqlParams $Blocks['PERF_TEARDOWN'] @{ p_Restore = [int]$restore; p_Orig = [int]$orig })) 'perf_teardown') | Select-Object -First 1
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

function Merge-SampleRows($Samples, [string]$Section, [string[]]$KeyCols, [string[]]$MaxCols) {
    # The same session / statement shows up in many samples: one row each, first / last seen, peaks
    $map = [ordered]@{}; $cols = $null
    foreach ($snap in @($Samples)) {
        if (-not $cols -and $snap -and $snap['columns'] -and $snap['columns'].ContainsKey($Section)) { $cols = @($snap['columns'][$Section]) }
        foreach ($r in @(Get-Rows $snap $Section)) {
            $key = ($KeyCols | ForEach-Object { Get-Val $r $_ }) -join '|'
            if (-not $map.Contains($key)) {
                $o = [ordered]@{ 'first_seen' = (Get-Val $r 'seen_at'); 'last_seen' = (Get-Val $r 'seen_at'); 'samples' = 0 }
                $map[$key] = $o
            }
            $o = $map[$key]; $o['last_seen'] = Get-Val $r 'seen_at'; $o['samples'] = [int]$o['samples'] + 1
            foreach ($c in @($cols | Where-Object { $_ -ne 'seen_at' })) {
                $v = Get-Val $r $c
                if ($MaxCols -contains $c -and $o.Contains($c)) { if ((ConvertTo-Num $v) -gt (ConvertTo-Num $o[$c])) { $o[$c] = $v } }
                else { $o[$c] = $v }
            }
        }
    }
    $out = New-Object System.Collections.ArrayList
    foreach ($v in $map.Values) { [void]$out.Add($v) }
    return ,$out
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
    $probRows  = Merge-SampleRows $S 'problem_sessions' @('session_id', 'reason', 'statement') @('wait_ms', 'elapsed_s', 'cpu_ms', 'logical_reads', 'writes', 'granted_mb', 'tempdb_mb')
    $headRows  = Merge-SampleRows $S 'head_blockers' @('session_id', 'statement') @('blocked_sessions', 'max_blocked_s')
    $grantRows = Merge-SampleRows $S 'memory_grants' @('session_id', 'statement') @('requested_mb', 'granted_mb', 'used_mb', 'wait_ms')
    $tdbRows   = Merge-SampleRows $S 'tempdb_sessions' @('session_id', 'statement') @('user_objects_mb', 'internal_objects_mb')
    $dlProcs   = @(Get-Rows $It.End 'xe_deadlock_procs')
    # every deadlock graph as a .xdl file (double-click opens the diagram in SSMS)
    $xdlFiles = @(); $n = 0
    foreach ($d in @(Get-Rows $It.End 'xe_deadlock_xml')) {
        $n++
        $f = Join-Path $Config.ReportsFolder ("{0}_deadlock_{1}_{2:D2}.xdl" -f $It.Safe, ((Get-Val $d 'event_time') -replace '[-: ]', ''), $n)
        try { [System.IO.File]::WriteAllText($f, [string]$d['deadlock_xml'], [System.Text.Encoding]::UTF8); $xdlFiles += $f } catch { }
    }
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
    foreach ($h in @($headRows | Where-Object { $_['statement_source'] -like 'last statement*' -and (ConvertTo-Num $_['open_tran']) -gt 0 })) {
        & $addIssue 'WARNING' 'Locking' "Idle session $($h['session_id']) holding locks" ("{0} on {1} ({2}) left a transaction open and blocked {3} session(s) for up to {4} s - last statement: {5}" -f $h['login'], $h['host'], $h['program'], $h['blocked_sessions'], $h['max_blocked_s'], $h['statement']) }
    $waitingGrants = @($grantRows | Where-Object { $_['grant_state'] -eq 'WAITING' })
    if ($waitingGrants.Count) { & $addIssue 'WARNING' 'Memory' 'Queries waiting for memory' ("{0} query(ies) waited for a memory grant - see 'Memory grants'" -f $waitingGrants.Count) }
    if ($xeLong.Count -gt 0) { & $addIssue 'WARNING' 'Queries' "Queries over $($Config.LongQuerySec) s" ("{0} query(ies), longest {1} s" -f $xeLong.Count, (Get-Val $xeLong[0] 'duration_s')) }
    foreach ($note in @($It.Notes)) { & $addIssue 'WARNING' 'Collection' 'Performance window' $note }

    $crit = @($issues | Where-Object { $_.severity -eq 'CRITICAL' }).Count
    $warn = @($issues | Where-Object { $_.severity -eq 'WARNING' }).Count

    # ---- HTML ----
    $t1 = if ($S.Count) { try { (Get-SampleTime $S[0]).ToString('yyyy-MM-dd HH:mm') } catch { '' } } else { '' }
    $t2 = if ($S.Count) { try { (Get-SampleTime $S[$S.Count - 1]).ToString('HH:mm') } catch { '' } } else { '' }
    $cols = { param($rows) if (@($rows).Count) { @(@($rows)[0].Keys) } else { @() } }
    $tbl = { param($title, $rows, $statusCol = '') $r = @($rows | Where-Object { $null -ne $_ }); "<h3>$(Enc $title) ($($r.Count))</h3>" + $(if ($r.Count) { [string](ConvertTo-HtmlTable $r (& $cols $r) '' $statusCol) } else { '<div style="color:#2e7d32">None</div>' }) }
    $endTbl = { param($title, $sec) $r = @(Get-Rows $It.End $sec); $c = if ($It.End -and $It.End['columns'].ContainsKey($sec)) { @($It.End['columns'][$sec]) } else { @() }
                "<h3>$(Enc $title) ($($r.Count))</h3>" + $(if ($r.Count -and $c.Count) { [string](ConvertTo-HtmlTable $r $c) } else { '<div style="color:#2e7d32">None</div>' }) }
    $tqInfo = @(Get-Rows $It.End 'topq_info') | Select-Object -First 1
    $qsNote = if (-not $Config.TopQueries) { 'Top queries skipped (TopQueries = $false).' }
              elseif ($tqInfo) { "Top queries = plan cache (sys.dm_exec_query_stats) at the end of the window minus the start, grouped by query_hash ($(Get-Val $tqInfo 'plan_cache_entries') cached statements). Plans evicted or recompiled during the window and OPTION (RECOMPILE) statements are not counted; those over $($Config.LongQuerySec) s are still in the list above." }
              else { 'Top queries not collected.' }

    $short = (@(
        "<h2>Performance window: $t1 - $t2 ($($iv.Count) intervals of $SampleSec s)</h2>"
        & $tbl 'Performance - needs attention' $issues 'severity'
        $(if (@($headRows).Count) { & $tbl 'Head blockers' $headRows })
        $(if (@($probRows).Count) { & $tbl 'Problem sessions (top 10 by elapsed time - all in the attachment)' (@($probRows | Sort-Object { ConvertTo-Num $_['elapsed_s'] } -Descending | Select-Object -First 10)) })
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
        & $tbl 'Head blockers (top of each blocking chain)' $headRows
        & $tbl 'Problem sessions (blocked, I/O / log / memory / tempdb waits, long running)' $probRows
        & $tbl 'Memory grants (waiting, or big)' $grantRows
        & $tbl "TempDB users (over $($Config.TempdbSessionMB) MB)" $tdbRows
        & $endTbl 'Deadlocks' 'xe_deadlocks'
        & $tbl 'Deadlock processes' $dlProcs
        $(if ($xdlFiles.Count) { "<div>Deadlock graphs saved on $(Enc $env:COMPUTERNAME) (open in SSMS): $(Enc (($xdlFiles | ForEach-Object { Split-Path $_ -Leaf }) -join ', '))</div>" })
        & $endTbl "Queries over $($Config.LongQuerySec) s" 'xe_long'
        "<div style='color:#555;margin-top:12px'>$(Enc $qsNote)</div>"
        & $endTbl 'Top 20 queries in the window by duration' 'top_duration'
        & $endTbl 'Top 20 queries in the window by CPU' 'top_cpu'
        & $endTbl 'Top 20 queries in the window by logical reads' 'top_reads'
    ) -join '')
    return [pscustomobject]@{ Short = $short; Full = $full; Crit = $crit; Warn = $warn; Intervals = $iv.Count; Xdl = $xdlFiles }
}

function Get-Rows($Snap, [string]$Section) {
    if ($null -eq $Snap) { return @() }
    $s = $Snap['sections']
    if ($s -and $s.ContainsKey($Section) -and $null -ne $s[$Section]) { return @($s[$Section]) }
    return @()
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

$HtmlHead = @'
<html><head><style>
body{font-family:Segoe UI,Arial,sans-serif;font-size:12px;color:#222}
h1{color:#fff;background:#1f4e79;padding:6px 10px;font-size:18px;margin:24px 0 6px 0} h2{color:#1f4e79;margin-bottom:2px} h3{color:#1f4e79;margin:18px 0 4px 0;border-bottom:1px solid #1f4e79}
table{border-collapse:collapse;margin-bottom:8px} th{background:#1f4e79;color:#fff;padding:4px 6px;text-align:left;font-weight:600}
td{border:1px solid #d0d0d0;padding:3px 6px;vertical-align:top}
.banner{padding:10px 14px;font-size:14px;font-weight:600;margin:8px 0}
</style></head><body>
'@

function Get-SqlFilePath {
    if ($SqlFile) { return (Resolve-Path $SqlFile).Path }
    $c = Join-Path $PSScriptRoot 'PerfCheck.sql'
    if (Test-Path $c) { return (Resolve-Path $c).Path }
    throw 'PerfCheck.sql not found next to this script (or pass -SqlFile).'
}

function Invoke-Cleanup {
    if ($Config.CleanupHours -le 0) { return }
    $cutoff = (Get-Date).AddHours(-$Config.CleanupHours); $n = 0
    foreach ($folder in @($Config.ReportsFolder, $Config.LogsFolder)) {
        if (-not (Test-Path $folder)) { continue }
        Get-ChildItem -Path $folder -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cutoff -and $_.Name -notlike 'perf_restore_*' } |
            ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop; $n++ } catch { } }
    }
    if ($n) { Write-Step "Cleanup    : $n report/log file(s) older than $($Config.CleanupHours) h removed" 'DarkGray' }
}

# ---- SQL login: saved with DPAPI (LocalMachine scope = usable by any account on THIS VM only) ----
Add-Type -AssemblyName System.Security
$script:Entropy = [System.Text.Encoding]::UTF8.GetBytes('DBA.PerfCheck.v1')

function Save-SqlCredential([pscredential]$Credential) {
    $plain = [System.Text.Encoding]::UTF8.GetBytes($Credential.GetNetworkCredential().Password)
    try {
        $enc = [System.Security.Cryptography.ProtectedData]::Protect($plain, $script:Entropy, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        $obj = @{ user = $Credential.UserName; pwd = [Convert]::ToBase64String($enc); saved_by = "$env:USERDOMAIN\$env:USERNAME"; saved_at = (Get-Date -Format 'yyyy-MM-dd HH:mm') }
        [System.IO.File]::WriteAllText($Config.CredentialFile, (ConvertTo-Json -InputObject $obj -Compress))
        # Only administrators and SYSTEM may read it (plus the account that saved it)
        $grants = @('*S-1-5-32-544:F', '*S-1-5-18:F', "$env:USERDOMAIN\$($env:USERNAME):F") + @($Config.CredentialReaders | Where-Object { $_ } | ForEach-Object { "$($_):R" })
        try { $ErrorActionPreference = 'Continue'; & icacls.exe "$($Config.CredentialFile)" /inheritance:r /grant:r @grants 2>&1 | Out-Null } catch { } finally { $ErrorActionPreference = 'Stop' }
        Write-Step "SQL login saved for this VM: $($Config.CredentialFile)" 'Green'
    }
    finally { [Array]::Clear($plain, 0, $plain.Length) }
}

function Read-SqlCredential {
    if (-not (Test-Path -LiteralPath $Config.CredentialFile)) { return $null }
    try {
        $obj = Get-Content -LiteralPath $Config.CredentialFile -Raw | ConvertFrom-Json
        $dec = [System.Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($obj.pwd), $script:Entropy, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        $ss = New-Object System.Security.SecureString
        foreach ($ch in [System.Text.Encoding]::UTF8.GetString($dec).ToCharArray()) { $ss.AppendChar($ch) }
        [Array]::Clear($dec, 0, $dec.Length)
        Write-Step "SQL login  : $($obj.user) (saved by $($obj.saved_by) on $($obj.saved_at))" 'DarkGray'
        return New-Object System.Management.Automation.PSCredential ([string]$obj.user, $ss)
    }
    catch { Write-Step "Saved SQL login could not be read ($($_.Exception.Message)) - run with -ResetCredential." 'Yellow'; return $null }
}

function New-SqlConnection([string]$Instance, [pscredential]$SqlCred) {
    $enc = if ($Config.Encrypt) { 'True' } else { 'False' }
    $base = "Server=$Instance;Database=master;Application Name=DBA PerfCheck;Connect Timeout=$($Config.ConnectTimeoutSec);Encrypt=$enc;TrustServerCertificate=True"
    if ($SqlCred) {
        $ss = $SqlCred.Password.Copy(); $ss.MakeReadOnly()
        return New-Object System.Data.SqlClient.SqlConnection ($base, (New-Object System.Data.SqlClient.SqlCredential ($SqlCred.UserName, $ss)))
    }
    return New-Object System.Data.SqlClient.SqlConnection ($base + ';Integrated Security=SSPI')
}

function Test-SqlAccess($Connection) {
    try { return ([int](Invoke-Scalar $Connection "SELECT ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE'), 0);") -eq 1) } catch { return $false }
}

function Open-SqlConnection([string]$Instance) {
    # 1st: the SQL login. Fail-safe: Windows authentication as the account running the script.
    $notes = @(); $win = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ($script:SqlCred) {
        $conn = New-SqlConnection $Instance $script:SqlCred
        try {
            $conn.Open()
            if (Test-SqlAccess $conn) { return [pscustomobject]@{ Connection = $conn; As = "SQL: $($script:SqlCred.UserName)" } }
            $notes += "$($script:SqlCred.UserName) has no VIEW SERVER STATE"; $conn.Dispose()
        }
        catch { $notes += "$($script:SqlCred.UserName): $($_.Exception.Message)"; $conn.Dispose() }
        Write-Step "  SQL login can't be used on $Instance ($($notes -join '; ')) - trying Windows authentication as $win" 'Yellow'
    }
    $conn = New-SqlConnection $Instance $null
    try { $conn.Open() } catch { $conn.Dispose(); throw ((@($notes) + "$($win): $($_.Exception.Message)") -join ' | ') }
    if (-not (Test-SqlAccess $conn)) { Write-Step "  WARNING: $win has no VIEW SERVER STATE on $Instance - most metrics will be empty." 'Yellow' }
    return [pscustomobject]@{ Connection = $conn; As = "Windows: $win" }
}

# ---- Health check report: order + titles (sections with no rows are skipped) ----
$ReportSections = [ordered]@{
    issues = 'Needs attention'; instance = 'Instance'; services = 'SQL Server services'; vitals = 'Vitals'; databases = 'Databases, backups & CHECKDB'
    ag_replicas = 'Always On - replicas (nodes)'; ag_listeners = 'Always On - listeners (IP / DHCP)'; ag_databases = 'Always On - databases per replica'; cluster = 'Cluster & quorum'; disks = 'Disk space'
    job_failures = 'Failed job steps (24 h)'; errorlog = 'Severe error log entries (24 h)'
    traceflags = 'Global trace flags'; config = 'sp_configure'
    linked_servers = 'Linked servers'; endpoints = 'Endpoints'; certificates = 'Certificates'; xe_sessions = 'XE sessions'
    ssis_catalog = 'SSIS catalog settings'; ssis_projects = 'SSIS projects'; ssis_environments = 'SSIS environments'; ssis_failures = 'SSIS failed executions (24 h)'
    ssrs_summary = 'SSRS content (report server databases)'; ssrs_subscriptions = 'SSRS subscriptions'
}
$BiSections = [ordered]@{ issues = 'Needs attention (SSIS / SSRS / SSAS on this VM)'; bi_services = 'SSIS / SSRS / SSAS services'; ssas_server = 'SSAS instances'; ssas_databases = 'SSAS databases' }

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

function Get-FullReportHtml($Snap, $Sections = $ReportSections) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($sec in $Sections.Keys) {
        $rows = @(Get-Rows $Snap $sec)
        $cols = $null
        if ($Snap['columns'] -and $Snap['columns'].ContainsKey($sec)) { $cols = @($Snap['columns'][$sec]) }
        if ($sec -ne 'issues' -and $rows.Count -eq 0) { continue }       # skip empty sections (e.g. no AG)
        [void]$sb.Append('<h3>' + (Enc $Sections[$sec]) + '</h3>')
        if (-not $cols) { [void]$sb.Append('<div style="color:#2e7d32">None</div>'); continue }
        $statusCol = if ($cols -contains 'status') { 'status' } elseif ($cols -contains 'severity') { 'severity' } else { '' }
        [void]$sb.Append((ConvertTo-HtmlTable $rows $cols '' $statusCol))
    }
    return $sb.ToString()
}

function Send-SmtpMail([string]$Subject, [string]$Html, [string]$Importance, [string[]]$Attachments) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $msg = New-Object System.Net.Mail.MailMessage
    $from = if ($Config.SmtpFrom) { $Config.SmtpFrom } elseif ($Config.FromAddress) { $Config.FromAddress } else { "sqlperfcheck@$([Environment]::MachineName.ToLower())" }
    $msg.From = New-Object System.Net.Mail.MailAddress $from
    foreach ($r in @($Config.Recipients -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) { $msg.To.Add($r) }
    foreach ($r in @([string]$Config.CopyRecipients -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) { $msg.CC.Add($r) }
    if ($Config.ReplyTo) { $msg.ReplyToList.Add($Config.ReplyTo) }
    $msg.Subject = $Subject; $msg.Body = $Html; $msg.IsBodyHtml = $true
    if ($Importance -eq 'High') { $msg.Priority = [System.Net.Mail.MailPriority]::High }
    foreach ($a in @($Attachments | Where-Object { $_ -and (Test-Path -LiteralPath $_) })) { $msg.Attachments.Add((New-Object System.Net.Mail.Attachment $a)) }
    $client = New-Object System.Net.Mail.SmtpClient ($Config.SmtpServer, [int]$Config.SmtpPort)
    $client.EnableSsl = [bool]$Config.SmtpUseSsl
    if ($Config.SmtpUseDefaultCredentials) { $client.UseDefaultCredentials = $true }
    try { $client.Send($msg) } finally { $msg.Dispose(); $client.Dispose() }
}

function Send-DbMailQueryAttachment($Connection, [string]$MailProfileName, [string]$Subject, [string]$Html, [string]$Importance, [string]$FileName, [string]$AttachHtml) {
    # Attaches the report as a query result (SELECT of the HTML text). Works for SQL logins too:
    # Database Mail does not allow @file_attachments for SQL-authenticated logins.
    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = 'msdb.dbo.sp_send_dbmail'; $cmd.CommandType = [System.Data.CommandType]::StoredProcedure; $cmd.CommandTimeout = 300
    [void]$cmd.Parameters.AddWithValue('@profile_name', $MailProfileName)
    [void]$cmd.Parameters.AddWithValue('@recipients', $Config.Recipients)
    if ($Config.CopyRecipients) { [void]$cmd.Parameters.AddWithValue('@copy_recipients', $Config.CopyRecipients) }
    if ($Config.FromAddress) { [void]$cmd.Parameters.AddWithValue('@from_address', $Config.FromAddress) }
    if ($Config.ReplyTo)     { [void]$cmd.Parameters.AddWithValue('@reply_to', $Config.ReplyTo) }
    [void]$cmd.Parameters.AddWithValue('@subject', $Subject)
    $pBody = $cmd.Parameters.Add('@body', [System.Data.SqlDbType]::NVarChar, -1); $pBody.Value = $Html
    [void]$cmd.Parameters.AddWithValue('@body_format', 'HTML')
    [void]$cmd.Parameters.AddWithValue('@importance', $Importance)
    $pQ = $cmd.Parameters.Add('@query', [System.Data.SqlDbType]::NVarChar, -1); $pQ.Value = "SET NOCOUNT ON; SELECT CAST(N'" + $AttachHtml.Replace("'", "''") + "' AS varchar(max));"   # varchar = plain text file
    [void]$cmd.Parameters.AddWithValue('@execute_query_database', 'master')
    [void]$cmd.Parameters.AddWithValue('@attach_query_result_as_file', 1)
    [void]$cmd.Parameters.AddWithValue('@query_attachment_filename', $FileName)
    [void]$cmd.Parameters.AddWithValue('@query_result_header', 0)
    [void]$cmd.Parameters.AddWithValue('@query_no_truncate', 1)
    [void]$cmd.Parameters.AddWithValue('@query_result_no_padding', 1)
    [void]$cmd.Parameters.AddWithValue('@exclude_query_output', 1)
    $pId = $cmd.Parameters.Add('@mailitem_id', [System.Data.SqlDbType]::Int); $pId.Direction = [System.Data.ParameterDirection]::Output
    [void]$cmd.ExecuteNonQuery()
    return [int]$pId.Value
}

function Wait-DbMailStatus($Connection, [int]$MailId) {
    # Waits until Database Mail has handed the email to the SMTP server; returns sent / failed / unsent / retrying
    $st = 'unknown'; $deadline = (Get-Date).AddSeconds([math]::Max(20, 3 * $Config.MailCheckDelaySec))
    do {
        Start-Sleep -Seconds 5
        $v = Invoke-Scalar $Connection "SELECT sent_status FROM msdb.dbo.sysmail_allitems WHERE mailitem_id = @id;" @{ '@id' = $MailId }
        $st = if ($null -eq $v -or $v -is [DBNull]) { 'unknown' } else { [string]$v }
    } while ($st -in @('unsent', 'retrying', 'unknown') -and (Get-Date) -lt $deadline)
    return $st
}

function Send-Notification([string]$Subject, [string]$BodyAttached, [string]$BodySummary, [string[]]$Files, [string]$Importance, $Candidates, [string]$ReportHtml = '') {
    # Tries every instance with Database Mail (local first). On each one, in order:
    #   1. report attached as a file (Windows authentication only - Database Mail rule)
    #   2. report attached as a query result (works for SQL logins)
    #   3. summary only
    # moving on when Database Mail rejects it or reports 'failed'; then the SMTP fallback. Returns @{ Sent; Status }.
    $attempts = @()
    foreach ($sender in @($Candidates | Sort-Object @{ Expression = { -not $_.Local } })) {
        $c = $null
        try {
            $oc = Open-SqlConnection $sender.Instance; $c = $oc.Connection
            $isSqlLogin = ([string]$oc.As) -like 'SQL:*'
            $maxBytes = 0
            try { $maxBytes = [int64](Invoke-Scalar $c "SELECT CAST(paramvalue AS bigint) FROM msdb.dbo.sysmail_configuration WHERE paramname = N'MaxFileSize';") } catch { }
            $reportFile = @($Files | Where-Object { $_ -and (Test-Path -LiteralPath $_) }) | Select-Object -First 1
            $methods = @()
            if ($Config.AttachReport -and $BodyAttached -and $reportFile) {
                if (-not $isSqlLogin) { $methods += 'file' }
                if ($ReportHtml) {
                    $ansiBytes = [System.Text.Encoding]::Default.GetByteCount($ReportHtml)
                    if ($maxBytes -le 0 -or $ansiBytes -le $maxBytes) { $methods += 'query' }
                    else { Write-Step ("  Report is {0:N0} KB, above Database Mail MaxFileSize ({1:N0} KB) on {2} - raise it with scripts/45_database_mail_setup.sql (@MaxFileSizeMB) or set SmtpServer." -f ($ansiBytes / 1KB), ($maxBytes / 1KB), $sender.Instance) 'Yellow' }
                }
            }
            $methods += 'summary'
            foreach ($m in $methods) {
                $mailId = $null; $how = ''
                $okFiles = @($Files | Where-Object { $_ -and (Test-Path -LiteralPath $_) -and ($maxBytes -le 0 -or (Get-Item -LiteralPath $_).Length -le $maxBytes) })
                if ($m -eq 'file' -and -not $okFiles.Count) { continue }      # report bigger than MaxFileSize
                try {
                    switch ($m) {
                        'file' {
                            $mailId = Send-DbMail $c $sender.Profile $Subject $BodyAttached $Importance ($okFiles -join ';'); $how = "with $($okFiles.Count) file attachment(s)"
                        }
                        'query'   { $mailId = Send-DbMailQueryAttachment $c $sender.Profile $Subject $BodyAttached $Importance (Split-Path $reportFile -Leaf) $ReportHtml; $how = 'with the report attached' }
                        'summary' { $mailId = Send-DbMail $c $sender.Profile $Subject $BodySummary $Importance; $how = 'summary only, full report on the VM' }
                    }
                }
                catch {
                    $attempts += "$($sender.Instance) [$m]: $($_.Exception.Message)"
                    Write-Step "  $($sender.Instance): sending $m failed ($($_.Exception.Message)) - trying the next way." 'Yellow'
                    continue
                }
                Write-Step "Email      : queued as mailitem_id $mailId via $($sender.Instance) / profile '$($sender.Profile)' ($how)" 'Green'
                $st = Wait-DbMailStatus $c $mailId
                if ($st -eq 'failed') {
                    $why = Invoke-Scalar $c "SELECT TOP (1) LEFT(description, 300) FROM msdb.dbo.sysmail_event_log WHERE mailitem_id = @id ORDER BY log_id DESC;" @{ '@id' = $mailId }
                    $attempts += "$($sender.Instance) [$m]: Database Mail failed - $why"
                    Write-Step "  Database Mail on $($sender.Instance) failed to deliver it ($why) - trying the next way." 'Yellow'
                    continue
                }
                $note = if ($st -eq 'sent') { 'sent' } else { "$st (still in the Database Mail queue)" }
                return @{ Sent = $true; Status = "$note via $($sender.Instance) / '$($sender.Profile)' ($how)" }
            }
        }
        catch {
            $attempts += "$($sender.Instance): $($_.Exception.Message)"
            Write-Step "  Could not send via $($sender.Instance): $($_.Exception.Message) - trying the next option." 'Yellow'
        }
        finally { if ($c) { $c.Dispose() } }
    }
    if ($Config.SmtpServer) {
        try {
            $body = if ($Config.AttachReport -and @($Files).Count -and $BodyAttached) { $BodyAttached } else { $BodySummary }
            Send-SmtpMail $Subject $body $Importance $(if ($Config.AttachReport) { $Files } else { @() })
            Write-Step "Email      : sent directly via SMTP $($Config.SmtpServer):$($Config.SmtpPort)" 'Green'
            return @{ Sent = $true; Status = "sent via SMTP $($Config.SmtpServer)" }
        }
        catch { $attempts += "SMTP $($Config.SmtpServer): $($_.Exception.Message)" }
    }
    if (-not $attempts.Count) { $attempts += 'no instance has a usable Database Mail profile and no SmtpServer is set in $Config' }
    return @{ Sent = $false; Status = 'NOT SENT - ' + ($attempts -join ' | ') }
}

# =============================================================================
#  MAIN
# =============================================================================
foreach ($f in @($Config.ReportsFolder, $Config.LogsFolder)) { if (-not (Test-Path $f)) { New-Item -ItemType Directory -Path $f -Force | Out-Null } }
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$logFile = Join-Path $Config.LogsFolder ("PerfCheck_{0}_{1}.log" -f $Label, $stamp)
try { Start-Transcript -Path $logFile -Append | Out-Null } catch { }

$me = "$env:USERDOMAIN\$env:USERNAME"
$summary = @(); $combinedFile = $null; $mailStatus = 'Not sent'; $exitCode = 0; $mailCandidates = @(); $script:MailSent = $false
$sampleSecUsed = if ($SampleSec -gt 0) { $SampleSec } else { [int]$Config.SampleSec }
$durationUsed  = if ($DurationMin -gt 0) { $DurationMin } else { [int]$Config.DurationMin }

try {
    Write-Step "=== $($Config.ReportTitle) - $env:COMPUTERNAME - $Label ===" 'Green'
    Write-Step ("Steps      : {0}{1}{2}" -f $(if (-not $NoHealth) { 'health check' } else { '' }), $(if (-not $NoHealth -and -not $NoPerf) { ' + ' } else { '' }), $(if (-not $NoPerf) { "performance window every $sampleSecUsed s for $durationUsed min" } else { '' }))
    if ($NoHealth -and $NoPerf) { throw '-NoHealth and -NoPerf together leave nothing to do.' }
    Invoke-Cleanup

    # ---- SQL login ----
    $script:SqlCred = $null
    if ($ResetCredential -and (Test-Path -LiteralPath $Config.CredentialFile)) { Remove-Item -LiteralPath $Config.CredentialFile -Force; Write-Step 'Saved SQL login removed.' 'Yellow' }
    if (-not $WindowsAuth) {
        $script:SqlCred = Read-SqlCredential
        if (-not $script:SqlCred -and -not $Unattended) {
            Write-Step "No saved SQL login. Enter the password for '$($Config.SqlLogin)' (or Cancel for Windows authentication as $me)." 'Yellow'
            try { $script:SqlCred = Get-Credential -UserName $Config.SqlLogin -Message "SQL login for the performance check (SQL authentication). Cancel = Windows authentication as $me" } catch { $script:SqlCred = $null }
            if ($script:SqlCred) {
                $ans = Read-Host 'Save it on this VM so later runs and the scheduled task do not ask? (Y/N)'
                if ($ans -match '^[Yy]') { Save-SqlCredential $script:SqlCred }
            }
        }
        if (-not $script:SqlCred) { Write-Step "Using Windows authentication as $me" 'Yellow' }
    }

    $blocks = Get-SqlBlocks ([System.IO.File]::ReadAllText((Get-SqlFilePath)))
    foreach ($b in 'HEALTH', 'PERF_START', 'PERF_SAMPLE', 'PERF_END', 'PERF_TEARDOWN') { if (-not $blocks.ContainsKey($b)) { throw "PerfCheck.sql has no --##$b block." } }

    $targets = Get-TargetInstances
    if (-not $targets) { throw 'No SQL Server instances found on this VM (and no ExtraInstances / -Instances).' }
    Write-Step "Instances  : $(($targets | ForEach-Object { $_.Instance }) -join ', ')"

    # ---- SSIS / SSRS / SSAS services and SSAS databases on THIS VM (once) ----
    $machineBi = $null
    if (-not $NoHealth -and @($targets | Where-Object { $_.Status -ne 'Listed' }).Count) {
        try { Write-Step 'Collecting SSIS / SSRS / SSAS service and SSAS database info for this VM...'; $machineBi = Get-MachineBiSnapshot }
        catch { Write-Step "SSIS / SSRS / SSAS info not collected: $($_.Exception.Message)" 'Yellow' }
    }

    # ---- connect to every instance (+ health check) ----
    $items = @()
    foreach ($t in $targets) {
        $row = [pscustomobject][ordered]@{ Instance = $t.Instance; ConnectedAs = ''; Outcome = ''; State = ''; ShortHtml = ''; FullHtml = ''
                                           HealthCrit = 0; HealthWarn = 0; HealthShort = ''; HealthFull = ''; PerfCrit = 0; PerfWarn = 0; PerfShort = ''; PerfFull = ''; PerfNote = '' }
        if ($t.Status -and $t.Status -notin @('Running', 'Listed', 'Unknown')) {
            $row.State = 'FAILED'; $row.Outcome = "SQL Server service is $($t.Status)"
            $row.ShortHtml = $row.FullHtml = "<h1>$(Enc $t.Instance)</h1><div class='banner' style='background:#f8d7da'>$(Enc $row.Outcome)</div>"
            Write-Step "$($t.Instance): $($row.Outcome) - skipped" 'Red'; $summary += $row; continue
        }
        try {
            $oc = Open-SqlConnection $t.Instance
            $row.ConnectedAs = $oc.As
            Write-Step "$($t.Instance): connected as $($oc.As)" 'Green'
            try {
                $p = Get-MailProfileName $oc.Connection
                if ($p) { $mailCandidates += [pscustomobject]@{ Instance = $t.Instance; Profile = $p; Local = ($t.Status -ne 'Listed') } }
                else { Write-Step "  $($t.Instance): no usable Database Mail profile for $($oc.As) (XPs off, no profile / account, or profile not public)" 'DarkGray' }
            } catch { Write-Step "  $($t.Instance): could not read Database Mail profiles - $($_.Exception.Message)" 'DarkGray' }
            $items += [pscustomobject]@{ Instance = $t.Instance; Conn = $oc.Connection; Safe = (Get-SafeFileName $t.Instance); Row = $row; Local = ($t.Status -ne 'Listed') }
            if (-not $NoHealth) {
                Write-Step "$($t.Instance): health check..."
                try {
                    $hc = Invoke-SqlSections $oc.Connection $blocks['HEALTH']
                    $hIssues = @(Get-Rows $hc 'issues')
                    $row.HealthCrit = @($hIssues | Where-Object { (Get-Val $_ 'severity') -eq 'CRITICAL' }).Count
                    $row.HealthWarn = @($hIssues | Where-Object { (Get-Val $_ 'severity') -eq 'WARNING' }).Count
                    $build = Get-Val (@(Get-Rows $hc 'instance') | Where-Object { (Get-Val $_ 'property_code') -eq 'build' } | Select-Object -First 1) 'value'
                    $hColor = if ($row.HealthCrit) { '#f8d7da' } elseif ($row.HealthWarn) { '#fff3cd' } else { '#d4edda' }
                    $hHead = "<h2>Health check</h2><div class='banner' style='background:$hColor'>Health: $($row.HealthCrit) critical, $($row.HealthWarn) warning(s)</div><div>Build: $(Enc $build)</div>"
                    $row.HealthShort = $hHead + "<h3>Needs attention ($($hIssues.Count))</h3>" + [string](ConvertTo-HtmlTable $hIssues @('severity', 'area', 'item', 'detail') '' 'severity')
                    $row.HealthFull  = $row.HealthShort + ([string](Get-FullReportHtml $hc) -replace '^<h3>Needs attention</h3>.*?(?=<h3>)', '')
                    Write-Step ("{0}: health - {1} critical, {2} warning(s)" -f $t.Instance, $row.HealthCrit, $row.HealthWarn) $(if ($row.HealthCrit) { 'Red' } elseif ($row.HealthWarn) { 'Yellow' } else { 'Green' })
                }
                catch {
                    $row.HealthCrit = 1
                    $row.HealthShort = $row.HealthFull = "<h2>Health check</h2><div class='banner' style='background:#f8d7da'>Health check failed: $(Enc $_.Exception.Message)</div>"
                    Write-Step "$($t.Instance): health check failed - $($_.Exception.Message)" 'Red'
                }
            }
        }
        catch {
            $row.State = 'FAILED'; $row.Outcome = 'FAILED: ' + $_.Exception.Message
            $row.ShortHtml = $row.FullHtml = "<h1>$(Enc $t.Instance)</h1><div class='banner' style='background:#f8d7da'>$(Enc $row.Outcome)</div>"
            Write-Step "$($t.Instance): $($row.Outcome)" 'Red'
        }
        $summary += $row
    }

    # ---- performance window (all instances sampled together) ----
    $xdlAll = @()
    if ($items.Count -and -not $NoPerf) {
        try { Invoke-PerfWindow $items $blocks $sampleSecUsed $durationUsed }
        finally {
            foreach ($it in $items) {
                try {
                    $pr = Get-PerfResult $it $sampleSecUsed
                    $it.Row.PerfCrit = $pr.Crit; $it.Row.PerfWarn = $pr.Warn; $it.Row.PerfShort = $pr.Short; $it.Row.PerfFull = $pr.Full
                    $it.Row.PerfNote = "$($pr.Intervals) intervals"; $xdlAll += @($pr.Xdl)
                    Write-Step ("{0}: performance - {1} critical, {2} warning(s)" -f $it.Instance, $pr.Crit, $pr.Warn) $(if ($pr.Crit) { 'Red' } elseif ($pr.Warn) { 'Yellow' } else { 'Green' })
                }
                catch {
                    $it.Row.PerfCrit = 1
                    $it.Row.PerfShort = $it.Row.PerfFull = "<h2>Performance window</h2><div class='banner' style='background:#f8d7da'>Performance report failed: $(Enc $_.Exception.Message)</div>"
                }
            }
        }
    }

    # ---- per instance: health + performance in one section ----
    foreach ($it in $items) {
        $r = $it.Row
        $c = $r.HealthCrit + $r.PerfCrit; $w = $r.HealthWarn + $r.PerfWarn
        $r.State = if ($c) { 'CRIT' } elseif ($w) { 'WARN' } else { 'OK' }
        $parts = @()
        if (-not $NoHealth) { $parts += "health: $($r.HealthCrit) critical, $($r.HealthWarn) warning(s)" }
        if (-not $NoPerf)   { $parts += "performance ($($r.PerfNote)): $($r.PerfCrit) critical, $($r.PerfWarn) warning(s)" }
        $r.Outcome = $parts -join '; '
        $banner = if ($c) { '#f8d7da' } elseif ($w) { '#fff3cd' } else { '#d4edda' }
        $hdr = "<h1>$(Enc $it.Instance)</h1><div class='banner' style='background:$banner'>$(Enc $r.Outcome)</div><div>Connected as: $(Enc $r.ConnectedAs)</div>"
        $r.ShortHtml = $hdr + $r.HealthShort + $r.PerfShort
        $r.FullHtml  = $hdr + $r.HealthFull + $r.PerfFull
    }

    # ---- one combined report + one email for the VM ----
    $states = @($summary | ForEach-Object { $_.State })
    $nCrit = @($states | Where-Object { $_ -in @('CRIT', 'FAILED') }).Count; $nWarn = @($states | Where-Object { $_ -eq 'WARN' }).Count
    $biShort = ''; $biFull = ''
    if ($machineBi) {
        $biIssues = @($machineBi.issues)
        $biSnap = @{ sections = $machineBi.sections; columns = $machineBi.columns }
        $biSnap.sections['issues'] = $biIssues; $biSnap.columns['issues'] = @('severity', 'area', 'item', 'detail')
        if (@($biIssues | Where-Object { (Get-Val $_ 'severity') -eq 'CRITICAL' }).Count) { $nCrit++ } elseif ($biIssues.Count) { $nWarn++ }
        $biShort = "<h3>SSIS / SSRS / SSAS on $(Enc $env:COMPUTERNAME) - needs attention ($($biIssues.Count))</h3>" + [string](ConvertTo-HtmlTable $biIssues @('severity', 'area', 'item', 'detail') '' 'severity')
        $biFull  = $biShort + ([string](Get-FullReportHtml $biSnap $BiSections) -replace '^<h3>Needs attention[^<]*</h3>.*?(?=<h3>)', '')
    }
    $tag = if ($nCrit) { 'CRITICAL' } elseif ($nWarn) { 'WARNING' } else { 'OK' }
    $overall = "$tag - $($summary.Count) instance(s): $nCrit critical/failed, $nWarn with warnings"
    $overallColor = switch ($tag) { 'CRITICAL' { '#f8d7da' } 'WARNING' { '#fff3cd' } default { '#d4edda' } }
    $importance = if ($tag -eq 'CRITICAL') { 'High' } else { 'Normal' }
    $summaryRows = @($summary | ForEach-Object {
        [pscustomobject][ordered]@{ status = $(switch ($_.State) { 'CRIT' { 'CRITICAL' } 'FAILED' { 'CRITICAL' } 'WARN' { 'WARNING' } default { '' } }); Instance = $_.Instance; ConnectedAs = $_.ConnectedAs; Outcome = $_.Outcome } })
    $header = (@(
        "<h2>$(Enc $Config.ReportTitle) - $(Enc $env:COMPUTERNAME)</h2>"
        "<div class='banner' style='background:$overallColor'>$(Enc $overall)</div>"
        "<div>Label: <b>$(Enc $Label)</b> &nbsp;|&nbsp; Window: every $sampleSecUsed s for $durationUsed min &nbsp;|&nbsp; Run by: $(Enc $me) &nbsp;|&nbsp; $(Get-Date -Format 'yyyy-MM-dd HH:mm')</div>"
        '<h3>Summary</h3>'
        [string](ConvertTo-HtmlTable $summaryRows @('Instance', 'ConnectedAs', 'Outcome') '' 'status')
    ) -join '')
    $headerShort = $header + $biShort; $header = $header + $biFull
    $combinedHtml = [string]$HtmlHead + $header + (($summary | ForEach-Object { $_.FullHtml }) -join "<hr style='margin:30px 0'>") + '</body></html>'
    $combinedFile = Join-Path $Config.ReportsFolder ("{0}_PERF_{1}_{2}.html" -f (Get-SafeFileName $env:COMPUTERNAME), $Label, (Get-Date -Format 'yyyyMMdd_HHmm'))
    [System.IO.File]::WriteAllText($combinedFile, $combinedHtml, [System.Text.Encoding]::UTF8)
    Write-Step "`nReport     : $combinedFile" 'Green'

    $subject = "[$tag] $($Config.ReportTitle) [$Label] - $env:COMPUTERNAME - $($summary.Count) instance(s)"
    $shortHtml = [string]$HtmlHead + $headerShort + (($summary | ForEach-Object { $_.ShortHtml }) -join "<hr style='margin:30px 0'>")
    $bodyAttached = $shortHtml + "<p style='color:#555'>The full report (per-interval tables and query lists) is attached: $(Enc (Split-Path $combinedFile -Leaf))</p></body></html>"
    $bodySummary  = $shortHtml + "<p style='color:#555'>Full report saved on $(Enc $env:COMPUTERNAME): $(Enc $combinedFile)</p></body></html>"
    $files = @($combinedFile) + @($xdlAll | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 5)
    $res = Send-Notification $subject $bodyAttached $bodySummary $files $importance $mailCandidates $combinedHtml
    $script:MailSent = $res.Sent; $mailStatus = $res.Status
    if (-not $res.Sent) { Write-Step "EMAIL NOT SENT: $mailStatus" 'Red' }
    if ($nCrit) { $exitCode = 2 } elseif ($nWarn) { $exitCode = 1 }
    if (-not $script:MailSent) { $exitCode = 4 }
}
catch {
    $err = $_.Exception.Message
    Write-Step ('ERROR: ' + $err) 'Red'; $exitCode = 3
    # Still tell the team: the check itself failed
    if (-not $script:MailSent) {
        try {
            $subj = "[FAILED] $($Config.ReportTitle) [$Label] - $env:COMPUTERNAME"
            $html = [string]$HtmlHead + "<h2>$(Enc $Config.ReportTitle) - $(Enc $env:COMPUTERNAME)</h2><div class='banner' style='background:#f8d7da'>The check failed: $(Enc $err)</div><div>Run by $(Enc $me) at $(Get-Date -Format 'yyyy-MM-dd HH:mm'). Log: $(Enc $logFile)</div></body></html>"
            $res = Send-Notification $subj '' $html @() 'High' @($mailCandidates)
            $script:MailSent = $res.Sent; $mailStatus = 'Failure notice: ' + $res.Status
        }
        catch { $mailStatus = "Failure notice not sent: $($_.Exception.Message)" }
    }
}
finally {
    foreach ($it in @($items)) { if ($it -and $it.Conn) { try { $it.Conn.Dispose() } catch { } } }
    Write-Step "`n=== SUMMARY ($Label) ===" 'Green'
    if ($summary) { $summary | Format-Table Instance, ConnectedAs, Outcome -AutoSize -Wrap | Out-String -Width 250 | Write-Host }
    Write-Step "Email      : $mailStatus"
    Write-Step "Report     : $combinedFile"
    if (-not $Unattended -and $combinedFile -and ($mailStatus -notlike 'Queued*') -and (Test-Path -LiteralPath $combinedFile)) {
        try { Invoke-Item -LiteralPath $combinedFile } catch { }
    }
    Write-Step "Log        : $logFile"
    try { Stop-Transcript | Out-Null } catch { }
    if (-not $Unattended) { Read-Host "`nPress Enter to close" }
}
exit $exitCode
