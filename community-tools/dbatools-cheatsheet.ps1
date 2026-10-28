<#
  dbatools cheat sheet - commands mapped to the toolkit's scenarios.
  Install:   Install-Module dbatools -Scope CurrentUser
  Help:      Get-Help Copy-DbaLogin -Examples      |   https://docs.dbatools.io
  Tip:       Get-Command -Module dbatools *AvailabilityGroup*   to discover commands
  Note:      Not meant to be run top-to-bottom - copy the lines you need.
#>

# ---------------------------------------------------------------------------
# 0. Connection basics
# ---------------------------------------------------------------------------
$servers = 'SQLVM1', 'SQLVM2'                              # or: Get-DbaRegServer
# Set-DbatoolsConfig -FullName sql.connection.trustcert -Value $true -Register   # self-signed certs
Connect-DbaInstance -SqlInstance SQLVM1
Invoke-DbaQuery -SqlInstance $servers -Query 'SELECT @@SERVERNAME, @@VERSION' -AppendServerInstance

# ---------------------------------------------------------------------------
# 1. Health checks across many servers  (toolkit 00, 06, 08, 09, 15)
# ---------------------------------------------------------------------------
Test-DbaBuild        -SqlInstance $servers -Latest                   # behind on CUs?
Test-DbaMaxMemory    -SqlInstance $servers                           # max server memory sane?
Test-DbaMaxDop       -SqlInstance $servers
Test-DbaTempDbConfig -SqlInstance $servers
Test-DbaPowerPlan    -ComputerName $servers                          # should be High performance
Get-DbaDiskSpace     -ComputerName $servers
Get-DbaDbSpace       -SqlInstance $servers
Get-DbaLastGoodCheckDb -SqlInstance $servers
Test-DbaDbOwner      -SqlInstance $servers
Test-DbaDbCompatibility -SqlInstance $servers
Get-DbaErrorLog      -SqlInstance SQLVM1 -After (Get-Date).AddHours(-24) | Where-Object Text -match 'error|fail'
Find-DbaDbGrowthEvent -SqlInstance SQLVM1                            # autogrowth events (default trace)
Get-DbaDbVirtualLogFile -SqlInstance SQLVM1 | Group-Object Database | Sort-Object Count -Descending   # VLFs

# ---------------------------------------------------------------------------
# 2. Backups  (toolkit 10)
# ---------------------------------------------------------------------------
Get-DbaLastBackup  -SqlInstance $servers | Format-Table
Get-DbaDbBackupHistory -SqlInstance SQLVM1 -Database YourDB -Last
Backup-DbaDatabase -SqlInstance SQLVM1 -Database YourDB -Path \\backup\sql -Type Full -CopyOnly -CompressBackup -Checksum
Test-DbaLastBackup -SqlInstance SQLVM1 -Destination SQLTEST -Database YourDB   # restore + CHECKDB on another box = real backup test

# ---------------------------------------------------------------------------
# 3. Always On  (toolkit 11, 25)
# ---------------------------------------------------------------------------
Get-DbaAvailabilityGroup -SqlInstance SQLVM1
Get-DbaAgReplica         -SqlInstance SQLVM1
Get-DbaAgDatabase        -SqlInstance SQLVM1 | Select-Object SqlInstance, AvailabilityGroup, Name, SynchronizationState, IsSuspended
Test-DbaAvailabilityGroup -SqlInstance SQLVM1 -AvailabilityGroup AG1
# Keep logins, jobs, credentials, linked servers in sync from primary to all replicas:
Sync-DbaAvailabilityGroup -Primary SQLVM1 -AvailabilityGroup AG1
# Add a DB to an AG incl. backup/restore to secondaries:
Add-DbaAgDatabase -SqlInstance SQLVM1 -AvailabilityGroup AG1 -Database NewDB -SeedingMode Automatic
Invoke-DbaAgFailover -SqlInstance SQLVM2 -AvailabilityGroup AG1     # planned failover (run against target)

# ---------------------------------------------------------------------------
# 4. Migration  (toolkit 29)
# ---------------------------------------------------------------------------
Test-DbaMigrationConstraint -Source SQLOLD -Destination SQLNEW       # edition feature blockers
Export-DbaInstance -SqlInstance SQLOLD -Path C:\DBA\Export\SQLOLD    # scripts EVERYTHING instance-level (logins, jobs, LS, creds...)
Copy-DbaLogin       -Source SQLOLD -Destination SQLNEW               # with SIDs + password hashes
Copy-DbaAgentJob    -Source SQLOLD -Destination SQLNEW
Copy-DbaLinkedServer -Source SQLOLD -Destination SQLNEW
Copy-DbaCredential  -Source SQLOLD -Destination SQLNEW
Copy-DbaDbMail      -Source SQLOLD -Destination SQLNEW
Copy-DbaDatabase    -Source SQLOLD -Destination SQLNEW -Database App -BackupRestore -SharedPath \\share\mig -WithReplace
Start-DbaMigration  -Source SQLOLD -Destination SQLNEW -BackupRestore -SharedPath \\share\mig   # whole instance
Repair-DbaDbOrphanUser -SqlInstance SQLNEW

# ---------------------------------------------------------------------------
# 5. Patching / upgrade  (toolkit 27, 30)
# ---------------------------------------------------------------------------
Get-DbaBuild   -SqlInstance $servers                                 # build + CU + support status
Test-DbaBuild  -SqlInstance $servers -MaxBehind 1CU
Update-DbaInstance -ComputerName SQLVM2 -Path \\share\SQLPatches -Restart -Confirm   # installs latest CU found in path
# AG rolling patch = patch secondary -> Invoke-DbaAgFailover -> patch old primary (see scripts/30 30.5)

# ---------------------------------------------------------------------------
# 6. Refresh PROD -> UAT  (toolkit 32)
# ---------------------------------------------------------------------------
Export-DbaUser -SqlInstance SQLUAT -Database App -FilePath C:\DBA\App_UAT_users.sql   # save UAT users/permissions first!
Restore-DbaDatabase -SqlInstance SQLUAT -Path \\backup\sql\SQLPROD\App\FULL -DatabaseName App -WithReplace `
                    -DestinationDataDirectory D:\Data -DestinationLogDirectory L:\Log
Invoke-DbaQuery -SqlInstance SQLUAT -Database App -File C:\DBA\App_UAT_users.sql
Repair-DbaDbOrphanUser -SqlInstance SQLUAT -Database App
# Static data masking for non-prod:
New-DbaDbMaskingConfig    -SqlInstance SQLUAT -Database App -Path C:\DBA\masking     # generates a JSON config (review it!)
Invoke-DbaDbDataMasking   -SqlInstance SQLUAT -Database App -FilePath C:\DBA\masking\<json file created above>

# ---------------------------------------------------------------------------
# 7. Security / audit  (toolkit 13, 23)
# ---------------------------------------------------------------------------
Get-DbaLogin -SqlInstance $servers -Type SQL | Select-Object SqlInstance, Name, IsDisabled, PasswordPolicyEnforced
Get-DbaServerRoleMember -SqlInstance $servers -ServerRole sysadmin
Get-DbaDbOrphanUser -SqlInstance $servers
Get-DbaPermission   -SqlInstance SQLVM1 -Database App
Test-DbaLoginPassword -SqlInstance $servers                          # weak / blank passwords

# ---------------------------------------------------------------------------
# 8. Schema / version control  (toolkit 28, 31)
# ---------------------------------------------------------------------------
Get-DbaDbTable -SqlInstance SQLVM1 -Database App | Export-DbaScript -FilePath C:\repo\schema\tables.sql
Get-DbaDbStoredProcedure -SqlInstance SQLVM1 -Database App -ExcludeSystemSp | Export-DbaScript -FilePath C:\repo\schema\procs.sql
Export-DbaDacPackage -SqlInstance SQLVM1 -Database App -Path C:\DBA\dacpac   # for sqlpackage DeployReport / schema compare

# ---------------------------------------------------------------------------
# 9. Community tools  (scripts/33)
# ---------------------------------------------------------------------------
Install-DbaWhoIsActive          -SqlInstance $servers -Database DBAdmin
Install-DbaFirstResponderKit    -SqlInstance $servers -Database DBAdmin
Install-DbaMaintenanceSolution  -SqlInstance $servers -Database DBAdmin -BackupLocation \\backup\sql -InstallJobs -LogToTable
Invoke-DbaWhoIsActive           -SqlInstance SQLVM1 -ShowSleepingSpids 1
Save-DbaDiagnosticQueryScript   -Path C:\DBA\GlennBerry
Invoke-DbaDiagnosticQuery       -SqlInstance SQLVM1 | Export-DbaDiagnosticQuery -Path C:\DBA\Reports
