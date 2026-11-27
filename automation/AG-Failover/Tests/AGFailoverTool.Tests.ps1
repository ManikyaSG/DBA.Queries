<#
    Pester 5 tests for AGFailoverTool.psm1. No SQL Server is needed: every SQL call is mocked,
    so these replay the failure scenarios the tool must handle.

    Run from the folder that holds AG-FailoverTool.ps1:
        Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck   # once
        Invoke-Pester .\Tests -Output Detailed
#>

BeforeAll {
    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'AGFailoverTool.psm1'
    Import-Module $modulePath -Force -DisableNameChecking
    Initialize-AGFailoverTool -BasePath $TestDrive
    InModuleScope AGFailoverTool {
        $Config.SyncWaitSec             = 0
        $Config.PollIntervalSec         = 0
        $Config.RoleVerifyWaitSec       = 2
        $Config.PostFailoverSyncWaitSec = 0
        $Config.ListenerWaitSec         = 0
        $script:DryRun                  = $false
    }

    function New-Replica {
        param($Name, $Role = 'SECONDARY', $Mode = 'SYNCHRONOUS_COMMIT', $Failover = 'MANUAL', $Connected = 'CONNECTED', $Health = 'HEALTHY')
        [pscustomobject]@{ ReplicaServer = $Name; Role = $Role; AvailabilityMode = $Mode; FailoverMode = $Failover
                           ConnectedState = $Connected; SyncHealth = $Health; LastConnectError = $null }
    }
    function New-DbRow {
        param($Replica, $Name = 'DB1', $State = 'SYNCHRONIZED', $Joined = $true, $Suspended = $false, $Ready = $true, $QueueKB = 0)
        [pscustomobject]@{ ReplicaServer = $Replica; DatabaseName = $Name; SyncState = $State; SyncHealth = 'HEALTHY'
                           IsJoined = $Joined; IsSuspended = $Suspended; SuspendReason = $null
                           LogSendQueueKB = $QueueKB; RedoQueueKB = 0; IsFailoverReady = $Ready; LastCommitTime = $null }
    }
}

AfterAll { Remove-Module AGFailoverTool -ErrorAction SilentlyContinue }

Describe 'Get-ReplicaReadiness' {
    It 'is ready when the replica is synchronous, connected and every database is synchronized' {
        $r = Get-ReplicaReadiness -Replica (New-Replica 'SQL2') -Databases @(New-DbRow 'SQL2')
        $r.Ready | Should -BeTrue
    }
    It 'rejects a replica where a database is NOT JOINED, and does not wait for it' {
        $r = Get-ReplicaReadiness -Replica (New-Replica 'SQL2') -Databases @(New-DbRow 'SQL2'; New-DbRow 'SQL2' -Name 'DB2' -State 'NOT JOINED' -Joined $false -Ready $null)
        $r.Ready    | Should -BeFalse
        $r.Waitable | Should -BeFalse
        ($r.Reasons -join ' ') | Should -Match 'NOT JOINED'
    }
    It 'rejects an asynchronous replica' {
        $r = Get-ReplicaReadiness -Replica (New-Replica 'SQL2' -Mode 'ASYNCHRONOUS_COMMIT') -Databases @(New-DbRow 'SQL2')
        $r.Ready    | Should -BeFalse
        $r.Waitable | Should -BeFalse
    }
    It 'waits for a replica that is only catching up' {
        $r = Get-ReplicaReadiness -Replica (New-Replica 'SQL2') -Databases @(New-DbRow 'SQL2' -State 'SYNCHRONIZING' -Ready $false)
        $r.Ready    | Should -BeFalse
        $r.Waitable | Should -BeTrue
    }
    It 'does not wait for a suspended database' {
        $r = Get-ReplicaReadiness -Replica (New-Replica 'SQL2') -Databases @(New-DbRow 'SQL2' -Suspended $true)
        $r.Waitable | Should -BeFalse
        $r.Suspended.Count | Should -Be 1
    }
    It 'rejects a replica on a lower SQL build than the primary' {
        $r = Get-ReplicaReadiness -Replica (New-Replica 'SQL2') -Databases @(New-DbRow 'SQL2') -CheckBuild -ReplicaBuild ([version]'15.0.4400.0') -PrimaryBuild ([version]'15.0.4415.2')
        $r.Ready    | Should -BeFalse
        $r.Waitable | Should -BeFalse
        ($r.Reasons -join ' ') | Should -Match 'lower'
    }
    It 'accepts a replica on a higher SQL build' {
        $r = Get-ReplicaReadiness -Replica (New-Replica 'SQL2') -Databases @(New-DbRow 'SQL2') -CheckBuild -ReplicaBuild ([version]'15.0.4420.2') -PrimaryBuild ([version]'15.0.4415.2')
        $r.Ready | Should -BeTrue
    }
    It 'rejects a replica whose build could not be read' {
        $r = Get-ReplicaReadiness -Replica (New-Replica 'SQL2') -Databases @(New-DbRow 'SQL2') -CheckBuild -ReplicaBuild $null -PrimaryBuild ([version]'15.0.4415.2')
        $r.Ready | Should -BeFalse
    }
}

Describe 'Find-FailoverTarget' {
    BeforeEach {
        Mock -ModuleName AGFailoverTool Start-Sleep { }
        Mock -ModuleName AGFailoverTool Get-ServerInfo { [pscustomobject]@{ ProductVersion = '15.0.4415.2' } }
        Mock -ModuleName AGFailoverTool Get-AGReplicas {
            @((New-Replica 'SQL1' -Role 'PRIMARY' -Failover 'AUTOMATIC'),
              (New-Replica 'SQL2'),
              (New-Replica 'SQL3' -Failover 'AUTOMATIC'),
              (New-Replica 'SQL4' -Mode 'ASYNCHRONOUS_COMMIT'))
        }
        Mock -ModuleName AGFailoverTool Get-AGDatabases {
            @((New-DbRow 'SQL1'), (New-DbRow 'SQL2'), (New-DbRow 'SQL3' -QueueKB 50), (New-DbRow 'SQL4' -State 'SYNCHRONIZING'))
        }
    }
    It 'prefers the AUTOMATIC failover partner' {
        (Find-FailoverTarget -PrimaryServer 'SQL1' -AGName 'AG1').Target | Should -Be 'SQL3'
    }
    It 'never picks an excluded replica (the VM being drained)' {
        (Find-FailoverTarget -PrimaryServer 'SQL1' -AGName 'AG1' -ExcludeReplica @('SQL1', 'SQL3')).Target | Should -Be 'SQL2'
    }
    It 'skips a replica on a lower build' {
        Mock -ModuleName AGFailoverTool Get-ServerInfo {
            if ($Server -eq 'SQL3') { [pscustomobject]@{ ProductVersion = '15.0.4400.0' } } else { [pscustomobject]@{ ProductVersion = '15.0.4415.2' } }
        }
        (Find-FailoverTarget -PrimaryServer 'SQL1' -AGName 'AG1').Target | Should -Be 'SQL2'
    }
    It 'returns no target, with the reason, when only an async replica is left' {
        $r = Find-FailoverTarget -PrimaryServer 'SQL1' -AGName 'AG1' -ExcludeReplica @('SQL2', 'SQL3')
        $r.Target | Should -BeNullOrEmpty
        $r.Reason | Should -Match 'SYNCHRONOUS_COMMIT'
    }
    It 'with -OnlyReplica only considers that replica' {
        (Find-FailoverTarget -PrimaryServer 'SQL1' -AGName 'AG1' -OnlyReplica 'SQL2').Target | Should -Be 'SQL2'
    }
}

Describe 'Failover outcome after an error' {
    BeforeEach {
        Mock -ModuleName AGFailoverTool Start-Sleep { }
        Mock -ModuleName AGFailoverTool Get-AGPrimary { $null }
    }
    It 'reports COMPLETED when the target became primary' {
        Mock -ModuleName AGFailoverTool Get-LocalRole { 'PRIMARY' }
        (Resolve-FailoverOutcome -AGName 'AG1' -Target 'SQL2' -FromPrimary 'SQL1').Outcome | Should -Be 'COMPLETED'
    }
    It 'reports NOT_STARTED when the old primary is still primary' {
        Mock -ModuleName AGFailoverTool Get-LocalRole { if ($Server -eq 'SQL1') { 'PRIMARY' } else { 'SECONDARY' } }
        (Resolve-FailoverOutcome -AGName 'AG1' -Target 'SQL2' -FromPrimary 'SQL1').Outcome | Should -Be 'NOT_STARTED'
    }
    It 'reports UNKNOWN when no replica answers' {
        Mock -ModuleName AGFailoverTool Get-LocalRole { throw 'unreachable' }
        (Resolve-FailoverOutcome -AGName 'AG1' -Target 'SQL2' -FromPrimary 'SQL1').Outcome | Should -Be 'UNKNOWN'
    }
    It 'Invoke-AGFailover treats a timed-out FAILOVER that did complete as success' {
        Mock -ModuleName AGFailoverTool Invoke-Sql { throw 'Timeout expired' } -ParameterFilter { $NonQuery }
        Mock -ModuleName AGFailoverTool Get-LocalRole { 'PRIMARY' }
        Invoke-AGFailover -AGName 'AG1' -Target 'SQL2' -FromPrimary 'SQL1' | Should -Be 'FAILED_OVER'
    }
    It 'Invoke-AGFailover rethrows the SQL error when the failover did not start' {
        Mock -ModuleName AGFailoverTool Invoke-Sql { throw 'Timeout expired' } -ParameterFilter { $NonQuery }
        Mock -ModuleName AGFailoverTool Get-LocalRole { if ($Server -eq 'SQL1') { 'PRIMARY' } else { 'SECONDARY' } }
        { Invoke-AGFailover -AGName 'AG1' -Target 'SQL2' -FromPrimary 'SQL1' } | Should -Throw '*Timeout expired*'
    }
    It 'Invoke-AGFailover throws OUTCOME UNKNOWN when it cannot tell' {
        Mock -ModuleName AGFailoverTool Invoke-Sql { throw 'Connection reset' } -ParameterFilter { $NonQuery }
        Mock -ModuleName AGFailoverTool Get-LocalRole { throw 'unreachable' }
        { Invoke-AGFailover -AGName 'AG1' -Target 'SQL2' -FromPrimary 'SQL1' } | Should -Throw 'OUTCOME UNKNOWN*'
    }
}

Describe 'Get-CommitRisk' {
    BeforeEach {
        Mock -ModuleName AGFailoverTool Get-AGReplicas {
            @((New-Replica 'SQL1' -Role 'PRIMARY'), (New-Replica 'SQL2'), (New-Replica 'SQL3' -Mode 'ASYNCHRONOUS_COMMIT'))
        }
    }
    It 'warns when too few synchronous secondaries remain' {
        Mock -ModuleName AGFailoverTool Invoke-Sql { [pscustomobject]@{ RequiredSecondaries = 1 } }
        Get-CommitRisk -PrimaryServer 'SQL1' -AGName 'AG1' -Target 'SQL2' -Drained @('SQL1') | Should -Match 'STOP ACCEPTING WRITES'
    }
    It 'is quiet when the setting is 0' {
        Mock -ModuleName AGFailoverTool Invoke-Sql { [pscustomobject]@{ RequiredSecondaries = 0 } }
        Get-CommitRisk -PrimaryServer 'SQL1' -AGName 'AG1' -Target 'SQL2' -Drained @('SQL1') | Should -BeNullOrEmpty
    }
    It 'is quiet when enough synchronous secondaries remain' {
        Mock -ModuleName AGFailoverTool Invoke-Sql { [pscustomobject]@{ RequiredSecondaries = 1 } }
        Mock -ModuleName AGFailoverTool Get-AGReplicas {
            @((New-Replica 'SQL1' -Role 'PRIMARY'), (New-Replica 'SQL2'), (New-Replica 'SQL3'))
        }
        Get-CommitRisk -PrimaryServer 'SQL1' -AGName 'AG1' -Target 'SQL2' -Drained @('SQL1') | Should -BeNullOrEmpty
    }
}

Describe 'Get-ClusterIssues' {
    It 'reports a down node and the quorum risk' {
        Mock -ModuleName AGFailoverTool Get-ClusterMembers {
            @([pscustomobject]@{ ClusterName = 'C1'; MemberName = 'VM1'; MemberType = 'CLUSTER_NODE'; MemberState = 'UP'; Votes = 1 },
              [pscustomobject]@{ ClusterName = 'C1'; MemberName = 'VM2'; MemberType = 'CLUSTER_NODE'; MemberState = 'UP'; Votes = 1 },
              [pscustomobject]@{ ClusterName = 'C1'; MemberName = 'VM3'; MemberType = 'CLUSTER_NODE'; MemberState = 'DOWN'; Votes = 1 })
        }
        $i = @(Get-ClusterIssues -VMName 'VM1' -QueryServers @('VM2'))
        ($i -join ' ') | Should -Match 'not UP'
        ($i -join ' ') | Should -Match 'Quorum risk'
    }
    It 'is quiet for a healthy 2-node cluster with a cloud witness' {
        Mock -ModuleName AGFailoverTool Get-ClusterMembers {
            @([pscustomobject]@{ ClusterName = 'C1'; MemberName = 'VM1'; MemberType = 'CLUSTER_NODE'; MemberState = 'UP'; Votes = 1 },
              [pscustomobject]@{ ClusterName = 'C1'; MemberName = 'VM2'; MemberType = 'CLUSTER_NODE'; MemberState = 'UP'; Votes = 1 },
              [pscustomobject]@{ ClusterName = 'C1'; MemberName = 'Cloud Witness'; MemberType = 'CLOUD_WITNESS'; MemberState = 'UP'; Votes = 1 })
        }
        @(Get-ClusterIssues -VMName 'VM1' -QueryServers @('VM2')).Count | Should -Be 0
    }
}

Describe 'Get-AutoFailoverStatus' {
    It 'says NO when the only automatic partner is on the drained VM' {
        Mock -ModuleName AGFailoverTool Get-AGReplicas {
            @((New-Replica 'SQL2' -Role 'PRIMARY' -Failover 'AUTOMATIC'), (New-Replica 'SQL1' -Failover 'AUTOMATIC'), (New-Replica 'SQL3'))
        }
        Get-AutoFailoverStatus -Primary 'SQL2' -AGName 'AG1' -Excluded @('SQL1') | Should -BeLike 'NO*'
    }
    It 'says YES when another automatic partner remains' {
        Mock -ModuleName AGFailoverTool Get-AGReplicas {
            @((New-Replica 'SQL2' -Role 'PRIMARY' -Failover 'AUTOMATIC'), (New-Replica 'SQL1' -Failover 'AUTOMATIC'), (New-Replica 'SQL3' -Failover 'AUTOMATIC'))
        }
        Get-AutoFailoverStatus -Primary 'SQL2' -AGName 'AG1' -Excluded @('SQL1') | Should -BeLike 'YES*SQL3*'
    }
}

Describe 'Move-AGToBestTarget (shared drain step)' {
    BeforeEach {
        Mock -ModuleName AGFailoverTool Get-CommitRisk { $null }
        Mock -ModuleName AGFailoverTool Get-LongTransactions { @() }
        Mock -ModuleName AGFailoverTool Wait-AGResync { 'All synchronous secondaries SYNCHRONIZED' }
        Mock -ModuleName AGFailoverTool Test-AGListener { 'AG1L OK' }
        Mock -ModuleName AGFailoverTool Write-AGSnapshot { }
    }
    It 'fails over to the chosen target and records re-sync and listener results' {
        Mock -ModuleName AGFailoverTool Find-FailoverTarget { [pscustomobject]@{ Target = 'SQL2'; Candidates = @(); Reason = $null } }
        Mock -ModuleName AGFailoverTool Invoke-AGFailover { 'FAILED_OVER' }
        $m = Move-AGToBestTarget -AGName 'AG1' -FromPrimary 'SQL1' -Excluded @('SQL1')
        $m.Result   | Should -Be 'FAILED_OVER'
        $m.To       | Should -Be 'SQL2'
        $m.Listener | Should -Be 'AG1L OK'
    }
    It 'skips with the reason when there is no eligible target' {
        Mock -ModuleName AGFailoverTool Find-FailoverTarget { [pscustomobject]@{ Target = $null; Candidates = @(); Reason = 'No eligible target' } }
        Mock -ModuleName AGFailoverTool Invoke-AGFailover { throw 'must not be called' }
        $m = Move-AGToBestTarget -AGName 'AG1' -FromPrimary 'SQL1' -Excluded @('SQL1')
        $m.Result | Should -Be 'SKIPPED'
        $m.Note   | Should -Be 'No eligible target'
        Should -Invoke -ModuleName AGFailoverTool Invoke-AGFailover -Times 0
    }
    It 'marks UNKNOWN and keeps the target when the outcome is unknown' {
        Mock -ModuleName AGFailoverTool Find-FailoverTarget { [pscustomobject]@{ Target = 'SQL2'; Candidates = @(); Reason = $null } }
        Mock -ModuleName AGFailoverTool Invoke-AGFailover { throw 'OUTCOME UNKNOWN: test' }
        $m = Move-AGToBestTarget -AGName 'AG1' -FromPrimary 'SQL1' -Excluded @('SQL1')
        $m.Result | Should -Be 'UNKNOWN'
        $m.To     | Should -Be 'SQL2'
    }
}

Describe 'State files' {
    It 'keeps the previous copy and falls back to it when the file is damaged' {
        $path = Join-Path $TestDrive 'AGState_test.json'
        $state = [pscustomobject]@{ Node = 'VM1'; Status = 'DRAIN_STARTED'; LastUpdated = $null }
        Save-State -State $state -Path $path
        $state.Status = 'DRAINED'
        Save-State -State $state -Path $path
        Test-Path "$path.bak" | Should -BeTrue
        (Read-StateFile -Path $path).Status | Should -Be 'DRAINED'

        Set-Content -LiteralPath $path -Value '{ broken json'
        (Read-StateFile -Path $path).Status | Should -Be 'DRAIN_STARTED'
    }
}

Describe 'Read-PreferredPrimaries' {
    It 'reads AGName = Instance lines and ignores comments, blanks and bad lines' {
        $f = Join-Path $TestDrive 'PreferredPrimaries.txt'
        Set-Content -LiteralPath $f -Value @('# comment', '', 'AG1 = SQLVM01', 'AG2=SQLVM02\INST2', 'not a valid line')
        $m = Read-PreferredPrimaries -Path $f
        $m.Count  | Should -Be 2
        $m['AG1'] | Should -Be 'SQLVM01'
        $m['AG2'] | Should -Be 'SQLVM02\INST2'
    }
}

Describe 'Test-TransientSqlNumber' {
    It 'treats timeouts and dropped connections as transient' {
        Test-TransientSqlNumber -Numbers @(-2)    | Should -BeTrue
        Test-TransientSqlNumber -Numbers @(10054) | Should -BeTrue
    }
    It 'does not retry login or permission errors' {
        Test-TransientSqlNumber -Numbers @(18456) | Should -BeFalse
        Test-TransientSqlNumber -Numbers @(229)   | Should -BeFalse
    }
}
