<#
.SYNOPSIS
    Always On Availability Group failover tool - launcher

.DESCRIPTION
    Menu-driven tool for planned maintenance on SQL Server Always On AG nodes
    (Windows patching, SQL CU patching, reboots, etc.).

      1 - Drain a VM before activity
          Takes a VM name (or one of its instances), finds every SQL instance on
          that VM, records the current primary of every AG, then fails each AG the
          VM is primary for over to the best synchronous secondary on ANOTHER VM.
          Writes a state file (used by option 2) and a leadership summary .txt.

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

      6 - Rebalance to preferred primaries
          Moves every AG listed in PreferredPrimaries.txt (AGName = Instance) to
          its preferred primary, with the same safety checks. Needs no state file;
          can generate the list from the current layout.

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

    Files (keep them in the same folder)
      AG-FailoverTool.ps1   this launcher - run this
      AGFailoverTool.psm1   all the logic; settings are in $Config at its top
      Tests\               Pester 5 tests (Invoke-Pester .\Tests)
      AG-FailoverTool-Guide.md   how to use the tool

    How to run
      powershell.exe -ExecutionPolicy Bypass -File .\AG-FailoverTool.ps1

    Failover safety checks (every option)
      - Target must be synchronous, connected, healthy, every AG database JOINED,
        SYNCHRONIZED, not suspended and failover-ready, on the same or a higher
        SQL build than the current primary, and not on the VM being drained.
      - Warns and asks before a failover that would leave fewer synchronous
        secondaries than REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT (writes stop).
      - If the FAILOVER command errors or times out, the replicas are asked whether
        the role changed anyway: COMPLETED, NOT STARTED, or OUTCOME UNKNOWN (stop).
      - State files are written atomically (<file>.tmp -> <file>, previous copy kept
        as <file>.bak, which is used automatically if the file is damaged).
      - Pre-flight before any change: every replica reachable with VIEW SERVER STATE
        and ALTER ANY AVAILABILITY GROUP, no other AGFailoverTool session active on
        them, and (draining) every other cluster node and the witness UP with quorum
        surviving the loss of the VM.
      - Before failover, transactions open longer than LongTranWarnMin minutes on
        the AG's databases are listed (they are rolled back) and you choose
        continue / re-check / skip.
      - Read-only queries are retried on transient connection errors; FAILOVER and
        ALTER statements are never retried.
      - After each failover, every AG listener is tested (MultiSubnetFailover, no
        pooling) until it reaches the new primary.
      - While a VM is drained its AUTOMATIC replicas are set to MANUAL failover, so the
        cluster cannot move an AG onto it mid-maintenance; failback restores them.

    Baseline scope (deliberately NOT done automatically)
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
    # Folder for Logs\, State\, Summary\, VMs.txt and PreferredPrimaries.txt (default: this script's folder).
    [string]$BasePath = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
$module = Join-Path $PSScriptRoot 'AGFailoverTool.psm1'
if (-not (Test-Path -LiteralPath $module)) {
    Write-Host "AGFailoverTool.psm1 was not found next to this script ($PSScriptRoot). Copy both files into the same folder." -ForegroundColor Red
    exit 1
}
try { Import-Module $module -Force -DisableNameChecking }
catch {
    Write-Host "Could not load $module : $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'If the files were downloaded, unblock them first: Get-ChildItem <folder> | Unblock-File' -ForegroundColor Yellow
    exit 1
}
Start-AGFailoverTool -BasePath $BasePath
