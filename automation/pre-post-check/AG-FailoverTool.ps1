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
    ToolVersion             = '1.0'
    ConnectTimeoutSec       = 15     # SQL connection timeout
    QueryTimeoutSec         = 120    # normal query timeout
    FailoverTimeoutSec      = 600    # ALTER AVAILABILITY GROUP ... FAILOVER timeout
    SyncWaitSec             = 180    # max wait for a target to become SYNCHRONIZED before failover
    PostFailoverSyncWaitSec = 120    # max wait for the other replicas to re-sync after failover
    RoleVerifyWaitSec       = 60     # max wait for the new role to show PRIMARY
    PollIntervalSec         = 5
    QueueWarnKB             = 102400 # warn when log send + redo queue exceeds this (100 MB)
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
        CAST(SERVERPROPERTY('HadrManagerStatus') AS int)            AS HadrManagerStatus;
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
      -ExcludeReplica : the node being drained (option 1)
      -OnlyReplica    : a fixed target (option 2, the original primary)
      Waits up to SyncWaitSec when the only blocker is transient sync lag.
      Preference: ready > AUTOMATIC failover partner > smallest log send + redo queue.
    #>
    param(
        [string]$PrimaryServer,
        [string]$AGName,
        [string]$ExcludeReplica,
        [string]$OnlyReplica
    )
    $deadline = (Get-Date).AddSeconds($Config.SyncWaitSec)
    $loggedWait = $false
    while ($true) {
        $reps = Get-AGReplicas  -Server $PrimaryServer -AGName $AGName
        $dbs  = Get-AGDatabases -Server $PrimaryServer -AGName $AGName

        $pool = @($reps | Where-Object { $_.Role -ne 'PRIMARY' })
        if ($ExcludeReplica) { $pool = @($pool | Where-Object { $_.ReplicaServer -ne $ExcludeReplica }) }
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
    Write-Host '  0. Exit'
    $choice = (Read-Host 'Select an option').Trim()

    try {
        switch ($choice) {
            '1' { Invoke-DrainNode }
            '2' { Invoke-Failback }
            '3' { Invoke-HealthCheck }
            '4' { $script:DryRun = -not $script:DryRun; Write-Log -Level WARN -Message "Dry run is now $(if($script:DryRun){'ON'}else{'OFF'})." }
            '0' { Write-Log -Message 'Exiting.'; return }
            default { Write-Host "Invalid option '$choice'." -ForegroundColor Yellow }
        }
    }
    catch {
        Write-ErrorDetail -ErrorRecord $_ -Step "Menu option $choice (unhandled)"
    }
}
