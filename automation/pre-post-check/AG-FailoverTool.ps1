<#
.SYNOPSIS
    Always On Availability Group - Drain / Failback / Health tool (baseline v1.0)

.DESCRIPTION
    Menu-driven tool for planned maintenance on SQL Server Always On AG nodes
    (Windows patching, SQL CU patching, reboots, etc.).

      1 - Drain a node before activity
          Records the current primary of every AG on the node, then fails each AG
          over to the best synchronous secondary. Writes a state file (used by
          option 2) and a leadership summary .txt.

      2 - Fail back after activity
          Reads a state file from option 1 and returns every AG to the primary it
          had before the activity. Appends the result to the same summary .txt.

      3 - AG health check
          Read-only report of replicas, databases, sync state, suspension and queues.

      4 - Toggle DRY RUN (shows the T-SQL that would run; changes nothing)

      5 - Rolling reboot of every VM in the cluster
          Detects the cluster VMs (or reads VMs.txt), takes a pre-snapshot of every
          AG primary, then one VM at a time: drain -> shutdown /r /t 0 -> wait for
          SQL to come back and re-sync -> return that VM's AGs. Before each VM you
          can continue, skip it (e.g. maintenance window over) or stop. The VM the
          tool runs on is drained last and left for a MANUAL reboot; run option 5
          again after it is back and the run resumes, returns its AGs and does a
          final rebalance of every AG to the pre-snapshot layout.

    Every action is wrapped in try/catch. Errors are written to a timestamped log
    with the SQL error number/severity/state, the exact T-SQL and server, the
    script line, the full exception chain, a likely root cause with a suggested
    fix, and a snapshot of the AG state at the moment of failure.

.NOTES
    Requirements
      - Windows PowerShell 5.1 or PowerShell 7 (uses System.Data.SqlClient; no
        SqlServer / dbatools module needed).
      - Run under the Windows account that holds the SQL permissions, e.g. start
        PowerShell with "Run as different user". Integrated security is used.
      - Permissions on every replica: VIEW SERVER STATE, ALTER AVAILABILITY GROUP
        (or CONTROL AVAILABILITY GROUP / sysadmin).
      - TCP connectivity from where it runs to every replica.

    How to run
      powershell.exe -ExecutionPolicy Bypass -File .\AG-FailoverTool.ps1

    Baseline scope (deliberately NOT done automatically in v1.0)
      - No forced failover / data-loss failover.
      - No automatic switch of async replicas to synchronous commit.
      - AGs with CLUSTER_TYPE = NONE / EXTERNAL and distributed AGs are reported and skipped.

    VMs.txt (optional, next to the script, used by option 5)
      One VM per line, in the order to reboot; lines starting with # are ignored.
      Without it every node of the cluster is rebooted. A line such as
      SQLVM02\INST2 also tells the tool about a named instance on that VM.
      The VM running the tool is always handled last, with a manual reboot.

    Reboots (option 5) run "shutdown /r /t 0 /m \\<VM>" as the current account,
    which must be local admin on the VMs, or "shutdown /r /t 0" through WinRM
    with a Windows admin credential you enter at the start.

    Output folders (created next to the script)
      Logs\     detailed run logs
      State\    JSON state files recording original primaries (drives option 2)
      Summary\  leadership summaries and health-check reports
#>

[CmdletBinding()]
param(
    [string]$BasePath = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
$Config = @{
    ToolVersion             = '1.1'
    ConnectTimeoutSec       = 15     # SQL connection timeout
    QueryTimeoutSec         = 120    # normal query timeout
    FailoverTimeoutSec      = 600    # ALTER AVAILABILITY GROUP ... FAILOVER timeout
    SyncWaitSec             = 180    # max wait for a target to become SYNCHRONIZED before failover
    PostFailoverSyncWaitSec = 120    # max wait for the other replicas to re-sync after failover
    RoleVerifyWaitSec       = 60     # max wait for the new role to show PRIMARY
    PollIntervalSec         = 5
    QueueWarnKB             = 102400 # warn when log send + redo queue exceeds this (100 MB)
    RebootDownTimeoutSec    = 600    # option 5: time for a VM to go down after the reboot command
    RebootUpTimeoutSec      = 3600   # option 5: time for SQL to come back after the reboot (patches can be slow)
    RebootSyncWaitSec       = 1800   # option 5: time for the rebooted VM's replicas to re-sync
    RebootPollSec           = 15
}

if ([string]::IsNullOrWhiteSpace($BasePath)) { $BasePath = (Get-Location).Path }
$script:LogDir     = Join-Path $BasePath 'Logs'
$script:StateDir   = Join-Path $BasePath 'State'
$script:SummaryDir = Join-Path $BasePath 'Summary'
foreach ($d in @($script:LogDir, $script:StateDir, $script:SummaryDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$script:RunStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$script:LogFile  = Join-Path $script:LogDir "AGFailoverTool_$($script:RunStamp).txt"
$script:DryRun   = $false
$script:LastSql  = $null
$script:RunAs    = [Security.Principal.WindowsIdentity]::GetCurrent().Name

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'STEP', 'DETAIL')][string]$Level = 'INFO',
        [switch]$NoConsole
    )
    $line = '{0} [{1,-7}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 }
    catch { Write-Host "!! Could not write to log file $($script:LogFile): $($_.Exception.Message)" -ForegroundColor Red }

    if (-not $NoConsole) {
        $color = switch ($Level) {
            'ERROR'   { 'Red' }
            'WARN'    { 'Yellow' }
            'SUCCESS' { 'Green' }
            'STEP'    { 'Cyan' }
            'DETAIL'  { 'DarkGray' }
            default   { 'White' }
        }
        Write-Host $line -ForegroundColor $color
    }
}

function Format-Rows {
    param($Rows)
    if (-not $Rows -or @($Rows).Count -eq 0) { return '(no rows)' }
    return ($Rows | Format-Table -AutoSize | Out-String -Width 300).TrimEnd()
}

# ----------------------------------------------------------------------------
# Root-cause hints for common failures
# ----------------------------------------------------------------------------
function Get-RootCauseHint {
    param([System.Exception]$Exception)

    $hints   = New-Object System.Collections.Generic.List[string]
    $numbers = New-Object System.Collections.Generic.List[int]
    $allText = ''
    $ex = $Exception
    while ($ex) {
        $allText += ' ' + $ex.Message
        if ($ex -is [System.Data.SqlClient.SqlException]) {
            foreach ($e in $ex.Errors) { $numbers.Add([int]$e.Number) }
        }
        $ex = $ex.InnerException
    }

    foreach ($n in ($numbers | Select-Object -Unique)) {
        switch ($n) {
            18456 { $hints.Add("Login failed (18456). The Windows account '$($script:RunAs)' has no login on that instance or it is disabled. Check you started PowerShell with 'Run as different user' using the account that holds SQL permissions, and check the SQL error log on that server for the exact state code.") }
            { $_ -in 2, 53, -1, 10060, 10061, 11001, 40 } { $hints.Add("Network / connectivity error ($n). The server name did not resolve, TCP 1433 (or the instance port) is blocked by Windows Firewall / Azure NSG, the SQL service is stopped, or a named instance needs the SQL Browser (UDP 1434). Test with: Test-NetConnection <server> -Port 1433") }
            { $_ -in -2, 258 } { $hints.Add("Timeout ($n). The server was too slow to respond or a lock/blocking chain held the command. For a failover timeout, check the cluster log and the SQL error log on the target; the failover may still have completed, so run option 3 before retrying.") }
            { $_ -in 229, 297, 300, 15247 } { $hints.Add("Permission denied ($n). The running account needs VIEW SERVER STATE and ALTER AVAILABILITY GROUP (or CONTROL ON AVAILABILITY GROUP / sysadmin) on every replica.") }
            41131 { $hints.Add("41131: the cluster could not bring the AG online on the target. Commonly NT AUTHORITY\SYSTEM is missing ALTER ANY AVAILABILITY GROUP, CONNECT SQL and VIEW SERVER STATE on the target, or the cluster service on that node is unhealthy. Check the cluster log (Get-ClusterLog).") }
            41142 { $hints.Add("41142: the target replica cannot become primary because one or more databases are not SYNCHRONIZED / not failover-ready. Run option 3, resume any suspended databases and wait for SYNCHRONIZED before retrying.") }
            35250 { $hints.Add("35250: the secondary is not connected to the primary. Check the database mirroring endpoint (started, port reachable, CONNECT permission for the service account) and the AG endpoint URLs.") }
            19405 { $hints.Add("19405: the WSFC cluster or the cluster service on this node is not available or the node lost quorum. Check Failover Cluster Manager / Get-ClusterNode and cluster quorum before retrying.") }
            976   { $hints.Add("976: the database is a secondary that does not allow connections. This usually means a query was sent to a non-readable secondary; verify the role of the server used.") }
            default { }
        }
    }

    if ($hints.Count -eq 0) {
        if ($allText -match 'network-related|server was not found|could not open a connection|No such host') {
            $hints.Add('Connectivity problem: name resolution, firewall/NSG on the SQL port, or the SQL service is down. Test with Test-NetConnection <server> -Port 1433.')
        }
        elseif ($allText -match 'Login failed|Cannot open database') {
            $hints.Add("Authentication problem for '$($script:RunAs)'. Use 'Run as different user' with the account that holds SQL permissions.")
        }
        elseif ($allText -match 'not synchroniz|failover ready|SYNCHRONIZED') {
            $hints.Add('Synchronization problem: one or more databases are not SYNCHRONIZED. Run option 3 to see which, and resume suspended data movement before retrying.')
        }
        elseif ($allText -match 'cluster|quorum|WSFC') {
            $hints.Add('Cluster problem: check node status, quorum and the cloud witness in Failover Cluster Manager, and generate the cluster log (Get-ClusterLog).')
        }
        elseif ($allText -match 'timeout|Timeout expired') {
            $hints.Add('Timeout: the operation exceeded its limit. Check blocking and the SQL error log, then confirm the current state with option 3 before retrying.')
        }
        elseif ($allText -match 'permission|denied') {
            $hints.Add('Permission problem: the running account needs VIEW SERVER STATE and ALTER AVAILABILITY GROUP on every replica.')
        }
        else {
            $hints.Add('No known pattern matched. Use the SQL error number(s) and the AG snapshot below, and check the SQL Server error log and cluster log on the servers involved.')
        }
    }
    return $hints.ToArray()
}

function Write-ErrorDetail {
    param(
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [string]$Step,
        [string]$Server,
        [string]$AGName
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('==================== ERROR DETAIL ====================')
    [void]$sb.AppendLine("Step            : $Step")
    if ($AGName) { [void]$sb.AppendLine("Availability grp: $AGName") }
    if ($Server) { [void]$sb.AppendLine("Server          : $Server") }
    [void]$sb.AppendLine("Run as          : $($script:RunAs) on $env:COMPUTERNAME")
    [void]$sb.AppendLine("Dry run         : $($script:DryRun)")

    $inv = $ErrorRecord.InvocationInfo
    if ($inv) {
        [void]$sb.AppendLine("Script line     : $($inv.ScriptLineNumber)")
        if ($inv.Line) { [void]$sb.AppendLine("Script code     : $($inv.Line.Trim())") }
    }

    if ($script:LastSql) {
        [void]$sb.AppendLine("Last SQL server : $($script:LastSql.Server)")
        [void]$sb.AppendLine('Last SQL text   :')
        [void]$sb.AppendLine(($script:LastSql.Query.Trim() -split "`n" | ForEach-Object { '    ' + $_.TrimEnd() }) -join "`n")
        if ($script:LastSql.Parameters -and $script:LastSql.Parameters.Count -gt 0) {
            $p = ($script:LastSql.Parameters.GetEnumerator() | ForEach-Object { "@$($_.Key)='$($_.Value)'" }) -join ', '
            [void]$sb.AppendLine("Last SQL params : $p")
        }
    }

    [void]$sb.AppendLine('Exception chain :')
    $ex = $ErrorRecord.Exception
    $depth = 0
    while ($ex) {
        [void]$sb.AppendLine(('  [{0}] {1}: {2}' -f $depth, $ex.GetType().FullName, $ex.Message.Trim()))
        if ($ex -is [System.Data.SqlClient.SqlException]) {
            foreach ($e in $ex.Errors) {
                [void]$sb.AppendLine(('      SQL Error {0} | Severity {1} | State {2} | Server {3} | Proc {4} | Line {5} | {6}' -f `
                            $e.Number, $e.Class, $e.State, $e.Server, $e.Procedure, $e.LineNumber, $e.Message))
            }
        }
        $ex = $ex.InnerException
        $depth++
    }

    [void]$sb.AppendLine('Likely root cause / fix:')
    foreach ($h in (Get-RootCauseHint -Exception $ErrorRecord.Exception)) { [void]$sb.AppendLine("  - $h") }

    if ($ErrorRecord.ScriptStackTrace) {
        [void]$sb.AppendLine('Script stack    :')
        [void]$sb.AppendLine(($ErrorRecord.ScriptStackTrace -split "`n" | ForEach-Object { '    ' + $_.Trim() }) -join "`n")
    }
    [void]$sb.AppendLine('======================================================')
    Write-Log -Level ERROR -Message $sb.ToString()
}

# ----------------------------------------------------------------------------
# SQL helpers
# ----------------------------------------------------------------------------
function Invoke-Sql {
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][string]$Query,
        [hashtable]$Parameters = @{},
        [int]$TimeoutSec = $Config.QueryTimeoutSec,
        [switch]$NonQuery
    )
    $script:LastSql = @{ Server = $Server; Query = $Query; Parameters = $Parameters }
    $cs = "Server=$Server;Database=master;Integrated Security=SSPI;Application Name=AGFailoverTool;" +
          "Connect Timeout=$($Config.ConnectTimeoutSec);TrustServerCertificate=True"
    $conn = $null
    try {
        $conn = New-Object System.Data.SqlClient.SqlConnection $cs
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText    = $Query
        $cmd.CommandTimeout = $TimeoutSec
        foreach ($k in $Parameters.Keys) { [void]$cmd.Parameters.AddWithValue("@$k", $Parameters[$k]) }

        if ($NonQuery) { [void]$cmd.ExecuteNonQuery(); return }

        $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
        $dt = New-Object System.Data.DataTable
        [void]$da.Fill($dt)
        foreach ($r in $dt.Rows) {
            $o = [ordered]@{}
            foreach ($c in $dt.Columns) {
                $v = $r[$c.ColumnName]
                if ($v -is [System.DBNull]) { $v = $null }
                $o[$c.ColumnName] = $v
            }
            [pscustomobject]$o
        }
    }
    finally {
        if ($conn) { $conn.Dispose() }
    }
}

function Get-QuotedName([string]$Name) { '[' + ($Name -replace '\]', ']]') + ']' }

function Get-ServerInfo {
    param([string]$Server)
    $q = @"
SELECT  @@SERVERNAME                                   AS ServerName,
        CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(50))      AS ProductVersion,
        CAST(SERVERPROPERTY('ProductMajorVersion') AS int)          AS MajorVersion,
        CAST(SERVERPROPERTY('ProductUpdateLevel') AS nvarchar(50))  AS UpdateLevel,
        CAST(SERVERPROPERTY('IsHadrEnabled') AS int)                AS IsHadrEnabled,
        CAST(SERVERPROPERTY('HadrManagerStatus') AS int)            AS HadrManagerStatus,
        CAST(SERVERPROPERTY('ComputerNamePhysicalNetBIOS') AS nvarchar(128)) AS PhysicalName,
        (SELECT sqlserver_start_time FROM sys.dm_os_sys_info)       AS SqlStartTime;
"@
    $r = @(Invoke-Sql -Server $Server -Query $q)
    if ($r.Count -eq 0) { throw "No server information returned from $Server." }
    return $r[0]
}

function Get-AGList {
    # AGs this instance participates in, with the local role and the current primary.
    param([string]$Server, [int]$MajorVersion)
    $ct = if ($MajorVersion -ge 14) { 'ag.cluster_type_desc' } else { "N'WSFC'" }
    $q = @"
SELECT  ag.name                                   AS AGName,
        $ct                                       AS ClusterType,
        CAST(ag.is_distributed AS bit)            AS IsDistributed,
        ags.primary_replica                       AS PrimaryReplica,
        ags.synchronization_health_desc           AS AGHealth,
        ISNULL(ars.role_desc, 'UNKNOWN')          AS LocalRole
FROM    sys.availability_groups ag
LEFT JOIN sys.dm_hadr_availability_group_states ags   ON ags.group_id = ag.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ars.group_id = ag.group_id AND ars.is_local = 1
ORDER BY ag.name;
"@
    return @(Invoke-Sql -Server $Server -Query $q)
}

function Get-AGReplicas {
    # Run on the PRIMARY for a complete picture (a secondary only sees itself).
    param([string]$Server, [string]$AGName)
    $q = @"
SELECT  ar.replica_server_name                         AS ReplicaServer,
        ISNULL(ars.role_desc, 'UNKNOWN')               AS Role,
        ar.availability_mode_desc                      AS AvailabilityMode,
        ar.failover_mode_desc                          AS FailoverMode,
        ISNULL(ars.connected_state_desc, 'UNKNOWN')    AS ConnectedState,
        ISNULL(ars.synchronization_health_desc, 'UNKNOWN') AS SyncHealth,
        ars.last_connect_error_description             AS LastConnectError
FROM    sys.availability_replicas ar
JOIN    sys.availability_groups ag ON ag.group_id = ar.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id
WHERE   ag.name = @AGName
ORDER BY ar.replica_server_name;
"@
    return @(Invoke-Sql -Server $Server -Query $q -Parameters @{ AGName = $AGName })
}

function Get-AGDatabases {
    param([string]$Server, [string]$AGName)
    $q = @"
SELECT  ar.replica_server_name                         AS ReplicaServer,
        adc.database_name                              AS DatabaseName,
        drs.synchronization_state_desc                 AS SyncState,
        drs.synchronization_health_desc                AS SyncHealth,
        CAST(drs.is_suspended AS bit)                  AS IsSuspended,
        drs.suspend_reason_desc                        AS SuspendReason,
        ISNULL(drs.log_send_queue_size, 0)             AS LogSendQueueKB,
        ISNULL(drs.redo_queue_size, 0)                 AS RedoQueueKB,
        CAST(drcs.is_failover_ready AS bit)            AS IsFailoverReady,
        drs.last_commit_time                           AS LastCommitTime
FROM    sys.dm_hadr_database_replica_states drs
JOIN    sys.availability_replicas ar        ON ar.replica_id = drs.replica_id
JOIN    sys.availability_groups ag          ON ag.group_id = drs.group_id
JOIN    sys.availability_databases_cluster adc
        ON adc.group_database_id = drs.group_database_id AND adc.group_id = drs.group_id
LEFT JOIN sys.dm_hadr_database_replica_cluster_states drcs
        ON drcs.replica_id = drs.replica_id AND drcs.group_database_id = drs.group_database_id
WHERE   ag.name = @AGName
ORDER BY ar.replica_server_name, adc.database_name;
"@
    return @(Invoke-Sql -Server $Server -Query $q -Parameters @{ AGName = $AGName })
}

function Get-AGPrimary {
    param([string]$Server, [string]$AGName)
    $q = @"
SELECT ags.primary_replica AS PrimaryReplica
FROM   sys.availability_groups ag
JOIN   sys.dm_hadr_availability_group_states ags ON ags.group_id = ag.group_id
WHERE  ag.name = @AGName;
"@
    $r = @(Invoke-Sql -Server $Server -Query $q -Parameters @{ AGName = $AGName })
    if ($r.Count -gt 0) { return $r[0].PrimaryReplica }
    return $null
}

function Get-LocalRole {
    param([string]$Server, [string]$AGName)
    $q = @"
SELECT ars.role_desc AS Role
FROM   sys.dm_hadr_availability_replica_states ars
JOIN   sys.availability_groups ag ON ag.group_id = ars.group_id
WHERE  ars.is_local = 1 AND ag.name = @AGName;
"@
    $r = @(Invoke-Sql -Server $Server -Query $q -Parameters @{ AGName = $AGName })
    if ($r.Count -gt 0) { return $r[0].Role }
    return 'UNKNOWN'
}

function Write-AGSnapshot {
    # Logs the AG state at the moment of a failure. Never throws.
    param([string]$Server, [string]$AGName)
    try {
        Write-Log -Level DETAIL -Message "AG snapshot for [$AGName] taken from $Server :`n$(Format-Rows (Get-AGReplicas -Server $Server -AGName $AGName))`n$(Format-Rows (Get-AGDatabases -Server $Server -AGName $AGName | Select-Object ReplicaServer, DatabaseName, SyncState, IsSuspended, SuspendReason, LogSendQueueKB, RedoQueueKB, IsFailoverReady))"
    }
    catch {
        Write-Log -Level WARN -Message "Could not take AG snapshot from $Server for [$AGName]: $($_.Exception.Message)"
    }
}

# ----------------------------------------------------------------------------
# Readiness evaluation
# ----------------------------------------------------------------------------
function Get-ReplicaReadiness {
    param($Replica, $Databases)

    $reasons = New-Object System.Collections.Generic.List[string]
    $myDbs   = @($Databases | Where-Object { $_.ReplicaServer -eq $Replica.ReplicaServer })

    if ($Replica.Role -ne 'SECONDARY') { $reasons.Add("role is $($Replica.Role), not SECONDARY") }
    if ($Replica.AvailabilityMode -ne 'SYNCHRONOUS_COMMIT') {
        $reasons.Add("availability mode is $($Replica.AvailabilityMode); a no-data-loss planned failover needs SYNCHRONOUS_COMMIT")
    }
    if ($Replica.ConnectedState -ne 'CONNECTED') {
        $msg = "replica is $($Replica.ConnectedState)"
        if ($Replica.LastConnectError) { $msg += " (last connect error: $($Replica.LastConnectError))" }
        $reasons.Add($msg)
    }
    if ($Replica.SyncHealth -ne 'HEALTHY') { $reasons.Add("replica synchronization health is $($Replica.SyncHealth)") }

    $suspended = @($myDbs | Where-Object { $_.IsSuspended -eq $true })
    foreach ($d in $myDbs) {
        if ($d.IsSuspended -eq $true) {
            $reasons.Add("DB [$($d.DatabaseName)] data movement is SUSPENDED (reason: $($d.SuspendReason))")
        }
        elseif ($d.SyncState -ne 'SYNCHRONIZED') {
            $reasons.Add("DB [$($d.DatabaseName)] is $($d.SyncState) (log send queue $($d.LogSendQueueKB) KB, redo queue $($d.RedoQueueKB) KB)")
        }
        elseif ($d.IsFailoverReady -ne $true) {
            $reasons.Add("DB [$($d.DatabaseName)] is SYNCHRONIZED but not yet failover-ready")
        }
    }

    $queue = 0
    foreach ($d in $myDbs) { $queue += [double]$d.LogSendQueueKB + [double]$d.RedoQueueKB }

    # "Waitable" = only transient sync lag stands between this replica and readiness.
    $waitable = ($Replica.Role -eq 'SECONDARY') -and
                ($Replica.AvailabilityMode -eq 'SYNCHRONOUS_COMMIT') -and
                ($Replica.ConnectedState -eq 'CONNECTED') -and
                ($suspended.Count -eq 0)

    [pscustomobject]@{
        Replica      = $Replica.ReplicaServer
        Ready        = ($reasons.Count -eq 0)
        Waitable     = $waitable
        IsAutomatic  = ($Replica.FailoverMode -eq 'AUTOMATIC')
        TotalQueueKB = $queue
        Suspended    = $suspended
        Reasons      = $reasons.ToArray()
    }
}

function Find-FailoverTarget {
    <#
      Picks the best failover target for an AG, evaluated from the current primary.
      -ExcludeReplica : the instance(s) being drained (option 1 / option 5)
      -OnlyReplica    : a fixed target (option 2, the original primary)
      Waits up to SyncWaitSec when the only blocker is transient sync lag.
      Preference: ready > AUTOMATIC failover partner > smallest log send + redo queue.
    #>
    param(
        [string]$PrimaryServer,
        [string]$AGName,
        [string[]]$ExcludeReplica,
        [string]$OnlyReplica
    )
    $deadline = (Get-Date).AddSeconds($Config.SyncWaitSec)
    $loggedWait = $false
    while ($true) {
        $reps = Get-AGReplicas  -Server $PrimaryServer -AGName $AGName
        $dbs  = Get-AGDatabases -Server $PrimaryServer -AGName $AGName

        $pool = @($reps | Where-Object { $_.Role -ne 'PRIMARY' })
        if ($ExcludeReplica) { $pool = @($pool | Where-Object { $ExcludeReplica -notcontains $_.ReplicaServer }) }
        if ($OnlyReplica)    { $pool = @($reps | Where-Object { $_.ReplicaServer -eq $OnlyReplica }) }

        if ($pool.Count -eq 0) {
            $why = if ($OnlyReplica) { "replica '$OnlyReplica' is no longer part of AG [$AGName]" } else { "AG [$AGName] has no other replica to fail over to" }
            return [pscustomobject]@{ Target = $null; Candidates = @(); Reason = $why }
        }

        $cands = @($pool | ForEach-Object { Get-ReplicaReadiness -Replica $_ -Databases $dbs })
        $ready = @($cands | Where-Object { $_.Ready } |
                   Sort-Object @{ Expression = { $_.IsAutomatic }; Descending = $true }, @{ Expression = { $_.TotalQueueKB }; Ascending = $true })

        if ($ready.Count -gt 0) {
            if ($ready[0].TotalQueueKB -gt $Config.QueueWarnKB) {
                Write-Log -Level WARN -Message "[$AGName] target $($ready[0].Replica) is ready but has $([math]::Round($ready[0].TotalQueueKB/1024,1)) MB queued."
            }
            return [pscustomobject]@{ Target = $ready[0].Replica; Candidates = $cands; Reason = $null }
        }

        $waitable = @($cands | Where-Object { $_.Waitable })
        if ($waitable.Count -eq 0 -or (Get-Date) -gt $deadline) {
            $lines = $cands | ForEach-Object { "$($_.Replica): " + ($_.Reasons -join '; ') }
            $prefix = if ($waitable.Count -gt 0) { "still not synchronized after waiting $($Config.SyncWaitSec)s. " } else { '' }
            return [pscustomobject]@{ Target = $null; Candidates = $cands; Reason = $prefix + 'No eligible target -> ' + ($lines -join ' | ') }
        }

        if (-not $loggedWait) {
            Write-Log -Level INFO -Message "[$AGName] waiting up to $($Config.SyncWaitSec)s for a synchronous secondary to reach SYNCHRONIZED..."
            $loggedWait = $true
        }
        Start-Sleep -Seconds $Config.PollIntervalSec
    }
}

# ----------------------------------------------------------------------------
# Failover execution
# ----------------------------------------------------------------------------
function Invoke-AGFailover {
    <#
      Runs a planned (no data loss) failover. Must be executed on the target.
      Returns 'FAILED_OVER' or 'DRYRUN'; throws on failure.
    #>
    param([string]$AGName, [string]$Target)

    $sql = "ALTER AVAILABILITY GROUP $(Get-QuotedName $AGName) FAILOVER;"
    if ($script:DryRun) {
        Write-Log -Level WARN -Message "[DRY RUN] Would run on $Target : $sql"
        return 'DRYRUN'
    }

    Write-Log -Level STEP -Message "[$AGName] Running on $Target : $sql"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-Sql -Server $Target -Query $sql -NonQuery -TimeoutSec $Config.FailoverTimeoutSec
    $sw.Stop()

    # Verify the new role
    $deadline = (Get-Date).AddSeconds($Config.RoleVerifyWaitSec)
    do {
        $role = Get-LocalRole -Server $Target -AGName $AGName
        if ($role -eq 'PRIMARY') { break }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    if ($role -ne 'PRIMARY') {
        throw "Failover command completed in $([math]::Round($sw.Elapsed.TotalSeconds,1))s but $Target reports role '$role' for [$AGName] after $($Config.RoleVerifyWaitSec)s. Check the cluster log and SQL error log on $Target."
    }
    Write-Log -Level SUCCESS -Message "[$AGName] $Target is now PRIMARY (failover took $([math]::Round($sw.Elapsed.TotalSeconds,1))s)."
    return 'FAILED_OVER'
}

function Wait-AGResync {
    # Informational: waits for the synchronous secondaries to re-sync after a failover.
    param([string]$PrimaryServer, [string]$AGName)
    if ($script:DryRun) { return 'n/a (dry run)' }
    $deadline = (Get-Date).AddSeconds($Config.PostFailoverSyncWaitSec)
    do {
        $reps   = Get-AGReplicas  -Server $PrimaryServer -AGName $AGName
        $dbs    = Get-AGDatabases -Server $PrimaryServer -AGName $AGName
        $syncRep = @($reps | Where-Object { $_.Role -eq 'SECONDARY' -and $_.AvailabilityMode -eq 'SYNCHRONOUS_COMMIT' } | ForEach-Object { $_.ReplicaServer })
        $lagging = @($dbs | Where-Object { $syncRep -contains $_.ReplicaServer -and ($_.SyncState -ne 'SYNCHRONIZED' -or $_.IsSuspended) })
        if ($lagging.Count -eq 0) { return 'All synchronous secondaries SYNCHRONIZED' }
        Start-Sleep -Seconds $Config.PollIntervalSec
    } while ((Get-Date) -lt $deadline)

    $txt = ($lagging | ForEach-Object { "$($_.ReplicaServer)/$($_.DatabaseName)=$($_.SyncState)$(if($_.IsSuspended){' SUSPENDED: ' + $_.SuspendReason})" }) -join ', '
    Write-Log -Level WARN -Message "[$AGName] After $($Config.PostFailoverSyncWaitSec)s some secondaries are not SYNCHRONIZED: $txt"
    return "Not yet synchronized: $txt"
}

# ----------------------------------------------------------------------------
# State and summary files
# ----------------------------------------------------------------------------
function Get-SafeName([string]$Name) { $Name -replace '[\\/:*?"<>|]', '_' }

function Save-State {
    param($State, [string]$Path)
    $State.LastUpdated = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $State | ConvertTo-Json -Depth 8 | Set-Content -Path $Path -Encoding UTF8
}

function Confirm-Action([string]$Prompt) {
    $ans = Read-Host "$Prompt  Type YES to continue"
    return ($ans -ceq 'YES')
}

function Get-OverallResult {
    param($Entries, [string[]]$GoodResults)
    $actionable = @($Entries | Where-Object { $_.Result -ne 'NOT_PRIMARY_HERE' })
    if ($actionable.Count -eq 0) { return 'NO ACTION NEEDED' }
    $good = @($actionable | Where-Object { $GoodResults -contains $_.Result })
    if ($good.Count -eq $actionable.Count) { return "SUCCESS ($($good.Count) of $($actionable.Count) AGs)" }
    if ($good.Count -eq 0) { return "FAILED (0 of $($actionable.Count) AGs)" }
    return "PARTIAL ($($good.Count) of $($actionable.Count) AGs) - see issues below"
}

function Write-DrainSummary {
    param($State)
    $mode = if ($State.Mode -eq 'DRYRUN') { 'DRY RUN (no changes were made)' } else { 'LIVE' }
    $moved     = @($State.AGs | Where-Object { $_.Result -ne 'NOT_PRIMARY_HERE' })
    $secondary = @($State.AGs | Where-Object { $_.Result -eq 'NOT_PRIMARY_HERE' })
    $overall   = Get-OverallResult -Entries $State.AGs -GoodResults @('FAILED_OVER', 'DRYRUN')

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('=====================================================================================')
    [void]$sb.AppendLine(' SQL SERVER ALWAYS ON - AG FAILOVER SUMMARY (NODE DRAIN BEFORE MAINTENANCE)')
    [void]$sb.AppendLine('=====================================================================================')
    [void]$sb.AppendLine(" Node drained     : $($State.Node)")
    [void]$sb.AppendLine(" SQL version      : $($State.NodeVersion)")
    [void]$sb.AppendLine(" Started          : $($State.CreatedAt)")
    [void]$sb.AppendLine(" Completed        : $($State.DrainCompletedAt)")
    [void]$sb.AppendLine(" Executed by      : $($State.CreatedBy) (from $($State.Machine))")
    [void]$sb.AppendLine(" Mode             : $mode")
    [void]$sb.AppendLine(" Overall result   : $overall")
    [void]$sb.AppendLine('-------------------------------------------------------------------------------------')
    [void]$sb.AppendLine(' AGs moved off the node')
    if ($moved.Count -gt 0) {
        $tbl = $moved | Select-Object @{n = 'AG Name'; e = { $_.AGName } },
                                      @{n = 'Original Primary'; e = { $_.OriginalPrimary } },
                                      @{n = 'Failed Over To'; e = { if ($_.FailedOverTo) { $_.FailedOverTo } else { '-' } } },
                                      @{n = 'Result'; e = { $_.Result } },
                                      @{n = 'Time'; e = { $_.FailoverTime } },
                                      @{n = 'Sync After Failover'; e = { $_.PostFailoverSync } }
        [void]$sb.AppendLine((Format-Rows $tbl))
    }
    else { [void]$sb.AppendLine(" None - $($State.Node) was not primary for any AG.") }

    if ($secondary.Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine(" AGs where $($State.Node) is a secondary (no failover needed): " + (($secondary | ForEach-Object { "$($_.AGName) (primary: $($_.OriginalPrimary))" }) -join ', '))
    }

    $issues = @($moved | Where-Object { $_.Result -notin @('FAILED_OVER', 'DRYRUN') })
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(' Issues / notes')
    if ($issues.Count -eq 0) { [void]$sb.AppendLine('  - None') }
    foreach ($i in $issues) { [void]$sb.AppendLine("  - $($i.AGName): $($i.Result) - $($i.Reason)") }

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(' Next step : after maintenance, run option 2 to return the AGs to their original primaries.')
    [void]$sb.AppendLine(" Detail log: $($State.LogFile)")
    [void]$sb.AppendLine(" State file: $($State.StateFile)")
    [void]$sb.AppendLine('=====================================================================================')

    Set-Content -Path $State.SummaryFile -Value $sb.ToString() -Encoding UTF8
}

function Add-FailbackSummary {
    param($State, [string]$StartedAt)
    $mode     = if ($script:DryRun) { 'DRY RUN (no changes were made)' } else { 'LIVE' }
    $relevant = @($State.AGs | Where-Object { $_.FailbackResult })
    $overall  = 'NO ACTION NEEDED'
    if ($relevant.Count -gt 0) {
        $good = @($relevant | Where-Object { $_.FailbackResult -in @('FAILED_BACK', 'ALREADY_PRIMARY', 'DRYRUN') })
        $overall = if ($good.Count -eq $relevant.Count) { "SUCCESS ($($good.Count) of $($relevant.Count) AGs on original primary)" }
                   elseif ($good.Count -eq 0) { "FAILED (0 of $($relevant.Count) AGs)" }
                   else { "PARTIAL ($($good.Count) of $($relevant.Count) AGs) - see issues below" }
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('=====================================================================================')
    [void]$sb.AppendLine(' FAILBACK AFTER MAINTENANCE')
    [void]$sb.AppendLine('=====================================================================================')
    [void]$sb.AppendLine(" Started          : $StartedAt")
    [void]$sb.AppendLine(" Completed        : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$sb.AppendLine(" Executed by      : $($script:RunAs) (from $env:COMPUTERNAME)")
    [void]$sb.AppendLine(" Mode             : $mode")
    [void]$sb.AppendLine(" Overall result   : $overall")
    [void]$sb.AppendLine('-------------------------------------------------------------------------------------')
    if ($relevant.Count -gt 0) {
        $tbl = $relevant | Select-Object @{n = 'AG Name'; e = { $_.AGName } },
                                         @{n = 'Moved From'; e = { $_.FailbackFrom } },
                                         @{n = 'Returned To'; e = { $_.OriginalPrimary } },
                                         @{n = 'Result'; e = { $_.FailbackResult } },
                                         @{n = 'Time'; e = { $_.FailbackTime } }
        [void]$sb.AppendLine((Format-Rows $tbl))
    }
    $issues = @($relevant | Where-Object { $_.FailbackResult -notin @('FAILED_BACK', 'ALREADY_PRIMARY', 'DRYRUN') })
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(' Issues / notes')
    if ($issues.Count -eq 0) { [void]$sb.AppendLine('  - None') }
    foreach ($i in $issues) { [void]$sb.AppendLine("  - $($i.AGName): $($i.FailbackResult) - $($i.FailbackReason)") }
    [void]$sb.AppendLine(" Detail log: $($script:LogFile)")
    [void]$sb.AppendLine('=====================================================================================')

    Add-Content -Path $State.SummaryFile -Value $sb.ToString() -Encoding UTF8
}

# ----------------------------------------------------------------------------
# Option 1 - drain a node
# ----------------------------------------------------------------------------
function Invoke-DrainNode {
    Write-Log -Level STEP -Message '===== OPTION 1: Drain node before activity ====='
    $nodeInput = (Read-Host 'Enter the SQL instance to drain (e.g. SQLVM01 or SQLVM01\INST)').Trim()
    if (-not $nodeInput) { Write-Log -Level WARN -Message 'No server entered.'; return }

    try {
        $info = Get-ServerInfo -Server $nodeInput
    }
    catch {
        Write-ErrorDetail -ErrorRecord $_ -Step 'Connect to node to drain' -Server $nodeInput
        return
    }
    $node = $info.ServerName
    Write-Log -Message "Connected to $node (version $($info.ProductVersion) $($info.UpdateLevel))."

    if ($info.IsHadrEnabled -ne 1) {
        Write-Log -Level ERROR -Message "Always On is not enabled on $node (IsHadrEnabled=$($info.IsHadrEnabled)). Nothing to drain."
        return
    }
    if ($info.HadrManagerStatus -ne 1) {
        Write-Log -Level WARN -Message "HadrManagerStatus on $node is $($info.HadrManagerStatus) (1 = started). The AG manager may not be healthy."
    }

    try { $ags = Get-AGList -Server $node -MajorVersion $info.MajorVersion }
    catch { Write-ErrorDetail -ErrorRecord $_ -Step 'List AGs on node' -Server $node; return }

    if ($ags.Count -eq 0) { Write-Log -Level WARN -Message "$node is not part of any availability group."; return }

    # ---- Build the plan -----------------------------------------------------
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($ag in $ags) {
        $e = [pscustomobject]@{
            AGName           = $ag.AGName
            ClusterType      = $ag.ClusterType
            OriginalPrimary  = $ag.PrimaryReplica
            PlannedTarget    = $null
            FailedOverTo     = $null
            Result           = 'PENDING'
            Reason           = $null
            FailoverTime     = $null
            PostFailoverSync = $null
            FailbackFrom     = $null
            FailbackResult   = $null
            FailbackReason   = $null
            FailbackTime     = $null
        }
        if ($ag.LocalRole -ne 'PRIMARY') {
            $e.Result = 'NOT_PRIMARY_HERE'
            $e.Reason = "$node is $($ag.LocalRole) for this AG"
        }
        elseif ($ag.IsDistributed -eq $true) {
            $e.Result = 'SKIPPED'
            $e.Reason = 'Distributed AG - needs its own failover procedure (not in baseline)'
        }
        elseif ($ag.ClusterType -ne 'WSFC') {
            $e.Result = 'SKIPPED'
            $e.Reason = "CLUSTER_TYPE = $($ag.ClusterType) - planned FAILOVER is not supported; needs demote + forced failover (not in baseline)"
        }
        else {
            try {
                $pick = Find-FailoverTarget -PrimaryServer $node -AGName $ag.AGName -ExcludeReplica $node
                if ($pick.Target) { $e.PlannedTarget = $pick.Target }
                else { $e.Result = 'SKIPPED'; $e.Reason = $pick.Reason }
            }
            catch {
                Write-ErrorDetail -ErrorRecord $_ -Step 'Evaluate failover target' -Server $node -AGName $ag.AGName
                Write-AGSnapshot -Server $node -AGName $ag.AGName
                $e.Result = 'FAILED'; $e.Reason = "Target evaluation error: $($_.Exception.Message)"
            }
        }
        $entries.Add($e)
    }

    Write-Log -Level STEP -Message "Plan for $node :`n$(Format-Rows ($entries | Select-Object AGName, ClusterType, OriginalPrimary, PlannedTarget, Result, Reason))"

    $toMove = @($entries | Where-Object { $_.PlannedTarget -and $_.Result -eq 'PENDING' })
    if ($toMove.Count -eq 0) { Write-Log -Level WARN -Message "No AG will be failed over from $node." }

    # ---- Record state BEFORE any change -------------------------------------
    $mode       = if ($script:DryRun) { 'DRYRUN' } else { 'LIVE' }
    $tag        = if ($script:DryRun) { '_DRYRUN' } else { '' }
    $safe       = Get-SafeName $node
    $statePath  = Join-Path $script:StateDir   "AGState_$($safe)_$($script:RunStamp)$tag.json"
    $summary    = Join-Path $script:SummaryDir "AG_Failover_Summary_$($safe)_$($script:RunStamp)$tag.txt"
    $state = [pscustomobject]@{
        Tool             = 'AGFailoverTool'
        ToolVersion      = $Config.ToolVersion
        Mode             = $mode
        Node             = $node
        NodeVersion      = "$($info.ProductVersion) $($info.UpdateLevel)"
        Status           = 'DRAIN_STARTED'
        CreatedAt        = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        CreatedBy        = $script:RunAs
        Machine          = $env:COMPUTERNAME
        DrainCompletedAt = $null
        LastUpdated      = $null
        LogFile          = $script:LogFile
        StateFile        = $statePath
        SummaryFile      = $summary
        AGs              = $entries.ToArray()
    }

    if ($toMove.Count -gt 0) {
        if (-not (Confirm-Action "About to fail over $($toMove.Count) AG(s) off $node$(if($script:DryRun){' [DRY RUN]'}).")) {
            Write-Log -Level WARN -Message 'Cancelled by user. No changes made.'
            return
        }
    }

    try { Save-State -State $state -Path $statePath; Write-Log -Message "Original primaries recorded in $statePath" }
    catch { Write-ErrorDetail -ErrorRecord $_ -Step 'Write state file' -Server $node; Write-Log -Level ERROR -Message 'Aborting: without a state file failback cannot be automated.'; return }

    # ---- Execute -------------------------------------------------------------
    foreach ($e in $toMove) {
        $pick = $null
        try {
            # Re-check right before acting; state can change between plan and execution.
            $pick = Find-FailoverTarget -PrimaryServer $node -AGName $e.AGName -ExcludeReplica $node
            if (-not $pick.Target) {
                $e.Result = 'SKIPPED'; $e.Reason = "At execution time: $($pick.Reason)"
                Write-Log -Level WARN -Message "[$($e.AGName)] skipped: $($e.Reason)"
                continue
            }
            if ($pick.Target -ne $e.PlannedTarget) {
                Write-Log -Level WARN -Message "[$($e.AGName)] best target changed from $($e.PlannedTarget) to $($pick.Target)."
            }
            $e.Result       = Invoke-AGFailover -AGName $e.AGName -Target $pick.Target
            $e.FailedOverTo = $pick.Target
            $e.FailoverTime = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            if ($e.Result -eq 'FAILED_OVER') {
                $e.PostFailoverSync = Wait-AGResync -PrimaryServer $pick.Target -AGName $e.AGName
            }
            else { $e.PostFailoverSync = 'n/a (dry run)' }
        }
        catch {
            $e.Result = 'FAILED'
            $e.Reason = $_.Exception.Message
            Write-ErrorDetail -ErrorRecord $_ -Step 'Fail over AG (drain)' -Server $(if ($pick) { $pick.Target } else { $node }) -AGName $e.AGName
            Write-AGSnapshot -Server $node -AGName $e.AGName
        }
        finally {
            try { Save-State -State $state -Path $statePath } catch { Write-Log -Level WARN -Message "Could not update state file: $($_.Exception.Message)" }
        }
    }

    $failed = @($entries | Where-Object { $_.Result -in @('FAILED', 'SKIPPED') })
    $state.Status           = if ($failed.Count -eq 0) { 'DRAINED' } else { 'PARTIALLY_DRAINED' }
    $state.DrainCompletedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    try {
        Save-State -State $state -Path $statePath
        Write-DrainSummary -State $state
    }
    catch { Write-ErrorDetail -ErrorRecord $_ -Step 'Write state/summary file' -Server $node }

    Write-Log -Level STEP -Message "Result for $node :`n$(Format-Rows ($entries | Select-Object AGName, OriginalPrimary, FailedOverTo, Result, Reason))"
    Write-Log -Level SUCCESS -Message "Summary written to $summary"
    if ($failed.Count -gt 0) { Write-Log -Level WARN -Message "$($failed.Count) AG(s) are still on $node or could not be evaluated. Do NOT reboot until they are handled." }
}

# ----------------------------------------------------------------------------
# Option 2 - fail back
# ----------------------------------------------------------------------------
function Invoke-Failback {
    Write-Log -Level STEP -Message '===== OPTION 2: Fail back to original primaries ====='
    $startedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    $files = @(Get-ChildItem -Path $script:StateDir -Filter 'AGState_*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    $choices = New-Object System.Collections.Generic.List[object]
    foreach ($f in $files) {
        try {
            $s = Get-Content -Path $f.FullName -Raw | ConvertFrom-Json
            if ($s.Status -eq 'RESTORED') { continue }
            $choices.Add([pscustomobject]@{ File = $f.FullName; State = $s })
        }
        catch { Write-Log -Level WARN -Message "Unreadable state file skipped: $($f.Name) ($($_.Exception.Message))" }
    }
    if ($choices.Count -eq 0) { Write-Log -Level WARN -Message "No pending state files in $($script:StateDir). Run option 1 first."; return }

    Write-Host ''
    for ($i = 0; $i -lt $choices.Count; $i++) {
        $s = $choices[$i].State
        $n = @($s.AGs | Where-Object { $_.Result -in @('FAILED_OVER', 'DRYRUN') }).Count
        Write-Host ('  {0}. Node {1} | drained {2} | {3} | {4} AG(s) moved | status {5}' -f ($i + 1), $s.Node, $s.CreatedAt, $s.Mode, $n, $s.Status)
    }
    $sel = Read-Host "Select the activity to fail back (1-$($choices.Count))"
    $idx = 0
    if (-not [int]::TryParse($sel, [ref]$idx) -or $idx -lt 1 -or $idx -gt $choices.Count) { Write-Log -Level WARN -Message "Invalid selection '$sel'."; return }

    $statePath = $choices[$idx - 1].File
    $state     = $choices[$idx - 1].State
    Write-Log -Message "Using state file $statePath (node $($state.Node), drained $($state.CreatedAt))."

    $eligible = @('FAILED_OVER')
    if ($script:DryRun) { $eligible += 'DRYRUN' }
    $work = @($state.AGs | Where-Object { $_.Result -in $eligible })
    if ($work.Count -eq 0) { Write-Log -Level WARN -Message 'No AGs in this state file were failed over, nothing to fail back.'; return }

    # ---- Evaluate ------------------------------------------------------------
    $plan = New-Object System.Collections.Generic.List[object]
    foreach ($ag in $work) {
        $p = [pscustomobject]@{ Entry = $ag; Current = $null; Action = $null; Issue = $null; Suspended = @() }
        try {
            $current = $null
            foreach ($probe in @($ag.OriginalPrimary, $ag.FailedOverTo)) {
                if (-not $probe) { continue }
                try { $current = Get-AGPrimary -Server $probe -AGName $ag.AGName; if ($current) { break } }
                catch { Write-Log -Level WARN -Message "[$($ag.AGName)] could not query $probe for the current primary: $($_.Exception.Message)" }
            }
            if (-not $current) { throw "Could not determine the current primary of [$($ag.AGName)] from $($ag.OriginalPrimary) or $($ag.FailedOverTo)." }
            $p.Current = $current

            if ($current -eq $ag.OriginalPrimary) {
                $p.Action = 'ALREADY_PRIMARY'
            }
            else {
                $verOrig = (Get-ServerInfo -Server $ag.OriginalPrimary).ProductVersion
                $verCurr = (Get-ServerInfo -Server $current).ProductVersion
                if ([version]$verOrig -lt [version]$verCurr) {
                    $p.Action = 'BLOCKED'
                    $p.Issue  = "Version mismatch: original primary $($ag.OriginalPrimary) is on $verOrig but current primary $current is on $verCurr. A database cannot move back to a lower build - patch $($ag.OriginalPrimary) first."
                }
                else {
                    if ($verOrig -ne $verCurr) { Write-Log -Level WARN -Message "[$($ag.AGName)] versions differ: $($ag.OriginalPrimary)=$verOrig, $current=$verCurr (rolling patch in progress?)." }
                    $reps = Get-AGReplicas  -Server $current -AGName $ag.AGName
                    $dbs  = Get-AGDatabases -Server $current -AGName $ag.AGName
                    $rep  = @($reps | Where-Object { $_.ReplicaServer -eq $ag.OriginalPrimary })
                    if ($rep.Count -eq 0) {
                        $p.Action = 'BLOCKED'; $p.Issue = "$($ag.OriginalPrimary) is no longer a replica of [$($ag.AGName)]."
                    }
                    else {
                        $r = Get-ReplicaReadiness -Replica $rep[0] -Databases $dbs
                        $p.Suspended = @($r.Suspended)
                        $p.Action    = if ($r.Ready) { 'FAILBACK' } elseif ($r.Waitable -or $p.Suspended.Count -gt 0) { 'FAILBACK_AFTER_SYNC' } else { 'BLOCKED' }
                        if (-not $r.Ready) { $p.Issue = ($r.Reasons -join '; ') }
                    }
                }
            }
        }
        catch {
            Write-ErrorDetail -ErrorRecord $_ -Step 'Evaluate failback' -Server $ag.OriginalPrimary -AGName $ag.AGName
            $p.Action = 'BLOCKED'; $p.Issue = $_.Exception.Message
        }
        $plan.Add($p)
    }

    Write-Log -Level STEP -Message "Failback plan:`n$(Format-Rows ($plan | Select-Object @{n='AGName';e={$_.Entry.AGName}}, @{n='CurrentPrimary';e={$_.Current}}, @{n='ReturnTo';e={$_.Entry.OriginalPrimary}}, Action, Issue))"

    $actionable = @($plan | Where-Object { $_.Action -in @('FAILBACK', 'FAILBACK_AFTER_SYNC') })
    $resume = $false
    $suspendedAll = @($actionable | ForEach-Object { $_.Suspended } | Where-Object { $_ })
    if ($suspendedAll.Count -gt 0) {
        Write-Log -Level WARN -Message "Suspended data movement found on original primaries:`n$(Format-Rows ($suspendedAll | Select-Object ReplicaServer, DatabaseName, SuspendReason))"
        $ans = Read-Host 'Resume data movement on these databases before failback? (Y/N)'
        $resume = ($ans -match '^[Yy]')
        if (-not $resume) { Write-Log -Level WARN -Message 'User chose not to resume. AGs with suspended databases will be skipped.' }
    }

    if ($actionable.Count -gt 0) {
        if (-not (Confirm-Action "About to fail back $($actionable.Count) AG(s) to their original primaries$(if($script:DryRun){' [DRY RUN]'}).")) {
            Write-Log -Level WARN -Message 'Cancelled by user. No changes made.'
            return
        }
    }

    # ---- Execute -------------------------------------------------------------
    foreach ($p in $plan) {
        $ag = $p.Entry
        $ag.FailbackFrom = $p.Current
        try {
            switch ($p.Action) {
                'ALREADY_PRIMARY' {
                    $ag.FailbackResult = 'ALREADY_PRIMARY'
                    $ag.FailbackReason = "$($ag.OriginalPrimary) was already primary"
                    $ag.FailbackTime   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                    Write-Log -Level SUCCESS -Message "[$($ag.AGName)] already on original primary $($ag.OriginalPrimary)."
                }
                'BLOCKED' {
                    $ag.FailbackResult = 'BLOCKED'
                    $ag.FailbackReason = $p.Issue
                    Write-Log -Level ERROR -Message "[$($ag.AGName)] failback blocked: $($p.Issue)"
                }
                default {
                    if ($p.Suspended.Count -gt 0) {
                        if (-not $resume) {
                            $ag.FailbackResult = 'SKIPPED'
                            $ag.FailbackReason = 'Suspended data movement on original primary; user declined resume'
                            break
                        }
                        foreach ($d in $p.Suspended) {
                            $sql = "ALTER DATABASE $(Get-QuotedName $d.DatabaseName) SET HADR RESUME;"
                            if ($script:DryRun) { Write-Log -Level WARN -Message "[DRY RUN] Would run on $($ag.OriginalPrimary) : $sql"; continue }
                            Write-Log -Level STEP -Message "[$($ag.AGName)] Running on $($ag.OriginalPrimary) : $sql"
                            Invoke-Sql -Server $ag.OriginalPrimary -Query $sql -NonQuery
                        }
                    }

                    $pick = Find-FailoverTarget -PrimaryServer $p.Current -AGName $ag.AGName -OnlyReplica $ag.OriginalPrimary
                    if (-not $pick.Target -and -not $script:DryRun) {
                        $ag.FailbackResult = 'SKIPPED'
                        $ag.FailbackReason = $pick.Reason
                        Write-Log -Level ERROR -Message "[$($ag.AGName)] not failing back: $($pick.Reason)"
                        break
                    }
                    $ag.FailbackResult = Invoke-AGFailover -AGName $ag.AGName -Target $ag.OriginalPrimary
                    if ($ag.FailbackResult -eq 'FAILED_OVER') { $ag.FailbackResult = 'FAILED_BACK' }
                    $ag.FailbackTime   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                    $ag.FailbackReason = Wait-AGResync -PrimaryServer $ag.OriginalPrimary -AGName $ag.AGName
                }
            }
        }
        catch {
            $ag.FailbackResult = 'FAILED'
            $ag.FailbackReason = $_.Exception.Message
            Write-ErrorDetail -ErrorRecord $_ -Step 'Fail back AG' -Server $ag.OriginalPrimary -AGName $ag.AGName
            Write-AGSnapshot -Server $(if ($p.Current) { $p.Current } else { $ag.OriginalPrimary }) -AGName $ag.AGName
        }
        finally {
            try { Save-State -State $state -Path $statePath } catch { Write-Log -Level WARN -Message "Could not update state file: $($_.Exception.Message)" }
        }
    }

    $done = @($work | Where-Object { $_.FailbackResult -in @('FAILED_BACK', 'ALREADY_PRIMARY') })
    if (-not $script:DryRun) {
        $state.Status = if ($done.Count -eq $work.Count) { 'RESTORED' } else { 'PARTIALLY_RESTORED' }
    }
    try {
        Save-State -State $state -Path $statePath
        if (-not (Test-Path $state.SummaryFile)) { Set-Content -Path $state.SummaryFile -Value "AG failover summary for $($state.Node) (drain section unavailable)" -Encoding UTF8 }
        Add-FailbackSummary -State $state -StartedAt $startedAt
    }
    catch { Write-ErrorDetail -ErrorRecord $_ -Step 'Write state/summary file' -Server $state.Node }

    Write-Log -Level STEP -Message "Failback result:`n$(Format-Rows ($work | Select-Object AGName, FailbackFrom, OriginalPrimary, FailbackResult, FailbackReason))"
    Write-Log -Level SUCCESS -Message "Summary updated: $($state.SummaryFile)"
}

# ----------------------------------------------------------------------------
# Option 3 - health check
# ----------------------------------------------------------------------------
function Invoke-HealthCheck {
    Write-Log -Level STEP -Message '===== OPTION 3: AG health check ====='
    $nodeInput = (Read-Host 'Enter any SQL instance in the AG(s) (e.g. SQLVM01)').Trim()
    if (-not $nodeInput) { Write-Log -Level WARN -Message 'No server entered.'; return }

    try { $info = Get-ServerInfo -Server $nodeInput }
    catch { Write-ErrorDetail -ErrorRecord $_ -Step 'Connect for health check' -Server $nodeInput; return }
    try { $ags = Get-AGList -Server $info.ServerName -MajorVersion $info.MajorVersion }
    catch { Write-ErrorDetail -ErrorRecord $_ -Step 'List AGs' -Server $info.ServerName; return }

    $report = New-Object System.Text.StringBuilder
    [void]$report.AppendLine("AG HEALTH CHECK - started from $($info.ServerName) ($($info.ProductVersion)) at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') by $($script:RunAs)")
    [void]$report.AppendLine('')
    $verdicts = New-Object System.Collections.Generic.List[object]

    foreach ($ag in $ags) {
        $issues = New-Object System.Collections.Generic.List[string]
        $primary = $ag.PrimaryReplica
        [void]$report.AppendLine("===== AG [$($ag.AGName)] | cluster type $($ag.ClusterType) | primary $primary | AG health $($ag.AGHealth) =====")
        try {
            if (-not $primary) { throw "Primary replica unknown from $($info.ServerName) - this node may be disconnected from the primary." }
            $reps = Get-AGReplicas  -Server $primary -AGName $ag.AGName
            $dbs  = Get-AGDatabases -Server $primary -AGName $ag.AGName

            $versions = foreach ($r in $reps) {
                $v = 'unreachable'
                try { $v = (Get-ServerInfo -Server $r.ReplicaServer).ProductVersion } catch { $issues.Add("Cannot connect to $($r.ReplicaServer): $($_.Exception.Message)") }
                [pscustomobject]@{ ReplicaServer = $r.ReplicaServer; Version = $v }
            }
            $repView = $reps | ForEach-Object {
                $rs = $_.ReplicaServer
                $_ | Select-Object ReplicaServer, Role, AvailabilityMode, FailoverMode, ConnectedState, SyncHealth,
                                   @{n = 'Version'; e = { ($versions | Where-Object { $_.ReplicaServer -eq $rs }).Version } }
            }
            [void]$report.AppendLine((Format-Rows $repView))
            [void]$report.AppendLine('')
            [void]$report.AppendLine((Format-Rows ($dbs | Select-Object ReplicaServer, DatabaseName, SyncState, SyncHealth, IsSuspended, SuspendReason, LogSendQueueKB, RedoQueueKB, IsFailoverReady, LastCommitTime)))

            foreach ($r in $reps) {
                if ($r.ConnectedState -ne 'CONNECTED') { $issues.Add("$($r.ReplicaServer) is $($r.ConnectedState)$(if($r.LastConnectError){' - ' + $r.LastConnectError})") }
                if ($r.SyncHealth -ne 'HEALTHY')        { $issues.Add("$($r.ReplicaServer) sync health is $($r.SyncHealth)") }
            }
            foreach ($d in $dbs) {
                $rep = $reps | Where-Object { $_.ReplicaServer -eq $d.ReplicaServer } | Select-Object -First 1
                if ($d.IsSuspended) { $issues.Add("$($d.ReplicaServer)/$($d.DatabaseName) data movement SUSPENDED ($($d.SuspendReason)) - resume with ALTER DATABASE [$($d.DatabaseName)] SET HADR RESUME on that replica after fixing the cause") }
                elseif ($rep -and $rep.Role -eq 'SECONDARY' -and $rep.AvailabilityMode -eq 'SYNCHRONOUS_COMMIT' -and $d.SyncState -ne 'SYNCHRONIZED') { $issues.Add("$($d.ReplicaServer)/$($d.DatabaseName) is $($d.SyncState) on a synchronous replica") }
                if (([double]$d.LogSendQueueKB + [double]$d.RedoQueueKB) -gt $Config.QueueWarnKB) { $issues.Add("$($d.ReplicaServer)/$($d.DatabaseName) has $([math]::Round(([double]$d.LogSendQueueKB + [double]$d.RedoQueueKB)/1024,1)) MB queued") }
            }
            $distinctVer = @($versions | Where-Object { $_.Version -ne 'unreachable' } | Select-Object -ExpandProperty Version -Unique)
            if ($distinctVer.Count -gt 1) { $issues.Add("Replicas run different builds: $(($versions | ForEach-Object { "$($_.ReplicaServer)=$($_.Version)" }) -join ', ')") }
            $syncSec = @($reps | Where-Object { $_.Role -eq 'SECONDARY' -and $_.AvailabilityMode -eq 'SYNCHRONOUS_COMMIT' })
            if ($syncSec.Count -eq 0) { $issues.Add('No synchronous secondary - a planned no-data-loss failover is not possible') }
        }
        catch {
            Write-ErrorDetail -ErrorRecord $_ -Step 'Health check' -Server $primary -AGName $ag.AGName
            $issues.Add("Health check error: $($_.Exception.Message)")
        }

        $verdict = if ($issues.Count -eq 0) { 'HEALTHY' } else { 'ATTENTION' }
        [void]$report.AppendLine('')
        [void]$report.AppendLine("Verdict: $verdict")
        foreach ($i in $issues) { [void]$report.AppendLine("  - $i") }
        [void]$report.AppendLine('')
        $verdicts.Add([pscustomobject]@{ AGName = $ag.AGName; Primary = $primary; Verdict = $verdict; Issues = $issues.Count })
    }

    [void]$report.AppendLine('===== OVERALL =====')
    [void]$report.AppendLine((Format-Rows $verdicts))

    $path = Join-Path $script:SummaryDir "AG_HealthCheck_$(Get-SafeName $info.ServerName)_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    try { Set-Content -Path $path -Value $report.ToString() -Encoding UTF8 } catch { Write-ErrorDetail -ErrorRecord $_ -Step 'Write health report' }
    Write-Host $report.ToString()
    Write-Log -Message $report.ToString() -NoConsole
    Write-Log -Level SUCCESS -Message "Health report written to $path"
}

# ----------------------------------------------------------------------------
# Option 5 - rolling reboot of every VM in the cluster
# ----------------------------------------------------------------------------
$script:OsCredential        = $null
$script:RollingAutoContinue = $false

function ConvertTo-Stamp([datetime]$Date) { $Date.ToString('yyyy-MM-dd HH:mm:ss') }
function ConvertFrom-Stamp([string]$Text) { [datetime]::ParseExact($Text, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) }

function Add-Item {
    # Appends to an array property; works on objects loaded back from JSON too.
    param($Object, [string]$Property, $Item)
    $current = @($Object.$Property | Where-Object { $null -ne $_ })
    $Object.$Property = @($current + @($Item))
}

function Read-Choice {
    param([string]$Prompt, [string[]]$Allowed)
    while ($true) {
        $a = (Read-Host $Prompt).Trim().ToUpper()
        if ($Allowed -contains $a) { return $a }
        Write-Host "Please enter one of: $($Allowed -join ', ')" -ForegroundColor Yellow
    }
}

function Test-TcpPort {
    param([string]$Computer, [int]$Port, [int]$TimeoutMs = 3000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($Computer, $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs) -and $client.Connected) { $client.EndConnect($iar); return $true }
        return $false
    }
    catch { return $false }
    finally { $client.Close() }
}

function Get-ClusterMembers {
    param([string]$Server)
    $q = @"
SELECT  c.cluster_name                          AS ClusterName,
        m.member_name                           AS MemberName,
        m.member_type_desc                      AS MemberType,
        m.member_state_desc                     AS MemberState,
        ISNULL(m.number_of_quorum_votes, 0)     AS Votes
FROM    sys.dm_hadr_cluster_members m
CROSS JOIN sys.dm_hadr_cluster c;
"@
    return @(Invoke-Sql -Server $Server -Query $q)
}

function Get-AGHealth {
    param([string]$Server, [string]$AGName)
    $q = @"
SELECT ags.synchronization_health_desc AS Health
FROM   sys.availability_groups ag
JOIN   sys.dm_hadr_availability_group_states ags ON ags.group_id = ag.group_id
WHERE  ag.name = @AGName;
"@
    $r = @(Invoke-Sql -Server $Server -Query $q -Parameters @{ AGName = $AGName })
    if ($r.Count -gt 0) { return $r[0].Health }
    return 'UNKNOWN'
}

function Get-LocalSqlInstances {
    $list = @()
    foreach ($svc in @(Get-Service -Name 'MSSQLSERVER', 'MSSQL$*' -ErrorAction SilentlyContinue)) {
        if ($svc.Status -ne 'Running') { Write-Log -Level WARN -Message "Local SQL service $($svc.Name) is $($svc.Status) - ignored."; continue }
        if ($svc.Name -eq 'MSSQLSERVER') { $list += $env:COMPUTERNAME }
        else { $list += "$env:COMPUTERNAME\$($svc.Name.Substring(6))" }
    }
    return $list
}

function Get-RollingTopology {
    <#
      Walks the AGs: connects to each seed instance, reads its AGs and replicas,
      then connects to every replica found, until no new instance turns up.
      Probes (VM names) are tried as default instances; failures there are quiet.
    #>
    param([string[]]$Seeds, [string[]]$Probes)
    $todo = New-Object System.Collections.Generic.Queue[object]
    foreach ($s in $Seeds)  { if ($s) { $todo.Enqueue([pscustomobject]@{ Name = $s; Probe = $false }) } }
    foreach ($p in $Probes) { if ($p) { $todo.Enqueue([pscustomobject]@{ Name = $p; Probe = $true }) } }

    $tried = @{}; $instances = @{}; $ags = @{}
    while ($todo.Count -gt 0) {
        $item = $todo.Dequeue()
        if ($tried.ContainsKey($item.Name)) { continue }
        $tried[$item.Name] = $true
        try { $info = Get-ServerInfo -Server $item.Name }
        catch {
            if ($item.Probe) { Write-Log -Level DETAIL -Message "No default SQL instance answered on $($item.Name) ($($_.Exception.Message))" -NoConsole }
            else { Write-Log -Level WARN -Message "Could not connect to $($item.Name): $($_.Exception.Message)" }
            continue
        }
        $name = $info.ServerName
        $tried[$name] = $true
        if ($instances.ContainsKey($name)) { continue }
        $instances[$name] = [pscustomobject]@{
            Instance     = $name
            VM           = $info.PhysicalName
            Version      = $info.ProductVersion
            MajorVersion = $info.MajorVersion
            HadrEnabled  = $info.IsHadrEnabled
        }
        Write-Log -Message "Found instance $name on VM $($info.PhysicalName) ($($info.ProductVersion))."
        if ($info.IsHadrEnabled -ne 1) { continue }

        try { $list = Get-AGList -Server $name -MajorVersion $info.MajorVersion }
        catch { Write-ErrorDetail -ErrorRecord $_ -Step 'Discover AGs' -Server $name; continue }

        foreach ($ag in $list) {
            if (-not $ags.ContainsKey($ag.AGName)) {
                $ags[$ag.AGName] = [pscustomobject]@{ AGName = $ag.AGName; ClusterType = $ag.ClusterType; IsDistributed = [bool]$ag.IsDistributed; Primary = $ag.PrimaryReplica; Replicas = @() }
            }
            elseif (-not $ags[$ag.AGName].Primary -and $ag.PrimaryReplica) { $ags[$ag.AGName].Primary = $ag.PrimaryReplica }
            if ($ag.IsDistributed) { continue }   # members of a distributed AG are AGs, not instances
            try {
                $reps = @(Get-AGReplicas -Server $name -AGName $ag.AGName)
                $ags[$ag.AGName].Replicas = @(@($ags[$ag.AGName].Replicas) + @($reps | ForEach-Object { $_.ReplicaServer }) | Select-Object -Unique)
                foreach ($r in $reps) { $todo.Enqueue([pscustomobject]@{ Name = $r.ReplicaServer; Probe = $false }) }
            }
            catch { Write-Log -Level WARN -Message "Could not read replicas of [$($ag.AGName)] from $name : $($_.Exception.Message)" }
        }
    }
    return [pscustomobject]@{ Instances = @($instances.Values); AGs = @($ags.Values) }
}

function Get-CurrentPrimary {
    param($AG)
    $candidates = @(@($AG.OriginalPrimary) + @($AG.Replicas) | Where-Object { $_ } | Select-Object -Unique)
    foreach ($c in $candidates) {
        try {
            $p = Get-AGPrimary -Server $c -AGName $AG.AGName
            if ($p) { return $p }
        }
        catch { Write-Log -Level DETAIL -Message "[$($AG.AGName)] $c not reachable for primary lookup: $($_.Exception.Message)" -NoConsole }
    }
    return $null
}

function Invoke-ReturnAG {
    # Planned failover of one AG back to its original primary, with all safety checks.
    param([string]$AGName, [string]$OriginalPrimary, [string]$CurrentPrimary)
    $res = [pscustomobject]@{ AGName = $AGName; From = $CurrentPrimary; To = $OriginalPrimary; Result = $null; Note = $null; Time = $null }
    try {
        if (-not $CurrentPrimary) { $res.Result = 'BLOCKED'; $res.Note = 'Current primary could not be determined'; return $res }
        if ($CurrentPrimary -eq $OriginalPrimary) { $res.Result = 'ALREADY_PRIMARY'; return $res }

        $verOrig = (Get-ServerInfo -Server $OriginalPrimary).ProductVersion
        $verCurr = (Get-ServerInfo -Server $CurrentPrimary).ProductVersion
        if ([version]$verOrig -lt [version]$verCurr) {
            $res.Result = 'BLOCKED'
            $res.Note   = "Version mismatch: $OriginalPrimary is on $verOrig, current primary $CurrentPrimary is on $verCurr. Cannot move back to a lower build - patch $OriginalPrimary first."
            Write-Log -Level ERROR -Message "[$AGName] $($res.Note)"
            return $res
        }
        $pick = Find-FailoverTarget -PrimaryServer $CurrentPrimary -AGName $AGName -OnlyReplica $OriginalPrimary
        if (-not $pick.Target) {
            $res.Result = 'BLOCKED'; $res.Note = $pick.Reason
            Write-Log -Level ERROR -Message "[$AGName] not returned to $OriginalPrimary : $($pick.Reason)"
            return $res
        }
        $r = Invoke-AGFailover -AGName $AGName -Target $OriginalPrimary
        $res.Result = if ($r -eq 'FAILED_OVER') { 'RETURNED' } else { $r }
        $res.Time   = ConvertTo-Stamp (Get-Date)
        if ($r -eq 'FAILED_OVER') { $res.Note = Wait-AGResync -PrimaryServer $OriginalPrimary -AGName $AGName }
    }
    catch {
        $res.Result = 'FAILED'; $res.Note = $_.Exception.Message
        Write-ErrorDetail -ErrorRecord $_ -Step 'Return AG to original primary' -Server $OriginalPrimary -AGName $AGName
        Write-AGSnapshot -Server $(if ($CurrentPrimary) { $CurrentPrimary } else { $OriginalPrimary }) -AGName $AGName
    }
    return $res
}

function Invoke-VMReboot {
    param([string]$Computer)
    $ErrorActionPreference = 'Continue'   # native stderr must not become a terminating error
    $script:LastSql = $null
    $comment = 'AGFailoverTool rolling reboot'
    if ($script:DryRun) { Write-Log -Level WARN -Message "[DRY RUN] Would run: shutdown /r /t 0 /m \\$Computer"; return }

    if ($script:OsCredential) {
        Write-Log -Level STEP -Message "Rebooting $Computer through WinRM as $($script:OsCredential.UserName): shutdown /r /t 0"
        $rc = Invoke-Command -ComputerName $Computer -Credential $script:OsCredential -ErrorAction Stop -ArgumentList $comment -ScriptBlock {
            param($c)
            & shutdown.exe /r /t 0 /d p:4:1 /c $c 2>&1 | Out-Null
            $LASTEXITCODE
        }
        if ($rc -is [int] -and $rc -ne 0) { throw "shutdown /r /t 0 on $Computer exited with code $rc. 1190/1115 = a shutdown is already scheduled or in progress; 5 = the credential is not local admin on $Computer." }
        return
    }

    Write-Log -Level STEP -Message "Rebooting $Computer : shutdown /r /t 0 /m \\$Computer (as $($script:RunAs))"
    $out = & shutdown.exe /r /t 0 /m "\\$Computer" /d p:4:1 /c $comment 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        $hint = switch ($code) {
            5    { "Access denied: $($script:RunAs) is not local admin on $Computer (or lacks 'Force shutdown from a remote system'). Restart option 5 and choose C to enter an admin credential (uses WinRM)." }
            53   { "Network path not found: $Computer did not resolve, or the firewall blocks remote shutdown (allow the 'Remote Shutdown' / 'Windows Management Instrumentation' rules or SMB/RPC from this VM)." }
            1115 { 'A shutdown is already in progress on that VM.' }
            1190 { 'A shutdown is already scheduled on that VM.' }
            default { 'See "net helpmsg <code>" for the meaning of the exit code.' }
        }
        throw "shutdown /r /t 0 /m \\$Computer failed with exit code $code. Output: $(($out | Out-String).Trim()). $hint"
    }
}

function Test-RollingGates {
    # Returns GO, SKIP or STOP.
    param($Run, $VM, [string[]]$InstOnVM)
    $issues = New-Object System.Collections.Generic.List[string]

    $members = $null
    $probeOrder = @(@($Run.Instances | Where-Object { $_.VM -ne $VM.VM }) + @($Run.Instances | Where-Object { $_.VM -eq $VM.VM }))
    foreach ($i in $probeOrder) {
        try { $members = @(Get-ClusterMembers -Server $i.Instance); if ($members.Count -gt 0) { break } }
        catch { Write-Log -Level DETAIL -Message "Cluster membership not readable from $($i.Instance): $($_.Exception.Message)" -NoConsole }
    }
    if ($members -and $members.Count -gt 0) {
        $nodes = @($members | Where-Object { $_.MemberType -eq 'CLUSTER_NODE' })
        $down  = @($nodes | Where-Object { $_.MemberName -ne $VM.VM -and $_.MemberState -ne 'UP' })
        if ($down.Count -gt 0) { $issues.Add("Other cluster node(s) not UP: $(($down | ForEach-Object { "$($_.MemberName)=$($_.MemberState)" }) -join ', '). Rebooting $($VM.VM) now could take the cluster down.") }
        $witnessDown = @($members | Where-Object { $_.MemberType -ne 'CLUSTER_NODE' -and $_.MemberState -ne 'UP' })
        if ($witnessDown.Count -gt 0) { $issues.Add("Quorum witness not UP: $(($witnessDown | ForEach-Object { "$($_.MemberName) ($($_.MemberType))=$($_.MemberState)" }) -join ', ').") }

        $me = @($nodes | Where-Object { $_.MemberName -eq $VM.VM })
        if ($me.Count -gt 0) {
            $total = [double](($members | Measure-Object -Property Votes -Sum).Sum)
            $up    = [double](($members | Where-Object { $_.MemberState -eq 'UP' } | Measure-Object -Property Votes -Sum).Sum)
            $mine  = [double](($me | Measure-Object -Property Votes -Sum).Sum)
            if ($total -gt 0 -and ($up - $mine) -le ($total / 2)) {
                $issues.Add("Quorum risk: $($up - $mine) of $total votes would remain while $($VM.VM) is down (more than half needed). Check node votes and the cloud witness.")
            }
        }
    }
    else { $issues.Add('Could not read cluster membership / quorum from any instance.') }

    foreach ($ag in @($Run.AGs | Where-Object { -not $_.Handled -and -not $_.IsDistributed })) {
        $p = Get-CurrentPrimary -AG $ag
        if ($p -and $InstOnVM -contains $p) { $issues.Add("AG [$($ag.AGName)] ($($ag.Note)) has its primary on $($VM.VM) and cannot be failed over by this tool - its databases will be offline during the reboot.") }
    }
    foreach ($inst in $InstOnVM) {
        try { [void](Get-ServerInfo -Server $inst) }
        catch { $issues.Add("Instance $inst on $($VM.VM) is not reachable before the reboot: $($_.Exception.Message)") }
    }

    if ($issues.Count -eq 0) { Write-Log -Level SUCCESS -Message "Pre-reboot checks passed for $($VM.VM)."; return 'GO' }

    Write-Log -Level ERROR -Message "Pre-reboot checks for $($VM.VM) found problems:`n  - $($issues -join "`n  - ")"
    $a = Read-Choice "[S]kip $($VM.VM) / [O]verride and continue anyway / [Q]uit (resume later with option 5)" @('S', 'O', 'Q')
    if ($a -eq 'O') { Write-Log -Level WARN -Message "Operator overrode the pre-reboot checks for $($VM.VM)."; Add-VMNote -VM $VM -Note 'Pre-reboot checks overridden by operator'; return 'GO' }
    if ($a -eq 'S') { return 'SKIP' }
    return 'STOP'
}

function Add-VMNote {
    param($VM, [string]$Note)
    if ($VM.Notes) { $VM.Notes = "$($VM.Notes); $Note" } else { $VM.Notes = $Note }
}

function Invoke-RollingDrain {
    # Fails over every AG whose primary is on the VM. Returns $true when nothing is left on it.
    param($Run, $VM, [string[]]$InstOnVM)
    $complete = $true
    foreach ($inst in $InstOnVM) {
        try {
            $info = Get-ServerInfo -Server $inst
            $ags  = @(Get-AGList -Server $inst -MajorVersion $info.MajorVersion | Where-Object { $_.LocalRole -eq 'PRIMARY' -and -not $_.IsDistributed })
        }
        catch {
            Write-ErrorDetail -ErrorRecord $_ -Step 'List primaries to drain' -Server $inst
            $complete = $false; continue
        }
        foreach ($ag in $ags) {
            $move = [pscustomobject]@{ AGName = $ag.AGName; From = $inst; To = $null; Result = $null; Note = $null; Time = $null }
            $pick = $null
            try {
                if ($ag.ClusterType -ne 'WSFC') { throw "CLUSTER_TYPE $($ag.ClusterType) - planned failover not supported by this tool." }
                $pick = Find-FailoverTarget -PrimaryServer $inst -AGName $ag.AGName -ExcludeReplica $InstOnVM
                if (-not $pick.Target) {
                    $move.Result = 'SKIPPED'; $move.Note = $pick.Reason; $complete = $false
                    Write-Log -Level ERROR -Message "[$($ag.AGName)] cannot be moved off $($VM.VM): $($pick.Reason)"
                }
                else {
                    $move.To     = $pick.Target
                    $move.Result = Invoke-AGFailover -AGName $ag.AGName -Target $pick.Target
                    $move.Time   = ConvertTo-Stamp (Get-Date)
                    if ($move.Result -eq 'FAILED_OVER') { $move.Note = Wait-AGResync -PrimaryServer $pick.Target -AGName $ag.AGName }
                }
            }
            catch {
                $move.Result = 'FAILED'; $move.Note = $_.Exception.Message; $complete = $false
                Write-ErrorDetail -ErrorRecord $_ -Step "Drain $($VM.VM)" -Server $(if ($pick -and $pick.Target) { $pick.Target } else { $inst }) -AGName $ag.AGName
                Write-AGSnapshot -Server $inst -AGName $ag.AGName
            }
            Add-Item -Object $VM -Property 'Moves' -Item $move
            Save-Rolling -Run $Run
        }
    }
    return $complete
}

function Wait-VMOnline {
    # Returns OK, NOT_REBOOTED (operator chose to continue), SKIP_RETURN or STOP.
    param($Run, $VM)
    if ($script:DryRun) { Write-Log -Level WARN -Message "[DRY RUN] Would wait for $($VM.VM) to reboot and SQL to start."; return 'OK' }

    $before   = @($VM.SqlStartBefore | Where-Object { $_ })
    $start    = Get-Date
    $upBy     = $start.AddSeconds($Config.RebootUpTimeoutSec)
    $downBy   = $start.AddSeconds($Config.RebootDownTimeoutSec)
    $wentDown = [bool]$VM.IsLocal   # for the local VM the tool was not running during the reboot
    $lastLog  = [datetime]::MinValue
    Write-Log -Message "Waiting for $($VM.VM) to come back (up to $([int]($Config.RebootUpTimeoutSec/60)) min)..."

    while ($true) {
        $states = @(); $upCount = 0; $notRestarted = 0
        if ($before.Count -eq 0) {
            $rdp = Test-TcpPort -Computer $VM.VM -Port 3389
            if (-not $rdp) { $wentDown = $true }
            elseif ($wentDown) { Write-Log -Level SUCCESS -Message "$($VM.VM) is back (RDP port answering)."; return 'OK' }
            $states += "RDP port 3389 $(if ($rdp) { 'open' } else { 'closed' })"
        }
        else {
            foreach ($b in $before) {
                try {
                    $i = Get-ServerInfo -Server $b.Instance
                    $nowStart = ConvertFrom-Stamp (ConvertTo-Stamp ([datetime]$i.SqlStartTime))
                    if ($nowStart -gt (ConvertFrom-Stamp $b.StartTime)) { $upCount++; $wentDown = $true; $states += "$($b.Instance): SQL started $(ConvertTo-Stamp $nowStart)" }
                    else { $notRestarted++; $states += "$($b.Instance): still running since $($b.StartTime) (not restarted)" }
                }
                catch { $wentDown = $true; $states += "$($b.Instance): not reachable yet" }
            }
            if ($upCount -eq $before.Count) {
                Write-Log -Level SUCCESS -Message "$($VM.VM) is back: $($states -join '; ')"
                return 'OK'
            }
        }

        if ($VM.IsLocal -and $before.Count -gt 0 -and $notRestarted -eq $before.Count) {
            Write-Log -Level WARN -Message "$($VM.VM) (this VM) has not been rebooted since it was drained: $($states -join '; ')"
            $a = Read-Choice '[W]ait and re-check / [C]ontinue without the reboot (return its AGs anyway) / [Q]uit (reboot this VM, then run option 5 again)' @('W', 'C', 'Q')
            if ($a -eq 'C') { return 'NOT_REBOOTED' }
            if ($a -eq 'Q') { return 'STOP' }
            Start-Sleep -Seconds $Config.RebootPollSec
            continue
        }

        if (-not $wentDown -and (Get-Date) -gt $downBy) {
            Write-Log -Level ERROR -Message "$($VM.VM) did not go down within $([int]($Config.RebootDownTimeoutSec/60)) min of the reboot command: $($states -join '; ')"
            $a = Read-Choice '[R]esend the reboot command / [W]ait longer / [B]ring its AGs back and skip this VM / [Q]uit' @('R', 'W', 'B', 'Q')
            if ($a -eq 'R') {
                try { Invoke-VMReboot -Computer $VM.VM; $VM.RebootSentAt = ConvertTo-Stamp (Get-Date) }
                catch { Write-ErrorDetail -ErrorRecord $_ -Step "Resend reboot to $($VM.VM)" -Server $VM.VM }
            }
            elseif ($a -eq 'B') { return 'SKIP_RETURN' }
            elseif ($a -eq 'Q') { return 'STOP' }
            $downBy = (Get-Date).AddSeconds($Config.RebootDownTimeoutSec)
            continue
        }

        if ((Get-Date) -gt $upBy) {
            Write-Log -Level ERROR -Message "$($VM.VM) is not fully back after $([int](((Get-Date) - $start).TotalMinutes)) min: $($states -join '; '). Check the VM in the Azure portal (boot diagnostics / serial console) - Windows updates may still be applying."
            $a = Read-Choice "[W]ait $([int]($Config.RebootUpTimeoutSec/60)) more minutes / [C]ontinue anyway / [Q]uit (resume later with option 5)" @('W', 'C', 'Q')
            if ($a -eq 'C') { return 'NOT_REBOOTED' }
            if ($a -eq 'Q') { return 'STOP' }
            $upBy = (Get-Date).AddSeconds($Config.RebootUpTimeoutSec)
            continue
        }

        if (((Get-Date) - $lastLog).TotalSeconds -ge 60) {
            Write-Log -Message "  ...$($VM.VM) after $([int](((Get-Date) - $start).TotalMinutes)) min: $($states -join '; ')"
            $lastLog = Get-Date
        }
        Start-Sleep -Seconds $Config.RebootPollSec
    }
}

function Wait-VMReplicasSynced {
    # Waits until every replica on the VM is connected and caught up.
    # Returns @{ Stop = bool; NotReady = AG names that are still not synchronized }.
    param($Run, $VM, [string[]]$InstOnVM)
    $result = [pscustomobject]@{ Stop = $false; NotReady = @() }
    if ($script:DryRun) { return $result }

    $ags = @($Run.AGs | Where-Object { $agR = @($_.Replicas); $_.Handled -and @($InstOnVM | Where-Object { $agR -contains $_ }).Count -gt 0 })
    if ($ags.Count -eq 0) { return $result }

    Write-Log -Message "Waiting for replicas on $($VM.VM) to re-sync (up to $([int]($Config.RebootSyncWaitSec/60)) min)..."
    $start = Get-Date; $deadline = $start.AddSeconds($Config.RebootSyncWaitSec); $lastLog = [datetime]::MinValue
    $resumeAsked = $false; $declined = @()

    while ($true) {
        $notReady = [ordered]@{}; $suspended = @()
        foreach ($ag in $ags) {
            if ($declined -contains $ag.AGName) { $notReady[$ag.AGName] = 'data movement suspended (resume declined)'; continue }
            try {
                $p = Get-CurrentPrimary -AG $ag
                if (-not $p) { $notReady[$ag.AGName] = 'primary not known yet'; continue }
                $reps = @(Get-AGReplicas  -Server $p -AGName $ag.AGName)
                $dbs  = @(Get-AGDatabases -Server $p -AGName $ag.AGName)
                foreach ($inst in $InstOnVM) {
                    if ($inst -eq $p) { continue }
                    $rep = $reps | Where-Object { $_.ReplicaServer -eq $inst } | Select-Object -First 1
                    if (-not $rep) { continue }
                    if ($rep.ConnectedState -ne 'CONNECTED') { $notReady[$ag.AGName] = "$inst is $($rep.ConnectedState)"; continue }
                    foreach ($d in @($dbs | Where-Object { $_.ReplicaServer -eq $inst })) {
                        if ($d.IsSuspended) {
                            $suspended += [pscustomobject]@{ AGName = $ag.AGName; Instance = $inst; DatabaseName = $d.DatabaseName; SuspendReason = $d.SuspendReason }
                            $notReady[$ag.AGName] = "$inst/$($d.DatabaseName) SUSPENDED ($($d.SuspendReason))"
                        }
                        elseif ($rep.AvailabilityMode -eq 'SYNCHRONOUS_COMMIT' -and $d.SyncState -ne 'SYNCHRONIZED') {
                            $notReady[$ag.AGName] = "$inst/$($d.DatabaseName) is $($d.SyncState) (redo queue $($d.RedoQueueKB) KB)"
                        }
                        elseif ($rep.AvailabilityMode -ne 'SYNCHRONOUS_COMMIT' -and $d.SyncState -notin @('SYNCHRONIZING', 'SYNCHRONIZED')) {
                            $notReady[$ag.AGName] = "$inst/$($d.DatabaseName) is $($d.SyncState)"
                        }
                    }
                }
            }
            catch { $notReady[$ag.AGName] = "check failed: $($_.Exception.Message)" }
        }

        if ($suspended.Count -gt 0 -and -not $resumeAsked) {
            $resumeAsked = $true
            Write-Log -Level WARN -Message "Suspended data movement on $($VM.VM) after the reboot:`n$(Format-Rows ($suspended | Select-Object AGName, Instance, DatabaseName, SuspendReason))"
            $ans = Read-Host 'Resume data movement on these databases? (Y/N)'
            if ($ans -match '^[Yy]') {
                foreach ($s in $suspended) {
                    $sql = "ALTER DATABASE $(Get-QuotedName $s.DatabaseName) SET HADR RESUME;"
                    try { Write-Log -Level STEP -Message "Running on $($s.Instance) : $sql"; Invoke-Sql -Server $s.Instance -Query $sql -NonQuery }
                    catch { Write-ErrorDetail -ErrorRecord $_ -Step 'Resume data movement' -Server $s.Instance -AGName $s.AGName }
                }
            }
            else { $declined += @($suspended | ForEach-Object { $_.AGName } | Select-Object -Unique) }
            continue
        }

        if ($notReady.Count -eq 0) {
            Write-Log -Level SUCCESS -Message "All replicas on $($VM.VM) are connected and synchronized."
            return $result
        }

        if ((Get-Date) -gt $deadline) {
            Write-Log -Level WARN -Message "Replicas on $($VM.VM) still not synchronized:`n  - $(($notReady.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" }) -join "`n  - ")"
            $a = Read-Choice "[W]ait $([int]($Config.RebootSyncWaitSec/60)) more minutes / [C]ontinue (these AGs are not returned now; the final rebalance retries them) / [Q]uit (resume later with option 5)" @('W', 'C', 'Q')
            if ($a -eq 'C') { $result.NotReady = @($notReady.Keys); return $result }
            if ($a -eq 'Q') { $result.Stop = $true; return $result }
            $deadline = (Get-Date).AddSeconds($Config.RebootSyncWaitSec)
            continue
        }

        if (((Get-Date) - $lastLog).TotalSeconds -ge 60) {
            Write-Log -Message "  ...re-sync after $([int](((Get-Date) - $start).TotalMinutes)) min: $(($notReady.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" }) -join '; ')"
            $lastLog = Get-Date
        }
        Start-Sleep -Seconds $Config.RebootPollSec
    }
}

function Invoke-RollingReturnStep {
    # Returns the AGs whose pre-snapshot primary is on this VM. Returns the number of problems.
    param($Run, $VM, [string[]]$NotReady = @())
    $problems = 0
    foreach ($ag in @($Run.AGs | Where-Object { $_.Handled -and $_.OriginalPrimaryVM -eq $VM.VM })) {
        $wasMoved = @($VM.Moves | Where-Object { $_ -and $_.AGName -eq $ag.AGName }).Count -gt 0
        if ($script:DryRun) {
            if ($wasMoved) {
                Write-Log -Level WARN -Message "[DRY RUN] Would return [$($ag.AGName)] to $($ag.OriginalPrimary)."
                Add-Item -Object $VM -Property 'Returns' -Item ([pscustomobject]@{ AGName = $ag.AGName; From = $null; To = $ag.OriginalPrimary; Result = 'DRYRUN'; Note = $null; Time = $null })
            }
            continue
        }
        if ($NotReady -contains $ag.AGName) {
            $problems++
            Add-Item -Object $VM -Property 'Returns' -Item ([pscustomobject]@{ AGName = $ag.AGName; From = $null; To = $ag.OriginalPrimary; Result = 'NOT_SYNCED'; Note = 'Not synchronized after the reboot - final rebalance will retry'; Time = $null })
            continue
        }
        $r = Invoke-ReturnAG -AGName $ag.AGName -OriginalPrimary $ag.OriginalPrimary -CurrentPrimary (Get-CurrentPrimary -AG $ag)
        if ($r.Result -ne 'ALREADY_PRIMARY' -or $wasMoved) { Add-Item -Object $VM -Property 'Returns' -Item $r }
        if ($r.Result -notin @('RETURNED', 'ALREADY_PRIMARY')) { $problems++ }
        Save-Rolling -Run $Run
    }
    return $problems
}

function Invoke-RollingVM {
    # Runs (or resumes) one VM. Returns NEXT, STOP or LOCAL_PENDING.
    param($Run, $VM)
    $instOnVM = @($VM.Instances | Where-Object { $_ })
    Write-Log -Level STEP -Message "========== VM $($VM.Order) of $(@($Run.VMs).Count): $($VM.VM)$(if ($VM.IsLocal) { ' (this VM - manual reboot)' }) | instances: $(if ($instOnVM.Count) { $instOnVM -join ', ' } else { 'none found' }) =========="

    if ($VM.Status -eq 'PENDING') { $VM.Status = 'IN_PROGRESS'; $VM.Step = 'DRAIN'; Save-Rolling -Run $Run }
    if ($VM.Status -eq 'AWAITING_MANUAL_REBOOT') { $VM.Status = 'IN_PROGRESS' }

    # ---- 1. checks + drain -------------------------------------------------------
    if ($VM.Step -eq 'DRAIN') {
        $gate = Test-RollingGates -Run $Run -VM $VM -InstOnVM $instOnVM
        if ($gate -eq 'STOP') { $VM.Status = 'PENDING'; $VM.Step = $null; return 'STOP' }
        if ($gate -eq 'SKIP') { $VM.Status = 'SKIPPED'; Add-VMNote -VM $VM -Note 'Skipped: pre-reboot checks failed'; return 'NEXT' }

        $VM.SqlStartBefore = @(foreach ($inst in $instOnVM) {
                try { [pscustomobject]@{ Instance = $inst; StartTime = ConvertTo-Stamp ([datetime](Get-ServerInfo -Server $inst).SqlStartTime) } }
                catch { Write-Log -Level WARN -Message "Could not read SQL start time of $inst : $($_.Exception.Message)" }
            })

        $complete = Invoke-RollingDrain -Run $Run -VM $VM -InstOnVM $instOnVM
        if (-not $complete) {
            Write-Log -Level ERROR -Message "Not every AG could be moved off $($VM.VM). It will NOT be rebooted while it still hosts primaries."
            $a = Read-Choice "[B]ring the moved AGs back and skip $($VM.VM) / [Q]uit and leave things as they are (resume later with option 5)" @('B', 'Q')
            if ($a -eq 'Q') { return 'STOP' }
            [void](Invoke-RollingReturnStep -Run $Run -VM $VM)
            $VM.Status = 'SKIPPED'; Add-VMNote -VM $VM -Note 'Skipped: drain incomplete, moved AGs returned'
            return 'NEXT'
        }
        $VM.DrainedAt = ConvertTo-Stamp (Get-Date)
        Write-Log -Level SUCCESS -Message "$($VM.VM) holds no primaries now."

        if ($VM.IsLocal) {
            if ($script:DryRun) {
                Write-Log -Level WARN -Message '[DRY RUN] This VM would now stop for a manual reboot.'
                $VM.Step = 'WAIT_ONLINE'
            }
            else {
                $VM.Status = 'AWAITING_MANUAL_REBOOT'; $VM.Step = 'WAIT_ONLINE'
                Save-Rolling -Run $Run
                return 'LOCAL_PENDING'
            }
        }
        else { $VM.Step = 'REBOOT' }
        Save-Rolling -Run $Run
    }

    # ---- 2. reboot --------------------------------------------------------------
    if ($VM.Step -eq 'REBOOT') {
        while ($true) {
            try {
                Invoke-VMReboot -Computer $VM.VM
                $VM.RebootSentAt = ConvertTo-Stamp (Get-Date)
                break
            }
            catch {
                Write-ErrorDetail -ErrorRecord $_ -Step "Reboot $($VM.VM)" -Server $VM.VM
                $a = Read-Choice "[R]etry the reboot / [W]ait anyway (the VM is rebooting) / [B]ring its AGs back and skip $($VM.VM) / [Q]uit" @('R', 'W', 'B', 'Q')
                if ($a -eq 'W') { $VM.RebootSentAt = ConvertTo-Stamp (Get-Date); break }
                if ($a -eq 'Q') { Save-Rolling -Run $Run; return 'STOP' }
                if ($a -eq 'B') {
                    [void](Invoke-RollingReturnStep -Run $Run -VM $VM)
                    $VM.Status = 'SKIPPED'; Add-VMNote -VM $VM -Note 'Skipped: reboot command failed, AGs returned'
                    return 'NEXT'
                }
            }
        }
        $VM.Step = 'WAIT_ONLINE'
        Save-Rolling -Run $Run
    }

    # ---- 3. wait for the VM and SQL ------------------------------------------------
    if ($VM.Step -eq 'WAIT_ONLINE') {
        $w = Wait-VMOnline -Run $Run -VM $VM
        if ($w -eq 'STOP') {
            if ($VM.IsLocal) { $VM.Status = 'AWAITING_MANUAL_REBOOT' }
            Save-Rolling -Run $Run; return 'STOP'
        }
        if ($w -eq 'SKIP_RETURN') {
            [void](Invoke-RollingReturnStep -Run $Run -VM $VM)
            $VM.Status = 'SKIPPED'; Add-VMNote -VM $VM -Note 'Skipped: VM did not reboot, AGs returned'
            return 'NEXT'
        }
        if ($w -eq 'NOT_REBOOTED') { Add-VMNote -VM $VM -Note 'Continued without a confirmed reboot' }
        $VM.BackOnlineAt = ConvertTo-Stamp (Get-Date)
        $from = if ($VM.RebootSentAt) { $VM.RebootSentAt } else { $VM.DrainedAt }
        if ($from) { $VM.DownMinutes = [math]::Round(((Get-Date) - (ConvertFrom-Stamp $from)).TotalMinutes, 1) }
        $VM.Step = 'WAIT_SYNC'
        Save-Rolling -Run $Run
    }

    # ---- 4. wait for re-sync, 5. return the VM's AGs ------------------------------
    $notReady = @()
    if ($VM.Step -eq 'WAIT_SYNC') {
        $s = Wait-VMReplicasSynced -Run $Run -VM $VM -InstOnVM $instOnVM
        if ($s.Stop) { Save-Rolling -Run $Run; return 'STOP' }
        $notReady = @($s.NotReady)
        $VM.Step = 'RETURN'
        Save-Rolling -Run $Run
    }
    if ($VM.Step -eq 'RETURN') {
        $problems = Invoke-RollingReturnStep -Run $Run -VM $VM -NotReady $notReady
        $VM.ReturnedAt = ConvertTo-Stamp (Get-Date)
        $VM.Step   = 'DONE'
        $VM.Status = if ($problems -eq 0 -and -not $VM.Notes) { 'COMPLETED' } else { 'COMPLETED_WITH_ISSUES' }
        Save-Rolling -Run $Run
        Write-Log -Level $(if ($VM.Status -eq 'COMPLETED') { 'SUCCESS' } else { 'WARN' }) -Message "$($VM.VM): $($VM.Status)$(if ($VM.DownMinutes) { " (down $($VM.DownMinutes) min)" })."
    }
    return 'NEXT'
}

function Read-RollingDecision {
    # Asks the operator what to do with the next VM. Returns GO, SKIP, SKIPALL or QUIT.
    param($Run, $VM)
    $expired = $false; $windowMsg = 'no maintenance window set'
    if ($Run.WindowEnd) {
        $left = ((ConvertFrom-Stamp $Run.WindowEnd) - (Get-Date)).TotalMinutes
        if ($left -le 0) { $expired = $true; $windowMsg = "MAINTENANCE WINDOW ENDED $([int][math]::Abs($left)) min ago ($($Run.WindowEnd))" }
        else { $windowMsg = "maintenance window ends $($Run.WindowEnd) ($([int]$left) min left)" }
    }
    $done = @($Run.VMs | Where-Object { $_.DrainedAt -and $_.ReturnedAt })
    $avg = $null
    if ($done.Count -gt 0) { $avg = [math]::Round((($done | ForEach-Object { ((ConvertFrom-Stamp $_.ReturnedAt) - (ConvertFrom-Stamp $_.DrainedAt)).TotalMinutes }) | Measure-Object -Average).Average, 0) }

    if ($script:RollingAutoContinue -and -not $expired) {
        Write-Log -Message "Continuing with $($VM.VM) without asking ($windowMsg)."
        return 'GO'
    }
    if ($script:RollingAutoContinue -and $expired) {
        Write-Log -Level WARN -Message 'Run-all mode paused because the maintenance window has ended.'
        $script:RollingAutoContinue = $false
    }

    $primaries = @($Run.AGs | Where-Object { $_.Handled -and $_.OriginalPrimaryVM -eq $VM.VM } | ForEach-Object { $_.AGName })
    $remaining = @($Run.VMs | Where-Object { $_.Status -eq 'PENDING' }).Count
    Write-Host ''
    Write-Host "---- Next: VM $($VM.Order) of $(@($Run.VMs).Count) - $($VM.VM)$(if ($VM.IsLocal) { ' (THIS VM: drain only, you reboot it manually)' }) ----" -ForegroundColor Cyan
    Write-Host "  AG primaries (pre-snapshot): $(if ($primaries.Count) { $primaries -join ', ' } else { 'none' })"
    Write-Host "  VMs still to do            : $remaining"
    if ($avg) { Write-Host "  Average time per VM so far : $avg min" }
    Write-Host "  $windowMsg" -ForegroundColor $(if ($expired) { 'Red' } else { 'White' })
    Write-Host '  C = continue with this VM        S = skip this VM (not rebooted)'
    Write-Host '  R = continue with this and all remaining VMs without asking (pauses if the window ends)'
    Write-Host '  A = skip ALL remaining VMs and go to the final rebalance'
    Write-Host '  Q = quit now (resume later with option 5)'
    $a = Read-Choice 'Choice' @('C', 'S', 'R', 'A', 'Q')
    switch ($a) {
        'C' { return 'GO' }
        'R' { $script:RollingAutoContinue = $true; return 'GO' }
        'S' { return 'SKIP' }
        'A' { return 'SKIPALL' }
        default { return 'QUIT' }
    }
}

function Invoke-RollingFinal {
    param($Run)
    Write-Log -Level STEP -Message '===== Final rebalance against the pre-snapshot ====='
    foreach ($ag in @($Run.AGs | Where-Object { $_.Handled })) {
        if ($script:DryRun) { $ag.FinalPrimary = $ag.OriginalPrimary; $ag.FinalResult = 'DRYRUN'; continue }
        $cur = Get-CurrentPrimary -AG $ag
        $ag.FinalNote = $null
        if ($cur -ne $ag.OriginalPrimary) {
            Write-Log -Message "[$($ag.AGName)] is on $cur, pre-snapshot primary is $($ag.OriginalPrimary) - returning it."
            $r = Invoke-ReturnAG -AGName $ag.AGName -OriginalPrimary $ag.OriginalPrimary -CurrentPrimary $cur
            $ag.FinalNote = "$($r.Result)$(if ($r.Note) { ': ' + $r.Note })"
            $cur = Get-CurrentPrimary -AG $ag
        }
        $ag.FinalPrimary = $cur
        $ag.FinalResult  = if ($cur -and $cur -eq $ag.OriginalPrimary) { 'BALANCED' } else { 'NOT_BALANCED' }
        try { $ag.FinalHealth = if ($cur) { Get-AGHealth -Server $cur -AGName $ag.AGName } else { 'UNKNOWN' } } catch { $ag.FinalHealth = 'UNKNOWN' }
        Save-Rolling -Run $Run
    }
    foreach ($i in @($Run.Instances)) {
        try { $i.VersionAfter = (Get-ServerInfo -Server $i.Instance).ProductVersion } catch { $i.VersionAfter = 'unreachable' }
    }
    $badVM = @($Run.VMs | Where-Object { $_.Status -ne 'COMPLETED' })
    $badAG = @($Run.AGs | Where-Object { $_.Handled -and $_.FinalResult -notin @('BALANCED', 'DRYRUN') })
    $Run.Status      = if ($badVM.Count -eq 0 -and $badAG.Count -eq 0) { 'COMPLETED' } else { 'COMPLETED_WITH_ISSUES' }
    $Run.CompletedAt = ConvertTo-Stamp (Get-Date)
    Save-Rolling -Run $Run
    Write-Log -Level STEP -Message "Final AG layout:`n$(Format-Rows ($Run.AGs | Where-Object { $_.Handled } | Select-Object AGName, OriginalPrimary, FinalPrimary, FinalResult, FinalHealth, FinalNote))"
}

function Save-Rolling {
    param($Run)
    try {
        Save-State -State $Run -Path $Run.StateFile
        Write-RollingSummary -Run $Run
    }
    catch { Write-Log -Level WARN -Message "Could not update rolling state/summary: $($_.Exception.Message)" }
}

function Write-RollingSummary {
    param($Run)
    $mode = if ($Run.Mode -eq 'DRYRUN') { 'DRY RUN (no changes were made)' } else { 'LIVE' }
    $vms  = @($Run.VMs | Sort-Object Order)
    $handled = @($Run.AGs | Where-Object { $_.Handled })
    $ok   = @($vms | Where-Object { $_.Status -eq 'COMPLETED' }).Count
    $warn = @($vms | Where-Object { $_.Status -eq 'COMPLETED_WITH_ISSUES' }).Count
    $skip = @($vms | Where-Object { $_.Status -eq 'SKIPPED' }).Count
    $open = $vms.Count - $ok - $warn - $skip
    $balanced = @($handled | Where-Object { $_.FinalResult -in @('BALANCED', 'DRYRUN') }).Count

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('=====================================================================================')
    [void]$sb.AppendLine(' SQL SERVER ALWAYS ON - ROLLING VM REBOOT SUMMARY')
    [void]$sb.AppendLine('=====================================================================================')
    [void]$sb.AppendLine(" Cluster          : $($Run.Cluster)")
    [void]$sb.AppendLine(" Started          : $($Run.StartedAt)")
    [void]$sb.AppendLine(" Completed        : $(if ($Run.CompletedAt) { $Run.CompletedAt } else { '-' })")
    [void]$sb.AppendLine(" Executed by      : $($Run.StartedBy) (from $($Run.Machine))")
    [void]$sb.AppendLine(" Mode             : $mode")
    [void]$sb.AppendLine(" Maintenance end  : $(if ($Run.WindowEnd) { $Run.WindowEnd } else { 'not set' })")
    [void]$sb.AppendLine(" Run status       : $($Run.Status)")
    [void]$sb.AppendLine(" VMs              : $($vms.Count) total | $ok rebooted OK | $warn with issues | $skip skipped | $open not finished")
    if ($Run.CompletedAt) { [void]$sb.AppendLine(" AG balance       : $balanced of $($handled.Count) AGs on their original primary") }
    [void]$sb.AppendLine('-------------------------------------------------------------------------------------')
    [void]$sb.AppendLine(' 1. AG layout before the activity (pre-snapshot)')
    [void]$sb.AppendLine((Format-Rows ($Run.AGs | Select-Object @{n = 'AG Name'; e = { $_.AGName } }, @{n = 'Primary'; e = { $_.OriginalPrimary } }, @{n = 'Primary VM'; e = { $_.OriginalPrimaryVM } }, @{n = 'Replicas'; e = { @($_.Replicas) -join ', ' } }, @{n = 'Note'; e = { $_.Note } })))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(' 2. VM progress')
    [void]$sb.AppendLine((Format-Rows ($vms | Select-Object @{n = '#'; e = { $_.Order } }, @{n = 'VM'; e = { "$($_.VM)$(if ($_.IsLocal) { ' (manual)' })" } }, @{n = 'Status'; e = { $_.Status } },
                @{n = 'Drained'; e = { $_.DrainedAt } }, @{n = 'Back online'; e = { $_.BackOnlineAt } }, @{n = 'Down (min)'; e = { $_.DownMinutes } },
                @{n = 'AGs moved'; e = { @($_.Moves | Where-Object { $_ }).Count } }, @{n = 'AGs returned'; e = { @($_.Returns | Where-Object { $_ -and $_.Result -in @('RETURNED', 'DRYRUN') }).Count } }, @{n = 'Notes'; e = { $_.Notes } })))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(' 3. AG movements')
    $moves = foreach ($v in $vms) {
        foreach ($m in @($v.Moves | Where-Object { $_ })) {
            $ret = @($v.Returns | Where-Object { $_ -and $_.AGName -eq $m.AGName }) | Select-Object -Last 1
            [pscustomobject]@{ 'VM' = $v.VM; 'AG Name' = $m.AGName; 'Moved from' = $m.From; 'Moved to' = $(if ($m.To) { $m.To } else { '-' }); 'Move result' = $m.Result; 'Moved at' = $m.Time
                'Return result' = $(if ($ret) { $ret.Result } else { '-' }); 'Returned at' = $(if ($ret) { $ret.Time } else { '-' }) }
        }
    }
    [void]$sb.AppendLine((Format-Rows $moves))
    if ($Run.CompletedAt) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine(' 4. AG layout after the activity')
        [void]$sb.AppendLine((Format-Rows ($handled | Select-Object @{n = 'AG Name'; e = { $_.AGName } }, @{n = 'Original primary'; e = { $_.OriginalPrimary } }, @{n = 'Final primary'; e = { $_.FinalPrimary } }, @{n = 'Result'; e = { $_.FinalResult } }, @{n = 'AG health'; e = { $_.FinalHealth } })))
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine(' 5. SQL builds')
        [void]$sb.AppendLine((Format-Rows ($Run.Instances | Select-Object @{n = 'Instance'; e = { $_.Instance } }, @{n = 'VM'; e = { $_.VM } }, @{n = 'Before'; e = { $_.Version } }, @{n = 'After'; e = { $_.VersionAfter } })))
    }

    $issues = New-Object System.Collections.Generic.List[string]
    foreach ($v in $vms) {
        if ($v.Status -in @('SKIPPED', 'COMPLETED_WITH_ISSUES') -and $v.Notes) { $issues.Add("$($v.VM): $($v.Notes)") }
        foreach ($m in @($v.Moves | Where-Object { $_ -and $_.Result -notin @('FAILED_OVER', 'DRYRUN') })) { $issues.Add("$($v.VM) / $($m.AGName): move $($m.Result) - $($m.Note)") }
        foreach ($r in @($v.Returns | Where-Object { $_ -and $_.Result -notin @('RETURNED', 'ALREADY_PRIMARY', 'DRYRUN') })) { $issues.Add("$($v.VM) / $($r.AGName): return $($r.Result) - $($r.Note)") }
    }
    foreach ($a in @($handled | Where-Object { $_.FinalResult -eq 'NOT_BALANCED' })) { $issues.Add("$($a.AGName): still on $($a.FinalPrimary), expected $($a.OriginalPrimary) - $($a.FinalNote)") }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(' Issues / notes')
    if ($issues.Count -eq 0) { [void]$sb.AppendLine('  - None') }
    foreach ($i in $issues) { [void]$sb.AppendLine("  - $i") }

    if ($Run.Status -eq 'AWAITING_LOCAL_REBOOT') {
        $local = $vms | Where-Object { $_.IsLocal } | Select-Object -First 1
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine(" NEXT STEP: $($local.VM) is drained. Reboot it manually, then run option 5 on it again to return its AGs and rebalance.")
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(" Detail logs: $(@($Run.LogFiles) -join ', ')")
    [void]$sb.AppendLine(" State file : $($Run.StateFile)")
    [void]$sb.AppendLine('=====================================================================================')
    Set-Content -Path $Run.SummaryFile -Value $sb.ToString() -Encoding UTF8
}

function New-RollingRun {
    # Discovers the VMs, instances and AGs, takes the pre-snapshot. Returns the run object or $null.
    $localInst = @(Get-LocalSqlInstances)
    $vmFile    = Join-Path $BasePath 'VMs.txt'
    $fileVMs = @(); $fileInst = @()
    if (Test-Path $vmFile) {
        foreach ($line in (Get-Content -Path $vmFile)) {
            $t = $line.Trim()
            if (-not $t -or $t.StartsWith('#')) { continue }
            if ($t.Contains('\')) { $fileInst += $t; $v = $t.Split('\')[0] } else { $v = $t }
            if ($fileVMs -notcontains $v) { $fileVMs += $v }
        }
        if ($fileVMs.Count -eq 0) { Write-Log -Level ERROR -Message "$vmFile has no VM names."; return $null }
        Write-Log -Message "VM list taken from $vmFile : $($fileVMs -join ', ')"
    }

    $members = @()
    foreach ($s in @($localInst + $fileInst + $fileVMs)) {
        try { $members = @(Get-ClusterMembers -Server $s); if ($members.Count -gt 0) { break } }
        catch { Write-Log -Level DETAIL -Message "Cluster membership not readable from $s : $($_.Exception.Message)" -NoConsole }
    }
    if ($members.Count -eq 0 -and $fileVMs.Count -eq 0) {
        Write-Log -Level ERROR -Message "Could not read the cluster from any SQL instance on $env:COMPUTERNAME (found: $(if ($localInst.Count) { $localInst -join ', ' } else { 'no running SQL service' })). Run this on a cluster VM with Always On enabled, or list the VMs in $vmFile."
        return $null
    }
    $clusterName = if ($members.Count -gt 0) { $members[0].ClusterName } else { 'UNKNOWN_CLUSTER' }
    $nodes = @($members | Where-Object { $_.MemberType -eq 'CLUSTER_NODE' } | ForEach-Object { $_.MemberName })
    if ($members.Count -gt 0) { Write-Log -Message "Cluster $clusterName nodes: $($nodes -join ', ')" }

    $vmList = if ($fileVMs.Count -gt 0) { $fileVMs } else { $nodes }
    foreach ($v in $vmList) { if ($nodes.Count -gt 0 -and $nodes -notcontains $v) { Write-Log -Level WARN -Message "$v (from VMs.txt) is not a node of cluster $clusterName - it will still be rebooted." } }

    $localVM  = $env:COMPUTERNAME
    $ordered  = @($vmList | Where-Object { $_ -ne $localVM })
    if ($vmList -contains $localVM) { $ordered += $localVM }
    else { Write-Log -Level WARN -Message "This VM ($localVM) is not in the list - every listed VM will be rebooted by the tool." }

    Write-Log -Message 'Discovering SQL instances and AGs (this can take a minute)...'
    $topo  = Get-RollingTopology -Seeds @($localInst + $fileInst) -Probes $vmList
    $insts = @($topo.Instances)

    $agSnap = @(foreach ($ag in ($topo.AGs | Sort-Object AGName)) {
            $handled = ($ag.ClusterType -eq 'WSFC') -and -not $ag.IsDistributed
            $note = if ($ag.IsDistributed) { 'Distributed AG - its member AGs are handled individually' }
                    elseif (-not $handled) { "CLUSTER_TYPE $($ag.ClusterType) - not failed over by this tool" }
                    else { '' }
            if ($handled -and -not $ag.Primary) { $handled = $false; $note = 'Primary unknown at snapshot time - not managed' }
            $pVM = ($insts | Where-Object { $_.Instance -eq $ag.Primary } | Select-Object -First 1).VM
            [pscustomobject]@{
                AGName = $ag.AGName; ClusterType = $ag.ClusterType; IsDistributed = $ag.IsDistributed; Handled = $handled; Note = $note
                OriginalPrimary = $ag.Primary; OriginalPrimaryVM = $pVM; Replicas = @($ag.Replicas)
                FinalPrimary = $null; FinalResult = $null; FinalNote = $null; FinalHealth = $null
            }
        })

    $order = 0
    $vmObjs = @(foreach ($v in $ordered) {
            $order++
            [pscustomobject]@{
                Order = $order; VM = $v; IsLocal = ($v -eq $localVM)
                Instances = @($insts | Where-Object { $_.VM -eq $v } | ForEach-Object { $_.Instance })
                Status = 'PENDING'; Step = $null; Notes = $null
                DrainedAt = $null; RebootSentAt = $null; BackOnlineAt = $null; ReturnedAt = $null; DownMinutes = $null
                SqlStartBefore = @(); Moves = @(); Returns = @()
            }
        })

    Write-Log -Level STEP -Message "Reboot order:`n$(Format-Rows ($vmObjs | Select-Object Order, VM, @{n='Reboot';e={ if ($_.IsLocal) { 'MANUAL (last)' } else { 'by tool' } }}, @{n='Instances';e={ @($_.Instances) -join ', ' }}, @{n='AG primaries';e={ $vmName = $_.VM; @($agSnap | Where-Object { $_.Handled -and $_.OriginalPrimaryVM -eq $vmName }).Count }}))"
    Write-Log -Level STEP -Message "AG pre-snapshot:`n$(Format-Rows ($agSnap | Select-Object AGName, OriginalPrimary, OriginalPrimaryVM, @{n='Replicas';e={ @($_.Replicas) -join ', ' }}, Note))"
    foreach ($v in $vmObjs) { if (@($v.Instances).Count -eq 0) { Write-Log -Level WARN -Message "No SQL instance found on $($v.VM). It will be rebooted without AG handling. If it has a named instance, add a line '$($v.VM)\<instance>' to VMs.txt." } }
    foreach ($a in @($agSnap | Where-Object { -not $_.Handled -and -not $_.IsDistributed })) { Write-Log -Level WARN -Message "AG [$($a.AGName)] is not managed by the tool: $($a.Note)" }

    $windowEnd = $null
    $we = (Read-Host 'Maintenance window end time (HH:mm, 24h; blank = no limit)').Trim()
    if ($we) {
        $t = [datetime]::MinValue
        if ([datetime]::TryParseExact($we, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$t)) {
            $end = (Get-Date).Date.Add($t.TimeOfDay)
            if ($end -lt (Get-Date)) { $end = $end.AddDays(1) }
            $windowEnd = ConvertTo-Stamp $end
            Write-Log -Message "Maintenance window ends $windowEnd."
        }
        else { Write-Log -Level WARN -Message "'$we' is not HH:mm - no maintenance window set." }
    }

    if (-not (Confirm-Action "About to start a rolling reboot of $($vmObjs.Count) VM(s) in cluster $clusterName$(if ($script:DryRun) { ' [DRY RUN]' }).")) {
        Write-Log -Level WARN -Message 'Cancelled by user. No changes made.'
        return $null
    }

    $tag  = if ($script:DryRun) { '_DRYRUN' } else { '' }
    $safe = Get-SafeName $clusterName
    $run = [pscustomobject]@{
        Tool        = 'AGFailoverTool'
        ToolVersion = $Config.ToolVersion
        Kind        = 'ROLLING_REBOOT'
        Mode        = $(if ($script:DryRun) { 'DRYRUN' } else { 'LIVE' })
        Cluster     = $clusterName
        LocalVM     = $localVM
        StartedAt   = ConvertTo-Stamp (Get-Date)
        StartedBy   = $script:RunAs
        Machine     = $env:COMPUTERNAME
        WindowEnd   = $windowEnd
        Status      = 'IN_PROGRESS'
        CompletedAt = $null
        LastUpdated = $null
        LogFiles    = @($script:LogFile)
        StateFile   = Join-Path $script:StateDir   "Rolling_$($safe)_$($script:RunStamp)$tag.json"
        SummaryFile = Join-Path $script:SummaryDir "Rolling_Reboot_Summary_$($safe)_$($script:RunStamp)$tag.txt"
        Instances   = @($insts | ForEach-Object { [pscustomobject]@{ Instance = $_.Instance; VM = $_.VM; Version = $_.Version; VersionAfter = $null } })
        AGs         = $agSnap
        VMs         = $vmObjs
    }
    Save-Rolling -Run $run
    Write-Log -Level SUCCESS -Message "Pre-snapshot saved to $($run.StateFile)"
    return $run
}

function Invoke-RollingReboot {
    Write-Log -Level STEP -Message '===== OPTION 5: Rolling reboot of the cluster VMs ====='
    $run = $null
    $savedDryRun = $script:DryRun

    # ---- resume an unfinished run? ---------------------------------------------------
    $pending = $null
    foreach ($f in @(Get-ChildItem -Path $script:StateDir -Filter 'Rolling_*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        try {
            $s = Get-Content -Path $f.FullName -Raw | ConvertFrom-Json
            if ($s.Status -in @('IN_PROGRESS', 'AWAITING_LOCAL_REBOOT')) { $pending = $s; break }
        }
        catch { Write-Log -Level WARN -Message "Unreadable rolling state file skipped: $($f.Name)" }
    }
    if ($pending) {
        $doneCount = @($pending.VMs | Where-Object { $_.Status -notin @('PENDING', 'IN_PROGRESS', 'AWAITING_MANUAL_REBOOT') }).Count
        Write-Host ''
        Write-Host "Unfinished rolling reboot found: cluster $($pending.Cluster), started $($pending.StartedAt) by $($pending.StartedBy), $($pending.Mode), status $($pending.Status), $doneCount of $(@($pending.VMs).Count) VMs done." -ForegroundColor Yellow
        $a = Read-Choice '[R]esume it / [N]ew run (the old one is marked ABANDONED) / [C]ancel' @('R', 'N', 'C')
        if ($a -eq 'C') { return }
        if ($a -eq 'R') {
            $run = $pending
            $script:DryRun = ($run.Mode -eq 'DRYRUN')
            if (@($run.LogFiles) -notcontains $script:LogFile) { Add-Item -Object $run -Property 'LogFiles' -Item $script:LogFile }
            Write-Log -Message "Resuming rolling run from $($run.StateFile) (dry run: $($script:DryRun))."
        }
        else {
            $pending.Status = 'ABANDONED'
            try { Save-State -State $pending -Path $pending.StateFile } catch { Write-Log -Level WARN -Message "Could not mark the old run abandoned: $($_.Exception.Message)" }
        }
    }

    try {
        if (-not $run) { $run = New-RollingRun }
        if (-not $run) { return }

        # ---- reboot account ----------------------------------------------------------
        $autoVMs = @($run.VMs | Where-Object { -not $_.IsLocal -and $_.Status -in @('PENDING', 'IN_PROGRESS') })
        if ($autoVMs.Count -gt 0 -and -not $script:DryRun) {
            Write-Host ''
            Write-Host "Reboots run 'shutdown /r /t 0 /m \\<VM>' as $($script:RunAs); that account must be local admin on the VMs."
            $a = Read-Choice "[U]se $($script:RunAs) / [C]redential: enter a different Windows admin account (reboot via WinRM)" @('U', 'C')
            if ($a -eq 'C') { $script:OsCredential = Get-Credential -Message 'Windows admin account used to reboot the VMs' }
            else { $script:OsCredential = $null }
        }

        if ($run.Status -eq 'AWAITING_LOCAL_REBOOT') { $run.Status = 'IN_PROGRESS' }
        $script:RollingAutoContinue = $false
        $skipAll = $false

        foreach ($vm in @($run.VMs | Sort-Object Order)) {
            if ($vm.Status -in @('COMPLETED', 'COMPLETED_WITH_ISSUES', 'SKIPPED')) { continue }
            if ($vm.Status -eq 'PENDING') {
                if ($skipAll) { $vm.Status = 'SKIPPED'; Add-VMNote -VM $vm -Note 'Skipped by operator (remaining VMs skipped)'; continue }
                $d = Read-RollingDecision -Run $run -VM $vm
                if ($d -eq 'QUIT') { Save-Rolling -Run $run; Write-Log -Level WARN -Message "Stopped by operator. Run option 5 again to resume. Summary: $($run.SummaryFile)"; return }
                if ($d -eq 'SKIP') { $vm.Status = 'SKIPPED'; Add-VMNote -VM $vm -Note 'Skipped by operator'; Save-Rolling -Run $run; Write-Log -Level WARN -Message "$($vm.VM) skipped."; continue }
                if ($d -eq 'SKIPALL') {
                    $skipAll = $true
                    $vm.Status = 'SKIPPED'; Add-VMNote -VM $vm -Note 'Skipped by operator (remaining VMs skipped)'
                    Write-Log -Level WARN -Message 'All remaining VMs skipped by operator.'
                    continue
                }
            }

            $r = Invoke-RollingVM -Run $run -VM $vm
            Save-Rolling -Run $run
            if ($r -eq 'STOP') {
                Write-Log -Level WARN -Message "Rolling reboot paused at $($vm.VM). Run option 5 again to resume from here. Summary: $($run.SummaryFile)"
                return
            }
            if ($r -eq 'LOCAL_PENDING') {
                $run.Status = 'AWAITING_LOCAL_REBOOT'
                Save-Rolling -Run $run
                Write-Host ''
                Write-Host '=====================================================================' -ForegroundColor Yellow
                Write-Host " $($vm.VM) (this VM) is drained and holds no AG primaries." -ForegroundColor Yellow
                Write-Host ' 1. Reboot it now:  shutdown /r /t 0' -ForegroundColor Yellow
                Write-Host ' 2. Log back in, start this tool again and choose option 5 -> Resume.' -ForegroundColor Yellow
                Write-Host '    It will wait for re-sync, return this VM''s AGs and rebalance all AGs.' -ForegroundColor Yellow
                Write-Host '=====================================================================' -ForegroundColor Yellow
                Write-Log -Level WARN -Message "Waiting for manual reboot of $($vm.VM). Summary: $($run.SummaryFile)"
                return
            }
        }

        Invoke-RollingFinal -Run $run
        Write-Log -Level $(if ($run.Status -eq 'COMPLETED') { 'SUCCESS' } else { 'WARN' }) -Message "Rolling reboot $($run.Status). Summary: $($run.SummaryFile)"
    }
    catch {
        Write-ErrorDetail -ErrorRecord $_ -Step 'Rolling reboot'
        if ($run) { Save-Rolling -Run $run; Write-Log -Level WARN -Message 'Progress is saved. Fix the problem and run option 5 again to resume.' }
    }
    finally {
        $script:DryRun = $savedDryRun
    }
}

# ----------------------------------------------------------------------------
# Main menu
# ----------------------------------------------------------------------------
Write-Log -Message "AGFailoverTool v$($Config.ToolVersion) started by $($script:RunAs) on $env:COMPUTERNAME (PowerShell $($PSVersionTable.PSVersion)). Log: $($script:LogFile)"

while ($true) {
    Write-Host ''
    Write-Host '=============================================================' -ForegroundColor Cyan
    Write-Host "  SQL Always On AG Failover Tool v$($Config.ToolVersion)   Run as: $($script:RunAs)" -ForegroundColor Cyan
    if ($script:DryRun) { Write-Host '  *** DRY RUN MODE - no changes will be made ***' -ForegroundColor Yellow }
    Write-Host '=============================================================' -ForegroundColor Cyan
    Write-Host '  1. Before activity  - record primaries and drain node (fail over AGs)'
    Write-Host '  2. After activity   - fail AGs back to original primaries'
    Write-Host '  3. AG health check  (read-only)'
    Write-Host "  4. Toggle dry run   (currently: $(if($script:DryRun){'ON'}else{'OFF'}))"
    Write-Host '  5. Rolling reboot   - drain, reboot and return every VM in the cluster, one at a time'
    Write-Host '  0. Exit'
    $choice = (Read-Host 'Select an option').Trim()

    try {
        switch ($choice) {
            '1' { Invoke-DrainNode }
            '2' { Invoke-Failback }
            '3' { Invoke-HealthCheck }
            '5' { Invoke-RollingReboot }
            '4' { $script:DryRun = -not $script:DryRun; Write-Log -Level WARN -Message "Dry run is now $(if($script:DryRun){'ON'}else{'OFF'})." }
            '0' { Write-Log -Message 'Exiting.'; return }
            default { Write-Host "Invalid option '$choice'." -ForegroundColor Yellow }
        }
    }
    catch {
        Write-ErrorDetail -ErrorRecord $_ -Step "Menu option $choice (unhandled)"
    }
}
