# Integration tests against a TEST SQL Server instance - run by hand, never on production.
# They create and drop a test database and login, change 'cost threshold for parallelism'
# for a moment (and put it back), and set up Database Mail with a dummy SMTP account.
#   $env:SQLCI_SERVER   = 'localhost,1433'
#   $env:SQLCI_PASSWORD = '<sa password of the test instance>'
#   Invoke-Pester ./automation/tests/Integration.Tests.ps1 -Output Detailed
# They run the SQL exactly as the tools do (System.Data.SqlClient, one connection), with SQL
# authentication (sa). Nothing here touches usp_DBA_HealthPerfCheck or creates Agent jobs.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    if (-not $env:SQLCI_SERVER -or -not $env:SQLCI_PASSWORD) { throw 'Set SQLCI_SERVER and SQLCI_PASSWORD.' }
    $PrePost = Join-Path $AutomationRoot 'pre-post-check/Invoke-PrePostCheck.ps1'
    . (Join-Path $AutomationRoot 'common/DbaCommon.ps1')
    . ([scriptblock]::Create((Get-ScriptFunctionText $PrePost 'Get-Snapshot', 'Get-CheckDefinitions', 'Test-CheckDefinitions', 'Compare-Snapshots',
        'Get-FullReportHtml', 'Get-Rows', 'Get-RowKey', 'ConvertTo-Number', 'Invoke-Scalar', 'Get-MailProfileName', 'Get-DbMailState', 'Find-QueuedMail')))
    $Config = Get-ScriptConfig $PrePost
    $SqlText = [System.IO.File]::ReadAllText((Join-Path $AutomationRoot 'pre-post-check/HC_Snapshot.sql'))
    $Checks = (Get-CheckDefinitions $SqlText).Checks
    $script:RunStart = Get-Date

    function New-CiConnection([string]$Database = 'master') {
        $cs = "Server=$($env:SQLCI_SERVER);Database=$Database;User ID=sa;Password=$($env:SQLCI_PASSWORD);Encrypt=False;TrustServerCertificate=True;Connect Timeout=30;Application Name=DBA automation tests"
        $c = New-Object System.Data.SqlClient.SqlConnection $cs
        $c.Open()
        return $c
    }
    function Invoke-CiBatches($Connection, [string]$Text, [int]$TimeoutSec = 600) {
        # Runs a GO-separated script batch by batch; returns the PRINT / info messages. Stops at the first error.
        $msgs = New-Object System.Collections.ArrayList
        $h = [System.Data.SqlClient.SqlInfoMessageEventHandler] { param($s, $e) [void]$msgs.Add($e.Message) }
        $Connection.add_InfoMessage($h)
        try {
            $n = 0
            foreach ($b in (Split-SqlBatches $Text)) {
                $n++
                $cmd = $Connection.CreateCommand(); $cmd.CommandText = $b; $cmd.CommandTimeout = $TimeoutSec
                try { [void]$cmd.ExecuteNonQuery() }
                catch { throw "batch $n failed: $(Get-SqlErrorMessage $_)`n--- messages:`n$($msgs -join "`n")`n--- batch:`n$($b.Substring(0, [Math]::Min(400, $b.Length)))" }
            }
        }
        finally { $Connection.remove_InfoMessage($h) }
        return $msgs
    }
    $Conn = New-CiConnection
    Write-Host ("SQL Server: " + (Invoke-Scalar $Conn "SELECT @@VERSION"))
}

AfterAll { if ($Conn) { $Conn.Dispose() } }

Describe 'pre-post-check: HC_Snapshot.sql' {
    BeforeAll {
        $script:Snap1 = Get-Snapshot $Conn $SqlText
    }
    It 'runs without errors and returns the core sections' {
        foreach ($s in 'instance', 'config', 'databases', 'logins', 'files', 'vitals') {
            $script:Snap1.sections.ContainsKey($s) | Should -BeTrue -Because "section $s should have rows"
        }
    }
    It 'returns every column the --@check definitions name' {
        Test-CheckDefinitions $script:Snap1 $env:SQLCI_SERVER | Should -BeNullOrEmpty
    }
    It 'shows no differences when nothing changed between PRE and POST' {
        $snap2 = Get-Snapshot $Conn $SqlText
        $cmp = Compare-Snapshots $script:Snap1 $snap2
        $detail = ($cmp.Unexpected | ForEach-Object { "$($_.Section) / $($_.Item) / $($_.Attribute): $($_.Before) -> $($_.After)" }) -join '; '
        $cmp.Unexpected.Count | Should -Be 0 -Because $detail
        $newP = ($cmp.NewProblems | ForEach-Object { "$($_['area']) / $($_['item'])" }) -join '; '
        $cmp.NewProblems.Count | Should -Be 0 -Because $newP
    }
    It 'finds a new database, a changed setting and a new login made between PRE and POST' {
        $ctp = [int](Invoke-Scalar $Conn "SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'cost threshold for parallelism'")
        try {
            [void](Invoke-CiBatches $Conn @"
CREATE DATABASE CI_PrePost_New;
GO
EXEC sys.sp_configure N'show advanced options', 1; RECONFIGURE;
EXEC sys.sp_configure N'cost threshold for parallelism', $($ctp + 7); RECONFIGURE;
GO
CREATE LOGIN ci_prepost_login WITH PASSWORD = N'Ci_Pre_Post_9f3!x', CHECK_POLICY = OFF;
"@)
            $after = Get-Snapshot $Conn $SqlText
            $cmp = Compare-Snapshots $script:Snap1 $after
            $u = @($cmp.Unexpected | ForEach-Object { "$($_.Section)|$($_.Item)|$($_.Attribute)|$($_.After)" })
            $u | Should -Contain "$($Checks['databases'].Title)|CI_PrePost_New|(row)|NEW"
            $u | Should -Contain "$($Checks['config'].Title)|cost threshold for parallelism|value_in_use|$($ctp + 7)"
            $u | Should -Contain "$($Checks['logins'].Title)|ci_prepost_login|(row)|NEW"
        }
        finally {
            [void](Invoke-CiBatches $Conn @"
IF DB_ID(N'CI_PrePost_New') IS NOT NULL DROP DATABASE CI_PrePost_New;
IF SUSER_ID(N'ci_prepost_login') IS NOT NULL DROP LOGIN ci_prepost_login;
EXEC sys.sp_configure N'cost threshold for parallelism', $ctp; RECONFIGURE;
"@)
        }
    }
    It 'renders the report' {
        $html = Get-FullReportHtml $script:Snap1
        $html | Should -Match '<h3>Instance</h3>'
        $html | Should -Match '<h3>sp_configure</h3>'
        $html | Should -Not -Match 'no --@check definition'
    }
}

Describe 'Database Mail (setup script, profile detection, sending)' {
    BeforeAll {
        $script:MailSkip = $null
        try {
            $setup = [System.IO.File]::ReadAllText((Join-Path $AutomationRoot 'perf-check-reports/database_mail_setup.sql'))
            $script:MailMsgs = Invoke-CiBatches $Conn $setup 300
        }
        catch { $script:MailSkip = $_.Exception.Message }
    }
    It 'database_mail_setup.sql runs batch by batch (as Invoke-PrePostCheck runs db_mail_setup.sql)' {
        if ($script:MailSkip -match 'not supported|platform|Linux') { Set-ItResult -Skipped -Because $script:MailSkip; return }
        $script:MailSkip | Should -BeNullOrEmpty
    }
    It 'Get-MailProfileName and Get-DbMailState see the profile' {
        if ($script:MailSkip) { Set-ItResult -Skipped -Because 'Database Mail setup did not run'; return }
        $st = Get-DbMailState $Conn
        $st.XpsOn | Should -BeTrue
        $st.Usable | Should -BeGreaterOrEqual 1
        Get-MailProfileName $Conn | Should -Not -BeNullOrEmpty
    }
    It 'Send-DbMailItem queues a mail item and Get-DbMailItemStatus reads it back' {
        if ($script:MailSkip) { Set-ItResult -Skipped -Because 'Database Mail setup did not run'; return }
        $prof = Get-MailProfileName $Conn
        $id = Send-DbMailItem -Connection $Conn -ProfileName $prof -Recipients 'test@example.invalid' -Subject "Automation test $(Get-Date -Format o)" -Body '<b>test</b>'
        $id | Should -BeGreaterThan 0
        Get-DbMailItemStatus $Conn $id | Should -Match '^(unsent|sent|retrying|failed)'
    }
}
